import { spawnSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

const injectHelperScript = resolve(import.meta.dirname, "../scripts/inject-helper.sh");

describe("FaceTime helper injection", () => {
  it.each([
    {
      name: "enabled",
      output: "System Integrity Protection status: enabled.",
      code: 0,
      state: "blocked",
    },
    {
      name: "disabled",
      output: "System Integrity Protection status: disabled.",
      code: 0,
      state: "permitted",
    },
    {
      name: "custom debug disabled",
      output:
        "System Integrity Protection status: unknown (Custom Configuration).\n\tDebugging Restrictions: disabled",
      code: 0,
      state: "permitted",
    },
    {
      name: "custom debug enabled",
      output:
        "System Integrity Protection status: unknown (Custom Configuration).\n\tDebugging Restrictions: enabled",
      code: 0,
      state: "blocked",
    },
    {
      name: "unknown",
      output: "System Integrity Protection status: unknown",
      code: 0,
      state: "unknown",
    },
    { name: "empty", output: "", code: 0, state: "unknown" },
    {
      name: "unrecognized suffix",
      output: "System Integrity Protection status: disabled unexpectedly",
      code: 0,
      state: "unknown",
    },
    {
      name: "failed command",
      output: "System Integrity Protection status: disabled.",
      code: 1,
      state: "unknown",
    },
  ])("reports $name SIP status without changing host policy", ({ output, code, state }) => {
    // Source the real entrypoint with shell-command fixtures. Developer Tools
    // stays disabled so even permitted SIP cases stop before native side effects.
    const result = spawnSync(
      "/bin/bash",
      [
        "-c",
        `
      function /usr/bin/csrutil() {
        printf '%s\\n' "$SIP_OUTPUT"
        return "$SIP_EXIT"
      }
      function DevToolsSecurity() { printf 'disabled\\n'; }
      script=$1
      shift
      source "$script" "$@"
    `,
        "sip-test",
        injectHelperScript,
      ],
      {
        encoding: "utf8",
        env: {
          PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
          HOME: "/nonexistent",
          SIP_OUTPUT: output,
          SIP_EXIT: String(code),
        },
        timeout: 5000,
      },
    );

    expect(result.error).toBeUndefined();
    expect(result.status).toBe(1);
    if (state === "unknown") {
      expect(result.stderr).toContain("Could not verify SIP debugging restrictions");
      expect(result.stderr).toContain("/usr/bin/csrutil status");
      expect(result.stderr).not.toContain("csrutil enable --without debug");
      expect(result.stderr).not.toContain("restrictions are enabled");
      expect(result.stderr).not.toContain("Developer Tools mode");
    } else if (state === "blocked") {
      expect(result.stderr).toContain("restrictions are enabled");
      expect(result.stderr).toContain("csrutil enable --without debug");
      expect(result.stderr).not.toContain("Developer Tools mode");
    } else {
      expect(result.stderr).toContain("Developer Tools mode is disabled");
      expect(result.stderr).not.toContain("csrutil enable --without debug");
    }
  });

  it("casts dynamic-loader results for LLDB's fallback expression parser", async () => {
    const source = await readFile(injectHelperScript, "utf8");

    expect(source).toContain('(void *)dlopen(\\"${dylib}\\", 2)');
    expect(source).toContain('(int *)(void *)dlsym(h, \\"OpenClawFaceTimeHelperInitialized\\")');
  });
});
