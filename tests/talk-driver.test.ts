import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  abortAgentRun: vi.fn(() => true),
  buildCancelResult: vi.fn((message: string) => ({ status: "cancelled", message })),
  bridge: {
    bridge: { supportsToolResultContinuation: false },
    acknowledgeMark: vi.fn(),
    close: vi.fn(),
    connect: vi.fn<() => Promise<void>>(),
    sendAudio: vi.fn(),
    sendUserMessage: vi.fn(),
    handleBargeIn: vi.fn(),
    setMediaTimestamp: vi.fn(),
    submitToolResult: vi.fn(),
    triggerGreeting: vi.fn(),
  },
  createSession: vi.fn(),
  consult: vi.fn(),
  resolveBootstrapContext: vi.fn(),
  senderAuthVersion: 1 as number | undefined,
  pump: {
    suppressionReady: vi.fn(async () => {}),
    routeReady: vi.fn(async () => {}),
    processOutputSuppressed: vi.fn(() => true),
    writeOutputAudio: vi.fn(),
    clearOutputAudio: vi.fn(),
    generatedAudioMs: vi.fn(() => 0),
    playedAudioMs: vi.fn(() => 0),
    queuedAudioMs: vi.fn(() => 0),
    stop: vi.fn(async () => {}),
  },
  pumpParams: undefined as undefined | { onError(error: Error): void },
  sessionParams: undefined as
    | undefined
    | {
        instructions?: string;
        onEvent(event: { direction: "client" | "server"; type: string; detail?: string }): void;
        onToolCall(event: { itemId: string; callId: string; name: string; args: unknown }): void;
      },
}));

vi.mock("openclaw/plugin-sdk/realtime-voice", () => ({
  get REALTIME_VOICE_AGENT_CONSULT_SENDER_AUTH_VERSION() {
    return mocks.senderAuthVersion;
  },
  buildRealtimeVoiceAgentConsultPolicyInstructions: vi.fn(() => "Consult behavior: always."),
  buildRealtimeVoiceAgentCancelProviderResult: mocks.buildCancelResult,
  buildRealtimeVoiceAgentConsultWorkingResponse: vi.fn(),
  consultRealtimeVoiceAgent: mocks.consult,
  createRealtimeVoiceBridgeSession: mocks.createSession,
  createTalkSessionController: vi.fn(() => ({
    outputAudioActive: false,
    emit: vi.fn((event) => event),
    ensureTurn: vi.fn(() => ({ turnId: "turn-1" })),
    startOutputAudio: vi.fn(() => ({ event: undefined })),
    finishOutputAudio: vi.fn(),
    endTurn: vi.fn(() => ({ ok: false })),
  })),
  REALTIME_VOICE_AGENT_CONSULT_TOOL_NAME: "openclaw_agent_consult",
  REALTIME_VOICE_AUDIO_FORMAT_PCM16_24KHZ: "pcm16-24khz",
  recordTalkObservabilityEvent: vi.fn(),
  resolveConfiguredRealtimeVoiceProvider: vi.fn(() => ({
    provider: { id: "openai" },
    providerConfig: {},
  })),
  resolveRealtimeVoiceAgentConsultTools: vi.fn(() => []),
  resolveRealtimeVoiceAgentConsultToolsAllow: vi.fn(() => []),
}));

vi.mock("openclaw/plugin-sdk/realtime-bootstrap-context", () => ({
  resolveRealtimeBootstrapContextInstructions: mocks.resolveBootstrapContext,
}));

vi.mock("openclaw/plugin-sdk/agent-runtime", () => ({
  resolveDefaultAgentId: vi.fn(
    (config: { agents?: { list?: Array<{ id: string; default?: boolean }> } }) => {
      const agents = config.agents?.list ?? [];
      return agents.find((agent) => agent.default)?.id ?? agents[0]?.id ?? "main";
    },
  ),
}));

vi.mock("openclaw/plugin-sdk/agent-harness", () => ({
  abortAgentHarnessRun: mocks.abortAgentRun,
}));

vi.mock("openclaw/plugin-sdk/secret-input-runtime", () => ({
  resolveConfiguredSecretInputString: vi.fn(async () => ({ value: undefined })),
}));

