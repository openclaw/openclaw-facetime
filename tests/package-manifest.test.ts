import { existsSync, readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

describe("private native development harness manifest", () => {
  it("does not advertise or depend on a competing OpenClaw plugin", () => {
    const packageManifest = JSON.parse(readFileSync("package.json", "utf8"));

    expect(packageManifest.name).toBe("@openclaw/facetime-native-harness");
    expect(packageManifest.version).toBe("0.0.0");
    expect(packageManifest.private).toBe(true);
    expect(packageManifest.openclaw).toBeUndefined();
    expect(packageManifest.dependencies).toBeUndefined();
    expect(Object.keys(packageManifest.devDependencies)).toEqual(["vitest"]);
    expect(packageManifest.scripts.build).toBeUndefined();
    expect(packageManifest.scripts.typecheck).toBeUndefined();
    expect(packageManifest.scripts.prepack).toBeUndefined();
    expect(packageManifest.files).toBeUndefined();
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
    for (const pluginPath of [
      "openclaw.plugin.json",
      "index.ts",
      "runtime-entry.ts",
      "runtime-api.ts",
      "doctor-contract-api.ts",
      "skills/facetime/SKILL.md",
    ]) {
      expect(existsSync(pluginPath), pluginPath).toBe(false);
    }

    const ciWorkflow = readFileSync(".github/workflows/ci.yml", "utf8");
    expect(ciWorkflow).toContain("  native:");
    expect(ciWorkflow).not.toContain("pnpm typecheck");
    expect(ciWorkflow).not.toContain("pnpm build\n");
  });
});
