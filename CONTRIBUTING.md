# Contributing

The supported native boundary is the out-of-process Swift capture executable.
Do not add injected dylibs, private FaceTime call-control APIs, LLDB attachment,
or SIP/AMFI bypass instructions.

Before opening a change, run:

```sh
pnpm install --frozen-lockfile
pnpm test
bash scripts/test-native.sh
make native-archive
make native-verify
```

Coordinate capture CLI or stderr-marker changes with the FaceTime plugin in
`openclaw/openclaw`. Never run native development builds against a personal
Gateway or active call.
