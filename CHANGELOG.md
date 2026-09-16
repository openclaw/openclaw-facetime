# Changelog

User-visible native, compatibility, security, and release changes are recorded
here. Published versions are listed in
[GitHub Releases](https://github.com/openclaw/openclaw-facetime/releases).

## Unreleased

### Added

- Repository ownership, contribution templates, private security reporting
  guidance, editor defaults, and dependency update automation.
- CodeQL analysis for Swift capture code, the TypeScript test harness, the
  Homebrew Ruby formula, and GitHub Actions workflows.
- Workflow linting and complete shell-script syntax checks in CI.

### Changed

- Upgrade the private development harness to Vitest 5. Repository development
  now requires Node.js 22.22.3+ within Node 22, 24.15.0+ within Node 24, or 26+;
  Node 25 users must upgrade to a supported version. Native binaries and the
  canonical OpenClaw plugin's runtime requirements are unchanged.
- Clarify first-release availability and the native/plugin ownership boundary.
- Keep the standard MIT license text separate from third-party notices.

## 0.1.1 - 2026-09-16

### Fixed

- Preserve the notarized `FaceTimeHelper.dylib` bytes and OpenClaw Foundation
  Developer ID signature when Homebrew relocates installed Mach-O files.
  `v0.1.0` remains immutable and must not be dispatched to the tap.
