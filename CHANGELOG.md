# Changelog

User-visible native, compatibility, security, and release changes are recorded
here. Published versions are listed in
[GitHub Releases](https://github.com/openclaw/openclaw-facetime/releases).

## Unreleased

## 0.1.2 - 2026-09-21

### Fixed

- Retain and report outbound carrier identities when native safety checks fail after dialing, so the Gateway can reconcile or cancel a call that may still be active. (#35)
- Retain audio suppression through stdin/stdout loss until captured and successor carriers are confirmed stopped; retry uncertain settlement and preserve explicit safe-close behavior. Thanks @SebTardif. (#32)
- Bind capture shutdown signals to the captured process generation so PID reuse cannot target another process, and let queued safe-close commands take precedence over stdout failure. (#32)
- Keep outgoing-call lookup from muting, disconnecting, or adopting a non-FaceTime call while preserving owned-carrier reconciliation and explicit cancellation. Thanks @SebTardif. (#31)
- Reject malformed `set-muted` values before changing call audio; only JSON booleans may mute or unmute a call. Thanks @SebTardif. (#30)
- Keep FaceTime capture alive during bounded audio backpressure by replacing stale pending frames instead of treating ordinary queue saturation as a fatal conversion failure. Thanks @omarshahine. (#26)
- Distinguish unknown or failed SIP status checks from enabled debugging restrictions before helper injection. Unknown status now asks for manual verification instead of recommending a security-policy change. Thanks @omarshahine. (#34)
- Dispatch the Homebrew updater with the tap-owned FaceTime profile alone, without the conflicting artifact override that prevented formula updates. Thanks @vincentkoc. (#25)
- Bind release signing and verification to the validated commit, and recheck the frozen annotated tag before release writes, publication, and handoff. Same-named branches and moved tags cannot substitute release source. Thanks @vincentkoc. (#24)

### Added

- A current-version Homebrew retry workflow for recovering a failed tap handoff after native release publication, without rebuilding or republishing assets. Release and recovery share the same tap-profile readiness checks. Thanks @vincentkoc. (#25)

### Changed

- Document the available signed native release and Homebrew installation.

## 0.1.1 - 2026-09-16

### Fixed

- Preserve the notarized `FaceTimeHelper.dylib` bytes and OpenClaw Foundation Developer ID signature when Homebrew relocates installed Mach-O files. `v0.1.0` remains immutable and must not be dispatched to the tap.

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
