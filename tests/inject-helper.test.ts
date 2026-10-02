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
      name: "explicit debug restriction overrides disabled summary",
      output: "System Integrity Protection status: disabled.\nDebugging Restrictions: enabled",
      code: 0,
      state: "blocked",
    },
    {
      name: "contradictory summary",
      output: "System Integrity Protection status: disabled.\nSystem Integrity Protection status: enabled.",
      code: 0,
      state: "unknown",
    },
    {
      name: "malformed debug restriction overrides disabled summary",
      output: "System Integrity Protection status: disabled.\nDebugging Restrictions: unknown",
      code: 0,
      state: "unknown",
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
      expect(result.stderr).toContain("facetime-audio-capture --select-backend");
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
  it("bounds the wait when the debugger ignores SIGTERM", async () => {
    const source = await readFile(injectHelperScript, "utf8");
    const start = source.indexOf("lldb_pid=$!");
    const end = source.indexOf('if [[ "${lldb_status}" -ne 0 ]]', start);
    expect(start).toBeGreaterThan(0);
    expect(end).toBeGreaterThan(start);
    // Exercise the production watchdog and wait against a non-cooperative child.
    // The pipe handshake ensures SIGTERM is ignored before the timeout starts.
    const result = spawnSync("python3", ["-c", String.raw`
import os, signal, subprocess, sys
read_fd, write_fd = os.pipe()
child = "import os,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); os.write(%d,b'1'); time.sleep(30)" % write_fd
script = '"$1" -c "$2" &\nIFS= read -r -n 1 -u "$3"\n' + sys.argv[1] + '\nexit "$lldb_status"'
process = subprocess.Popen(["/bin/bash", "-c", script, "watchdog-test", sys.executable, child, str(read_fd)],
    pass_fds=(read_fd, write_fd), env={**os.environ, "FACETIME_HELPER_ATTACH_TIMEOUT_SECONDS": "0.1"},
    start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
os.close(read_fd)
os.close(write_fd)
try:
    out, err = process.communicate(timeout=3)
    sys.stdout.write(out)
    sys.stderr.write(err)
    sys.exit(process.returncode)
except subprocess.TimeoutExpired:
    sys.stderr.write("watchdog left debugger alive\n")
    sys.exit(124)
finally:
    try: os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError: pass
`, 'target_app=Fixture\n' + source.slice(start, end)], { encoding: "utf8", timeout: 5000 });
    expect(result.error).toBeUndefined();
    expect(result.status).toBe(137);
    expect(result.stderr).toContain("LLDB attach to Fixture timed out");
    expect(result.stderr).not.toContain("watchdog left debugger alive");
  });

});
