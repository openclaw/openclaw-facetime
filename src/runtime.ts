import { constants } from "node:fs";
import { access } from "node:fs/promises";
import type { OpenClawConfig } from "openclaw/plugin-sdk/config-types";
import type { PluginRuntime, RuntimeLogger } from "openclaw/plugin-sdk/plugin-runtime";
import { OPENCLAW_FEED_DEVICE, OPENCLAW_MIC_DEVICE } from "./audio-pump.js";
import {
  isActiveCall,
  isEndedCall,
  isIncomingRingingCall,
  isWhitelistedFaceTimeCall,
  normalizeFaceTimeCallEvent,
  normalizeFaceTimeHandle,
  normalizeFaceTimeHandleCandidates,
  type FaceTimeCallStatusEvent,
} from "./call-events.js";
import { resolveFaceTimeConfig, validateFaceTimeConfig, type FaceTimeConfig } from "./config.js";
import { formatErrorMessage } from "./errors.js";
import { FaceTimeHelperSocketServer, type HelperActionResult } from "./helper-rpc.js";
import { assertPairedAudioTransport } from "./paired-audio-transport.js";
import { ensureCaptureBinary } from "./plugin-paths.js";
import { runFaceTimePreflight, type FaceTimePreflightResult } from "./preflight.js";
import { startFaceTimeTalkDriver, type FaceTimeTalkDriver } from "./talk-driver.js";
import { summarizeRecentTalkEvents, type FaceTimeTalkEventSummary } from "./talk-events-summary.js";
import { playFaceTimeTestAudio } from "./test-audio.js";

type ActiveFaceTimeCall = {
  callUUID: string;
  lifecycleAbort: AbortController;
  handle?: string;
  callStatus?: number;
  isSendingAudio?: boolean;
  isSendingTransmission?: boolean;
  isUplinkMuted?: boolean;
  isSendingVideo?: boolean;
  conversationUUID?: string;
  conversationGroupUUID?: string;
  conversationAudioEnabled?: boolean;
  conversationVideoEnabled?: boolean;
  conversationAVMode?: number;
  conversationResolvedAudioVideoMode?: number;
  audioReady: boolean;
  audioTransport?: {
    captureBinary: string;
    feedDevice: string;
    microphoneDevice: string;
    processInputVerified: boolean;
    processOutputSuppressed: boolean;
  };
  lastHelperAction?: HelperActionResult;
  lastRoutingError?: string;
  audioRouting?: Promise<void>;
  talk?: FaceTimeTalkDriver;
  talkStarting?: Promise<void>;
  talkActivation?: Promise<void>;
  audioEnabled?: boolean;
  audioEnablePromise?: Promise<void>;
  unmuteRequested?: boolean;
  carrierHangupPending?: boolean;
  carrierHangupRetryTimer?: NodeJS.Timeout;
};

export type FaceTimeRuntimeStatus = {
  enabled: true;
  helperConnected: boolean;
  processOutputSuppressed: boolean;
  calls: Array<{
    callUUID: string;
    handle?: string;
    callStatus?: number;
    isSendingAudio?: boolean;
    isSendingTransmission?: boolean;
    isUplinkMuted?: boolean;
    isSendingVideo?: boolean;
    conversationUUID?: string;
    conversationGroupUUID?: string;
    conversationAudioEnabled?: boolean;
    conversationVideoEnabled?: boolean;
    conversationAVMode?: number;
    conversationResolvedAudioVideoMode?: number;
    realtimeActive: boolean;
    audioReady: boolean;
    audioTransport?: ActiveFaceTimeCall["audioTransport"];
    lastHelperAction?: HelperActionResult;
    lastRoutingError?: string;
    carrierHangupPending?: boolean;
    recentTalkEvents?: FaceTimeTalkEventSummary[];
  }>;
};

export type FaceTimeRuntime = {
  config: FaceTimeConfig;
  status(): Promise<FaceTimeRuntimeStatus>;
  preflight(): Promise<FaceTimePreflightResult>;
  hangup(params?: { callUUID?: unknown }): Promise<{ callUUID: string }>;
  testAudio(params?: { phrase?: unknown }): Promise<{ phrase: string; deviceName: string }>;
  stop(): Promise<void>;
};

