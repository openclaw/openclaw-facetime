# Releasing the native FaceTime components

This repository publishes only the native capture executable and injected
helper consumed by the FaceTime plugin in `openclaw/openclaw`. The release shape
follows `openclaw/imsg`: build from versioned source, sign with Developer ID,
notarize one ZIP archive, independently verify it, publish it on GitHub, then
update Homebrew from the release URL and SHA-256.

## Artifact contract

`openclaw-facetime-macos-arm64.zip` contains exactly:

- `facetime-audio-capture`, an arm64 macOS executable
- `FaceTimeHelper.dylib`, an arm64e + arm64 Mac Catalyst injected helper
- `FaceTimeHelper.build-id`, the identity required by the plugin handshake
- `native-protocol.env`, the plugin/native compatibility contract
- `VERSION`
- `LICENSE`
- `THIRD_PARTY_NOTICES.md`

The archive is intentionally Apple Silicon only. It does not contain
`OpenClawBridge.driver`; that driver is a modified GPL-3.0 BlackHole build with
a separate distribution decision.

## Local testing

Local development uses ad-hoc signing and does not require Foundation secrets:

```bash
make native-archive
make native-verify
```

For a private local production-signing test, provide the Developer ID and App
Store Connect values through environment variables, then run:

```bash
OUTPUT_DIR=/tmp make native-sign
REQUIRE_DEVELOPER_ID=1 \
  REQUIRE_NOTARIZATION_RECEIPT=1 \
  REQUIRE_NOTARIZED_GATEKEEPER=1 \
  scripts/verify-native-release.sh /tmp/openclaw-facetime-macos-arm64.zip
```

Do not add credentials to this repository or pass secret values as command
arguments.

## Foundation release

Update `VERSION` in `version.env`, merge with green CI, then dispatch **Release**
from the current `main` branch with that version. The workflow:

1. Validates SemVer, current `main`, and independent green CI.
2. Creates or verifies an immutable annotated tag.
3. Imports only `Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)` into an ephemeral keychain.
4. Builds, signs, and notarizes the seven-file archive.
5. Creates a draft release, downloads it independently, verifies checksums,
   Foundation Team ID, helper identity, protocol version, and online Apple
   notarization tickets.
6. Publishes the verified draft.
7. Dispatches the formula updater in `openclaw/homebrew-tap`.

The required organization secrets, public-download decision, branch settings,
and first-formula procedure are in `FOUNDATION_RELEASE_HANDOFF.md`.

## Homebrew

The initial formula must be created only after the first public release. Copy
`packaging/homebrew/openclaw-facetime.rb` to
`openclaw/homebrew-tap/Formula/openclaw-facetime.rb`, replace
`RELEASE_SHA256` with the published archive digest, and validate it in the tap.
Future releases use `scripts/update-homebrew.sh` automatically.

The formula preserves both Mach-O signatures with `skip_clean` and installs all
seven files under `opt/openclaw-facetime/libexec`, which is the plugin's native
artifact contract.

## Security properties

- `scripts/sign-and-notarize.sh` refuses to fall back to ad-hoc signing.
- The release workflow rejects any signing certificate outside Team ID
  `FWJYW4S8P8` or with a different authority name.
- `scripts/verify-native-release.sh` checks exact inventory, checksum, version,
  protocol, architecture slices, signatures, receipt binding, and Gatekeeper's
  online notarization result.
- The helper contains no machine credential. Injection creates a private
  one-use sidecar, and the helper rejects unsafe ownership, permissions, type,
  size, or token format.
