import type { OpenClawConfig } from "openclaw/plugin-sdk/config-types";
import type { PluginRuntime, RuntimeLogger } from "openclaw/plugin-sdk/plugin-runtime";
import {
  captureCurrentDefaults,
  listAudioDevices,
  type AudioDefaultsSnapshot,
} from "./audio-routing.js";
import type { FaceTimeConfig } from "./config.js";
import { formatErrorMessage } from "./errors.js";

type RunCommandWithTimeout = PluginRuntime["system"]["runCommandWithTimeout"];

export type FaceTimePreflightCheck = {
  id: string;
  label: string;
  ok: boolean;
  required: boolean;
  message?: string;
};

export type FaceTimePreflightResult = {
  ok: boolean;
  helperConnected: boolean;
  currentAudioDefaults?: AudioDefaultsSnapshot;
  currentAudioError?: string;
  checks: FaceTimePreflightCheck[];
};

function normalizeDeviceName(value: string) {
  return value.trim().toLowerCase();
}

function firstLine(value: unknown) {
  return `${value ?? ""}`.trim().split(/\r?\n/)[0] || undefined;
}

function shellSingleQuote(value: string) {
  return `'${value.replaceAll("'", "'\\''")}'`;
}

function pushCheck(
  checks: FaceTimePreflightCheck[],
  check: Omit<FaceTimePreflightCheck, "required"> & { required?: boolean },
) {
  checks.push({ required: true, ...check });
}

async function checkCommandCandidates(params: {
  runCommandWithTimeout: RunCommandWithTimeout;
  checks: FaceTimePreflightCheck[];
  id: string;
  label: string;
  candidates: string[];
  args: string[];
  required?: boolean;
}) {
  let lastMessage: string | undefined;
  for (const command of params.candidates) {
    const result = await params.runCommandWithTimeout([command, ...params.args], {
      timeoutMs: 5_000,
    });
    if (result.code === 0) {
      pushCheck(params.checks, {
        id: params.id,
        label: params.label,
        ok: true,
        required: params.required,
        message: firstLine(result.stdout) ?? command,
      });
      return;
    }
    lastMessage = firstLine(result.stderr) ?? firstLine(result.stdout) ?? `${command} failed`;
    if (!/ENOENT/i.test(`${result.stderr ?? ""}`)) {
      break;
    }
  }
  pushCheck(params.checks, {
    id: params.id,
    label: params.label,
    ok: false,
    required: params.required,
    message: lastMessage,
  });
}

async function checkBlackHoleLoopback(params: {
  runCommandWithTimeout: RunCommandWithTimeout;
  checks: FaceTimePreflightCheck[];
  deviceName: string;
}) {
  const device = shellSingleQuote(params.deviceName);
  const script = `
set -euo pipefail
if [[ -x /opt/homebrew/bin/sox ]]; then sox=/opt/homebrew/bin/sox
elif [[ -x /usr/local/bin/sox ]]; then sox=/usr/local/bin/sox
else sox=sox
fi
tmp="$(mktemp -t openclaw-facetime-loopback.XXXXXX.raw)"
cleanup() { rm -f "$tmp"; }
trap cleanup EXIT
if [[ -x /usr/bin/caffeinate ]]; then /usr/bin/caffeinate -u -t 8 >/dev/null 2>&1 & fi
"$sox" -q -t coreaudio ${device} -t raw -r 48000 -c 1 -e signed-integer -b 16 -L "$tmp" trim 0 3 &
recpid=$!
sleep 0.3
"$sox" -q -n -t coreaudio ${device} synth 2 sine 880 vol 0.2
wait "$recpid" || true
stat="$("$sox" -q -t raw -r 48000 -c 1 -e signed-integer -b 16 -L "$tmp" -n stat 2>&1)"
rms="$(printf "%s\\n" "$stat" | awk '/RMS[[:space:]]+amplitude/ { print $3; exit }')"
node -e 'const rms=Number(process.argv[1]); if (!Number.isFinite(rms) || rms < 0.005) process.exit(1)' "$rms"
printf 'loopback rms=%s\\n' "$rms"
`;
  const result = await params.runCommandWithTimeout(["/bin/bash", "-lc", script], {
    timeoutMs: 10_000,
  });
  pushCheck(params.checks, {
    id: "blackhole-loopback",
    label: "BlackHole loopback audio",
    ok: result.code === 0,
    message:
      firstLine(result.stdout) ??
      firstLine(result.stderr) ??
      `no loopback signal detected on ${params.deviceName}`,
  });
}

