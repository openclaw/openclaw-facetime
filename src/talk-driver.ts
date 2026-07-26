import type { OpenClawConfig } from "openclaw/plugin-sdk/config-types";
import { resolveDefaultAgentId } from "openclaw/plugin-sdk/agent-runtime";
import { abortAgentHarnessRun } from "openclaw/plugin-sdk/agent-harness";
import type { PluginRuntime, RuntimeLogger } from "openclaw/plugin-sdk/plugin-runtime";
import { resolveRealtimeBootstrapContextInstructions } from "openclaw/plugin-sdk/realtime-bootstrap-context";
import * as realtimeVoiceSdk from "openclaw/plugin-sdk/realtime-voice";
import {
  buildRealtimeVoiceAgentConsultPolicyInstructions,
  buildRealtimeVoiceAgentCancelProviderResult,
  buildRealtimeVoiceAgentConsultWorkingResponse,
  consultRealtimeVoiceAgent,
  createRealtimeVoiceBridgeSession,
  createTalkSessionController,
  REALTIME_VOICE_AGENT_CONSULT_TOOL_NAME,
  REALTIME_VOICE_AUDIO_FORMAT_PCM16_24KHZ,
  recordTalkObservabilityEvent,
  resolveConfiguredRealtimeVoiceProvider,
  resolveRealtimeVoiceAgentConsultTools,
  resolveRealtimeVoiceAgentConsultToolsAllow,
  type RealtimeVoiceBridgeSession,
  type RealtimeVoiceToolCallEvent,
  type TalkEvent,
  type TalkEventInput,
} from "openclaw/plugin-sdk/realtime-voice";
import { resolveConfiguredSecretInputString } from "openclaw/plugin-sdk/secret-input-runtime";
import { startFaceTimeAudioPump, type FaceTimeAudioPump } from "./audio-pump.js";
import type { FaceTimeConfig } from "./config.js";
import { formatErrorMessage } from "./errors.js";
import {
  PCM16_MONO_24KHZ_BYTES_PER_MILLISECOND,
  resolvePlaybackMediaTimestamp,
} from "./playback-clock.js";

export type FaceTimeTalkDriver = {
  readonly callUUID: string;
  readonly recentTalkEvents: readonly TalkEvent[];
  readyForAudio(): Promise<void>;
  processOutputSuppressed(): boolean;
  activate(): void;
  close(reason?: string): Promise<void>;
};

type TranscriptEntry = { role: "user" | "assistant"; text: string };
type AuthenticatedOwnerConsultParams = Parameters<typeof consultRealtimeVoiceAgent>[0] & {
  senderId: string;
  senderIsOwner: true;
};
type SenderAuthCapableRealtimeVoiceSdk = {
  REALTIME_VOICE_AGENT_CONSULT_SENDER_AUTH_VERSION?: unknown;
};

const CONSULT_SYSTEM_PROMPT = [
  "You are the configured OpenClaw agent receiving a delegated request from an authenticated owner in a private 1:1 FaceTime call.",
  "The authenticated caller is the configured owner/user described by this agent's workspace context, including USER.md. When asked who is speaking, identify them from that workspace context without asking them to reconfirm.",
  "Use the normal workspace, memory, tools, and approval policies for this agent.",
  "Prefer registered OpenClaw tools over exec.",
  "Never claim completion unless the relevant tool result confirms it.",
  "Return a concise, speakable answer suitable for realtime TTS.",
].join(" ");
const INPUT_AUDIO_STATUS_INTERVAL_MS = 1000;
// FaceTime carries audio but is not an OpenClaw message channel. Approval
// followups validate this field, so use the always-registered internal channel.
const AGENT_CONSULT_MESSAGE_PROVIDER = "webchat";

function pushRecent(events: TalkEvent[], event: TalkEvent | undefined): void {
  if (!event) {
    return;
  }
  events.push(event);
  if (events.length > 40) {
    events.splice(0, events.length - 40);
  }
}

