import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

describe("privileged FaceTime support boundaries", () => {
  it("loads helper secrets from a private one-use sidecar and rejects action replay", () => {
    const buildHelper = readFileSync("scripts/build-helper-macabi.sh", "utf8");
    const compileHelper = readFileSync("scripts/compile-helper-macabi.sh", "utf8");
    const ensureHelperKey = readFileSync("scripts/ensure-helper-ipc-key.sh", "utf8");
    const injectHelper = readFileSync("scripts/inject-helper.sh", "utf8");
    const helperSource = readFileSync("helper/FaceTimeHelper/FaceTimeHelper.m", "utf8");
    const connectionAuthSource = readFileSync(
      "helper/FaceTimeHelper/ConnectionAuthentication.m",
      "utf8",
    );

    expect(buildHelper).not.toContain("OPENCLAW_FACETIME_HELPER_TOKEN");
    expect(compileHelper).not.toContain("OPENCLAW_FACETIME_HELPER_TOKEN");
    expect(compileHelper).toContain("ConnectionAuthentication.m");
    expect(buildHelper).toContain('scripts/ensure-helper-ipc-key.sh"');
    expect(buildHelper).toContain("/opt/homebrew/opt/openclaw-facetime/libexec");
    expect(buildHelper).toContain('candidate_build_id="${native_dir}/FaceTimeHelper.build-id"');
    expect(buildHelper).toContain("codesign --verify --strict");
    expect(buildHelper).toContain('strings "${candidate_dylib}"');
    expect(injectHelper).toContain('scripts/ensure-helper-ipc-key.sh"');
    expect(ensureHelperKey).toContain('/bin/mv -n "${temporary_key}"');
    expect(ensureHelperKey).toContain('[[ -L "${ipc_key_file}"');
    expect(ensureHelperKey).toContain('"${file_mode}" != "600"');
    expect(injectHelper).toContain('auth_sidecar="${dylib}.auth"');
    expect(injectHelper).toContain('descriptor = os.open(path, flags, 0o600)');
    expect(injectHelper).toContain("os.O_WRONLY | os.O_CREAT | os.O_EXCL");
    expect(injectHelper).toContain('flags |= os.O_NOFOLLOW');
    expect(injectHelper).toContain("os.unlink(p) if os.path.lexists(p) else None");
    expect(injectHelper).not.toContain(': > "${auth_sidecar}"');
    expect(injectHelper).toContain("OpenClawFaceTimeHelperInitialized");
    expect(injectHelper).toContain("ready && *ready == 1");
    expect(injectHelper).toContain("LLDB did not confirm that FaceTimeHelper.dylib initialized");
    expect(connectionAuthSource).toContain("O_NOFOLLOW");
    expect(connectionAuthSource).toContain("metadata.st_uid != getuid()");
    expect(connectionAuthSource).toContain(
      "(S_IRWXU | S_IRWXG | S_IRWXO)) != (S_IRUSR | S_IWUSR)",
    );
    expect(connectionAuthSource).toContain("server-to-helper");
    expect(connectionAuthSource).toContain("helper-to-server");
    expect(helperSource).toContain("OpenClawFaceTimeLoadHelperTokenForImageAddress");
    expect(helperSource).toContain("OpenClawFaceTimeHelperInitialized = 1");
    expect(connectionAuthSource).toContain("sequence != _incomingSequence + 1");
    expect(helperSource).not.toContain("Received raw json");
    expect(helperSource).not.toContain("Message received: %{public}@, %{public}@");
  });

  it("binds privileged driver installation to a fresh hash-verified archive", () => {
    const installer = readFileSync("scripts/install-driver.sh", "utf8");
    const privilegedInstaller = readFileSync("scripts/install-driver.applescript", "utf8");
    const rootInstallerBuffer = readFileSync("scripts/install-driver-root.sh");
    const rootInstaller = rootInstallerBuffer.toString("utf8");
    const rootInstallerDigest = createHash("sha256").update(rootInstallerBuffer).digest("hex");

    expect(installer).toContain('scripts/install-driver-root.sh"');
    expect(privilegedInstaller).toContain(
      `set expectedInstallerDigest to "${rootInstallerDigest}"`,
    );
    expect(privilegedInstaller).toContain("/private/tmp/openclaw-driver-install.XXXXXX");
    expect(rootInstaller).toContain("e9de179da54ed55ff27876990f3a2dcf");
    expect(rootInstaller).toContain("CFBundleIdentifier");
    expect(rootInstaller).toContain("OpenClawDriverRecipe");
    expect(rootInstaller).toContain("codesign --verify --strict");
  });

  it("fails closed on rejected notarization and an unexpected Developer ID team", () => {
    const notarize = readFileSync("scripts/sign-and-notarize.sh", "utf8");
    const updateHomebrew = readFileSync("scripts/update-homebrew.sh", "utf8");
    const verifyRelease = readFileSync("scripts/verify-native-release.sh", "utf8");
    const releaseWorkflow = readFileSync(".github/workflows/release.yml", "utf8");

    expect(notarize).toContain('--output-format json)"');
    expect(notarize).toContain('"${notary_status}" != "Accepted"');
    expect(notarize).toContain('notarytool log "${notary_id}"');
    expect(notarize).toContain('EXPECTED_TEAM_ID="${expected_team_id}"');
    expect(verifyRelease).toContain("certificate leaf[subject.OU]");
    expect(verifyRelease).toContain('"${expected_team_id}"');
    expect(verifyRelease).toContain('"${checksum_filename}" != "$(basename');
    expect(verifyRelease).toContain('[[ -L "${check_dir}/${required_file}"');
    expect(verifyRelease).toContain("com.apple.security.device.audio-input");
    expect(notarize).toContain('notarytool log "${notary_id}" "${notary_log_file}"');
    expect(notarize).toContain('"archive_sha256": archive_sha256');
    expect(notarize).toContain('issues = log.get("issues") or []');
    expect(notarize).toContain("os.O_WRONLY | os.O_CREAT | os.O_EXCL");
    expect(notarize).toContain('/bin/mv -f "${notary_dir}/notarization-receipt.json"');
    expect(verifyRelease).toContain("REQUIRE_NOTARIZATION_RECEIPT");
    expect(verifyRelease).toContain('receipt["archive_sha256"] != archive_sha256');
    expect(verifyRelease).toContain("REQUIRE_NOTARIZED_GATEKEEPER");
    expect(verifyRelease).toContain("codesign --verify --strict --check-notarization");
    expect(verifyRelease).toContain('-R="notarized"');
    expect(releaseWorkflow).toContain("Developer ID Application: OpenClaw Foundation ($team)");
    expect(releaseWorkflow).toContain("EXPECTED_TEAM_ID: FWJYW4S8P8");
    expect(releaseWorkflow).toContain("REQUIRE_NOTARIZATION_RECEIPT=1");
    expect(releaseWorkflow).toContain("REQUIRE_NOTARIZED_GATEKEEPER=1");
    expect(releaseWorkflow).toContain("ref: ${{ needs.validate.outputs.tag }}");
    expect(releaseWorkflow).toContain("HOMEBREW_TAP_TOKEN");
    expect(updateHomebrew).toContain(
      'tap_repository="${HOMEBREW_TAP_REPOSITORY:-openclaw/homebrew-tap}"',
    );
    expect(updateHomebrew).not.toContain("steipete/homebrew-tap");
  });

  it("gates every release side effect on exact CI and distribution readiness", () => {
    const releaseWorkflow = readFileSync(".github/workflows/release.yml", "utf8");
    const tagJob = releaseWorkflow.indexOf("\n  tag:");
    const readinessGate = releaseWorkflow.indexOf("Validate release and Homebrew readiness");

    expect(readinessGate).toBeGreaterThan(0);
    expect(readinessGate).toBeLessThan(tagJob);
    expect(releaseWorkflow).toContain("workflow_id: 'ci.yml'");
    expect(releaseWorkflow).toContain("run.conclusion === 'success'");
    expect(releaseWorkflow).toContain("REPOSITORY_VISIBILITY");
    expect(releaseWorkflow).toContain("MACOS_SIGNING_P12_PASSWORD");
    expect(releaseWorkflow).toContain("ASC_PRIVATE_KEY_P8");
    expect(releaseWorkflow).toContain("HOMEBREW_TAP_TOKEN");
    expect(releaseWorkflow).toContain(".github/formula-profiles/openclaw-facetime.rb");
    expect(releaseWorkflow).toContain(
      'cmp -s packaging/homebrew/openclaw-facetime.rb "$tap_profile"',
    );
    expect(releaseWorkflow).toContain("formula_profile");
    expect(releaseWorkflow).not.toContain(".permissions.push");
  });

  it("restores the signing search list and resumes existing releases", () => {
    const releaseWorkflow = readFileSync(".github/workflows/release.yml", "utf8");

    expect(releaseWorkflow).toContain('security list-keychains -d user -s "$keychain"');
    expect(releaseWorkflow).toContain('security list-keychains -d user -s "${original_keychains[@]}"');
    expect(releaseWorkflow).toContain('gh release view "$TAG"');
    expect(releaseWorkflow).toContain('gh release upload "$TAG" release-assets/* --clobber');
    expect(releaseWorkflow).toContain("publish-needed");
    expect(releaseWorkflow).toContain("if: steps.release-state.outputs.publish-needed == 'true'");
  });

  it("keeps the reviewed Homebrew profile contract in the native repository", () => {
    const formula = readFileSync("packaging/homebrew/openclaw-facetime.rb", "utf8");

    expect(formula).toContain('sha256 "RELEASE_SHA256"');
    expect(formula).toContain('depends_on "sox"');
    expect(formula).toContain(
      'skip_clean "libexec/facetime-audio-capture", "libexec/FaceTimeHelper.dylib"',
    );
    for (const file of [
      "facetime-audio-capture",
      "FaceTimeHelper.dylib",
      "FaceTimeHelper.build-id",
      "VERSION",
      "native-protocol.env",
      "LICENSE",
      "THIRD_PARTY_NOTICES.md",
    ]) {
      expect(formula).toContain(`libexec.install "${file}"`);
    }
  });

  it("keeps the tap token dispatch-only", () => {
    const updateHomebrew = readFileSync("scripts/update-homebrew.sh", "utf8");

    expect(updateHomebrew).toContain("gh workflow run update-formula.yml");
    expect(updateHomebrew).toContain("-f formula_profile=openclaw-facetime");
    expect(updateHomebrew).not.toContain("gh repo clone");
    expect(updateHomebrew).not.toContain("git push");
  });
});
