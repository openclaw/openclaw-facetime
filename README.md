# OpenClaw FaceTime native components

[![CI](https://github.com/openclaw/openclaw-facetime/actions/workflows/ci.yml/badge.svg)](https://github.com/openclaw/openclaw-facetime/actions/workflows/ci.yml)
[![CodeQL](https://github.com/openclaw/openclaw-facetime/actions/workflows/codeql.yml/badge.svg)](https://github.com/openclaw/openclaw-facetime/actions/workflows/codeql.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

This repository owns the native binaries, build scripts, signing, notarization,
and Homebrew release contract used by the FaceTime plugin in
[`openclaw/openclaw`](https://github.com/openclaw/openclaw).

The TypeScript plugin, configuration, tools, skills, runtime lifecycle, and user
documentation live in the OpenClaw repository. Start with the canonical
[FaceTime plugin guide](https://docs.openclaw.ai/plugins/facetime) and
[recovery guide](https://docs.openclaw.ai/plugins/facetime-recovery).

## Native boundary

The release archive contains exactly seven files:

- `facetime-audio-capture`, an arm64 Core Audio process-tap executable
- `FaceTimeHelper.dylib`, an arm64e + arm64 Mac Catalyst injected helper
- `FaceTimeHelper.build-id`, which binds the helper source and endpoint contract
- `native-protocol.env`, the plugin/native compatibility version
- `VERSION`
- `LICENSE`
- `THIRD_PARTY_NOTICES.md`

The injected helper owns native FaceTime and Phone call control. The capture
executable accepts only Apple-signed FaceTime, Phone, or `avconferenced`
processes and captures the active call process. The OpenClaw plugin owns every
higher-level policy and runtime decision.

This is an experimental private-API integration for a dedicated Apple Silicon
Mac. It requires debugger attachment to protected Apple applications. Review
the security tradeoff and recovery steps in the canonical OpenClaw docs before
using it.

## Requirements

- Apple Silicon and macOS 14.4 or later
- full Xcode, normally at `/Applications/Xcode.app`
- Node.js and pnpm 11.24.0 only for this repository's small test harness

The first signed release and Homebrew formula are still being prepared. Check
[GitHub Releases](https://github.com/openclaw/openclaw-facetime/releases) and the
[release handoff](FOUNDATION_RELEASE_HANDOFF.md) for availability. After that
handoff completes, production installation uses the signed and notarized artifact:

```sh
brew install openclaw/tap/openclaw-facetime
```

The formula also installs SoX for the OpenClaw host's separate playback process.
Install and configure the plugin separately by following the canonical FaceTime
plugin guide.

## Build and verify

Review the source, then run:

```sh
corepack enable
pnpm install --frozen-lockfile
pnpm test
for script in scripts/*.sh; do bash -n "$script"; done
bash scripts/test-native.sh
make native-archive
make native-verify
```

`make native-archive` produces an ad-hoc-signed local archive at
`bin/openclaw-facetime-macos-arm64.zip`. It is for development verification and
must not be published. Foundation releases use Developer ID signing and Apple
notarization through the release workflow.

Useful focused build commands:

```sh
pnpm build:capture
pnpm build:helper:macabi
pnpm inject:helper
pnpm inject:helper:phone
```

The injection commands are development tools. They require the manual SIP and
Developer Tools preparation documented in the recovery guide. They never
change SIP, TCC, or developer-tools policy themselves.

## Paired audio driver

The native build scripts can create the paired `OpenClaw-Feed` and
`OpenClaw-Mic` Core Audio driver from pinned BlackHole source:

```sh
pnpm build:driver
pnpm install:driver
```

The generated driver is a separate modified GPL-3.0 artifact. It is ignored by
Git and intentionally excluded from this repository's release archive and
Homebrew formula.

## Shared native contracts

Two small files intentionally mirror contracts consumed by the canonical
plugin:

- `helper-endpoint.json` is a build input for the injected helper. Its hash is
  part of `FaceTimeHelper.build-id`.
- `native-protocol.env` is included in every release archive. The plugin checks
  it before using installed helpers.

These are native protocol fixtures, not alternate plugin configuration. Any
change must be coordinated with the FaceTime plugin in `openclaw/openclaw` and
validated on both sides.

## Release

See [docs/RELEASING.md](docs/RELEASING.md) for the artifact contract and
workflow, and [FOUNDATION_RELEASE_HANDOFF.md](FOUNDATION_RELEASE_HANDOFF.md) for
the remaining organization-owned prerequisites.

The repository package is private and exists only to pin the local Vitest
harness and native convenience commands. It is not an npm distribution and
does not register an OpenClaw plugin.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, validation, and the native
ownership boundary, and [CHANGELOG.md](CHANGELOG.md) for changes. Report native
defects through the [issue templates](https://github.com/openclaw/openclaw-facetime/issues/new/choose).
Report vulnerabilities privately using [SECURITY.md](SECURITY.md).

CI validates workflows, tests the harness and native checks, and builds and
verifies the native archive. CodeQL scans Swift, TypeScript, Ruby, and Actions;
it does not analyze the Objective-C helper.

## License

Repository-owned source is available under the [MIT License](LICENSE).
Incorporated and adapted helper source retains the upstream terms recorded in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