function assertAuthenticatedSenderConsultSupport(): void {
  const version = (realtimeVoiceSdk as SenderAuthCapableRealtimeVoiceSdk)
    .REALTIME_VOICE_AGENT_CONSULT_SENDER_AUTH_VERSION;
  if (version !== 1) {
    throw new Error(
      "OpenClaw host does not support authenticated sender identity for realtime agent consults; update OpenClaw before enabling FaceTime",
    );
  }
}

function agentIdFromSessionKey(sessionKey: string, config: OpenClawConfig): string {
  const normalized = sessionKey.trim();
  if (normalized.startsWith("agent:")) {
    return normalized.split(":")[1] || resolveDefaultAgentId(config);
  }
  return resolveDefaultAgentId(config);
}

function buildRealtimeInstructions(params: {
  instructions: string | undefined;
  bootstrapContext: string | undefined;
  toolPolicy: FaceTimeConfig["realtime"]["toolPolicy"];
}): string {
  const proxyInstructions =
    params.toolPolicy === "none"
      ? undefined
      : [
          "Mode: OpenClaw agent proxy.",
          "You are the realtime voice surface for the same configured OpenClaw agent the owner can message directly.",
          "The FaceTime caller is the authenticated owner/user described by the loaded workspace profile context. Recognize them from that context without asking them to reconfirm.",
          "Do not mention a backend, supervisor, helper, or separate system. Present the result as your own work.",
          `Delegate substantive requests, actions, tool work, current facts, memory, workspace context, identity, persona, and user-specific context with ${REALTIME_VOICE_AGENT_CONSULT_TOOL_NAME}.`,
          "Do not block, refuse, or downscope at the voice layer. Delegate to OpenClaw and treat its result as authoritative.",
          'While waiting for a tool result, use at most one short natural backchannel such as "one sec"; do not repeat progress updates or treat it as the final answer.',
          "Never claim you retried or are retrying unless a new tool result explicitly confirms a new attempt.",
          buildRealtimeVoiceAgentConsultPolicyInstructions({
            toolPolicy: params.toolPolicy,
            consultPolicy: "always",
          }),
        ]
          .filter(Boolean)
          .join("\n");
  return [params.instructions?.trim(), params.bootstrapContext?.trim(), proxyInstructions]
    .filter(Boolean)
    .join("\n\n");
}

async function resolveRealtimeProviderConfigs(params: {
  config: FaceTimeConfig;
  fullConfig: OpenClawConfig;
}): Promise<Record<string, Record<string, unknown>>> {
  const providers: Record<string, Record<string, unknown>> = {};
  for (const [providerId, providerConfig] of Object.entries(params.config.realtime.providers)) {
    const next = { ...providerConfig };
    if ("apiKey" in next) {
      const resolved = await resolveConfiguredSecretInputString({
        config: params.fullConfig,
        env: process.env,
        value: next.apiKey,
        path: `plugins.entries.facetime.config.realtime.providers.${providerId}.apiKey`,
      });
      if (resolved.value) {
        next.apiKey = resolved.value;
      }
    }
    providers[providerId] = next;
  }
  return providers;
}

