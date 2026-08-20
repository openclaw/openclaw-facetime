# Contributing

OpenClaw FaceTime is an experimental macOS plugin that controls protected Apple
apps, captures live call audio, and installs a local Core Audio driver. Treat
changes to call admission, routing, helper authentication, or cleanup as
security-sensitive.

## Development setup

You need:

- an Apple Silicon Mac
- full Xcode at `/Applications/Xcode.app`
- a supported Node.js version from `package.json`
- pnpm 10.34.5 through Corepack
- SoX

Install dependencies and build:

```sh
corepack enable
brew install sox
pnpm install --frozen-lockfile
pnpm build
```

## Validation

Run the checks that cover your change. Before opening a pull request, run the
complete local suite:

```sh
pnpm typecheck
pnpm test
bash -n scripts/*.sh
bash scripts/test-native.sh
pnpm build:capture
pnpm build:helper:macabi
make native-archive
make native-verify
pnpm build
npm pack --dry-run
```

Release archives are signed and notarized separately. Follow
`docs/RELEASING.md`; CI comparison artifacts are ad-hoc signed and must never
be published as release assets.

Changes to the carrier, helper, audio route, or Realtime session also require
the live acceptance procedure in `docs/phase1-verification.md`. A real remote
participant must confirm caller audio, assistant audio, interruption behavior,
and Mac speaker suppression.

## Pull requests

- Explain the user-visible failure or capability.
- Include automated proof and any required live proof.
- Document new setup, security, or compatibility requirements.
- Never commit API keys, helper authentication keys, generated native binaries,
  or generated `OpenClawBridge.driver` artifacts.

Original plugin source is MIT licensed. Incorporated and adapted helper source
retains the terms recorded in `THIRD_PARTY_NOTICES.md`. The locally generated
audio driver is a separate modified build of GPL-3.0 BlackHole and must remain
outside this repository and the npm package.
