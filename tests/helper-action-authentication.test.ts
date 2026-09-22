import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";

function runNativeCheck(sources: string[], generatedSource?: string, helperImages = false) {
  const outputDir = mkdtempSync(path.join(tmpdir(), "facetime-helper-check."));
  const binary = path.join(outputDir, "native-check");
  try {
    if (generatedSource) {
      const source = path.join(outputDir, "dispatch-check.m");
      writeFileSync(source, generatedSource);
      sources = [...sources, source];
    }
    const images: string[] = [];
    if (helperImages) {
      for (const name of ["A", "B"]) {
        const image = path.join(outputDir, `helper-${name}.dylib`);
        execFileSync("/usr/bin/clang", [
          "-fobjc-arc", "-framework", "Foundation", "-dynamiclib",
          "-undefined", "dynamic_lookup", "-DHELPER_IMAGE", `-DHelper=Helper${name}`,
          ...sources, "-o", image,
        ]);
        images.push(image);
      }
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
    expect(() => execFileSync(binary, images)).not.toThrow();
  } finally {
    rmSync(outputDir, { recursive: true, force: true });
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
        fixture
          .replace(
            "/* OPENCLAW_REQUIRED_CALL_UUID */",
            helper.slice(
              helper.indexOf("static NSString *RequiredCallUUIDString("),
              helper.indexOf("static BOOL ApplyOutboundSafetyMute("),
            ),
          )
          .replace("/* OPENCLAW_SET_MUTED_BODY */", helper.slice(start, end)),
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
            branch("cancel-outgoing-call", "\n    } else {"),
          ),
      );
    },
  );
  it(
    "retains exact carrier identity when safety checks fail after dialing",
    { timeout: 20_000 },
    () => {
      const helper = readFileSync("helper/FaceTimeHelper/FaceTimeHelper.m", "utf8");
      const action = helper.indexOf('} else if ([event isEqualToString:@"start-call"]) {');
      const start = helper.indexOf("\n", action) + 1;
      const end = helper.indexOf(
        '    } else if ([event isEqualToString:@"find-outgoing-call"])',
        start,
      );
      expect(action).toBeGreaterThan(0);
      expect(end).toBeGreaterThan(start);
      // Compile the actual dispatch branch verbatim against synthetic Apple
      // carriers. This exercises private-API reply ordering without dialing or
      // adding test hooks to the injected helper; authentication is covered above.
      const fixture = readFileSync("helper/tests/OutboundCallReconciliationTests.m", "utf8");
      runNativeCheck(
        [],
        fixture.replace("/* OPENCLAW_START_CALL_BODY */", helper.slice(start, end)),
      );
    },
  );
  it(
    "replies when an authenticated action is unknown",
    { timeout: 20_000 },
    () => {
      const helper = readFileSync("helper/FaceTimeHelper/FaceTimeHelper.m", "utf8");
      const elseStart = helper.lastIndexOf("\n    } else {") + 1;
      const elseBodyStart = helper.indexOf("\n", elseStart) + 1;
      const elseEnd = helper.indexOf("\n    }\n}", elseStart);
      expect(elseStart).toBeGreaterThan(0);
      expect(elseEnd).toBeGreaterThan(elseBodyStart);
      const fixture = readFileSync("helper/tests/UnknownActionDispatchTests.m", "utf8");
      runNativeCheck(
        [],
        fixture.replace("/* OPENCLAW_UNKNOWN_ACTION_ELSE */", helper.slice(elseBodyStart, elseEnd)),
      );
    },
  );  it(
    "stops the previous helper poll owner on reinjection",
    { timeout: 20_000 },
    () => {
      const helper = readFileSync("helper/FaceTimeHelper/FaceTimeHelper.m", "utf8");
      const start = helper.indexOf("-(void)openclaw_stopHelperPolling {");
      const end = helper.indexOf("\n-(void) initializeNetworkController {", start);
      expect(start).toBeGreaterThan(0);
      expect(end).toBeGreaterThan(start);
      const fixture = readFileSync("helper/tests/HelperPollOwnerTests.m", "utf8");
      runNativeCheck(
        [],
        fixture
          .replace("/* OPENCLAW_POLL_LIFECYCLE */", helper.slice(start, end))
          .replace(
            "/* OPENCLAW_POLL_METHOD */",
            helper.slice(
              helper.indexOf("-(void) pollCallStatuses {"),
              helper.indexOf("-(void) callStatusChanged:"),
            ),
          ),
        true,
      );
    },
  );
});
