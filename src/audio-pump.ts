import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import type { Writable } from "node:stream";
import type { RuntimeLogger } from "openclaw/plugin-sdk/plugin-runtime";
import { formatErrorMessage } from "./errors.js";

type PumpProcess = {
  pid?: number;
  killed?: boolean;
  stdin?: Writable | null;
  stdout?: { on(event: "data", listener: (chunk: Buffer | string) => void): unknown } | null;
  stderr?: { on(event: "data", listener: (chunk: Buffer | string) => void): unknown } | null;
  kill(signal?: NodeJS.Signals): boolean;
  on(
    event: "exit",
    listener: (code: number | null, signal: NodeJS.Signals | null) => void,
  ): unknown;
  on(event: "error", listener: (error: Error) => void): unknown;
};

type SpawnFn = (
  command: string,
  args: string[],
  options: { stdio: ["pipe" | "ignore", "pipe" | "ignore", "pipe" | "ignore"] },
) => PumpProcess;

const SOX_COMMAND = ["/opt/homebrew/bin/sox", "/usr/local/bin/sox"].find((path) =>
  existsSync(path),
) ?? "sox";
const CAFFEINATE_COMMAND = "/usr/bin/caffeinate";

export type FaceTimeAudioPumpConfig = {
  deviceName: string;
  sampleRateHz: number;
  bufferBytes?: number;
  outputChannels?: number;
  outputGain?: number;
};

export type FaceTimeAudioPump = {
  writeOutputAudio(audio: Buffer): void;
  clearOutputAudio(): void;
  stop(): Promise<void>;
};

function soxInputCommand(config: FaceTimeAudioPumpConfig): string[] {
  return [
    SOX_COMMAND,
    "-q",
    "--buffer",
    String(config.bufferBytes ?? 4096),
    "-t",
    "coreaudio",
    config.deviceName,
    "-t",
    "raw",
    "-r",
    String(config.sampleRateHz),
    "-c",
    "1",
    "-e",
    "signed-integer",
    "-b",
    "16",
    "-L",
    "-",
  ];
}

function soxOutputCommand(config: FaceTimeAudioPumpConfig): string[] {
  const outputChannels =
    Number.isInteger(config.outputChannels) && (config.outputChannels ?? 0) > 0
      ? String(config.outputChannels)
      : "16";
  const outputGain =
    typeof config.outputGain === "number" && Number.isFinite(config.outputGain)
      ? config.outputGain
      : 3;
  const command = [
    SOX_COMMAND,
    "-q",
    "--buffer",
    String(config.bufferBytes ?? 4096),
    "-t",
    "raw",
    "-r",
    String(config.sampleRateHz),
    "-c",
    "1",
    "-e",
    "signed-integer",
    "-b",
    "16",
    "-L",
    "-",
    "-c",
    outputChannels,
    "-t",
    "coreaudio",
    config.deviceName,
  ];
  if (outputGain !== 1) {
    command.push("gain", String(outputGain));
  }
  return command;
}

function splitCommand(argv: string[]): { command: string; args: string[] } {
  const [command, ...args] = argv;
  if (!command) {
    throw new Error("audio command must not be empty");
  }
  return { command, args };
}

async function terminateProcess(proc: PumpProcess, signal: NodeJS.Signals = "SIGTERM") {
  if (proc.killed && signal !== "SIGKILL") {
    return;
  }
  let exited = false;
  const exitedPromise = new Promise<void>((resolve) => {
    proc.on("exit", () => {
      exited = true;
      resolve();
    });
  });
  try {
    proc.stdin?.end?.();
  } catch {
    // The process may already have closed stdin.
  }
  try {
    proc.kill(signal);
  } catch {
    return;
  }
  if (signal !== "SIGKILL") {
    await Promise.race([
      exitedPromise,
      new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, 1000);
        timer.unref?.();
      }),
    ]);
    if (!exited) {
      try {
        proc.kill("SIGKILL");
      } catch {
        // Process may have exited after the grace check.
      }
    }
  }
  await Promise.race([
    exitedPromise,
    new Promise<void>((resolve) => {
      const timer = setTimeout(resolve, 1000);
      timer.unref?.();
    }),
  ]);
}