function readCallUUID(event: FaceTimeCallStatusEvent): string {
  return String(event.data.call_uuid);
}

function isCarrierAlreadyGoneError(error: unknown): boolean {
  const message = formatErrorMessage(error);
  return /call not found|not waiting to be left/iu.test(message);
}

function updateCallStatus(call: ActiveFaceTimeCall, event: FaceTimeCallStatusEvent): void {
  call.callStatus =
    typeof event.data.call_status === "number" ? event.data.call_status : call.callStatus;
  call.isSendingAudio =
    typeof event.data.is_sending_audio === "boolean"
      ? event.data.is_sending_audio
      : call.isSendingAudio;
  call.isSendingTransmission =
    typeof event.data.is_sending_transmission === "boolean"
      ? event.data.is_sending_transmission
      : call.isSendingTransmission;
  call.isUplinkMuted =
    typeof event.data.is_uplink_muted === "boolean"
      ? event.data.is_uplink_muted
      : call.isUplinkMuted;
  call.isSendingVideo =
    typeof event.data.is_sending_video === "boolean"
      ? event.data.is_sending_video
      : call.isSendingVideo;
  call.conversationUUID =
    typeof event.data.conversation_uuid === "string"
      ? event.data.conversation_uuid
      : call.conversationUUID;
  call.conversationGroupUUID =
    typeof event.data.conversation_group_uuid === "string"
      ? event.data.conversation_group_uuid
      : call.conversationGroupUUID;
  call.conversationAudioEnabled =
    typeof event.data.conversation_audio_enabled === "boolean"
      ? event.data.conversation_audio_enabled
      : call.conversationAudioEnabled;
  call.conversationVideoEnabled =
    typeof event.data.conversation_video_enabled === "boolean"
      ? event.data.conversation_video_enabled
      : call.conversationVideoEnabled;
  call.conversationAVMode =
    typeof event.data.conversation_av_mode === "number"
      ? event.data.conversation_av_mode
      : call.conversationAVMode;
  call.conversationResolvedAudioVideoMode =
    typeof event.data.conversation_resolved_audio_video_mode === "number"
      ? event.data.conversation_resolved_audio_video_mode
      : call.conversationResolvedAudioVideoMode;
}

