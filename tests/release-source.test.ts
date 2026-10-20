import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const workflow = readFileSync(".github/workflows/release.yml", "utf8");

describe("frozen release source", () => {
  it("validates real release notes and requires independent push CI", () => {
    const result = spawnSync("python3", ["-B", "scripts/test_release_preflight.py"], { encoding: "utf8" });
    expect(result.status, result.stderr).toBe(0);
  });

  it("never creates or rewrites version tags", () => {
    expect(workflow).not.toMatch(/createTag|createRef|--clobber/);
    expect(workflow).toContain("needs: [validate, sign, verify]");
    expect(workflow).toContain("verify-tag refs/audit/tag");
    expect(workflow).toContain('test "$(git rev-parse refs/audit/tag)" = "$TAG_OBJECT"');
  });

  it("keeps verification available without publishing", () => {
    const verify = workflow.split("\n  verify:\n")[1].split("\n  release:\n")[0];
    expect(verify).not.toContain("if:");
    expect(verify).toContain("make native-verify");
    expect(workflow.split("\n  release:\n")[1]).toContain("if: github.event_name == 'push'");
  });

  it.each(["v0.2.0", "v0.2.1-rc.1"])("builds publication arguments under Bash nounset for %s", (tag) => {
    const command = workflow.split("          PYCODE\n")[1].split("          gh release download")[0];
    const result = spawnSync("/bin/bash", ["-uc", `gh() { printf '%s\\n' "$@"; }\n${command}`], {
      encoding: "utf8",
      env: { PATH: process.env.PATH, TAG: tag },
    });
    expect(result.status, result.stderr).toBe(0);
    expect(result.stdout.split("\n")).toContain(tag);
    expect(result.stdout.includes("--prerelease")).toBe(tag.includes("-"));
  });
});
