# OpenClaw FaceTime

This repository is the canonical FaceTime voice plugin for OpenClaw and Lobster.

It combines call control, OpenClaw agent consultation, and the audio path proven on current macOS:

```text
caller -> FaceTime or Phone -> Core Audio process tap -> OpenClaw Realtime
caller <- FaceTime or Phone <- OpenClaw-Mic <- OpenClaw-Feed <- OpenClaw Realtime
```

The injected FaceTime helper owns call events, answering, transmission, and hangup. The Swift capture helper accepts only Apple-signed FaceTime, Phone, or `avconferenced` identities and taps the single process reporting active audio output. Model speech is written to the output-only `OpenClaw-Feed`, then mirrored by the paired driver to the input-only `OpenClaw-Mic` selected in the call app.

This avoids the duplex BlackHole route that current FaceTime Voice Processing suppresses. The plugin never changes the Mac's default input or output devices.

## Requirements

- macOS 14.4 or later
- FaceTime signed in
- Xcode
- CocoaPods for the injected helper
- SoX
- an OpenAI Platform API key with Realtime access configured in OpenClaw
- consent from everyone on the call before capturing or processing audio

Install local dependencies:

```sh
brew install cocoapods sox
pnpm install
```

## Build the audio path

Build and sign the Core Audio process-tap helper:

```sh
pnpm build:capture
```

OpenClaw installs npm plugins with lifecycle scripts disabled. On first plugin activation, the plugin checks for this helper and builds it from the packaged Swift source when missing. Xcode must therefore remain installed on the Lobster Mac. The explicit command above is useful for setup verification and development.

Build the pinned BlackHole v0.7.1 source as the paired OpenClaw driver, then install it:

```sh
pnpm build:driver
pnpm install:driver
system_profiler SPAudioDataType | grep -E 'OpenClaw-(Mic|Feed)'
```

Driver installation prompts for the administrator password, restarts Core Audio, and disconnects active calls.

The first process-tap check prompts for Screen & System Audio Recording permission. Grant it to the app that runs OpenClaw, quit that app completely, reopen it, and rerun preflight.

## Driver licensing boundary

The generated `OpenClawBridge.driver` is a separate modified build of GPL-3.0 BlackHole. It is ignored by Git and excluded from the npm package. The build script pins and verifies the upstream archive, then records the changed identity, device names, visibility, and input/output capabilities in its compiler flags.

Do not commit or silently distribute the generated driver. Distribution requires compliance with BlackHole's GPL-3.0 terms, a separate license from Existential Audio, or a replacement driver with a compatible license.

## Build the plugin and helper

```sh
pnpm build
pnpm build:helper:macabi
```

Open FaceTime and Phone, then inject the helper into both call apps from an
interactive Terminal:

```sh
pnpm inject:helper
pnpm inject:helper:phone
```

If a non-interactive agent owns the terminal, use:

```sh
pnpm inject:helper:terminal
```

Each helper connects to `127.0.0.1` on `45670 + uid - 501`. FaceTime owns
incoming video calls, while Phone owns incoming FaceTime Audio calls on current
macOS.

## Configure OpenClaw

The plugin must be installed, allowlisted, enabled, and given at least one allowed FaceTime handle. Its Realtime provider defaults to OpenAI `gpt-realtime-2.1` with the `marin` voice.

Older local builds used `plugins.entries.facetime.config.audio` for duplex BlackHole routing. That property is retired. Migrate it once with:

```sh
openclaw doctor --fix
```

The plugin doctor removes only the obsolete audio object and preserves the rest of the FaceTime configuration.

OpenAI Realtime uses Platform API billing. A ChatGPT subscription or Codex OAuth login does not replace the Platform API key.

## Route FaceTime or Phone

Set this route once in the app that owns the call:

- microphone: `OpenClaw-Mic`
- output: physical speakers or headphones
- macOS system input: any physical microphone
- macOS system output: any physical device

FaceTime video calls use FaceTime. FaceTime audio calls use Phone on current macOS. The helper answers with the uplink muted, verifies that `OpenClaw-Mic` is the actual active call process's only input device and that its outputs are physical, then enables transmission. It keeps re-resolving the audio owner and checking both routes during the call, then hangs up if anything changes.

Do not select an Aggregate, Multi-Output, BlackHole, `OpenClaw-Feed`, or `OpenClaw-Mic` device as the call output.

The Core Audio process tap starts before auto-answer and uses per-process mute behavior. Caller audio is still captured for OpenClaw, but the call process sends nothing to speakers or headphones. This suppression follows the process across volume and default-output changes and does not change the Mac's global mute state.

If carrier hangup fails, the helper safety-mutes both directions, retains the process tap, and retries instead of dropping local protection around a still-connected call.

## Preflight and live test

Start the OpenClaw gateway with the plugin enabled, inject the helper, then run:

```sh
openclaw gateway call facetime.preflight --json
```

Required checks cover:

- helper connection
- SoX
- signed capture helper
- FaceTime or Phone process
- `OpenClaw-Mic` and `OpenClaw-Feed`
- physical system output
- live Core Audio process tap and TCC permission
- `OpenClaw-Feed` to `OpenClaw-Mic` signal
- Realtime provider credentials

The call-specific `OpenClaw-Mic` check happens when the actual FaceTime or Phone audio process becomes active.

Start an allowlisted outbound audio call from the OpenClaw Mac:

```sh
openclaw gateway call facetime.dial \
  --params '{"handle":"user@example.com","mode":"audio"}' \
  --json
```

Use `"mode":"video"` for a FaceTime video call. The injected helper creates a
native dial request with the macOS confirmation UI disabled, so this works when
the call app's window is off-screen. The target must match `whitelistHandles`,
and the plugin rejects a second dial while a call or outbound request is active.
The result includes an immediate `dialID` and uses `state: "pending"` when macOS
accepts the dial before assigning its call UUID. The helper stamps that ID into
the native call for exact cancellation and helper-restart recovery, then
correlates the UUID from the outgoing event.

Alternatively, place a whitelisted call manually and inspect status:

```sh
openclaw gateway call facetime.status --json
```

An active call should report `audioReady: true`, `realtimeActive: true`, `processOutputSuppressed: true`, and the paired transport names.

Send a deterministic test phrase through the same output-only path:

```sh
openclaw gateway call facetime.testAudio \
  --params '{"phrase":"This is OpenClaw speaking through FaceTime."}' \
  --json
```

Run the guided acceptance sequence with the user present:

```sh
scripts/live-acceptance.sh
```

Hang up through OpenClaw:

```sh
openclaw gateway call facetime.hangup --json
```

## Development checks

```sh
pnpm typecheck
pnpm test
pnpm build
pnpm build:capture
npm pack --dry-run
```

Generated `dist/`, `native/.build/`, and `native-driver/.build/` outputs are ignored. The npm package includes the TypeScript build, native capture source, helper source, and setup scripts, but excludes generated native binaries and drivers.

## Current limits

- This is a dedicated AI side of a private call. Selecting `OpenClaw-Mic` replaces the Mac's physical microphone for that call app.
- One bridged call is supported at a time.
- FaceTime video and Phone-owned FaceTime audio require separate live acceptance passes.
- A live remote participant is required to prove that app-specific routing reaches the caller.
