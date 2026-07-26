# OpenClaw FaceTime

This repository is the canonical FaceTime voice plugin for OpenClaw agents.

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
- SoX
- an OpenAI Platform API key with Realtime access configured in OpenClaw
- consent from everyone on the call before capturing or processing audio

Install local dependencies:

```sh
brew install sox
pnpm install
```

## Build the audio path

Build and sign the Core Audio process-tap helper:

```sh
pnpm build:capture
```

OpenClaw installs npm plugins with lifecycle scripts disabled. On first plugin activation, the plugin checks for this helper and builds it from the packaged Swift source when missing. Xcode must therefore remain installed on the OpenClaw Mac. The explicit command above is useful for setup verification and development.

Install the pinned BlackHole v0.7.1 source as the paired OpenClaw driver:

```sh
openclaw gateway call facetime.installDriver --json
system_profiler SPAudioDataType | grep -E 'OpenClaw-(Mic|Feed)'
```

This idempotent setup action builds the driver locally when needed, presents the
normal macOS administrator prompt, verifies the installed bundle, and restarts
Core Audio only when the installed recipe is missing or stale. The plugin
rejects the action during an active or pending managed call. You can inspect it
without changing the system:

```sh
openclaw gateway call facetime.driverStatus --json
```

`facetime.installDriver` acknowledges as soon as setup starts so the gateway
call does not time out while the administrator prompt is open. Follow
`driverInstall.phase` in `facetime.status`; it becomes `succeeded` or `failed`
when setup finishes.

For development, `pnpm build:driver` and `pnpm install:driver` invoke the same
build and installation path.

The first process-tap check prompts for Screen & System Audio Recording permission. Grant it to the app that runs OpenClaw, quit that app completely, reopen it, and rerun preflight.

## Driver licensing boundary

The generated `OpenClawBridge.driver` is a separate modified build of GPL-3.0 BlackHole. It is ignored by Git and excluded from the npm package. The build script pins and verifies the upstream archive, then records the changed identity, device names, visibility, and input/output capabilities in its compiler flags.

Do not commit or silently distribute the generated driver. Distribution requires compliance with BlackHole's GPL-3.0 terms, a separate license from Existential Audio, or a replacement driver with a compatible license.

## Build the plugin

```sh
pnpm build
```

The persistent OpenClaw gateway now owns helper preparation and injection. On
startup it builds the signed helper from packaged source when missing or stale,
opens FaceTime and Phone in the background if needed, injects each process, and
retries with bounded backoff whenever an authenticated helper disconnects.
There is no separate LaunchAgent and no CocoaPods dependency, so plugin updates
and removal cannot leave a stale helper service behind.

### System Integrity Protection requirement

The beta intentionally uses the same private-API deployment boundary as tools
such as `imsg`: helper injection requires SIP debugging restrictions to be
disabled. FaceTime and Phone are protected Apple system apps, and Apple
documents that SIP rejects LLDB attachment to protected processes even for
root. This is a supported beta prerequisite for a dedicated Mac, not an
unresolved release blocker and not something the plugin can or should change
automatically.

From macOS Recovery, open Terminal and run:

```sh
csrutil enable --without debug
```

Reboot, then confirm `csrutil status` reports `Debugging Restrictions:
disabled` before starting the gateway. This keeps the other SIP protections
enabled, but allowing debugger attachment still reduces macOS security. Use a
dedicated OpenClaw Mac, keep it patched and physically controlled, and do not
install unrelated software on it. A future helper-free implementation can
remove this requirement, but it is not required for the private-API beta.

Enable Developer Tools mode once from an interactive Terminal before the first
automatic injection:

```sh
sudo /usr/sbin/DevToolsSecurity -enable
```

macOS can also request permission for the OpenClaw host to control developer
tools the first time LLDB attaches. Grant that prompt once.

Manual build and injection commands remain available for development or
recovery:

```sh
pnpm build:helper:macabi
pnpm inject:helper
pnpm inject:helper:phone
```

If a non-interactive agent owns the terminal, use:

```sh
pnpm inject:helper:terminal
```

Each helper connects to `127.0.0.1` on `45670 + uid - 501`. The connection is
authenticated with a locally generated key. FaceTime owns
incoming video calls, while Phone owns incoming FaceTime Audio calls on current
macOS.

