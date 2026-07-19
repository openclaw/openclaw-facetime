import { constants } from "node:fs";
import { access } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { PluginRuntime } from "openclaw/plugin-sdk/plugin-runtime";

export function resolvePluginRoot(entryUrl: string): string {
  const entryDirectory = dirname(fileURLToPath(entryUrl));
  return entryDirectory.endsWith("/dist") ? resolve(entryDirectory, "..") : entryDirectory;
}

export function resolveCaptureBinary(pluginRoot: string): string {
  return resolve(pluginRoot, "native", ".build", "release", "facetime-audio-capture");
}

export async function ensureCaptureBinary(params: {
  pluginRoot: string;
  runCommandWithTimeout: PluginRuntime["system"]["runCommandWithTimeout"];
  access?: typeof access;
}): Promise<string> {
  const binary = resolveCaptureBinary(params.pluginRoot);
  const checkAccess = params.access ?? access;
  try {
    await checkAccess(binary, constants.X_OK);
    return binary;
  } catch {
    // OpenClaw installs npm plugins with lifecycle scripts disabled. Build the
    // signed helper from the packaged Swift source on first activation instead.
  }
  const buildScript = resolve(params.pluginRoot, "scripts", "build-capture.sh");
  const result = await params.runCommandWithTimeout(["/bin/bash", buildScript], {
    timeoutMs: 120_000,
  });
  if (result.code !== 0) {
    throw new Error(
      `FaceTime capture helper build failed: ${result.stderr || result.stdout || `exit ${result.code}`}`,
    );
  }
  await checkAccess(binary, constants.X_OK);
  return binary;
}
