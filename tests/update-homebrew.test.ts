import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { describe, it } from "vitest";

const script = resolve("scripts/update-homebrew.sh");

describe("Homebrew profile dispatch", () => {
  for (const watchExit of [0, 1]) {
    it(`sends profile-owned inputs and propagates tap exit ${watchExit}`, () => {
      const directory = mkdtempSync(join(tmpdir(), "facetime-tap-test-"));
      try {
        writeFileSync(join(directory, "gh"), `#!${process.execPath}
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const args = process.argv.slice(2);
const callsPath = path.join(process.env.STUB_DIR, "calls.json");
const calls = fs.existsSync(callsPath) ? JSON.parse(fs.readFileSync(callsPath, "utf8")) : [];
calls.push(args);
fs.writeFileSync(callsPath, JSON.stringify(calls));
const option = (name) => args[args.indexOf(name) + 1];
assert.equal(option("--repo"), "openclaw/homebrew-tap");
if (args[0] === "workflow" && args[1] === "run") {
  assert.equal(args[2], "update-formula.yml");
  assert.equal(option("--ref"), "main");
  const fields = {};
  for (let index = 0; index < args.length; index++) {
    if (args[index] !== "-f") continue;
    const [name, value] = args[++index].split("=");
    fields[name] = value;
  }
  // The tap profile owns its artifact; combining it with an override is rejected.
  assert.deepEqual(Object.keys(fields).sort(), ["formula", "formula_profile", "repository", "request_id", "tag"]);
  assert.equal(fields.formula, "openclaw-facetime");
  assert.equal(fields.formula_profile, "openclaw-facetime");
  assert.equal(fields.repository, "openclaw/openclaw-facetime");
  assert.equal(fields.tag, "v0.1.2");
  assert.match(fields.request_id, /^openclaw-facetime-v0\\.1\\.2-[0-9]+-[0-9]+$/);
  fs.writeFileSync(path.join(process.env.STUB_DIR, "request-id"), fields.request_id);
} else if (args[0] === "run" && args[1] === "list") {
  assert.equal(option("--workflow"), "update-formula.yml");
  assert.equal(option("--branch"), "main");
  assert.equal(option("--event"), "workflow_dispatch");
  const requestId = fs.readFileSync(path.join(process.env.STUB_DIR, "request-id"), "utf8");
  const title = "Update openclaw-facetime for v0.1.2 (" + requestId + ")";
  assert.equal(option("--jq"), ".[] | select(.displayTitle == " + JSON.stringify(title) + ") | .databaseId");
  process.stdout.write("4242\\n");
} else if (args[0] === "run" && args[1] === "watch") {
  assert.equal(args[2], "4242");
  assert.ok(args.includes("--exit-status"));
  process.exit(Number(process.env.WATCH_EXIT));
} else {
  throw new Error("unexpected gh command: " + args.join(" "));
}
`, { mode: 0o755 });

        const result = spawnSync("/bin/bash", [script, "v0.1.2"], {
          env: {
            PATH: `${directory}:/usr/bin:/bin`,
            STUB_DIR: directory,
            WATCH_EXIT: String(watchExit),
          },
          encoding: "utf8",
          timeout: 5_000,
        });
        assert.equal(result.error, undefined);
        assert.equal(result.status, watchExit, result.stderr);
        const calls = JSON.parse(readFileSync(join(directory, "calls.json"), "utf8"));
        assert.deepEqual(calls.map((args) => args.slice(0, 2)), [
          ["workflow", "run"], ["run", "list"], ["run", "watch"],
        ]);
        assert.equal(result.stdout.includes("Homebrew tap update completed:"), watchExit === 0);
        if (watchExit === 0) {
          assert.ok(result.stdout.includes("https://github.com/openclaw/homebrew-tap/actions/runs/4242"));
        }
      } finally {
        rmSync(directory, { recursive: true, force: true });
      }
    });
  }
});
