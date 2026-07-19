import type { PluginRuntime } from "openclaw/plugin-sdk/plugin-runtime";
import { OPENCLAW_FEED_DEVICE, OPENCLAW_MIC_DEVICE, SOX_COMMAND } from "./audio-pump.js";

type RunCommandWithTimeout = PluginRuntime["system"]["runCommandWithTimeout"];

export function pairedAudioProbeCommands(): Array<{ label: string; argv: string[] }> {
  return [
    {
      label: OPENCLAW_FEED_DEVICE,
      argv: [SOX_COMMAND, "-q", "-n", "-t", "coreaudio", OPENCLAW_FEED_DEVICE, "trim", "0", "0.05"],
    },
    {
      label: OPENCLAW_MIC_DEVICE,
      argv: [SOX_COMMAND, "-q", "-t", "coreaudio", OPENCLAW_MIC_DEVICE, "-n", "trim", "0", "0.05"],
    },
  ];
}

export async function assertPairedAudioTransport(
  runCommandWithTimeout: RunCommandWithTimeout,
): Promise<void> {
  for (const { label, argv } of pairedAudioProbeCommands()) {
    const probe = await runCommandWithTimeout(argv, { timeoutMs: 3_000 });
    if (probe.code !== 0) {
      throw new Error(
        `${label} audio probe failed: ${probe.stderr || probe.stdout || `exit ${probe.code}`}`,
      );
    }
  }
}
