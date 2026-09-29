# Foundation release handoff

The Foundation-owned release publishes one notarized Apple Silicon capture
binary and its metadata. Required secrets remain the Developer ID certificate,
App Store Connect notarization credentials, and Homebrew tap token documented
in the release workflow.

The reviewed Homebrew formula installs `facetime-audio-capture`, `VERSION`,
license/notices, and SoX. It must not install a FaceTime helper dylib or instruct
users to alter SIP or Developer Tools policy.

Before first publication, verify on a clean macOS host that:

- Homebrew preserves the capture binary signature.
- `facetime-audio-capture --check` reaches the supported Screen & System Audio
  Recording permission boundary.
- The OpenClaw plugin setup reports operator-assisted control and no debugger,
  injection, SIP, Xcode, or reboot prerequisite.
- A manually answered/confirmed FaceTime call can be explicitly attached and
  detached without claiming carrier hangup.
