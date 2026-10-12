# Native releases

The signed macOS arm64 archive and Homebrew handoff are published by
`.github/workflows/release.yml` after a signed annotated `vX.Y.Z` tag push.
Prepare `version.env` and a matching dated `CHANGELOG.md` section on protected
main, and require successful push CI on the exact commit before tagging.
Only signers in `.github/release-allowed-signers` are accepted. Existing versions
are refused and tags are never created or changed by the workflow.

Dispatch from main with `dry_run=true` (default) to build, sign, notarize, run
native verification, and retain the ZIP, checksum and notarization receipt.
The rehearsal does not publish or update Homebrew. The final publish job
reverifies the immutable signed tag, publishes changelog notes with the verified
payload, and hands off to `openclaw/homebrew-tap`.

Required secrets: `MACOS_SIGNING_P12`, `MACOS_SIGNING_P12_PASSWORD`, `ASC_KEY_ID`,
`ASC_ISSUER_ID`, `ASC_PRIVATE_KEY_P8`, and `HOMEBREW_TAP_TOKEN`.
Local native build and verification scripts remain useful for development;
publication belongs to CI. Releases require separate explicit authorization.
