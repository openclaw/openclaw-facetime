import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "vitest";

const workflow = readFileSync(".github/workflows/homebrew.yml", "utf8");
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;

function script(name: string) {
  const step = workflow.split(`- name: ${name}\n`)[1];
  const block = step?.match(/          script: \|\n((?:            .*\n|\n)+)/)?.[1];
  assert.ok(block, `missing ${name} script`);
  return new AsyncFunction("github", "context", "core", "process", block.replace(/^ {12}/gm, ""));
}

const verifySource = script("Verify protected source");
const verifyRelease = script("Verify published archive");

function fixture() {
  const context = { repo: { owner: "example", repo: "native" }, ref: "refs/heads/main", sha: "a".repeat(40) };
  const state = {
    repository: { default_branch: "main", visibility: "public" },
    branch: { protected: true, commit: { sha: context.sha } },
    release: { draft: false, assets: [{ name: "openclaw-facetime-macos-arm64.zip", state: "uploaded", digest: `sha256:${"b".repeat(64)}` }] },
    effects: [] as string[],
    logs: [] as string[],
  };
  const github = { rest: { repos: {
    async get(args: object) { assert.deepEqual(args, context.repo); return { data: state.repository }; },
    async getBranch(args: object) {
      assert.deepEqual(args, { ...context.repo, branch: "main" });
      return { data: state.branch };
    },
    async getReleaseByTag(args: object) {
      assert.deepEqual(args, { ...context.repo, tag: "v0.1.1" });
      state.effects.push("release lookup");
      return { data: state.release };
    },
  } } };
  const core = { info: (message: string) => state.logs.push(message) };
  return {
    state, context,
    async run() {
      await verifySource(github, context, core, { env: {} });
      await verifyRelease(github, context, core, { env: { TAG: "v0.1.1" } });
      state.effects.push("dispatch");
    },
  };
}

describe("current-version Homebrew recovery", () => {
  it("permits a published archive only from current protected main", async () => {
    const run = fixture();
    await run.run();
    assert.deepEqual(run.state.effects, ["release lookup", "dispatch"]);
    assert.ok(run.state.logs.some((message) => message.includes(run.state.release.assets[0].digest)));
  });

  for (const change of ["other branch", "stale source", "unprotected branch", "private repository"]) {
    it(`rejects ${change} before release lookup or dispatch`, async () => {
      const run = fixture();
      if (change === "other branch") run.context.ref = "refs/heads/topic";
      if (change === "stale source") run.state.branch.commit.sha = "c".repeat(40);
      if (change === "unprotected branch") run.state.branch.protected = false;
      if (change === "private repository") run.state.repository.visibility = "private";
      await assert.rejects(run.run);
      assert.deepEqual(run.state.effects, []);
    });
  }

  for (const change of ["draft", "missing archive", "incomplete upload", "missing digest"]) {
    it(`rejects a ${change} before dispatch`, async () => {
      const run = fixture();
      if (change === "draft") run.state.release.draft = true;
      if (change === "missing archive") run.state.release.assets = [];
      if (change === "incomplete upload") run.state.release.assets[0].state = "starter";
      if (change === "missing digest") run.state.release.assets[0].digest = "";
      await assert.rejects(run.run);
      assert.deepEqual(run.state.effects, ["release lookup"]);
    });
  }

  for (const versionFile of ["VERSION=0.1.1\n", "VERSION=0.1.1\nVERSION=0.1.2\n", "VERSION=invalid\n"]) {
    it(`propagates canonical version validation for ${JSON.stringify(versionFile)}`, () => {
      const step = workflow.split("- name: Read current version\n")[1];
      const block = step.match(/        run: \|\n((?:          .*\n)+)/)?.[1];
      assert.ok(block);
      const directory = mkdtempSync(join(tmpdir(), "facetime-version-test-"));
      try {
        mkdirSync(join(directory, "scripts"));
        writeFileSync(join(directory, "scripts/native-version.sh"), readFileSync("scripts/native-version.sh"), { mode: 0o755 });
        writeFileSync(join(directory, "version.env"), versionFile);
        const output = join(directory, "output");
        const result = spawnSync("/bin/bash", ["-e", "-c", block.replace(/^ {10}/gm, "")], {
          cwd: directory, env: { PATH: "/usr/bin:/bin", GITHUB_OUTPUT: output }, encoding: "utf8", timeout: 5_000,
        });
        assert.equal(result.error, undefined);
        if (versionFile === "VERSION=0.1.1\n") {
          assert.equal(result.status, 0, result.stderr);
          assert.equal(readFileSync(output, "utf8"), "tag=v0.1.1\n");
        } else {
          assert.notEqual(result.status, 0);
          assert.equal(existsSync(output), false, "invalid versions must not become step outputs");
        }
      } finally {
        rmSync(directory, { recursive: true, force: true });
      }
    });
  }

  it("uses the canonical version and passes only the tap secret to the shared handoff", () => {
    const source = workflow.indexOf("- name: Verify protected source");
    const checkout = workflow.indexOf("- uses: actions/checkout@");
    const version = workflow.indexOf("- name: Read current version");
    const release = workflow.indexOf("- name: Verify published archive");
    const dispatch = workflow.indexOf("\n  homebrew:");
    assert.ok(source >= 0 && source < checkout && checkout < version && version < release && release < dispatch);
    assert.match(workflow.slice(checkout, version), /ref: \$\{\{ github\.sha \}\}/);
    assert.match(workflow.slice(checkout, version), /persist-credentials: false/);
    assert.match(workflow.slice(version, release), /scripts\/native-version\.sh/);
    assert.doesNotMatch(workflow.slice(0, dispatch), /secrets\./);
    assert.match(workflow.slice(dispatch), /needs: prepare/);
    assert.match(workflow.slice(dispatch), /uses: \.\/\.github\/workflows\/homebrew-handoff\.yml/);
    assert.match(workflow.slice(dispatch), /native-source-sha: \$\{\{ github\.sha \}\}/);
    assert.match(workflow.slice(dispatch), /tag: \$\{\{ needs\.prepare\.outputs\.tag \}\}/);
    assert.match(workflow.slice(dispatch), /HOMEBREW_TAP_TOKEN: \$\{\{ secrets\.HOMEBREW_TAP_TOKEN \}\}/);
    assert.doesNotMatch(workflow.slice(dispatch), /secrets: inherit|always\(\)|continue-on-error/);
    assert.match(workflow, /group: facetime-release\n  cancel-in-progress: false/);
    assert.match(workflow, /permissions:\n  contents: read/);
    assert.doesNotMatch(workflow, /\binputs:|contents: write|sign-and-notarize|release (create|edit|upload)/);
  });
});
