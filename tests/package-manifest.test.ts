import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

describe("published plugin manifest", () => {
  it("loads the compiled entry and leaves the UID-derived helper port dynamic", () => {
    const packageManifest = JSON.parse(readFileSync("package.json", "utf8"));
    const pluginManifest = JSON.parse(readFileSync("openclaw.plugin.json", "utf8"));

    expect(packageManifest.openclaw.extensions).toEqual(["./dist/index.js"]);
    expect(packageManifest.openclaw.runtimeExtensions).toEqual(["./dist/index.js"]);
    expect(packageManifest.scripts.prepack).toBe("pnpm build");
    expect(packageManifest.license).toBe("MIT");
    expect(packageManifest.author).toBe("OpenClaw contributors");
    expect(packageManifest.homepage).toBe(
      "https://github.com/openclaw/openclaw-facetime#readme",
    );
    expect(packageManifest.bugs.url).toBe(
      "https://github.com/openclaw/openclaw-facetime/issues",
    );
    expect(packageManifest.os).toEqual(["darwin"]);
    expect(packageManifest.cpu).toEqual(["arm64"]);
    expect(packageManifest.files).toContain("dist/");
    expect(packageManifest.files).toContain("doctor-contract-api.ts");
    expect(packageManifest.files).toContain("version.env");
    expect(packageManifest.files).toContain("native/Resources/");
    expect(packageManifest.files).toContain("LICENSE");
    expect(packageManifest.files).toContain("THIRD_PARTY_NOTICES.md");
    expect(packageManifest.files).toContain("skills/");
    expect(packageManifest.devDependencies.openclaw).toBe("2026.7.2-beta.3");
    expect(packageManifest.peerDependencies.openclaw).toBe(">=2026.7.2-beta.4");
    expect(packageManifest.openclaw.install.minHostVersion).toBe(">=2026.7.2-beta.4");
    expect(packageManifest.openclaw.compat.pluginApi).toBe(">=2026.7.2-beta.4");
    expect(packageManifest.openclaw.build.openclawVersion).toBe("2026.7.2-beta.3");
    expect(pluginManifest.skills).toEqual(["./skills"]);
    expect(pluginManifest.contracts.tools).toEqual(["facetime_call"]);
    expect(pluginManifest.configSchema.properties.helperPort).toEqual({ type: "number" });
  });
});