export function startFaceTimeAudioPump(params: {
  config: FaceTimeAudioPumpConfig;
  logger: RuntimeLogger;
  onInputAudio: (audio: Buffer) => void;
  onError?: (error: Error) => void;
  spawn?: SpawnFn;
}): FaceTimeAudioPump {
  const spawnFn: SpawnFn =
    params.spawn ??
    ((command, args, options) => spawn(command, args, options) as unknown as PumpProcess);
  const input = splitCommand(soxInputCommand(params.config));
  const output = splitCommand(soxOutputCommand(params.config));
  const spawnOutput = () =>
    spawnFn(output.command, output.args, { stdio: ["pipe", "ignore", "pipe"] });
  const wakeProcess = existsSync(CAFFEINATE_COMMAND)
    ? spawnFn(CAFFEINATE_COMMAND, ["-d", "-i"], { stdio: ["ignore", "ignore", "pipe"] })
    : undefined;
  const inputProcess = spawnFn(input.command, input.args, { stdio: ["ignore", "pipe", "pipe"] });
  let outputProcess = spawnOutput();
  let stopped = false;

  const fail = (label: string) => (error: Error) => {
    if (stopped) {
      return;
    }
    params.logger.warn(`[facetime] ${label} failed: ${formatErrorMessage(error)}`);
    params.onError?.(error);
    void stop();
  };

  const attachOutputHandlers = (proc: PumpProcess) => {
    proc.on("error", (error) => {
      if (proc === outputProcess) {
        fail("audio output command")(error);
      }
    });
    proc.stdin?.on?.("error", (error: Error) => {
      if (proc === outputProcess) {
        fail("audio output command")(error);
      }
    });
    proc.on("exit", (code, signal) => {
      if (!stopped && proc === outputProcess) {
        fail("audio output command")(new Error(`exited (${code ?? signal ?? "done"})`));
      }
    });
    proc.stderr?.on("data", (chunk) => {
      params.logger.debug?.(`[facetime] audio output: ${String(chunk).trim()}`);
    });
  };

  const stop = async () => {
    if (stopped) {
      return;
    }
    stopped = true;
    await Promise.all([
      terminateProcess(inputProcess),
      terminateProcess(outputProcess),
      wakeProcess ? terminateProcess(wakeProcess) : Promise.resolve(),
    ]);
  };

  wakeProcess?.on("error", (error) => {
    params.logger.debug?.(`[facetime] caffeinate command failed: ${formatErrorMessage(error)}`);
  });
  wakeProcess?.on("exit", (code, signal) => {
    if (!stopped) {
      params.logger.debug?.(
        `[facetime] caffeinate command exited (${code ?? signal ?? "done"})`,
      );
    }
  });
  wakeProcess?.stderr?.on("data", (chunk) => {
    params.logger.debug?.(`[facetime] caffeinate: ${String(chunk).trim()}`);
  });

  inputProcess.on("error", fail("audio input command"));
  inputProcess.on("exit", (code, signal) => {
    if (!stopped) {
      fail("audio input command")(new Error(`exited (${code ?? signal ?? "done"})`));
    }
  });
  inputProcess.stderr?.on("data", (chunk) => {
    params.logger.debug?.(`[facetime] audio input: ${String(chunk).trim()}`);
  });
  inputProcess.stdout?.on("data", (chunk) => {
    if (!stopped) {
      const audio = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      if (audio.byteLength > 0) {
        params.onInputAudio(audio);
      }
    }
  });
  attachOutputHandlers(outputProcess);

  return {
    writeOutputAudio(audio) {
      if (stopped) {
        return;
      }
      try {
        outputProcess.stdin?.write(audio);
      } catch (error) {
        fail("audio output command")(error as Error);
      }
    },
    clearOutputAudio() {
      if (stopped) {
        return;
      }
      const previous = outputProcess;
      outputProcess = spawnOutput();
      attachOutputHandlers(outputProcess);
      void terminateProcess(previous, "SIGKILL");
    },
    stop,
  };
}
