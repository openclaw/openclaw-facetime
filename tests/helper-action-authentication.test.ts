import { execFileSync } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";

describe("FaceTime helper action authentication", () => {
  it("rejects same-session replay and envelopes captured before reconnect", () => {
    const outputDir = mkdtempSync(path.join(tmpdir(), "facetime-helper-auth."));
    const binary = path.join(outputDir, "action-auth-tests");
    try {
      execFileSync("/usr/bin/clang", [
        "-fobjc-arc",
        "-framework",
        "Foundation",
        "helper/FaceTimeHelper/ActionAuthentication.m",
        "helper/tests/ActionAuthenticationTests.m",
        "-o",
        binary,
      ]);
      expect(() => execFileSync(binary)).not.toThrow();
    } finally {
      execFileSync("/usr/bin/trash", [outputDir]);
    }
  });
});
