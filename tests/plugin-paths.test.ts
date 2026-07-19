import { describe, expect, it, vi } from "vitest";
import {
  ensureCaptureBinary,
  resolveCaptureBinary,
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

  it("builds the packaged capture helper on first activation", async () => {
    const access = vi
      .fn()
      .mockRejectedValueOnce(new Error("missing"))
      .mockResolvedValueOnce(undefined);
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
      }),
    ).resolves.toBe("/tmp/facetime/native/.build/release/facetime-audio-capture");
    expect(runCommandWithTimeout).toHaveBeenCalledWith(
      ["/bin/bash", "/tmp/facetime/scripts/build-capture.sh"],
      { timeoutMs: 120_000 },
    );
    expect(access).toHaveBeenCalledTimes(2);
  });
});
