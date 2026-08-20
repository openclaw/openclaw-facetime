import { constants } from "node:fs";
import { access, readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { PluginRuntime } from "openclaw/plugin-sdk/plugin-runtime";

const HOMEBREW_NATIVE_DIRS = [
  "/opt/homebrew/opt/openclaw-facetime/libexec",
  "/usr/local/opt/openclaw-facetime/libexec",
] as const;

export function resolvePluginRoot(entryUrl: string): string {
  const entryDirectory = dirname(fileURLToPath(entryUrl));
  return entryDirectory.endsWith("/dist") ? resolve(entryDirectory, "..") : entryDirectory;
}

export function resolveCaptureBinary(pluginRoot: string): string {
  return resolve(pluginRoot, "native", ".build", "release", "facetime-audio-capture");
}

export function resolveInstalledCaptureCandidates(
  env: NodeJS.ProcessEnv = process.env,
): string[] {
  const configured = env.OPENCLAW_FACETIME_NATIVE_DIR?.trim();
  return [
    ...(configured ? [resolve(configured, "facetime-audio-capture")] : []),
    ...HOMEBREW_NATIVE_DIRS.map((directory) =>
      resolve(directory, "facetime-audio-capture"),
    ),
  ];
}

export function resolveHelperDylib(): string {
  return resolve(
    homedir(),
    "Library",
    "Containers",
    "com.apple.FaceTime",
    "Data",
    "tmp",
    "FaceTimeHelper.dylib",
  );
}

export function resolveHelperIpcKey(): string {
  return resolve(
    homedir(),
    "Library",
    "Application Support",
    "OpenClaw",
    "FaceTime",
    "helper-ipc-key",
  );
}

export function resolveHelperBuildStamp(): string {
  return resolve(
    homedir(),
    "Library",
    "Application Support",
    "OpenClaw",
    "FaceTime",
    "helper-build.sha256",
  );
}

export async function ensureCaptureBinary(params: {
  pluginRoot: string;
  runCommandWithTimeout: PluginRuntime["system"]["runCommandWithTimeout"];
  access?: typeof access;
  env?: NodeJS.ProcessEnv;
}): Promise<string> {
  const checkAccess = params.access ?? access;
  for (const candidate of resolveInstalledCaptureCandidates(params.env)) {
    try {
      await checkAccess(candidate, constants.X_OK);
      return candidate;
    } catch {
      // Continue through the ordered native-install candidates.
    }
  }

  const binary = resolveCaptureBinary(params.pluginRoot);
  try {
    await checkAccess(binary, constants.X_OK);
    return binary;
  } catch {
    // Source installs retain a local build fallback for development.
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

export async function ensureHelperArtifacts(params: {
  pluginRoot: string;
  runCommandWithTimeout: PluginRuntime["system"]["runCommandWithTimeout"];
  access?: typeof access;
  readFile?: typeof readFile;
}): Promise<{ buildId: string; dylib: string; ipcKey: string }> {
  const buildScript = resolve(params.pluginRoot, "scripts", "build-helper-macabi.sh");
  const result = await params.runCommandWithTimeout(["/bin/bash", buildScript, "--if-needed"], {
    timeoutMs: 120_000,
  });
  if (result.code !== 0) {
    throw new Error(
      `FaceTime injected helper build failed: ${result.stderr || result.stdout || `exit ${result.code}`}`,
    );
  }
  const dylib = resolveHelperDylib();
  await (params.access ?? access)(dylib, constants.R_OK);
  const ipcKey = (await (params.readFile ?? readFile)(resolveHelperIpcKey(), "utf8")).trim();
  if (!/^[\da-f]{64}$/u.test(ipcKey)) {
    throw new Error("FaceTime helper build produced an invalid IPC authentication key");
  }
  const buildId = (
    await (params.readFile ?? readFile)(resolveHelperBuildStamp(), "utf8")
  ).trim();
  if (!/^[\da-f]{64}$/u.test(buildId)) {
    throw new Error("FaceTime helper build produced an invalid build identity");
  }
  return { buildId, dylib, ipcKey };
}
