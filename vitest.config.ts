import { existsSync } from "node:fs";
import path from "node:path";
import { defineConfig } from "vitest/config";

const localPluginSdkRoot = path.resolve(__dirname, "../openclaw/src/plugin-sdk");

export default defineConfig({
  resolve: {
    // A sibling OpenClaw checkout gives local development source-level SDK
    // coverage. Standalone clones must exercise the installed package instead.
    alias: existsSync(localPluginSdkRoot)
      ? [
          {
            find: /^openclaw\/plugin-sdk\/(.+)$/,
            replacement: path.join(localPluginSdkRoot, "$1.ts"),
          },
          {
            find: "openclaw/plugin-sdk",
            replacement: path.join(localPluginSdkRoot, "index.ts"),
          },
        ]
      : [],
  },
  test: {
    environment: "node",
    include: ["tests/**/*.test.ts"],
  },
});
