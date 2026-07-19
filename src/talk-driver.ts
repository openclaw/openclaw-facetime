import type { OpenClawConfig } from "openclaw/plugin-sdk/config-types";
import type { PluginRuntime, RuntimeLogger } from "openclaw/plugin-sdk/plugin-runtime";
import {
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

const CONSULT_SYSTEM_PROMPT = [
  "You are Lobster's main agent being consulted from a private 1:1 FaceTime voice call.",
  "Act on behalf of Omar with normal memory and tool access.",
  "Return a concise, speakable answer suitable for realtime TTS.",
].join(" ");
const INPUT_AUDIO_STATUS_INTERVAL_MS = 1000;

function pushRecent(events: TalkEvent[], event: TalkEvent | undefined): void {
  if (!event) {
    return;
  }
  events.push(event);
  if (events.length > 40) {
    events.splice(0, events.length - 40);
  }
}

function agentIdFromSessionKey(sessionKey: string): string {
  const normalized = sessionKey.trim();
  if (normalized.startsWith("agent:")) {
    return normalized.split(":")[1] || "main";
  }
  return "main";
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
  captureBinary: string;
  signal?: AbortSignal;
  onFailure?: (error: Error) => boolean | Promise<boolean>;
}): Promise<FaceTimeTalkDriver> {
  if (params.signal?.aborted) {
    throw new Error("FaceTime talk startup aborted");
  }
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
  const handleToolCall = (event: RealtimeVoiceToolCallEvent) => {
    const callId = event.callId || event.itemId;
    if (event.name !== REALTIME_VOICE_AGENT_CONSULT_TOOL_NAME) {
      submitToolError(event, `Tool "${event.name}" not available`);
      return;
    }
    const turnId = ensureTurn();
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
    void consultRealtimeVoiceAgent({
      cfg: params.fullConfig,
      agentRuntime: params.runtime.agent,
      logger: params.logger,
      agentId: agentIdFromSessionKey(params.config.realtime.sessionKey),
      sessionKey: params.config.realtime.sessionKey,
      messageProvider: "facetime",
      lane: "facetime",
      runIdPrefix: `facetime:${params.callUUID}`,
      args: event.args,
      transcript,
      surface: "a private FaceTime call",
      userLabel: "Caller",
      assistantLabel: "Lobster",
      questionSourceLabel: "caller",
      toolsAllow: resolveRealtimeVoiceAgentConsultToolsAllow(params.config.realtime.toolPolicy),
      extraSystemPrompt: CONSULT_SYSTEM_PROMPT,
    })
      .then((result) => {
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
        const message = formatErrorMessage(error);
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
      instructions: params.config.realtime.instructions,
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