async function checkBlackHolePcmLoopback(params: {
  runCommandWithTimeout: RunCommandWithTimeout;
  checks: FaceTimePreflightCheck[];
  deviceName: string;
}) {
  const device = shellSingleQuote(params.deviceName);
  const script = `
set -euo pipefail
if [[ -x /opt/homebrew/bin/sox ]]; then sox=/opt/homebrew/bin/sox
elif [[ -x /usr/local/bin/sox ]]; then sox=/usr/local/bin/sox
else sox=sox
fi
capture="$(mktemp -t openclaw-facetime-pcm-loopback-capture.XXXXXX.raw)"
source="$(mktemp -t openclaw-facetime-pcm-loopback-source.XXXXXX.raw)"
cleanup() { rm -f "$capture" "$source"; }
trap cleanup EXIT
if [[ -x /usr/bin/caffeinate ]]; then /usr/bin/caffeinate -u -t 8 >/dev/null 2>&1 & fi
"$sox" -q -n -t raw -r 24000 -c 1 -e signed-integer -b 16 -L "$source" synth 2 sine 880 vol 0.2
"$sox" -q -t coreaudio ${device} -t raw -r 48000 -c 1 -e signed-integer -b 16 -L "$capture" trim 0 3 &
recpid=$!
sleep 0.3
"$sox" -q --buffer 4096 -t raw -r 24000 -c 1 -e signed-integer -b 16 -L "$source" -c 16 -t coreaudio ${device} gain 1
wait "$recpid" || true
stat="$("$sox" -q -t raw -r 48000 -c 1 -e signed-integer -b 16 -L "$capture" -n stat 2>&1)"
rms="$(printf "%s\\n" "$stat" | awk '/RMS[[:space:]]+amplitude/ { print $3; exit }')"
node -e 'const rms=Number(process.argv[1]); if (!Number.isFinite(rms) || rms < 0.005) process.exit(1)' "$rms"
printf 'pcm loopback rms=%s\\n' "$rms"
`;
  const result = await params.runCommandWithTimeout(["/bin/bash", "-lc", script], {
    timeoutMs: 10_000,
  });
  pushCheck(params.checks, {
    id: "blackhole-pcm-loopback",
    label: "BlackHole PCM loopback audio",
    ok: result.code === 0,
    message:
      firstLine(result.stdout) ??
      firstLine(result.stderr) ??
      `no PCM loopback signal detected on ${params.deviceName}`,
  });
}

function hasProviderCredential(params: {
  config: FaceTimeConfig;
  fullConfig: OpenClawConfig;
}): boolean {
  const providerConfig = params.config.realtime.providers[params.config.realtime.provider];
  if (providerConfig && "apiKey" in providerConfig) {
    return true;
  }
  return Boolean(process.env.OPENAI_API_KEY);
}

export async function runFaceTimePreflight(params: {
  config: FaceTimeConfig;
  fullConfig: OpenClawConfig;
  runtime: PluginRuntime;
  logger?: RuntimeLogger;
  helperConnected: boolean;
}): Promise<FaceTimePreflightResult> {
  const checks: FaceTimePreflightCheck[] = [];
  pushCheck(checks, {
    id: "helper-connected",
    label: "FaceTime helper socket",
    ok: params.helperConnected,
    message: params.helperConnected
      ? "helper connected"
      : `no helper connected on ${params.config.helperHost}:${params.config.helperPort}`,
  });

  let currentAudioDefaults: AudioDefaultsSnapshot | undefined;
  let currentAudioError: string | undefined;
  try {
    currentAudioDefaults = await captureCurrentDefaults({
      runCommandWithTimeout: params.runtime.system.runCommandWithTimeout,
      logger: params.logger,
    });
    pushCheck(checks, {
      id: "current-audio-defaults",
      label: "Current audio defaults",
      ok: true,
      message: `input=${currentAudioDefaults.inputDeviceUid ?? "unknown"}, output=${
        currentAudioDefaults.outputDeviceUid ?? "unknown"
      }`,
    });
  } catch (error) {
    currentAudioError = formatErrorMessage(error);
    pushCheck(checks, {
      id: "current-audio-defaults",
      label: "Current audio defaults",
      ok: false,
      message: currentAudioError,
    });
  }

  for (const type of ["input", "output"] as const) {
    try {
      const devices = await listAudioDevices(
        { runCommandWithTimeout: params.runtime.system.runCommandWithTimeout },
        type,
      );
      const target = normalizeDeviceName(params.config.audio.blackholeDeviceUid);
      const found = devices.some((device) => normalizeDeviceName(device) === target);
      pushCheck(checks, {
        id: `blackhole-${type}`,
        label: `BlackHole ${type} device`,
        ok: found,
        message: found
          ? params.config.audio.blackholeDeviceUid
          : `missing ${params.config.audio.blackholeDeviceUid}; found: ${devices.join(", ")}`,
      });
    } catch (error) {
      pushCheck(checks, {
        id: `blackhole-${type}`,
        label: `BlackHole ${type} device`,
        ok: false,
        message: formatErrorMessage(error),
      });
    }
  }

  await checkCommandCandidates({
    runCommandWithTimeout: params.runtime.system.runCommandWithTimeout,
    checks,
    id: "sox",
    label: "SoX command",
    candidates: ["/opt/homebrew/bin/sox", "/usr/local/bin/sox", "sox"],
    args: ["--version"],
  });

  await checkBlackHoleLoopback({
    runCommandWithTimeout: params.runtime.system.runCommandWithTimeout,
    checks,
    deviceName: params.config.audio.blackholeDeviceUid,
  });
  await checkBlackHolePcmLoopback({
    runCommandWithTimeout: params.runtime.system.runCommandWithTimeout,
    checks,
    deviceName: params.config.audio.blackholeDeviceUid,
  });

  await checkCommandCandidates({
    runCommandWithTimeout: params.runtime.system.runCommandWithTimeout,
    checks,
    id: "facetime-running",
    label: "FaceTime.app process",
    candidates: ["/usr/bin/pgrep"],
    args: ["-x", "FaceTime"],
  });

  pushCheck(checks, {
    id: "realtime-provider",
    label: "Realtime provider credentials",
    ok: hasProviderCredential({ config: params.config, fullConfig: params.fullConfig }),
    message: `${params.config.realtime.provider}:${params.config.realtime.model}`,
  });

  return {
    ok: checks.every((check) => check.ok || !check.required),
    helperConnected: params.helperConnected,
    currentAudioDefaults,
    currentAudioError,
    checks,
  };
}