## Configure OpenClaw

The plugin must be installed, allowlisted, enabled, and given at least one owner
FaceTime handle. Every entry in `whitelistHandles` is an authenticated owner,
not a guest caller: admitted calls inherit owner authorization and the
configured agent's normal workspace, memory, tools, and approval policies. Do
not add a handle that should have reduced privileges.

The realtime voice layer derives its identity and persona from the configured
agent's `IDENTITY.md`, `USER.md`, and `SOUL.md`; the delegated agent turn also
loads the normal full workspace context. The Realtime provider defaults to
OpenAI `gpt-realtime-2.1` with the `marin` voice.

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

For unattended inbound calls on a remotely managed Mac:

- Keep Focus off, or configure the active Focus to allow the expected caller.
- In System Settings > Notifications, set "when mirroring or sharing the
  display" to "Allow Notifications." macOS otherwise rejects an incoming call
  through its DND filter before the injected helper can observe or answer it.
- If Phone diverts filtered calls before the helper can answer, turn off Live
  Voicemail in Phone > Settings > Calls while diagnosing the route.

The Core Audio process tap starts before auto-answer and uses per-process mute behavior. Caller audio is still captured for OpenClaw, but the call process sends nothing to speakers or headphones. This suppression follows the process across volume and default-output changes and does not change the Mac's global mute state.

If carrier hangup fails, the helper safety-mutes both directions, retains the process tap, and retries instead of dropping local protection around a still-connected call.

## Preflight and live test

Start the OpenClaw gateway with the plugin enabled, then run:

```sh
openclaw gateway call facetime.setup --json
```

The guided setup report checks Xcode command line tools, developer-tools
access, SIP debugging restrictions, the paired audio driver, automatic helper
injection into FaceTime and Phone, Focus, notification behavior while the
display is shared, and all preflight checks below. It returns machine-readable
actions for anything that still needs attention.

Safe repairs happen automatically when the plugin runtime starts: native
artifacts are built when missing, FaceTime and Phone are launched, and the
authenticated helper is injected and supervised. Protected macOS changes are
never applied silently:

- Install or update the audio driver with `facetime.installDriver`. macOS may
  request administrator approval and Core Audio restarts after installation.
- Grant Screen & System Audio Recording in System Settings when requested.
- Enable developer tools access with
  `sudo /usr/sbin/DevToolsSecurity -enable` if setup reports it disabled.
- Disable only SIP debugging restrictions from macOS Recovery after accepting
  the security tradeoff. The plugin detects the state but never changes it.
- Turn off Focus and allow notifications while mirroring or sharing the
  display for unattended incoming calls.

FaceTime sign-in and the final per-process audio route do not have supported
macOS readiness APIs. The report marks those checks as `verify-on-call` until a
live call proves caller audio, assistant audio, and Mac speaker suppression.

For the lower-level audio preflight alone, run:

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

## Agent tool and skill

The plugin bundles a `facetime` skill and registers the `facetime_call` tool so
OpenClaw agents can inspect readiness and manage calls without shell commands.
The available actions are:

- `get_status`
- `check_readiness`
- `initiate_call`
- `end_call`

Outbound calls require an allowlisted handle and a trusted, one-shot OpenClaw
plugin approval. Persistent approval is intentionally unavailable. Driver
installation, SIP changes, FaceTime sign-in, TCC permissions, and System
Settings remain operator-only.

Agents using a restrictive tool profile must also allow the tool explicitly:

```json5
{
  agents: {
    list: [
      {
        id: "main",
        tools: { alsoAllow: ["facetime_call"] },
      },
    ],
  },
}
```

## Development checks

```sh
pnpm typecheck
pnpm test
pnpm build
pnpm build:capture
npm pack --dry-run
```

Generated `dist/` and `native/.build/` outputs are ignored. Helper and driver
artifacts are built into user cache or application-support directories. The npm
package includes the TypeScript build, native capture source, helper source, and
setup scripts, but excludes generated native binaries and GPL driver artifacts.

## Current limits

- This is a dedicated AI side of a private call. Selecting `OpenClaw-Mic` replaces the Mac's physical microphone for that call app.
- One bridged call is supported at a time.
- FaceTime video and Phone-owned FaceTime audio require separate live acceptance passes.
- A live remote participant is required to prove that app-specific routing reaches the caller.
