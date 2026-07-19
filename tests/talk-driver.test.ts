import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
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
}));

vi.mock("openclaw/plugin-sdk/realtime-voice", () => ({
  buildRealtimeVoiceAgentConsultWorkingResponse: vi.fn(),
  consultRealtimeVoiceAgent: vi.fn(),
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
    runtime: { agent: {} } as any,
    logger: console,
    callUUID: "call-1",
    captureBinary: "/capture",
    ...overrides,
  };
}

describe("FaceTime talk driver lifecycle", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.pumpParams = undefined;
    mocks.createSession.mockReturnValue(mocks.bridge);
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
});