vi.mock("../src/audio-pump.js", () => ({
  startFaceTimeAudioPump: vi.fn((params) => {
    mocks.pumpParams = params;
    return mocks.pump;
  }),
}));

import { resolveFaceTimeConfig } from "../src/config.js";
import { startFaceTimeTalkDriver } from "../src/talk-driver.js";

function startParams(overrides: Record<string, unknown> = {}) {
  return {
    config: resolveFaceTimeConfig({ whitelistHandles: ["caller@example.com"] }),
    fullConfig: {} as any,
    runtime: {
      agent: {
        session: {
          resolveStorePath: vi.fn(() => "/store"),
          getSessionEntry: vi.fn(() => ({ sessionId: "facetime-consult-session" })),
        },
      },
    } as any,
    logger: console,
    callUUID: "call-1",
    senderId: "caller@example.com",
    senderIsOwner: true,
    captureBinary: "/capture",
    ...overrides,
  };
}

describe("FaceTime talk driver lifecycle", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.senderAuthVersion = 1;
    mocks.resolveBootstrapContext.mockResolvedValue(undefined);
    mocks.pumpParams = undefined;
    mocks.sessionParams = undefined;
    mocks.bridge.bridge.supportsToolResultContinuation = false;
    (
      mocks.bridge.bridge as { supportsToolResultSuppression?: boolean }
    ).supportsToolResultSuppression = true;
    mocks.createSession.mockImplementation((params) => {
      mocks.sessionParams = params;
      return mocks.bridge;
    });
  });

  it("closes native audio when startup is aborted during provider connect", async () => {
    mocks.bridge.connect.mockImplementation(() => new Promise<void>(() => {}));
    const controller = new AbortController();
    const starting = startFaceTimeTalkDriver(startParams({ signal: controller.signal }));

    await vi.waitFor(() => expect(mocks.bridge.connect).toHaveBeenCalledOnce());
    controller.abort();

    await expect(starting).rejects.toThrow("startup aborted");
    expect(mocks.bridge.close).toHaveBeenCalledOnce();
    expect(mocks.pump.stop).toHaveBeenCalledOnce();
  });

  it("fails closed when OpenClaw cannot forward authenticated sender identity", async () => {
    mocks.senderAuthVersion = undefined;

    await expect(startFaceTimeTalkDriver(startParams())).rejects.toThrow(
      "does not support authenticated sender identity",
    );
    expect(mocks.createSession).not.toHaveBeenCalled();
    expect(mocks.pump.stop).not.toHaveBeenCalled();
  });

  it("reports an audio-child failure to the owning runtime", async () => {
    mocks.bridge.connect.mockResolvedValue();
    const onFailure = vi.fn();
    await startFaceTimeTalkDriver(startParams({ onFailure }));

    mocks.pumpParams?.onError(new Error("capture failed"));

    expect(onFailure).toHaveBeenCalledWith(expect.objectContaining({ message: "capture failed" }));
    await vi.waitFor(() => expect(mocks.pump.stop).toHaveBeenCalledOnce());
    expect(mocks.bridge.close).toHaveBeenCalledOnce();
  });

  it("retains process-tap suppression when carrier cleanup is not yet safe", async () => {
    mocks.bridge.connect.mockResolvedValue();
    const onFailure = vi.fn(async () => false);
    await startFaceTimeTalkDriver(startParams({ onFailure }));

    await mocks.pumpParams?.onError(new Error("carrier hangup pending"));

    expect(onFailure).toHaveBeenCalledOnce();
    expect(mocks.pump.stop).not.toHaveBeenCalled();
    expect(mocks.bridge.close).not.toHaveBeenCalled();
  });

  it("rejects startup instead of returning a stopped driver after an audio failure", async () => {
    mocks.bridge.connect.mockImplementation(() => new Promise<void>(() => {}));
    const onFailure = vi.fn(async () => true);
    const starting = startFaceTimeTalkDriver(startParams({ onFailure }));

    await vi.waitFor(() => expect(mocks.bridge.connect).toHaveBeenCalledOnce());
    await mocks.pumpParams?.onError(new Error("capture failed during connect"));

    await expect(starting).rejects.toThrow("capture failed during connect");
    expect(onFailure).toHaveBeenCalledOnce();
    expect(mocks.pump.stop).toHaveBeenCalledOnce();
    expect(mocks.bridge.close).toHaveBeenCalledOnce();
  });

  it("retains process suppression until provider-startup carrier cleanup is safe", async () => {
    mocks.bridge.connect.mockRejectedValue(new Error("provider connect failed"));
    let releaseCarrierSafety = (_safeToClose: boolean) => {};
    const onFailure = vi.fn(
      () =>
        new Promise<boolean>((resolve) => {
          releaseCarrierSafety = resolve;
        }),
    );
    const starting = startFaceTimeTalkDriver(startParams({ onFailure }));

    await vi.waitFor(() => expect(onFailure).toHaveBeenCalledOnce());
    expect(mocks.pump.stop).not.toHaveBeenCalled();
    expect(mocks.bridge.close).not.toHaveBeenCalled();

    releaseCarrierSafety(true);

    await expect(starting).rejects.toThrow("provider connect failed");

    expect(mocks.pump.stop).toHaveBeenCalledOnce();
    expect(mocks.bridge.close).toHaveBeenCalledOnce();
  });

  it("stops native audio when Realtime session construction throws", async () => {
    mocks.createSession.mockImplementationOnce(() => {
      throw new Error("session construction failed");
    });

    await expect(startFaceTimeTalkDriver(startParams())).rejects.toThrow(
      "session construction failed",
    );
    expect(mocks.pump.stop).toHaveBeenCalledOnce();
  });

  it("activates the greeting only after the call is answered", async () => {
    mocks.bridge.connect.mockResolvedValue();
    const driver = await startFaceTimeTalkDriver(startParams());

    expect(mocks.bridge.triggerGreeting).not.toHaveBeenCalled();
    driver.activate();
    driver.activate();

    expect(mocks.bridge.triggerGreeting).toHaveBeenCalledOnce();
  });

  it("makes concurrent close callers join the same cleanup", async () => {
    mocks.bridge.connect.mockResolvedValue();
    let finishStop = () => {};
    mocks.pump.stop.mockImplementationOnce(
      () => new Promise<void>((resolve) => (finishStop = resolve)),
    );
    const driver = await startFaceTimeTalkDriver(startParams());

    const first = driver.close("first");
    const second = driver.close("second");
    expect(mocks.pump.stop).toHaveBeenCalledOnce();
    finishStop();
    await Promise.all([first, second]);

    expect(mocks.bridge.close).toHaveBeenCalledOnce();
  });

  it("aborts a pending agent consult when the FaceTime call closes", async () => {
    mocks.bridge.connect.mockResolvedValue();
    let finishConsult = (_result: { text: string }) => {};
    mocks.consult.mockImplementationOnce(
      () =>
        new Promise<{ text: string }>((resolve) => {
          finishConsult = resolve;
        }),
    );
    const driver = await startFaceTimeTalkDriver(startParams());

    mocks.sessionParams?.onToolCall({
      itemId: "item-1",
      callId: "call-1",
      name: "openclaw_agent_consult",
      args: { question: "Change my calendar." },
    });
    await vi.waitFor(() => expect(mocks.consult).toHaveBeenCalledOnce());

    await driver.close("carrier-ended");

    await vi.waitFor(() =>
      expect(mocks.abortAgentRun).toHaveBeenCalledWith("facetime-consult-session"),
    );
    finishConsult({ text: "Too late." });
    await Promise.resolve();
    expect(mocks.bridge.submitToolResult).not.toHaveBeenCalled();
  });

  it("does not keep gateway shutdown alive while waiting for late consult registration", async () => {
    mocks.bridge.connect.mockResolvedValue();
    mocks.consult.mockImplementationOnce(() => new Promise<{ text: string }>(() => {}));
    const params = startParams();
    params.runtime.agent.session.getSessionEntry.mockReturnValue(undefined);
    const driver = await startFaceTimeTalkDriver(params);

    mocks.sessionParams?.onToolCall({
      itemId: "item-1",
      callId: "call-1",
      name: "openclaw_agent_consult",
      args: { question: "Change my calendar." },
    });
    await vi.waitFor(() => expect(mocks.consult).toHaveBeenCalledOnce());

    const unref = vi.fn();
    const timer = { unref } as unknown as ReturnType<typeof setTimeout>;
    const setTimeoutSpy = vi.spyOn(globalThis, "setTimeout").mockReturnValueOnce(timer);
    try {
      await driver.close("carrier-ended");
      await vi.waitFor(() => expect(unref).toHaveBeenCalledOnce());
    } finally {
      setTimeoutSpy.mockRestore();
    }

    expect(mocks.abortAgentRun).not.toHaveBeenCalled();
  });

  it("silently closes a consult superseded by new caller speech", async () => {
    mocks.bridge.connect.mockResolvedValue();
    let finishConsult = (_result: { text: string }) => {};
    mocks.consult.mockImplementationOnce(
      () =>
        new Promise<{ text: string }>((resolve) => {
          finishConsult = resolve;
        }),
    );
    await startFaceTimeTalkDriver(startParams());

    mocks.sessionParams?.onToolCall({
      itemId: "item-1",
      callId: "call-1",
      name: "openclaw_agent_consult",
      args: { question: "Who am I?" },
    });
    mocks.sessionParams?.onEvent({
      direction: "server",
      type: "input_audio_buffer.speech_started",
    });

    await vi.waitFor(() =>
      expect(mocks.bridge.submitToolResult).toHaveBeenCalledWith(
        "call-1",
        {
          status: "cancelled",
          message: "The caller continued speaking before this consult completed.",
        },
        { suppressResponse: true },
      ),
    );
    expect(mocks.abortAgentRun).toHaveBeenCalledWith("facetime-consult-session");
    finishConsult({ text: "You are Omar." });
    await Promise.resolve();
    expect(mocks.bridge.submitToolResult).toHaveBeenCalledTimes(1);
  });

  it("silently closes a failed consult superseded by new caller speech", async () => {
    mocks.bridge.connect.mockResolvedValue();
    let failConsult = (_error: Error) => {};
    mocks.consult.mockImplementationOnce(
      () =>
        new Promise<{ text: string }>((_resolve, reject) => {
          failConsult = reject;
        }),
    );
    await startFaceTimeTalkDriver(startParams());

    mocks.sessionParams?.onToolCall({
      itemId: "item-1",
      callId: "call-1",
      name: "openclaw_agent_consult",
      args: { question: "Who am I?" },
    });
    mocks.sessionParams?.onEvent({
      direction: "server",
      type: "input_audio_buffer.speech_started",
    });

    await vi.waitFor(() =>
      expect(mocks.bridge.submitToolResult).toHaveBeenCalledWith(
        "call-1",
        {
          status: "cancelled",
          message: "The caller continued speaking before this consult completed.",
        },
        { suppressResponse: true },
      ),
    );
    failConsult(new Error("agent unavailable"));
    await Promise.resolve();
    expect(mocks.bridge.submitToolResult).toHaveBeenCalledTimes(1);
  });

  it("uses an unsuppressed terminal cancellation when the provider requires it", async () => {
    mocks.bridge.connect.mockResolvedValue();
    (
      mocks.bridge.bridge as { supportsToolResultSuppression?: boolean }
    ).supportsToolResultSuppression = false;
    mocks.consult.mockImplementationOnce(() => new Promise<{ text: string }>(() => {}));
    await startFaceTimeTalkDriver(startParams());

    mocks.sessionParams?.onToolCall({
      itemId: "item-1",
      callId: "call-1",
      name: "openclaw_agent_consult",
      args: { question: "Who am I?" },
    });
    mocks.sessionParams?.onEvent({
      direction: "server",
      type: "input_audio_buffer.speech_started",
    });

    await vi.waitFor(() =>
      expect(mocks.bridge.submitToolResult).toHaveBeenCalledWith(
        "call-1",
        {
          status: "cancelled",
          message: "The caller continued speaking before this consult completed.",
        },
        undefined,
      ),
    );
  });

  it("closes safely when a terminal consult cancellation cannot be submitted", async () => {
    mocks.bridge.connect.mockResolvedValue();
    mocks.bridge.submitToolResult.mockRejectedValueOnce(new Error("submission failed"));
    mocks.consult.mockImplementationOnce(() => new Promise<{ text: string }>(() => {}));
    const onFailure = vi.fn(async () => true);
    await startFaceTimeTalkDriver(startParams({ onFailure }));

    mocks.sessionParams?.onToolCall({
      itemId: "item-1",
      callId: "call-1",
      name: "openclaw_agent_consult",
      args: { question: "Who am I?" },
    });
    mocks.sessionParams?.onEvent({
      direction: "server",
      type: "input_audio_buffer.speech_started",
    });

    await vi.waitFor(() => expect(onFailure).toHaveBeenCalledWith(new Error("submission failed")));
    expect(mocks.bridge.close).toHaveBeenCalledOnce();
  });

  it("routes the main session key to the configured default agent", async () => {
    mocks.bridge.connect.mockResolvedValue();
    mocks.consult.mockResolvedValueOnce({ text: "I know my SOUL.md." });
    await startFaceTimeTalkDriver(
      startParams({
        fullConfig: {
          agents: { list: [{ id: "lobster", default: true }] },
        },
      }),
    );

    mocks.sessionParams?.onToolCall({
      itemId: "item-1",
      callId: "call-1",
      name: "openclaw_agent_consult",
      args: { question: "Can you read SOUL.md?" },
    });

    await vi.waitFor(() =>
      expect(mocks.consult).toHaveBeenCalledWith(
        expect.objectContaining({
          agentId: "lobster",
          sessionKey: "agent:lobster:facetime:call-1",
          spawnedBy: "agent:lobster:main",
          contextMode: "fork",
          senderId: "caller@example.com",
          senderIsOwner: true,
          messageProvider: "webchat",
          lane: "facetime:call-1",
          extraSystemPrompt: expect.stringContaining(
            "configured owner/user described by this agent's workspace context",
          ),
        }),
      ),
    );
  });

  it("normalizes FaceTime UUID casing for one consult session and lane", async () => {
    mocks.bridge.connect.mockResolvedValue();
    mocks.consult.mockResolvedValueOnce({ text: "Done." });
    await startFaceTimeTalkDriver(
      startParams({
        callUUID: "17BC43FD-5800-4B54-86DB-698C49253C42",
        fullConfig: {
          agents: { list: [{ id: "lobster", default: true }] },
        },
      }),
    );

    mocks.sessionParams?.onToolCall({
      itemId: "item-1",
      callId: "call-1",
      name: "openclaw_agent_consult",
      args: { question: "Check my calendar." },
    });

    await vi.waitFor(() =>
      expect(mocks.consult).toHaveBeenCalledWith(
        expect.objectContaining({
          sessionKey: "agent:lobster:facetime:17bc43fd-5800-4b54-86db-698c49253c42",
          lane: "facetime:17bc43fd-5800-4b54-86db-698c49253c42",
          runIdPrefix: "facetime:17bc43fd-5800-4b54-86db-698c49253c42",
        }),
      ),
    );
  });

  it("combines custom instructions with workspace identity and agent proxy policy", async () => {
    mocks.bridge.connect.mockResolvedValue();
    mocks.resolveBootstrapContext.mockResolvedValue(
      "OpenClaw realtime voice profile context:\n\n### IDENTITY.md\nName: Tide",
    );
    await startFaceTimeTalkDriver(
      startParams({
        config: resolveFaceTimeConfig({
          whitelistHandles: ["caller@example.com"],
          realtime: { instructions: "Speak warmly and keep answers short." },
        }),
      }),
    );

    expect(mocks.sessionParams?.instructions).toContain("Speak warmly and keep answers short.");
    expect(mocks.sessionParams?.instructions).toContain("Name: Tide");
    expect(mocks.sessionParams?.instructions).toContain("same configured OpenClaw agent");
    expect(mocks.sessionParams?.instructions).toContain(
      "authenticated owner/user described by the loaded workspace profile context",
    );
    expect(mocks.sessionParams?.instructions).toContain("Consult behavior: always.");
    expect(mocks.sessionParams?.instructions).toContain("Never claim you retried");
    expect(mocks.sessionParams?.instructions).not.toContain("Lobster");
    expect(mocks.sessionParams?.instructions).not.toContain("Omar");
  });
});
