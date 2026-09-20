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

Update `VERSION` in `version.env` and move the relevant `CHANGELOG.md` entries
into that version's dated section. Merge with green CI, then dispatch **Release**
from the current `main` branch with that version. Before creating a tag, the
workflow verifies that the repository is public, all six signing/notarization/
tap secrets are present, and the exact target commit has a successful `ci.yml`
push run on the default branch. It then:

1. Validates SemVer, current `main`, exact green CI, and distribution readiness.
2. Creates or verifies an immutable annotated tag.
3. Imports only `Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)`
   into an ephemeral keychain.
4. Builds, signs, and notarizes the seven-file archive.
5. Creates or resumes a draft release, downloads it independently, verifies
   checksums, Foundation Team ID, helper identity, protocol version, and online
   Apple notarization tickets.
6. Publishes the verified draft. A rerun resumes an existing draft or verifies
   the same existing published release without replacing its assets.
7. Verifies that the tap's allowlisted FaceTime profile is present on `main`,
   byte-identical to the native formula contract, and exposed by the active tap
   updater workflow.
8. Dispatches the formula updater in `openclaw/homebrew-tap`.

The required organization secrets, public-download decision, branch settings,
and first-formula procedure are in `FOUNDATION_RELEASE_HANDOFF.md`.

## Homebrew

The release workflow never asks the tap's generic missing-formula path to create
this formula. That path targets ordinary four-platform command-line archives and
cannot preserve FaceTime's seven-file `libexec` contract. The tap-owned
`formula_profile=openclaw-facetime` implementation must be merged in
`openclaw/homebrew-tap` before Homebrew dispatch. The native workflow checks the
allowlisted capability and byte-identical profile only after it has published
and verified the native release.

For the first release, run the native workflow before merging the tap profile.
The run publishes the signed and notarized GitHub release, then is expected to
fail at **Validate Homebrew handoff readiness**. Use that real public archive to
prove and merge the tap profile. Rerun the native workflow with the same version;
it reuses the immutable annotated tag and published release, verifies the
existing public assets, and completes the tap dispatch. Do not delete or
recreate the tag or release between runs. Later releases normally complete in a
single run because the profile is already present.

`packaging/homebrew/openclaw-facetime.rb` records the reviewed native archive
contract. Releases use `scripts/update-homebrew.sh` to dispatch the tap-owned
profile after the verified release is public, allowing the tap to download and
hash the asset before it seeds or updates the formula. `HOMEBREW_TAP_TOKEN`
needs Actions write only; the tap's own `GITHUB_TOKEN` owns formula commits.

If publication succeeded but the tap handoff failed, repair the tap credential
or profile first, then dispatch **Homebrew** from current protected `main`.
This retry uses the version in `version.env` and requires its published archive
and SHA-256 digest. It runs the canonical updater with `HOMEBREW_TAP_TOKEN` and
waits for the matching tap run to finish. It does not rebuild, sign, or modify
the native release. There is no tag input: older releases require a separate
maintainer decision. A successful retry of an already-current formula is a no-op.

Both entrypoints use the same readiness and dispatch workflow. It requires the
active tap updater and a byte-identical profile before using the tap token.
On historical release reruns, the expected profile comes from the validated
native commit, while the updater comes from the frozen workflow commit. Older
tags do not need to contain the shared workflow or the corrected updater.

The formula preserves both Mach-O signatures with `skip_clean` and installs all
seven files under `opt/openclaw-facetime/libexec`, which is the plugin's native
artifact contract. It also declares SoX for the OpenClaw host's separate
playback process.

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