export async function createFaceTimeRuntime(params: {
  config: FaceTimeConfig;
  fullConfig: OpenClawConfig;
  runtime: PluginRuntime;
  logger: RuntimeLogger;
  pluginRoot: string;
}): Promise<FaceTimeRuntime> {
  const config = resolveFaceTimeConfig(params.config);
  if (!config.enabled) {
    throw new Error("facetime disabled in plugin config");
  }
  const validation = validateFaceTimeConfig(config);
  if (!validation.valid) {
    throw new Error(`Invalid facetime config: ${validation.errors.join("; ")}`);
  }

  const calls = new Map<string, ActiveFaceTimeCall>();
  const captureBinary = await ensureCaptureBinary({
    pluginRoot: params.pluginRoot,
    runCommandWithTimeout: params.runtime.system.runCommandWithTimeout,
  });
  let stopping = false;
  const helper = new FaceTimeHelperSocketServer({
    host: config.helperHost,
    port: config.helperPort,
    logger: params.logger,
    onMessage(message) {
      const event = normalizeFaceTimeCallEvent(message);
      if (event) {
        void handleCallEvent(event).catch((error: Error) => {
          params.logger.warn(`[facetime] call event handling failed: ${formatErrorMessage(error)}`);
        });
      }
    },
    onDisconnect() {
      if (stopping || calls.size === 0) {
        return;
      }
      // The helper socket is the only carrier control path. Keep the process tap
      // and route monitor alive until the helper reconnects or the call ends.
      params.logger.warn(
        "[facetime] helper disconnected during a call; retaining audio safety bridge",
      );
    },
  });

  const routeCallAudio = async (call: ActiveFaceTimeCall) => {
    if (!call.audioReady) {
      const routing =
        call.audioRouting ??
        (async () => {
          const assertCallOpen = () => {
            if (call.lifecycleAbort.signal.aborted || calls.get(call.callUUID) !== call) {
              throw new Error("FaceTime call closed during audio routing");
            }
          };
          assertCallOpen();
          await access(captureBinary, constants.X_OK);
          assertCallOpen();
          await assertPairedAudioTransport(params.runtime.system.runCommandWithTimeout);
          assertCallOpen();
          call.audioReady = true;
          call.audioTransport = {
            captureBinary,
            feedDevice: OPENCLAW_FEED_DEVICE,
            microphoneDevice: OPENCLAW_MIC_DEVICE,
            processInputVerified: false,
            processOutputSuppressed: false,
          };
          call.lastRoutingError = undefined;
        })();
      call.audioRouting = routing;
      try {
        await routing;
      } catch (error) {
        call.audioReady = false;
        call.lastRoutingError = formatErrorMessage(error);
        throw error;
      } finally {
        if (call.audioRouting === routing) {
          call.audioRouting = undefined;
        }
      }
    }
    if (call.lifecycleAbort.signal.aborted) {
      throw new Error("FaceTime call closed during audio routing");
    }
  };

  const enableCallAudio = async (call: ActiveFaceTimeCall) => {
    const mutedResult = await helper.setMuted(call.callUUID, false);
    call.lastHelperAction = mutedResult;
    params.logger.debug?.(
      `[facetime] helper set-muted result ${call.callUUID}: ${JSON.stringify(mutedResult)}`,
    );
    const transmissionResult = await helper.startTransmission(call.callUUID);
    call.lastHelperAction = transmissionResult;
    params.logger.debug?.(
      `[facetime] helper start-transmission result ${call.callUUID}: ${JSON.stringify(transmissionResult)}`,
    );
    if (call.audioTransport) {
      call.audioTransport.processInputVerified = true;
      call.audioTransport.processOutputSuppressed = true;
    }
  };

  const closeCall = async (callUUID: string, reason: string) => {
    const call = calls.get(callUUID);
    if (!call) {
      return;
    }
    calls.delete(callUUID);
    if (call.carrierHangupRetryTimer) {
      clearTimeout(call.carrierHangupRetryTimer);
      call.carrierHangupRetryTimer = undefined;
    }
    call.lifecycleAbort.abort();
    await call.audioRouting?.catch((error: Error) => {
      params.logger.debug?.(
        `[facetime] audio routing cancellation for ${callUUID}: ${formatErrorMessage(error)}`,
      );
    });
    await call.talkStarting?.catch((error: Error) => {
      params.logger.debug?.(
        `[facetime] talk startup cancellation for ${callUUID}: ${formatErrorMessage(error)}`,
      );
    });
    await call.talk?.close(reason).catch((error: Error) => {
      params.logger.debug?.(
        `[facetime] talk close ignored for ${callUUID}: ${formatErrorMessage(error)}`,
      );
    });
    await call.talkActivation?.catch((error: Error) => {
      params.logger.debug?.(
        `[facetime] talk activation cancellation for ${callUUID}: ${formatErrorMessage(error)}`,
      );
    });
    call.audioReady = false;
    call.audioTransport = undefined;
    params.logger.info(`[facetime] call closed: ${callUUID} (${reason})`);
  };

  const attemptCarrierHangup = async (
    call: ActiveFaceTimeCall,
    reason: string,
    options: { closeLocal?: boolean; scheduleRetry?: boolean } = {},
  ): Promise<boolean> => {
    const closeLocal = options.closeLocal !== false;
    const scheduleRetry = options.scheduleRetry !== false;
    if (calls.get(call.callUUID) !== call) {
      return true;
    }
    try {
      await helper.safetyMute(call.callUUID);
    } catch (error) {
      params.logger.warn(
        `[facetime] failed to safety-mute carrier ${call.callUUID}: ${formatErrorMessage(error)}`,
      );
    }
    try {
      await helper.leaveCall(call.callUUID);
      call.carrierHangupPending = false;
      if (closeLocal) {
        await closeCall(call.callUUID, reason);
      }
      return true;
    } catch (error) {
      if (isCarrierAlreadyGoneError(error)) {
        call.carrierHangupPending = false;
        if (closeLocal) {
          await closeCall(call.callUUID, `${reason}: carrier-already-ended`);
        }
        return true;
      }
      call.carrierHangupPending = true;
      params.logger.warn(
        `[facetime] carrier hangup pending for ${call.callUUID}: ${formatErrorMessage(error)}`,
      );
      if (scheduleRetry && !call.carrierHangupRetryTimer) {
        call.carrierHangupRetryTimer = setTimeout(() => {
          call.carrierHangupRetryTimer = undefined;
          void attemptCarrierHangup(call, reason);
        }, 1_000);
        call.carrierHangupRetryTimer.unref?.();
      }
      // Keep the process tap alive until leaveCall succeeds or an ended event arrives.
      return false;
    }
  };

  const waitForStartupCarrierHangup = async (
    call: ActiveFaceTimeCall,
    reason: string,
  ): Promise<boolean> => {
    while (calls.get(call.callUUID) === call && !call.lifecycleAbort.signal.aborted) {
      // Do not close local call state from inside talkStarting: closeCall waits
      // for that same promise. The outer call-event path closes it after startup rejects.
      if (
        await attemptCarrierHangup(call, reason, {
          closeLocal: false,
          scheduleRetry: false,
        })
      ) {
        return true;
      }
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, 1_000);
        timer.unref?.();
      });
    }
    return true;
  };

  const startCallTalk = async (call: ActiveFaceTimeCall) => {
    if (call.talk) {
      return;
    }
    if (!call.talkStarting) {
      const callUUID = call.callUUID;
      call.talkStarting = (async () => {
        await routeCallAudio(call);
        const talk = await startFaceTimeTalkDriver({
          config,
          fullConfig: params.fullConfig,
          runtime: params.runtime,
          logger: params.logger,
          callUUID,
          captureBinary,
          signal: call.lifecycleAbort.signal,
          async onFailure(error) {
            // Ringing calls have not joined a carrier yet, so their tap can close
            // immediately. Active calls retain it until carrier hangup is proven.
            if (call.callStatus !== 1) {
              return true;
            }
            if (!call.talk) {
              return await waitForStartupCarrierHangup(
                call,
                `talk-start-failed: ${formatErrorMessage(error)}`,
              );
            }
            return await attemptCarrierHangup(call, `talk-failed: ${formatErrorMessage(error)}`);
          },
        });
        // A helper disconnect or hangup can arrive while the provider connects.
        if (stopping || calls.get(callUUID) !== call) {
          await talk.close("call-ended-during-start");
          return;
        }
        call.talk = talk;
        if (call.audioTransport) {
          call.audioTransport.processOutputSuppressed = true;
        }
        params.logger.info(`[facetime] realtime talk suppression ready: ${callUUID}`);
      })();
    }
    const starting = call.talkStarting;
    try {
      await starting;
    } finally {
      if (call.talkStarting === starting) {
        call.talkStarting = undefined;
      }
    }
  };

  const activateCallTalk = async (call: ActiveFaceTimeCall, options: { unmute: boolean }) => {
    call.unmuteRequested ||= options.unmute;
    const ensureAudioEnabled = async () => {
      if (call.audioEnabled) {
        return;
      }
      call.audioEnablePromise ??= (async () => {
        await enableCallAudio(call);
        call.audioEnabled = true;
      })();
      const enabling = call.audioEnablePromise;
      try {
        await enabling;
      } finally {
        if (call.audioEnablePromise === enabling) {
          call.audioEnablePromise = undefined;
        }
      }
    };
    if (!call.talkActivation) {
      call.talkActivation = (async () => {
        await call.talk?.readyForAudio();
        if (call.lifecycleAbort.signal.aborted || calls.get(call.callUUID) !== call) {
          throw new Error("FaceTime call closed during audio activation");
        }
        if (call.unmuteRequested) {
          await ensureAudioEnabled();
        } else if (call.audioTransport) {
          call.audioTransport.processInputVerified = true;
        }
        call.talk?.activate();
      })();
    }
    const activation = call.talkActivation;
    try {
      await activation;
      // A concurrent caller may request unmute after the shared readiness path
      // has already inspected the coalesced flag.
      if (options.unmute) {
        await ensureAudioEnabled();
      }
    } finally {
      if (call.talkActivation === activation) {
        call.talkActivation = undefined;
      }
    }
  };

  const answerIncomingCall = async (event: FaceTimeCallStatusEvent) => {
    const callUUID = readCallUUID(event);
    const existing = calls.get(callUUID);
    if (existing) {
      return;
    }
    if (calls.size > 0) {
      params.logger.warn(
        `[facetime] ignored incoming call ${callUUID}; another FaceTime bridge is active`,
      );
      return;
    }
    const handle = normalizeFaceTimeHandle(event.data.handle);
    const call: ActiveFaceTimeCall = {
      callUUID,
      handle,
      lifecycleAbort: new AbortController(),
      audioReady: false,
    };
    updateCallStatus(call, event);
    calls.set(callUUID, call);
    let answerAttempted = false;
    try {
      // The native process tap is ready and suppressing hardware playback before answer.
      await startCallTalk(call);
      answerAttempted = true;
      await helper.answerCall(callUUID);
      await activateCallTalk(call, { unmute: true });
      params.logger.info(
        `[facetime] answered whitelisted FaceTime call: ${callUUID} from ${handle ?? "unknown"}`,
      );
    } catch (error) {
      params.logger.warn(
        `[facetime] failed to answer FaceTime call ${callUUID}: ${formatErrorMessage(error)}`,
      );
      if (answerAttempted) {
        await attemptCarrierHangup(call, "answer-failed");
        return;
      }
      await closeCall(callUUID, "answer-failed").catch((closeError: Error) => {
        params.logger.warn(
          `[facetime] answer failure cleanup failed: ${formatErrorMessage(closeError)}`,
        );
      });
    }
  };

  const activateCall = async (event: FaceTimeCallStatusEvent) => {
    const callUUID = readCallUUID(event);
    let call = calls.get(callUUID);
    if (!call) {
      if (calls.size > 0) {
        params.logger.warn(
          `[facetime] ignored active call ${callUUID}; another FaceTime bridge is active`,
        );
        return;
      }
      call = {
        callUUID,
        handle: normalizeFaceTimeHandle(event.data.handle),
        lifecycleAbort: new AbortController(),
        audioReady: false,
      };
      calls.set(callUUID, call);
    }
    updateCallStatus(call, event);
    try {
      await startCallTalk(call);
      await activateCallTalk(call, { unmute: event.data.is_sending_audio === false });
      params.logger.info(`[facetime] realtime talk session active: ${callUUID}`);
    } catch (error) {
      if (call.lifecycleAbort.signal.aborted || calls.get(callUUID) !== call) {
        return;
      }
      params.logger.warn(
        `[facetime] failed to start realtime talk for ${callUUID}: ${formatErrorMessage(error)}`,
      );
      await attemptCarrierHangup(call, "talk-start-failed");
    }
  };

  const handleCallEvent = async (event: FaceTimeCallStatusEvent) => {
    if (stopping) {
      return;
    }
    const callUUID = readCallUUID(event);
    const existingCall = calls.get(callUUID);
    if (existingCall) {
      updateCallStatus(existingCall, event);
    }
    const handleForLog =
      normalizeFaceTimeHandleCandidates(event.data.handle).join(", ") || "unknown";
    if (isIncomingRingingCall(event)) {
      if (isWhitelistedFaceTimeCall({ event, whitelistHandles: config.whitelistHandles })) {
        await answerIncomingCall(event);
      } else {
        params.logger.info(
          `[facetime] ignored non-whitelisted FaceTime call: ${callUUID} handle=${handleForLog}`,
        );
      }
      return;
    }
    if (isActiveCall(event)) {
      if (
        !calls.has(callUUID) &&
        !isWhitelistedFaceTimeCall({ event, whitelistHandles: config.whitelistHandles })
      ) {
        params.logger.info(
          `[facetime] ignored active non-whitelisted FaceTime call: ${callUUID} handle=${handleForLog}`,
        );
        return;
      }
      await activateCall(event);
      return;
    }
    if (isEndedCall(event)) {
      await closeCall(callUUID, `status-${event.data.call_status}`);
    }
  };

  await helper.start();
  params.logger.info(
    `[facetime] listening for FaceTime helper events on ${config.helperHost}:${config.helperPort}`,
  );

  return {
    config,
    async status() {
      return {
        enabled: true,
        helperConnected: helper.connectedSockets > 0,
        processOutputSuppressed: [...calls.values()].some(
          (call) => call.talk?.processOutputSuppressed() === true,
        ),
        calls: [...calls.values()].map((call) => ({
          callUUID: call.callUUID,
          handle: call.handle,
          callStatus: call.callStatus,
          isSendingAudio: call.isSendingAudio,
          isSendingTransmission: call.isSendingTransmission,
          isUplinkMuted: call.isUplinkMuted,
          isSendingVideo: call.isSendingVideo,
          conversationUUID: call.conversationUUID,
          conversationGroupUUID: call.conversationGroupUUID,
          conversationAudioEnabled: call.conversationAudioEnabled,
          conversationVideoEnabled: call.conversationVideoEnabled,
          conversationAVMode: call.conversationAVMode,
          conversationResolvedAudioVideoMode: call.conversationResolvedAudioVideoMode,
          realtimeActive: Boolean(call.talk),
          audioReady: call.audioReady,
          audioTransport: call.audioTransport
            ? {
                ...call.audioTransport,
                processOutputSuppressed: call.talk?.processOutputSuppressed() === true,
              }
            : undefined,
          lastHelperAction: call.lastHelperAction,
          lastRoutingError: call.lastRoutingError,
          carrierHangupPending: call.carrierHangupPending,
          recentTalkEvents: call.talk
            ? summarizeRecentTalkEvents(call.talk.recentTalkEvents)
            : undefined,
        })),
      };
    },
    async hangup(hangupParams) {
      const requestedCallUUID =
        typeof hangupParams?.callUUID === "string" && hangupParams.callUUID.trim()
          ? hangupParams.callUUID.trim()
          : undefined;
      const call = requestedCallUUID
        ? calls.get(requestedCallUUID)
        : ([...calls.values()].find((candidate) => candidate.talk) ?? [...calls.values()][0]);
      if (!call) {
        throw new Error("no active FaceTime call to hang up");
      }
      const closed = await attemptCarrierHangup(call, "operator-hangup");
      if (!closed) {
        throw new Error(`carrier hangup pending for ${call.callUUID}; retry scheduled`);
      }
      return { callUUID: call.callUUID };
    },
    async preflight() {
      return await runFaceTimePreflight({
        config,
        fullConfig: params.fullConfig,
        runtime: params.runtime,
        logger: params.logger,
        helperConnected: helper.connectedSockets > 0,
        captureBinary,
      });
    },
    async testAudio(testParams) {
      const activeCall = [...calls.values()].find((call) => call.talk) ?? [...calls.values()][0];
      if (activeCall) {
        await routeCallAudio(activeCall);
      }
      return await playFaceTimeTestAudio(
        {
          runCommandWithTimeout: params.runtime.system.runCommandWithTimeout,
          logger: params.logger,
        },
        { phrase: testParams?.phrase },
      );
    },
    async stop() {
      stopping = true;
      let cleanupError: Error | undefined;
      for (const call of [...calls.values()]) {
        const closed = await attemptCarrierHangup(call, "runtime-stop");
        if (!closed) {
          cleanupError ??= new Error(
            `carrier hangup remains pending for ${call.callUUID}; audio safety bridge retained`,
          );
        }
      }
      if (cleanupError) {
        stopping = false;
        throw cleanupError;
      }
      await helper.stop();
    },
  };
}
