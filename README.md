# OpenClaw FaceTime native capture

This repository owns the signed, notarized, out-of-process audio capture binary
used by the FaceTime plugin in `openclaw/openclaw`.

## Supported architecture

The package does not inject into FaceTime or Phone and contains no private-API
call-control dylib. Apple platform binaries reject third-party mapped code under
library validation, so debugger-based injection is not a supported user path.
Normal installation requires no SIP change, Developer Tools access, Xcode, or
reboot.

`facetime-audio-capture` accepts only Apple-signed FaceTime, Phone, or
`avconferenced` processes, requires exactly one active carrier owner, verifies
the `OpenClaw-Mic` route, and streams 24 kHz PCM while suppressing duplicate
local output. The OpenClaw plugin owns operator authorization, realtime media,
video, and lifecycle policy.

## Release archive

The archive contains exactly four files:

- `facetime-audio-capture`
- `VERSION`
- `LICENSE`
- `THIRD_PARTY_NOTICES.md`

Install through Homebrew; the formula also installs SoX:

```sh
brew install openclaw/tap/openclaw-facetime
```

## Development

```sh
corepack enable
pnpm install --frozen-lockfile
pnpm test
for script in scripts/*.sh; do bash -n "$script"; done
bash scripts/test-native.sh
make native-archive
make native-verify
```

The paired `OpenClaw-Feed`/`OpenClaw-Mic` Core Audio driver remains a separately
built GPL-3.0 artifact and is intentionally excluded from the release archive.

See [docs/RELEASING.md](docs/RELEASING.md) for the signed release contract.
