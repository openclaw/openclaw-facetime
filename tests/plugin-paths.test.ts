import { describe, expect, it, vi } from "vitest";
import {
  ensureCaptureBinary,
  ensureHelperArtifacts,
  resolveCaptureBinary,
  resolveInstalledCaptureCandidates,
  resolvePluginRoot,
} from "../src/plugin-paths.js";

describe("plugin paths", () => {
  it("resolves source and built entries to the same package root", () => {
    expect(resolvePluginRoot("file:///tmp/facetime/index.ts")).toBe("/tmp/facetime");
    expect(resolvePluginRoot("file:///tmp/facetime/dist/index.js")).toBe("/tmp/facetime");
    expect(resolveCaptureBinary("/tmp/facetime")).toBe(
      "/tmp/facetime/native/.build/release/facetime-audio-capture",
    );
  });

  it("prefers an explicitly configured native installation, then Homebrew", () => {
    expect(
      resolveInstalledCaptureCandidates({
        OPENCLAW_FACETIME_NATIVE_DIR: "/custom/facetime",
      }),
    ).toEqual([
      "/custom/facetime/facetime-audio-capture",
      "/opt/homebrew/opt/openclaw-facetime/libexec/facetime-audio-capture",
      "/usr/local/opt/openclaw-facetime/libexec/facetime-audio-capture",
    ]);
  });

  it("uses the Homebrew capture helper without rebuilding", async () => {
    const access = vi.fn(async (path: string) => {
      if (path !== "/opt/homebrew/opt/openclaw-facetime/libexec/facetime-audio-capture") {
        throw new Error("missing");
      }
    });
    const runCommandWithTimeout = vi.fn();

    await expect(
      ensureCaptureBinary({
        pluginRoot: "/tmp/facetime",
        runCommandWithTimeout: runCommandWithTimeout as any,
        access: access as any,
      }),
    ).resolves.toBe(
      "/opt/homebrew/opt/openclaw-facetime/libexec/facetime-audio-capture",
    );
    expect(runCommandWithTimeout).not.toHaveBeenCalled();
  });

  it("builds the packaged capture helper on first activation", async () => {
    let localChecks = 0;
    const access = vi.fn(async (path: string) => {
      if (path !== "/tmp/facetime/native/.build/release/facetime-audio-capture") {
        throw new Error("missing");
      }
      localChecks += 1;
      if (localChecks === 1) {
        throw new Error("not built yet");
      }
    });
    const runCommandWithTimeout = vi.fn().mockResolvedValue({
      code: 0,
      stdout: "",
      stderr: "",
    });

    await expect(
      ensureCaptureBinary({
        pluginRoot: "/tmp/facetime",
        runCommandWithTimeout: runCommandWithTimeout as any,
        access,
        env: {},
      }),
    ).resolves.toBe("/tmp/facetime/native/.build/release/facetime-audio-capture");
    expect(runCommandWithTimeout).toHaveBeenCalledWith(
      ["/bin/bash", "/tmp/facetime/scripts/build-capture.sh"],
      { timeoutMs: 120_000 },
    );
    expect(access).toHaveBeenCalledTimes(4);
  });

  it("builds and validates the packaged injected helper on activation", async () => {
    const runCommandWithTimeout = vi.fn().mockResolvedValue({
      code: 0,
      stdout: "",
      stderr: "",
    });
    const access = vi.fn().mockResolvedValue(undefined);
    const readFile = vi.fn().mockResolvedValue("b".repeat(64));

    await expect(
      ensureHelperArtifacts({
        pluginRoot: "/tmp/facetime",
        runCommandWithTimeout: runCommandWithTimeout as any,
        access,
        readFile: readFile as any,
      }),
    ).resolves.toMatchObject({
      buildId: "b".repeat(64),
      ipcKey: "b".repeat(64),
    });
    expect(runCommandWithTimeout).toHaveBeenCalledWith(
      ["/bin/bash", "/tmp/facetime/scripts/build-helper-macabi.sh", "--if-needed"],
      { timeoutMs: 120_000 },
    );
  });
});
