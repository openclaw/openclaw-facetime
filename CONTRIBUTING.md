# Contributing

This repository owns the privileged native FaceTime components and their
release pipeline. The TypeScript plugin and its product behavior live in
`openclaw/openclaw`. Send plugin configuration, tool, skill, realtime-provider,
and runtime-lifecycle changes there.

## Development setup

You need an Apple Silicon Mac, full Xcode, a supported Node.js version from
`package.json`, and pnpm 11.24.0 through Corepack.

```sh
corepack enable
pnpm install --frozen-lockfile
```

## Validation

Run the checks that cover your change. Before opening a pull request, run:

```sh
pnpm test
bash -n scripts/*.sh
bash scripts/test-native.sh
pnpm build:capture
pnpm build:helper:macabi
make native-archive
make native-verify
```

Release archives are signed and notarized separately. Follow
`docs/RELEASING.md`; local archives are ad-hoc signed and must never be
published as release assets.

Changes that affect the end-to-end FaceTime product also need the live proof
defined by the canonical
[FaceTime plugin documentation](https://docs.openclaw.ai/plugins/facetime).

## Pull requests

- Explain the native failure, capability, or release invariant.
- Include automated proof and any required live proof.
- Document new security or compatibility requirements.
- Coordinate changes to `helper-endpoint.json` or `native-protocol.env` with
  the canonical plugin.
- Never commit credentials, generated native binaries, or generated
  `OpenClawBridge.driver` artifacts.

Repository-owned source is MIT licensed. Incorporated and adapted helper source
retains the terms in `THIRD_PARTY_NOTICES.md`. The locally generated audio
driver is a separate modified GPL-3.0 artifact and stays outside release
archives.