export async function startFaceTimeTalkDriver(params: {
  config: FaceTimeConfig;
  fullConfig: OpenClawConfig;
  runtime: PluginRuntime;
  logger: RuntimeLogger;
  callUUID: string;
  senderId: string;
  senderIsOwner: true;
  captureBinary: string;
  signal?: AbortSignal;
  onFailure?: (error: Error) => boolean | Promise<boolean>;
}): Promise<FaceTimeTalkDriver> {
  if (params.signal?.aborted) {
    throw new Error("FaceTime talk startup aborted");
  }
  // Fail closed before the call is answered; older hosts silently ignore the
  // owner fields and would otherwise create a privilege-downgrade footgun.
  assertAuthenticatedSenderConsultSupport();
  const providerConfigs = await resolveRealtimeProviderConfigs({
    config: params.config,
    fullConfig: params.fullConfig,
  });
  const resolved = resolveConfiguredRealtimeVoiceProvider({
    configuredProviderId: params.config.realtime.provider,
    providerConfigs: {
      ...providerConfigs,
      [params.config.realtime.provider]: {
        ...(providerConfigs[params.config.realtime.provider] ?? {}),
        voice: params.config.realtime.voice,
      },
    },
    cfg: params.fullConfig,
    defaultModel: params.config.realtime.model,
    noRegisteredProviderMessage: "No realtime voice provider registered",
  });
  const consultAgentId = agentIdFromSessionKey(
    params.config.realtime.sessionKey,
    params.fullConfig,
  );
  const normalizedCallUUID = params.callUUID.trim().toLowerCase();
  const consultSessionKey = `agent:${consultAgentId}:facetime:${normalizedCallUUID}`;
  const requesterSessionKey = params.config.realtime.sessionKey.startsWith("agent:")
    ? params.config.realtime.sessionKey
    : `agent:${consultAgentId}:${params.config.realtime.sessionKey}`;
  let bootstrapContext: string | undefined;
  try {
    bootstrapContext = await resolveRealtimeBootstrapContextInstructions({
      config: params.fullConfig,
      agentId: consultAgentId,
      sessionKey: requesterSessionKey,
      warn: (message) =>
        params.logger.warn?.(`[facetime] realtime bootstrap context: ${message}`),
    });
  } catch (error) {
    params.logger.warn?.(
      `[facetime] realtime bootstrap context unavailable: ${formatErrorMessage(error)}`,
    );
  }
  const talk = createTalkSessionController(
    {
      sessionId: `facetime:${params.callUUID}`,
      mode: "realtime",
      transport: "gateway-relay",
      brain: "agent-consult",
      provider: resolved.provider.id,
      turnIdPrefix: `facetime:${params.callUUID}:turn`,
    },
    { onEvent: recordTalkObservabilityEvent },
  );
  const recentTalkEvents: TalkEvent[] = [];
  const transcript: TranscriptEntry[] = [];
  let stopped = false;
  let bridge: RealtimeVoiceBridgeSession | undefined;
  let pump: FaceTimeAudioPump | undefined;
  let lastInputAudioStatusAt = 0;
  let callMediaTimestampMs = 0;
  let responseStartTimestampMs: number | undefined;
  let responsePlaybackStartMs: number | undefined;
  let responseGenerationDone = false;
  const pendingAgentConsults = new Map<
    string,
    {
      callId: string;
      turnId: string;
      name: string;
      cancelRequested: boolean;
      backendSettled: boolean;
    }
  >();
  let failurePromise: Promise<boolean> | undefined;
  let activated = false;
  let closePromise: Promise<void> | undefined;
  let startupSettled = false;
  let startupFailure: Error | undefined;
  let rejectStartupFailure: ((error: Error) => void) | undefined;
  const startupFailurePromise = new Promise<never>((_resolve, reject) => {
    rejectStartupFailure = reject;
  });
  // A provider or audio callback can fail while connect() is still pending.
  // Keep that failure observable until startup either rejects or returns a live driver.
  void startupFailurePromise.catch(() => {});

  const signalStartupFailure = (error: Error) => {
    if (startupSettled || startupFailure) {
      return;
    }
    startupFailure = error;
    rejectStartupFailure?.(error);
  };

  const reportFailure = (error: Error): Promise<boolean> => {
    if (failurePromise) {
      return failurePromise;
    }
    failurePromise = Promise.resolve(params.onFailure?.(error)).then((safeToClose) => {
      return safeToClose !== false;
    });
    return failurePromise;
  };

  const close = async (reason = "closed") => {
    if (closePromise) {
      return await closePromise;
    }
    stopped = true;
    abortPendingAgentConsultsForClose();
    closePromise = (async () => {
      try {
        bridge?.close();
      } catch (error) {
        params.logger.debug?.(
          `[facetime] realtime bridge close ignored: ${formatErrorMessage(error)}`,
        );
      }
      await pump?.stop();
      remember({ type: "session.closed", payload: { reason }, final: true });
    })();
    return await closePromise;
  };

  const remember = (input: TalkEventInput) => pushRecent(recentTalkEvents, talk.emit(input));
  const ensureTurn = () => {
    const turn = talk.ensureTurn({ payload: { callUUID: params.callUUID } });
    pushRecent(recentTalkEvents, turn.event);
    return turn.turnId;
  };
  const finishOutputAudio = (reason: string) => {
    pushRecent(recentTalkEvents, talk.finishOutputAudio({ payload: { reason } }));
  };
  const endTurn = (reason: string) => {
    const ended = talk.endTurn({ payload: { reason } });
    if (ended.ok) {
      pushRecent(recentTalkEvents, ended.event);
    }
  };
  const playedCurrentResponseMs = () =>
    responsePlaybackStartMs === undefined
      ? 0
      : Math.max(0, (pump?.playedAudioMs() ?? 0) - responsePlaybackStartMs);
  const resetResponsePlayback = () => {
    responseStartTimestampMs = undefined;
    responsePlaybackStartMs = undefined;
    responseGenerationDone = false;
  };
  const finishDrainedResponse = () => {
    if (responseStartTimestampMs === undefined) {
      return;
    }
    callMediaTimestampMs = Math.max(
      callMediaTimestampMs,
      responseStartTimestampMs + playedCurrentResponseMs(),
    );
    bridge?.setMediaTimestamp(Math.floor(callMediaTimestampMs));
    resetResponsePlayback();
    finishOutputAudio("playback-drained");
    endTurn("response.done");
  };
  const submitToolError = (event: RealtimeVoiceToolCallEvent, error: string) => {
    const callId = event.callId || event.itemId;
    remember({
      type: "tool.error",
      callId,
      payload: { name: event.name, error },
      final: true,
    });
    bridge?.submitToolResult(callId, { error });
  };
  const abortPendingAgentConsult = async (pending: {
    cancelRequested: boolean;
    backendSettled: boolean;
  }) => {
    const storePath = params.runtime.agent.session.resolveStorePath(
      params.fullConfig.session?.store,
      {
        agentId: consultAgentId,
      },
    );
    // Session creation and run registration are asynchronous. Keep looking
    // until the cancelled backend settles. Unref each retry so a provider that
    // never settles cannot keep gateway shutdown alive.
    let retryDelayMs = 25;
    while (pending.cancelRequested && !pending.backendSettled) {
      try {
        const sessionEntry = params.runtime.agent.session.getSessionEntry({
          storePath,
          sessionKey: consultSessionKey,
          readConsistency: "latest",
        });
        const sessionId = sessionEntry?.sessionId?.trim();
        if (sessionId && abortAgentHarnessRun(sessionId)) {
          return;
        }
      } catch (error) {
        params.logger.debug?.(
          `[facetime] agent consult abort lookup retry: ${formatErrorMessage(error)}`,
        );
      }
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, retryDelayMs);
        timer.unref?.();
      });
      retryDelayMs = Math.min(retryDelayMs * 2, 1_000);
    }
  };
  function abortPendingAgentConsultsForClose() {
    for (const pending of pendingAgentConsults.values()) {
      pending.cancelRequested = true;
      pendingAgentConsults.delete(pending.callId);
      void abortPendingAgentConsult(pending);
    }
  }
  const cancelPendingAgentConsults = () => {
    for (const pending of pendingAgentConsults.values()) {
      if (pending.cancelRequested) {
        continue;
      }
      pending.cancelRequested = true;
      void abortPendingAgentConsult(pending);
      const result = buildRealtimeVoiceAgentCancelProviderResult(
        "The caller continued speaking before this consult completed.",
      );
      void (async () => {
        try {
          if (!bridge) {
            throw new Error("Realtime bridge unavailable during agent consult cancellation");
          }
          const options =
            bridge.bridge.supportsToolResultSuppression === false
              ? undefined
              : { suppressResponse: true };
          await bridge.submitToolResult(pending.callId, result, options);
          if (pendingAgentConsults.get(pending.callId) !== pending) {
            return;
          }
          pendingAgentConsults.delete(pending.callId);
          remember({
            type: "tool.result",
            turnId: pending.turnId,
            callId: pending.callId,
            payload: { name: pending.name, result },
            final: true,
          });
        } catch (error) {
          if (pendingAgentConsults.get(pending.callId) !== pending) {
            return;
          }
          pendingAgentConsults.delete(pending.callId);
          const normalized = error instanceof Error ? error : new Error(String(error));
          remember({
            type: "tool.error",
            turnId: pending.turnId,
            callId: pending.callId,
            payload: { name: pending.name, error: formatErrorMessage(normalized) },
            final: true,
          });
          const safeToClose = await reportFailure(normalized);
          if (safeToClose) {
            await close("consult-cancel-failed");
          }
        }
      })();
    }
  };
  const handleToolCall = (event: RealtimeVoiceToolCallEvent) => {
    const callId = event.callId || event.itemId;
    if (event.name !== REALTIME_VOICE_AGENT_CONSULT_TOOL_NAME) {
      submitToolError(event, `Tool "${event.name}" not available`);
      return;
    }
    const turnId = ensureTurn();
    const pendingConsult = {
      callId,
      turnId,
      name: event.name,
      cancelRequested: false,
      backendSettled: false,
    };
    pendingAgentConsults.set(callId, pendingConsult);
    remember({
      type: "tool.call",
      turnId,
      itemId: event.itemId,
      callId,
      payload: { name: event.name, args: event.args },
    });
    remember({
      type: "tool.progress",
      turnId,
      callId,
      payload: { name: event.name, status: "working" },
    });
    if (bridge?.bridge.supportsToolResultContinuation) {
      bridge.submitToolResult(callId, buildRealtimeVoiceAgentConsultWorkingResponse("caller"), {
        willContinue: true,
      });
    }
    // Keep compatibility with hosts whose declarations predate these additive
    // fields; updated OpenClaw runtimes forward both into runEmbeddedAgent.
    void (consultRealtimeVoiceAgent as (params: AuthenticatedOwnerConsultParams) => Promise<{
      text: string;
    }>)({
      cfg: params.fullConfig,
      agentRuntime: params.runtime.agent,
      logger: params.logger,
      agentId: consultAgentId,
      sessionKey: consultSessionKey,
      spawnedBy: requesterSessionKey,
      senderId: params.senderId,
      senderIsOwner: params.senderIsOwner,
      contextMode: "fork",
      messageProvider: AGENT_CONSULT_MESSAGE_PROVIDER,
      lane: `facetime:${normalizedCallUUID}`,
      runIdPrefix: `facetime:${normalizedCallUUID}`,
      args: event.args,
      transcript,
      surface: "a private FaceTime call",
      userLabel: "Caller",
      assistantLabel: "Assistant",
      questionSourceLabel: "caller",
      toolsAllow: resolveRealtimeVoiceAgentConsultToolsAllow(params.config.realtime.toolPolicy),
      extraSystemPrompt: CONSULT_SYSTEM_PROMPT,
    })
      .then((result) => {
        pendingConsult.backendSettled = true;
        if (pendingAgentConsults.get(callId) !== pendingConsult || pendingConsult.cancelRequested) {
          return;
        }
        pendingAgentConsults.delete(callId);
        remember({
          type: "tool.result",
          turnId,
          callId,
          payload: { name: event.name, result },
          final: true,
        });
        bridge?.submitToolResult(callId, result);
      })
      .catch((error: Error) => {
        pendingConsult.backendSettled = true;
        if (pendingAgentConsults.get(callId) !== pendingConsult || pendingConsult.cancelRequested) {
          return;
        }
        pendingAgentConsults.delete(callId);
        const message = formatErrorMessage(error);
        params.logger.warn?.(`[facetime] agent consult failed: ${message}`);
        remember({
          type: "tool.error",
          turnId,
          callId,
          payload: { name: event.name, error: message },
          final: true,
        });
        bridge?.submitToolResult(callId, { error: message });
      });
  };

  remember({ type: "session.started", payload: { callUUID: params.callUUID } });
  pump = startFaceTimeAudioPump({
    captureBinary: params.captureBinary,
    logger: params.logger,
    onInputAudio(audio) {
      if (stopped || !activated) {
        return;
      }
      callMediaTimestampMs += audio.byteLength / PCM16_MONO_24KHZ_BYTES_PER_MILLISECOND;
      if (!talk.outputAudioActive) {
        bridge?.setMediaTimestamp(Math.floor(callMediaTimestampMs));
      }
      const now = Date.now();
      if (now - lastInputAudioStatusAt >= INPUT_AUDIO_STATUS_INTERVAL_MS) {
        lastInputAudioStatusAt = now;
        remember({
          type: "input.audio.delta",
          turnId: ensureTurn(),
          payload: { byteLength: audio.byteLength },
        });
      }
      bridge?.sendAudio(audio);
    },
    async onError(error) {
      signalStartupFailure(error);
      remember({
        type: "session.error",
        payload: { message: formatErrorMessage(error) },
        final: true,
      });
      const safeToClose = await reportFailure(error);
      if (safeToClose) {
        await close("audio-error");
      }
      return safeToClose;
    },
    onPlaybackDrained() {
      if (responseGenerationDone) {
        finishDrainedResponse();
      }
    },
  });
  try {
    await Promise.race([pump.suppressionReady(), startupFailurePromise]);
  } catch (error) {
    const normalized = error instanceof Error ? error : new Error(String(error));
    const safeToClose = startupFailure === normalized ? await reportFailure(normalized) : true;
    if (safeToClose) {
      await close("capture-start-failed");
    }
    throw error;
  }
  try {
    bridge = createRealtimeVoiceBridgeSession({
      provider: resolved.provider,
      providerConfig: resolved.providerConfig,
      audioFormat: REALTIME_VOICE_AUDIO_FORMAT_PCM16_24KHZ,
      // Configured voice/personality instructions remain customizable, but the
      // authoritative-agent boundary must not disappear when they are replaced.
      instructions: buildRealtimeInstructions({
        instructions: params.config.realtime.instructions,
        bootstrapContext,
        toolPolicy: params.config.realtime.toolPolicy,
      }),
      autoRespondToAudio: true,
      triggerGreetingOnReady: false,
      initialGreetingInstructions: "Greet the caller briefly and say you are listening.",
      markStrategy: "ack-immediately",
      tools: resolveRealtimeVoiceAgentConsultTools(params.config.realtime.toolPolicy),
      audioSink: {
        isOpen: () => !stopped,
        sendAudio(audio) {
          const turnId = ensureTurn();
          if (!talk.outputAudioActive) {
            responseStartTimestampMs = callMediaTimestampMs;
            responsePlaybackStartMs = pump?.generatedAudioMs() ?? 0;
            responseGenerationDone = false;
            bridge?.setMediaTimestamp(Math.floor(callMediaTimestampMs));
          }
          pushRecent(
            recentTalkEvents,
            talk.startOutputAudio({ turnId, payload: { callUUID: params.callUUID } }).event,
          );
          remember({
            type: "output.audio.delta",
            turnId,
            payload: { byteLength: audio.byteLength },
          });
          pump?.writeOutputAudio(audio);
        },
        clearAudio() {
          pump?.clearOutputAudio();
          resetResponsePlayback();
          finishOutputAudio("clear");
        },
      },
      onTranscript(role, text, final) {
        const turnId = ensureTurn();
        remember({
          type:
            role === "assistant"
              ? final
                ? "output.text.done"
                : "output.text.delta"
              : final
                ? "transcript.done"
                : "transcript.delta",
          turnId,
          payload: role === "assistant" ? { text } : { role, text },
          final,
        });
        if (role === "user" && final) {
          remember({
            type: "input.audio.committed",
            turnId,
            payload: { callUUID: params.callUUID },
            final: true,
          });
        }
        if (final) {
          transcript.push({ role, text });
          if (transcript.length > 40) {
            transcript.splice(0, transcript.length - 40);
          }
        }
      },
      onEvent(event) {
        if (!(event.direction === "client" && event.type === "input_audio_buffer.append")) {
          remember({
            type: "health.changed",
            payload: {
              name: `${event.direction}:${event.type}`,
              message: event.detail,
            },
          });
        }
        if (event.type === "input_audio_buffer.speech_started") {
          // A caller follow-up supersedes any consult started for the previous
          // utterance. Close its provider tool call immediately so a slow agent
          // cannot block the new turn, then ignore its eventual settlement.
          cancelPendingAgentConsults();
          const playbackActive =
            responseStartTimestampMs !== undefined && (pump?.queuedAudioMs() ?? 0) > 0;
          if (responseStartTimestampMs !== undefined) {
            bridge?.setMediaTimestamp(
              resolvePlaybackMediaTimestamp({
                responseStartTimestampMs,
                playedAudioMs: playedCurrentResponseMs(),
              }),
            );
          }
          bridge?.handleBargeIn({ audioPlaybackActive: playbackActive });
          if (playbackActive || talk.outputAudioActive) {
            pump?.clearOutputAudio();
            finishOutputAudio("barge-in");
          }
          resetResponsePlayback();
        } else if (event.type === "response.done") {
          responseGenerationDone = true;
          if (responseStartTimestampMs === undefined) {
            finishOutputAudio("response.done");
            endTurn("response.done");
          } else if ((pump?.queuedAudioMs() ?? 0) === 0) {
            finishDrainedResponse();
          }
        } else if (event.type === "error") {
          remember({
            type: "session.error",
            payload: { message: event.detail ?? "Realtime provider error" },
            final: true,
          });
        }
      },
      onToolCall: handleToolCall,
      onReady() {
        remember({ type: "session.ready", payload: { callUUID: params.callUUID } });
      },
      onError(error) {
        signalStartupFailure(error);
        remember({
          type: "session.error",
          payload: { message: formatErrorMessage(error) },
          final: true,
        });
        params.logger.warn(`[facetime] realtime bridge failed: ${formatErrorMessage(error)}`);
        void reportFailure(error).then(async (safeToClose) => {
          if (safeToClose) {
            await close("error");
          }
        });
      },
      onClose(reason) {
        finishOutputAudio(reason);
        remember({ type: "session.closed", payload: { reason }, final: true });
        if (!stopped) {
          const error = new Error(`Realtime bridge closed unexpectedly: ${reason}`);
          signalStartupFailure(error);
          void reportFailure(error).then(async (safeToClose) => {
            if (safeToClose) {
              await close("provider-closed");
            }
          });
        }
      },
    });
  } catch (error) {
    const normalized = error instanceof Error ? error : new Error(String(error));
    const safeToClose = await reportFailure(normalized);
    if (safeToClose) {
      await close("session-create-failed");
    }
    throw error;
  }

  let abortConnect: (() => void) | undefined;
  try {
    const connectPromise = bridge.connect();
    const abortPromise = new Promise<never>((_resolve, reject) => {
      abortConnect = () => reject(new Error("FaceTime talk startup aborted"));
      params.signal?.addEventListener("abort", abortConnect, { once: true });
      if (params.signal?.aborted) {
        abortConnect();
      }
    });
    await Promise.race([
      connectPromise,
      startupFailurePromise,
      ...(params.signal ? [abortPromise] : []),
    ]);
    if (params.signal?.aborted) {
      throw new Error("FaceTime talk startup aborted");
    }
    if (startupFailure) {
      throw startupFailure;
    }
    startupSettled = true;
  } catch (error) {
    const normalized = error instanceof Error ? error : new Error(String(error));
    const safeToClose = params.signal?.aborted ? true : await reportFailure(normalized);
    if (safeToClose) {
      await close(params.signal?.aborted ? "startup-aborted" : "connect-failed");
    }
    throw error;
  } finally {
    if (abortConnect) {
      params.signal?.removeEventListener("abort", abortConnect);
    }
  }
  return {
    callUUID: params.callUUID,
    get recentTalkEvents() {
      return recentTalkEvents;
    },
    async readyForAudio() {
      await pump?.routeReady();
    },
    processOutputSuppressed() {
      return pump?.processOutputSuppressed() ?? false;
    },
    activate() {
      if (stopped || activated) {
        return;
      }
      activated = true;
      bridge?.triggerGreeting("Greet the caller briefly and say you are listening.");
    },
    close,
  };
}
