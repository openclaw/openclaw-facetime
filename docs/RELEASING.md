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

If publication fails before a GitHub release is created, keep the original
version tag unchanged. Fix the workflow on main and require green push CI, then
push a separately signed annotated `release-recovery/vX.Y.Z/N` tag on that repair
commit, using the same allowed release signer and an unused positive attempt
number. This runs the repaired workflow while rebuilding the native payload and
reading its version and notes from the original `vX.Y.Z` tag. Both tags must be
signed, the original source must be an ancestor of the repair, and both commits
need green push CI. Publication rechecks both frozen tag objects. Recovery
refuses any existing draft or published GitHub release; it never changes version
tags or replaces assets. For an already published release with a failed
Homebrew handoff, use the existing Homebrew retry workflow instead.

`python3 -B scripts/test_release_recovery.py` exercises the production preflight
and publication commands with real local Git repositories and SSH signatures.
Its controlled GitHub transport records allowed publication of the original
notes and payload, and verifies zero release writes for unauthorized signers or
tags moved/deleted after validation. It creates no live GitHub releases.

Required secrets: `MACOS_SIGNING_P12`, `MACOS_SIGNING_P12_PASSWORD`, `ASC_KEY_ID`,
`ASC_ISSUER_ID`, `ASC_PRIVATE_KEY_P8`, and `HOMEBREW_TAP_TOKEN`.
Local native build and verification scripts remain useful for development;
publication belongs to CI. Releases require separate explicit authorization.
