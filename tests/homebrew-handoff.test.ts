import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "vitest";

const workflow = readFileSync(".github/workflows/homebrew-handoff.yml", "utf8");
const block = workflow.split("- name: Validate Homebrew handoff readiness\n")[1]
  ?.match(/        run: \|\n((?:          .*\n|\n)+)/)?.[1];
assert.ok(block, "missing shared readiness check");
const readiness = block.replace(/^ {10}/gm, "");

describe("shared Homebrew handoff", () => {
  for (const scenario of ["ready", "mismatched profile", "missing tap profile", "missing native profile", "disabled updater", "missing capability", "wrong default branch"]) {
    it(`checks the frozen native profile before dispatch: ${scenario}`, () => {
      const directory = mkdtempSync(join(tmpdir(), "facetime-readiness-test-"));
      try {
        mkdirSync(join(directory, "scripts"));
        writeFileSync(join(directory, "scripts/update-homebrew.sh"), readFileSync("scripts/update-homebrew.sh"), { mode: 0o755 });
        mkdirSync(join(directory, "packaging/homebrew"), { recursive: true });
        // The current controller B differs from the released native contract A.
        writeFileSync(join(directory, "packaging/homebrew/openclaw-facetime.rb"), "controller B profile\n");
        writeFileSync(join(directory, "gh"), `#!${process.execPath}
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const args = process.argv.slice(2);
const callsPath = path.join(process.env.STUB_DIR, "calls.json");
const calls = fs.existsSync(callsPath) ? JSON.parse(fs.readFileSync(callsPath, "utf8")) : [];
calls.push(args);
fs.writeFileSync(callsPath, JSON.stringify(calls));
const scenario = process.env.SCENARIO;
const profile = "released A profile\\n";
const content = (text) => process.stdout.write(Buffer.from(text).toString("base64") + "\\n");
if (args[0] === "api") {
  if (args[1] === "repos/openclaw/homebrew-tap") {
    assert.equal(args[3], ".default_branch");
    console.log(scenario === "wrong default branch" ? "topic" : "main");
  } else if (args[1] === "repos/openclaw/homebrew-tap/actions/workflows/update-formula.yml") {
    assert.equal(args[3], ".state");
    console.log(scenario === "disabled updater" ? "disabled_manually" : "active");
  } else if (args[1] === "repos/openclaw/homebrew-tap/contents/.github/formula-profiles/openclaw-facetime.rb?ref=main") {
    if (scenario === "missing tap profile") process.exit(1);
    content(scenario === "mismatched profile" ? "different tap profile\\n" : profile);
  } else if (args[1] === "repos/openclaw/openclaw-facetime/contents/packaging/homebrew/openclaw-facetime.rb?ref=" + "a".repeat(40)) {
    if (scenario === "missing native profile") process.exit(1);
    content(profile);
  } else if (args[1] === "repos/openclaw/homebrew-tap/contents/.github/workflows/update-formula.yml?ref=main") {
    content(scenario === "missing capability" ? "on: workflow_dispatch\\n" : "inputs:\\n  formula_profile:\\n");
  } else { throw new Error("unexpected API path: " + args[1]); }
} else if (args[0] === "workflow" && args[1] === "run") {
  assert.equal(args[2], "update-formula.yml");
  assert.ok(args.includes("formula_profile=openclaw-facetime"));
  assert.ok(args.includes("tag=v0.1.1"));
  assert.ok(!args.some((arg) => arg.startsWith("macos_artifact=")));
} else if (args[0] === "run" && args[1] === "list") {
  console.log("4242");
} else if (args[0] === "run" && args[1] === "watch") {
  assert.equal(args[2], "4242");
} else { throw new Error("unexpected command"); }
`, { mode: 0o755 });
        // Execute the real guard then the real current caller; no credentials are available.
        const result = spawnSync("/bin/bash", ["-e", "-c", `${readiness}\nscripts/update-homebrew.sh v0.1.1`], {
          cwd: directory,
          env: {
            PATH: `${directory}:/usr/bin:/bin`, STUB_DIR: directory, SCENARIO: scenario,
            RUNNER_TEMP: directory, GITHUB_REPOSITORY: "openclaw/openclaw-facetime", NATIVE_SOURCE_SHA: "a".repeat(40),
          },
          encoding: "utf8", timeout: 5_000,
        });
        assert.equal(result.error, undefined);
        const calls = JSON.parse(readFileSync(join(directory, "calls.json"), "utf8"));
        assert.equal(calls.some((args) => args[0] === "workflow"), scenario === "ready", result.stderr);
        if (scenario === "ready") {
          assert.equal(result.status, 0, result.stderr);
          assert.ok(calls.some((args) => args[1]?.endsWith(`?ref=${"a".repeat(40)}`)));
          assert.equal(calls.at(-1)[1], "watch");
        } else {
          assert.notEqual(result.status, 0);
        }
      } finally {
        rmSync(directory, { recursive: true, force: true });
      }
    });
  }

  it("keeps control code at the caller SHA and the PAT after readiness", () => {
    const readinessStep = workflow.indexOf("- name: Validate Homebrew handoff readiness");
    const dispatch = workflow.indexOf("- name: Update OpenClaw Homebrew tap");
    assert.match(workflow.slice(0, readinessStep), /ref: \$\{\{ github\.sha \}\}/);
    assert.match(workflow.slice(readinessStep, dispatch), /GH_TOKEN: \$\{\{ github\.token \}\}/);
    assert.match(workflow.slice(readinessStep, dispatch), /NATIVE_SOURCE_SHA: \$\{\{ inputs\.native-source-sha \}\}/);
    assert.doesNotMatch(workflow.slice(readinessStep, dispatch), /secrets\./);
    assert.match(workflow.slice(dispatch), /GH_TOKEN: \$\{\{ secrets\.HOMEBREW_TAP_TOKEN \}\}/);
    assert.match(workflow.slice(dispatch), /TAG: \$\{\{ inputs\.tag \}\}/);
    assert.match(workflow.slice(dispatch), /scripts\/update-homebrew\.sh "\$TAG"/);
    assert.doesNotMatch(workflow, /concurrency:|secrets: inherit|always\(\)|continue-on-error/);
  });
});
