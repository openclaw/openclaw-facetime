# Releasing

Foundation releases contain the signed `facetime-audio-capture` executable plus
`VERSION`, `LICENSE`, and `THIRD_PARTY_NOTICES.md`. No injected helper or native
call-control artifact is permitted.

1. Validate the exact source commit with `pnpm test` and
   `bash scripts/test-native.sh`.
2. Build the unsigned local archive with `make native-archive`; never publish
   this ad-hoc-signed artifact.
3. Run the release workflow with the Foundation Developer ID and notarization
   credentials. The workflow freezes the source tag, signs the capture binary,
   notarizes the archive, and independently verifies checksum, four-file shape,
   arm64 architecture, entitlements, Developer ID team, and Gatekeeper ticket.
4. Only after the GitHub release is published may the reviewed Homebrew profile
   be dispatched to the tap.

`scripts/verify-native-release.sh` is the executable artifact contract. Changes
to that contract require coordinated plugin and Homebrew review.
