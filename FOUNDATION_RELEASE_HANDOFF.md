# OpenClaw FaceTime Release Handoff

The repository owns only the native FaceTime binaries, their source, signing, notarization, and releases. The FaceTime plugin lives in `openclaw/openclaw`, and the install formula lives in `openclaw/homebrew-tap`.

The release workflow is locked to this signing identity:

```text
Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)
```

It builds `openclaw-facetime-macos-arm64.zip`, signs both Mach-O files, notarizes the ZIP, independently verifies the draft release and online notarization tickets, publishes the release, then dispatches the OpenClaw Homebrew tap updater.

## Foundation actions required

### 1. Choose a public download location

`openclaw/openclaw-facetime` is currently private. Homebrew cannot anonymously download GitHub release assets from a private repository.

Before the first release, choose one option:

1. Recommended: audit the repository and its history for secrets and licensing, then make `openclaw/openclaw-facetime` public.
2. Keep the source repository private, publish the signed assets from a separate public OpenClaw release repository, and update both the release workflow and formula URL.

Do not publish a Homebrew formula until its release asset URL is anonymously downloadable.

### 2. Add organization-managed GitHub Actions secrets

Grant these OpenClaw organization secrets to `openclaw/openclaw-facetime`:

| Secret | Required value |
| --- | --- |
| `MACOS_SIGNING_P12` | Base64 PKCS#12 export containing the OpenClaw Foundation Developer ID Application certificate and private key |
| `MACOS_SIGNING_P12_PASSWORD` | PKCS#12 export password |
| `ASC_KEY_ID` | App Store Connect API key ID |
| `ASC_ISSUER_ID` | App Store Connect API issuer ID |
| `ASC_PRIVATE_KEY_P8` | Complete App Store Connect `.p8` private key contents |
| `HOMEBREW_TAP_TOKEN` | Fine-grained token or GitHub App token able to dispatch workflows in `openclaw/homebrew-tap` |

The Apple API key must be authorized to notarize software for Team ID `FWJYW4S8P8`. The tap token only needs Actions write access to `openclaw/homebrew-tap`; that repository's own `GITHUB_TOKEN` performs the formula commit.

Secret names can be checked without exposing values:

```bash
gh secret list --repo openclaw/openclaw-facetime
```

### 3. Protect and enable the release path

In `openclaw/openclaw-facetime`:

1. Protect `main` and require the normal `CI` workflow.
2. Keep GitHub Actions enabled with the workflow-declared permissions.
3. Confirm the release workflow can create annotated tags and GitHub releases.

In `openclaw/homebrew-tap`:

1. Keep `.github/workflows/update-formula.yml` enabled for `workflow_dispatch`.
2. Allow that workflow's repository `GITHUB_TOKEN` to write contents.

### 4. Publish the first release before seeding the formula

The custom FaceTime formula installs a seven-file, arm64-only native payload into `libexec`. The tap's generic missing-formula generator is intended for ordinary four-platform command-line tools and must not seed this formula.

For the first release:

1. Merge the release workflow and native protocol changes with green CI.
2. Run `.github/workflows/release.yml` from `main` with version `0.1.0`.
3. Confirm the release asset is anonymously downloadable.
4. Replace `RELEASE_SHA256` in `packaging/homebrew/openclaw-facetime.rb` with the published ZIP checksum.
5. Add that formula as `Formula/openclaw-facetime.rb` in `openclaw/homebrew-tap` and merge it after tap CI passes.
6. Future releases can use the automated tap handoff.

### 5. Verify the complete user path

On an Apple Silicon Mac:

```bash
brew update
brew install openclaw/tap/openclaw-facetime
```

Then verify both installed binaries retain the Foundation signature and Apple notarization ticket:

```bash
codesign --verify --strict --check-notarization -R=notarized \
  /opt/homebrew/opt/openclaw-facetime/libexec/facetime-audio-capture
codesign --verify --strict --check-notarization -R=notarized \
  /opt/homebrew/opt/openclaw-facetime/libexec/FaceTimeHelper.dylib
```

Finally install or enable the FaceTime plugin from OpenClaw and run its setup flow. The plugin validates `native-protocol.env` before using the installed helpers, so incompatible plugin and native releases fail closed.

## Security notes

- Never paste certificates, passwords, API keys, or token values into issues, pull requests, workflow inputs, shell arguments, or this document.
- The workflow imports the certificate into an ephemeral runner keychain and deletes that keychain after signing.
- The injected helper receives its per-install IPC key through a private one-use sidecar. The release binary does not embed a user credential.
- The separately built GPL-derived audio driver is not included in the release archive or Homebrew formula.
