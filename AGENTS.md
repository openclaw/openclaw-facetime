# Repository guidance

This repository owns native FaceTime binaries, build scripts, and their signed
release artifacts. The FaceTime plugin, configuration, tools, and runtime policy
belong in `openclaw/openclaw`. Read `README.md` and `CONTRIBUTING.md` first.

## Development

- Use Apple Silicon, full Xcode, the Node.js range in `package.json`, and its
  pinned pnpm version. Keep `pnpm-lock.yaml` aligned with dependency changes.
- Run `pnpm test`, syntax-check each `scripts/*.sh` file, and run
  `bash scripts/test-native.sh` for native changes. Build and verify changed
  artifacts with `make native-archive` and `make native-verify`.
- Validate workflow changes with `actionlint`. CI owns macOS build and archive
  proof; CodeQL covers Swift, TypeScript, Ruby, and Actions, not Objective-C.
- Keep changes focused and explain the observed failure or capability. Record
  user-visible, compatibility, security, and release changes in `CHANGELOG.md`.
- Use semantic commit and PR titles. Include exact validation and any remaining
  gaps in the PR. Squash merge after required checks and review pass.

## Boundaries

- Coordinate `helper-endpoint.json` and `native-protocol.env` changes with the
  canonical OpenClaw plugin. Do not change protocol versions independently.
- Never change SIP, TCC, Developer Tools policy, inject into an application, or
  install a driver as part of automated tests. Live device work needs explicit
  operator authorization.
- Never commit credentials, IPC keys, call identifiers, private logs, generated
  binaries, or signing material. Use `SECURITY.md` for private reports.
- Keep third-party attribution intact. The generated GPL-derived audio driver
  remains separate from the MIT/Apache native release archive.
- Read `docs/RELEASING.md` before release work. Local ad-hoc-signed archives are
  development artifacts; only the Foundation release workflow publishes.
- Edit this file rather than its `CLAUDE.md` symlink.
