import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

describe("privileged FaceTime support boundaries", () => {
  it("keeps helper secrets out of compiler arguments and rejects action replay", () => {
    const buildHelper = readFileSync("scripts/build-helper-macabi.sh", "utf8");
    const helperSource = readFileSync("helper/FaceTimeHelper/FaceTimeHelper.m", "utf8");
    const actionAuthSource = readFileSync(
      "helper/FaceTimeHelper/ActionAuthentication.m",
      "utf8",
    );

    expect(buildHelper).toContain("-include \"${secret_header}\"");
    expect(buildHelper).not.toContain(
      '"-DOPENCLAW_FACETIME_HELPER_TOKEN=\\"${ipc_key}\\""',
    );
    expect(buildHelper).toContain("ActionAuthentication.m");
    expect(actionAuthSource).toContain('![_session isEqualToString:session]');
    expect(actionAuthSource).not.toContain("removeObject");
    expect(helperSource).toContain("Replayed FaceTime helper action");
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
});
