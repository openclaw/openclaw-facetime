import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

describe("published plugin manifest", () => {
  it("loads the compiled entry and leaves the UID-derived helper port dynamic", () => {
    const packageManifest = JSON.parse(readFileSync("package.json", "utf8"));
    const pluginManifest = JSON.parse(readFileSync("openclaw.plugin.json", "utf8"));

    expect(packageManifest.openclaw.extensions).toEqual(["./dist/index.js"]);
    expect(packageManifest.openclaw.runtimeExtensions).toEqual(["./dist/index.js"]);
    expect(packageManifest.scripts.prepack).toBe("pnpm build");
    expect(packageManifest.files).toContain("dist/");
    expect(packageManifest.files).toContain("doctor-contract-api.ts");
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
