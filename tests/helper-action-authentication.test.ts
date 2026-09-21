import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";

function runNativeCheck(sources: string[], generatedSource?: string) {
  const outputDir = mkdtempSync(path.join(tmpdir(), "facetime-helper-check."));
  const binary = path.join(outputDir, "native-check");
  try {
    if (generatedSource) {
      const source = path.join(outputDir, "dispatch-check.m");
      writeFileSync(source, generatedSource);
      sources = [...sources, source];
    }
    execFileSync("/usr/bin/clang", [
      "-fobjc-arc",
      "-framework",
      "Foundation",
      "-framework",
      "Security",
      ...sources,
      "-o",
      binary,
    ]);
    expect(() => execFileSync(binary)).not.toThrow();
  } finally {
    if (existsSync("/usr/bin/trash")) {
      execFileSync("/usr/bin/trash", [outputDir]);
    } else {
      execFileSync("/usr/bin/python3", [
        "-c",
        "import shutil, sys; shutil.rmtree(sys.argv[1])",
        outputDir,
      ]);
    }
  }
}

describe("FaceTime helper native contracts", () => {
  it(
    "rejects same-session replay and envelopes captured before reconnect",
    { timeout: 20_000 },
    () => {
      // Cold macOS CI compiles this native harness inside the test, so allow
      // toolchain startup without weakening any authentication assertion.
      runNativeCheck([
        "helper/FaceTimeHelper/ConnectionAuthentication.m",
        "helper/tests/ConnectionAuthenticationTests.m",
      ]);
    },
  );

  it(
    "validates set-muted JSON before changing call or conversation audio",
    { timeout: 20_000 },
    () => {
      const helper = readFileSync("helper/FaceTimeHelper/FaceTimeHelper.m", "utf8");
      const action = helper.indexOf('} else if ([event isEqualToString:@"set-muted"]) {');
      const start = helper.indexOf("\n", action) + 1;
      const end = helper.indexOf(
        '    } else if ([event isEqualToString:@"start-transmission"])',
        start,
      );
      expect(action).toBeGreaterThan(0);
      expect(end).toBeGreaterThan(start);
      // Compile the real dispatch branch against synthetic Apple calls so a
      // missing guard fails on actual audio writes, without injecting a helper.
      const fixture = readFileSync("helper/tests/SetMutedDispatchTests.m", "utf8");
      runNativeCheck(
        [],
        fixture.replace("/* OPENCLAW_SET_MUTED_BODY */", helper.slice(start, end)),
      );
    },
  );
  it(
    "keeps outgoing lookup off non-FaceTime audio and retained ownership",
    { timeout: 20_000 },
    () => {
      const helper = readFileSync("helper/FaceTimeHelper/FaceTimeHelper.m", "utf8");
      const between = (startMarker: string, endMarker: string) => {
        const start = helper.indexOf(startMarker);
        const end = helper.indexOf(endMarker, start + startMarker.length);
        expect(start).toBeGreaterThan(0);
        expect(end).toBeGreaterThan(start);
        return helper.slice(start, end);
      };
      const branch = (name: string, next: string) => {
        const content = between(`} else if ([event isEqualToString:@"${name}"]) {`, next);
        return content.slice(content.indexOf("\n") + 1);
      };
      const fixture = readFileSync("helper/tests/FindOutgoingDispatchTests.m", "utf8");
      runNativeCheck(
        [],
        fixture
          .replace(
            "/* OPENCLAW_OUTBOUND_LOOKUP */",
            between(
              "static BOOL CallsShareCarrierIdentity(",
              "static void ReleaseRetainedOutboundCall(",
            ),
          )
          .replace(
            "/* OPENCLAW_FIND_OUTGOING_BODY */",
            branch(
              "find-outgoing-call",
              '    } else if ([event isEqualToString:@"cancel-outgoing-call"])',
            ),
          )
          .replace(
            "/* OPENCLAW_CANCEL_OUTGOING_BODY */",
            branch("cancel-outgoing-call", "\n    }\n}\n\n@end"),
          ),
      );
    },
  );
});
