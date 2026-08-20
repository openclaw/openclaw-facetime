# Releasing the native FaceTime components

The release shape follows `openclaw/imsg`: build from versioned source, sign both
native components with Developer ID, notarize one ZIP archive, publish that
immutable archive on GitHub, then update Homebrew from the release URL and
SHA-256.

This pipeline publishes only the native capture executable and injected helper.
It does not create a second TypeScript plugin distribution. The plugin moves to
`openclaw/openclaw` through its experimental integration PR.

## Artifact contract

`openclaw-facetime-macos-arm64.zip` contains:

- `facetime-audio-capture`, an arm64 macOS executable
- `FaceTimeHelper.dylib`, an arm64e + arm64 Mac Catalyst injected helper
- `FaceTimeHelper.build-id`, the helper identity expected by the plugin handshake
- `VERSION`, `LICENSE`, and `THIRD_PARTY_NOTICES.md`

The archive is Apple Silicon only. That is intentional. The supported FaceTime
carrier currently targets Apple Silicon, and the injected helper specifically
requires an arm64e slice. Do not call the archive universal until Intel call
control and audio capture are implemented and live-tested.

The capture executable is signed with the hardened runtime and the narrow
`com.apple.security.device.audio-input` entitlement required by Apple's Core
Audio tap sample. It also embeds `NSAudioCaptureUsageDescription`; the first
capture still requires the user's system-audio recording permission.

The archive does not contain `OpenClawBridge.driver`. That driver is a modified
GPL-3.0 BlackHole build with a separate distribution decision. See issue #11.

## Prerequisites

- Full Xcode at `/Applications/Xcode.app`
- A Developer ID Application signing identity available to `codesign`
- `CODESIGN_IDENTITY`
- `EXPECTED_TEAM_ID`, the non-secret 10-character Apple Developer Team ID
- `APP_STORE_CONNECT_API_KEY_P8`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`

Pass credentials through the environment or the shared macOS release wrapper.
Do not add them to this repository or pass secret values as command arguments.

## Release steps

1. Update `VERSION` in `version.env` and prepare GitHub release notes.
2. Run the complete validation suite from `CONTRIBUTING.md`.
3. Build an ad-hoc-signed test archive:

   ```sh
   make native-archive
   make native-verify
   ```

4. Build, sign, notarize, and verify the release archive:

   ```sh
   OUTPUT_DIR=/tmp make native-sign
   ```

   The output is:

   ```text
   /tmp/openclaw-facetime-macos-arm64.zip
   /tmp/openclaw-facetime-macos-arm64.zip.sha256
   /tmp/openclaw-facetime-macos-arm64.zip.notarization.json
   ```

5. Inspect the archive before publishing:

   ```sh
   REQUIRE_DEVELOPER_ID=1 \
     scripts/verify-native-release.sh /tmp/openclaw-facetime-macos-arm64.zip
   ```

6. Create and push an annotated `vX.Y.Z` tag, then publish all three files as GitHub
   release assets. The tag version must match `version.env`.
7. Dispatch `.github/workflows/release.yml` for the tag. It rebuilds an
   ad-hoc-signed comparison artifact from source and independently verifies the
   published Developer ID-signed archive. Configure the repository variable
   `MAC_RELEASE_TEAM_ID` to the same non-secret Team ID first.
8. After the Homebrew tap exists and is configured, dispatch its updater from a
   trusted maintainer shell. Keep the cross-repository token out of workflows
   that can execute code from a selected release ref:

   ```sh
   scripts/update-homebrew.sh vX.Y.Z
   ```

   The updater uses the immutable GitHub release URL and SHA-256, waits for the
   exact tap workflow run it dispatched, and fails if that run does not pass.

The target is the organization-owned `openclaw/homebrew-tap`, not a personal
maintainer tap. The initial tap formula must be created from
`packaging/homebrew/openclaw-facetime.rb`, replacing `RELEASE_SHA256` with the
published archive digest. Later releases use `scripts/update-homebrew.sh` to
update that formula in place. The formula installs all six archive files under
Homebrew's stable `opt/openclaw-facetime/libexec` path, which is the plugin's
native artifact contract.

[Apple's custom notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
accepts ZIP archives, but ZIP files cannot have a ticket stapled directly. The
ticket is published online for Gatekeeper after `notarytool submit --wait`
succeeds. A future DMG or installer-package release may add a stapled container
without changing the files inside the archive.

## Release safety

- `scripts/sign-and-notarize.sh` refuses to fall back to ad-hoc signing.
- CI never publishes its ad-hoc-signed comparison build as a GitHub release.
- `scripts/verify-native-release.sh` checks the exact archive inventory,
  checksum filename and digest, regular-file types, version, helper build
  identity, required architecture slices, code-signing integrity, and
  optionally Developer ID plus the accepted notarization receipt tied to the
  exact archive SHA-256. Published-asset CI additionally asks Gatekeeper to
  assess both extracted code objects against Apple's online notarization
  service; the repository-generated JSON receipt is traceability metadata, not
  the authoritative acceptance proof.
- The helper contains no machine credential. Injection creates a private
  one-use sidecar beside the copied dylib, and the helper refuses to connect if
  ownership, permissions, type, size, or token format is wrong.
