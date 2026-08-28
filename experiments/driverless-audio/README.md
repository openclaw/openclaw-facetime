# Driverless return-audio experiments

Experimental, build-only, not a product feature. Neither path has completed live
FaceTime proof. The historical prototype compiled and was signed, but the test
host lacked FaceTime sign-in and the operator permissions needed for live proof.
No historical result is imported as evidence here.

These sources are not imported, packaged, installed, or invoked by production
FaceTime or the native release flow. They do not change the product support floor,
runtime defaults, call ownership, or configuration. Removing an audio driver would
not remove the existing private call-control helper's SIP requirements.

## Architectures and what remains unknown

| Lane | Path | Contract and limits |
| --- | --- | --- |
| `catalyst_injection` | Finite app-generated PCM → AVAudioSession spoken-audio preference → active compatible calling app | Public Catalyst 18.2 APIs, not native macOS APIs. Permission and compatible-call availability are required. Apple describes mixing with the call microphone, local playback, and following call mute. No call UUID selector. Intended for AAC synthesized speech; tones are diagnostic markers, not an assertion of eligibility for a production use case. |
| `aggregate_input` | Own output engine → SELF process tap → public aggregate input → manually selected call microphone | macOS 14.2+. Taps capture process **output**, not microphone input. `.muted` requests suppression whether or not a client opens the aggregate. Public tap and input-only aggregate, no physical subdevices. No default-device setter or capture reader. |
| `paired_driver_baseline` | Approved marker source → OpenClaw-Feed → OpenClaw-Mic → manually selected call microphone | Requires an existing approved paired installation, or separate installation approval. This tool never installs drivers. Stock duplex BlackHole is not the baseline: voice-processing suppression was already observed with that route. |

The aggregate is named **OpenClaw Driverless Input Probe**, with a fresh
`ai.openclaw.driverless-audio.aggregate.<UUID>` UID per preparation. Creation and
`ready` do not prove FaceTime enumeration, input open, remote audibility, or
physical silence. `running` is a HAL observation, not proof of which app opened
it. Requested `.muted` is not a physical-silence measurement. There is deliberately
no diagnostic reader or IOProc that could make our own read activity look like
FaceTime activity. No player-rendered or capture-observed frame counters are claimed.

A device route is not inherently unsafe because it lacks a call UUID; the paired
baseline also uses selected devices. Assess intended-call binding and fail-closed
behavior at the call owner. Catalyst's untargeted service is an API limitation;
it is separate from measured routing. Neither probe implements production call
ownership or a fallback policy. They stop on detected local resource/capability
loss, but this does not prove that the call app fails closed on a route loss.

## Build and inspect without launching

Use installed full Xcode via `xcrun` and, optionally, a command-scoped
`DEVELOPER_DIR`. Do not change global Xcode selection or download an SDK.
Xcode 16.2+ provides the required Catalyst 18.2 SDK declarations and Swift 6;
no Xcode 27-only API is used. CI uses the stock `macos-15` Xcode selection.
Only Apple Silicon artifacts are built. Compilation on a newer SDK is not
runtime proof on the deployment minimum or a stable fleet OS.

```sh
./experiments/driverless-audio/check.sh
./experiments/driverless-audio/build.sh
```

`check.sh` runs Python stdlib CLI tests and a Swift executable containing only
pure contracts (no AVFAudio/CoreAudio). It compiles both probes with optimization
and Swift 6 concurrency checking. It never launches a probe, signs an artifact,
or requests TCC. The test executable is distinct from both probe artifacts.
`verify_artifacts.py` reads Mach-O bytes to check arm64, platforms and deployment
versions, absence of code signatures, embedded/bundle identifiers and privacy
strings. Unsigned probe files have their executable bits removed.

Unsigned outputs under `.build/unsigned/` are **compile-only / not launchable**:

- `DriverlessInjectionProbe.app` — UIKit Catalyst bundle, stable identifier
  `ai.openclaw.driverless-audio.catalyst`, Catalyst 18.2 / macOS 15.2 minimum,
  `NSMicrophoneInjectionUsageDescription`.
- `driverless-aggregate-probe` — native macOS 14.2 CLI with an embedded Info.plist,
  stable identifier `ai.openclaw.driverless-audio.aggregate`,
  `NSAudioCaptureUsageDescription`.

Signing is separate and requires an explicit, available Developer ID identity:

```sh
./experiments/driverless-audio/build.sh --sign 'Developer ID Application: Name (TEAMID)'
```

There is no auto identity selection or ad-hoc execution fallback. This rebuilds
unsigned outputs, copies to `.build/signed/`, signs with hardened runtime and a
secure timestamp, and verifies both signatures, authority and team. Outputs are
not notarized, installed, or launched. If signing needs Keychain unlock, an access
prompt, account sign-in, or permissions changes, stop: those actions need separate
authority. Do not use the production release/signing scripts. No signing secrets
or Foundation credentials belong in this experiment's CI.

`.build/`, `evidence/`, and Python caches are ignored. Do not commit artifacts or
live records. A host handoff may be a source-only archive of this directory
excluding those ignored paths; build and sign on the approved host. No package
manager, driver installer, helper injector, or live automation is involved.

## Operator gates and command protocol

Everything below is a **manual future procedure**, not authority to perform it.
Build permission is not permission to launch, install, grant TCC, record, change
routes, restart apps, crash a probe, or place a call. First obtain approval for
the particular host, signed artifact, stable installation path, consenting remote
endpoint, local speaker exposure, physical-microphone tests, route changes,
app/probe restarts, SIGKILL, and recovery. Record that consent separately. Never
automate sign-in, accessibility settings, TCC acceptance, SIP, Developer Tools,
Keychain changes, drivers, or call placement.

After approval, an operator copies signed outputs to a chosen stable per-user
location, verifies signatures there, and preserves that path for TCC identity.
Do not run from changing build directories against saved permissions. For
Catalyst, launch `DriverlessInjectionProbe.app/Contents/MacOS/DriverlessInjectionProbe`
explicitly from a terminal; launch the native executable similarly. Both use
**stdin JSONL**, not a socket or TCP. Finder launch is not a supported control
transport. EOF quits; keep stdin open for the interactive session.

Default launch emits status and does no permission request or engine start.
Native status inventories names/default devices read-only and does not create a
lock, tap, aggregate, or cleanup any stale object. These probes never open the
physical microphone and never request recording permission. Catalyst initializes
the shared audio session to observe public capability notifications, as in the
Apple sample; it does not set a category, `playAndRecord`, or `voiceChat`.

Launch flags are records of operator consent, not OS grants or evidence:

| Probe | Explicit launch flags | Required commands after launch |
| --- | --- | --- |
| Catalyst permission only | `--allow-permission-prompt` | `request_permission`; inspect returned actual permission |
| Catalyst output | `--allow-audio` (plus prompt flag only if separately authorized) | `enable`, then `start_tone` after granted permission and compatible-call availability |
| Aggregate | `--allow-audio-capture --allow-audio` | `prepare`; wait for `phase: ready`, then `start_tone` |

Each stdin command is one JSON object ending with newline:

```jsonl
{"command":"status"}
{"command":"request_permission"}
{"command":"enable"}
{"command":"prepare"}
{"command":"start_tone","duration":3}
{"command":"stop_tone"}
{"command":"disable"}
{"command":"quit"}
```

Use only the commands supported by the chosen probe; Catalyst does not implement
`prepare`, and native does not implement `request_permission` or `enable`.
`duration` is allowed only for `start_tone`, defaults to 3 seconds, and must be
0.03–10 seconds. Each command produces a 440/660/880 Hz sequence in equal thirds,
48 kHz mono, peak amplitude capped at 0.08 with short fades. Replacing a tone
clears the old player queue. `stop_tone` stops/clears the player immediately but
keeps the aggregate's silent engine and process identity alive. A finite PCM
buffer bounds output even if control processing stalls; old completion callbacks
cannot stop a newer playback generation. Player state never means “delivered.”

Protocol bounds: 1024 bytes per frame/read, at most 16 frames per read,
16 KiB per response, 32 KiB total queued writes, nonblocking stdio serviced every
20 ms. Oversize/flooded framing or output backpressure shuts down owned resources
and exits nonzero. Malformed commands produce errors without mutations. SIGINT,
SIGTERM, EOF, `quit`, and `disable` stop only owned resources. Catalyst reacts to
capability-loss notifications immediately on the main queue and also checks
permission/availability/mode every 50 ms. Loss disarms output; recovery needs a
new `enable`. It never automatically resumes after interruptions or media resets.
OS notification latency and downstream buffer drain still need measurement.

Native preparation obtains a per-user advisory lock only after both flags and
`prepare`. It verifies owner, 0700 directory, 0600 regular single-link lock file,
refuses symlinks, and never unlinks a lock file or kills another instance. Its
lock is `~/Library/Caches/ai.openclaw.driverless-audio/aggregate.lock`. A second
process may inspect status, but cannot mutate while the lock is held.

The engine starts silent before resolving its own HAL PID object, with up to
5 seconds of asynchronous registration polling and another 5 seconds for an
alive aggregate. No audible buffer is scheduled before suppression and readiness.
The same engine remains alive through tone stops. Shutdown clears the player,
destroys its aggregate, destroys its tap, then stops the engine. There is no
capture IO resource to destroy. Exact IDs plus per-run UIDs must match before
deletion; namespace inventory is not ownership. Removal is confirmed against HAL
lists with a bounded wait; errors give a nonzero exit and `cleanup_failed`.

**SIGKILL cannot guarantee cleanup or retained silence.** On an approved crash
exercise, mute the call before inspecting stale devices/fallback, record the
last per-run UID, and do not unmute until the intended safe route is confirmed.
A new probe does not reclaim old objects. If anything remains, inspect status
read-only, verify the original process has exited, and obtain approval for manual
recovery of those exact objects (or a separately approved audio-service restart).
Never delete by name/prefix, unlink an active lock, or install a fallback driver.

## Manual matrix, separately for both call types

Run every lane for `phone_facetime_audio` (Audio in Phone) and `facetime_video`
(video in FaceTime), with approved signed artifacts and a consenting endpoint.
If an OS assigns ownership differently, document it as a gap; do not silently
substitute one app/modality for another. Record live OS version/build, timestamp,
artifact identifier/SHA-256/signature team, operator consent reference and exact
scope. macOS beta results cannot stand for stable fleet or all minimum versions.

Before changes, note only the relevant call app input/output, system defaults,
physical speaker/headphone route, microphone, mute state, and existing probe
inventory. Do not collect accounts, private host names, screenshots, or unrelated
settings. Use the existing approved paired OpenClaw-Feed/OpenClaw-Mic baseline;
feed it with a separately approved bounded marker source. This experiment does
not automate baseline playback or setup.

| Required checkpoint | Procedure and pass criterion |
| --- | --- |
| `remote_audibility` | With consent, remote endpoint hears the ordered marker clearly; optionally records with explicit recording consent. Record the marker start/stop and endpoint observation, not just local player state. |
| `local_playback_policy` | First verify the physical listening path using an explicitly approved local audible positive control, then observe the marker on the candidate route. The desired replacement policy is no unexpected local output; record leakage as failure. Catalyst documents local playback, but still record an observation rather than fabricating a failure from the API contract. |
| `physical_microphone_leakage` | Positive control: remote endpoint hears speech/taps from the identified physical mic on an approved ordinary call route. Then select the test route and repeat with the marker off/on; physical mic must not leak under the intended agent-only policy. A virtual Jump Desktop mic is not evidence about a physical microphone. Never infer silence from an untested/muted/dead mic. |
| `call_mute` | Start marker, mute in the call owner, verify remote marker stops, unmute, verify expected behavior; also check physical mic. Record local behavior separately. |
| `intended_call_routing` | Identify intended call owner/endpoint, selected input, and output. Check app/device selection, call transition and wrong-owner conditions with separate consent for any additional call. Speech must reach only the intended endpoint; loss/ambiguity must stop or keep call muted. No UUID is not an automatic failure for device routes. Record Catalyst's untargeted service separately. |
| `barge_in_stop_drain` | Have remote endpoint mark time of `stop_tone`, then of a replacing marker. Measure last audible old sample and latency, with a predeclared acceptance budget in the observation. Confirm no old marker resumes or late completion stops the replacement. Pause/clear downstream drain is not proven by a local response timestamp. |
| `call_app_restart` | With approved restart and endpoint expectations, restart the call owner. Record app input/output retention, capability changes and old/new call ownership. Do not automatically resume output. Fail if an unintended call or physical mic becomes live. |
| `probe_crash` | Separately approve a probe restart and SIGKILL of the exact probe PID. Observe remote/local output and call input fallback. Record whether suppression persists or disappears. Crash recovery must leave the call muted/safe until the intended route is re-established. |
| `stale_device_cleanup` | Compare before/after inventory for normal quit, disable, and approved crash. Record exact per-run UIDs and any teardown error. Verify no other probe's object was removed. Observe/manual recover stale objects with separate approval; no namespace cleanup. For Catalyst, observe that no aggregate was created and owned mode/output ended; do not mark NA. |
| `fallback` | While muted, inspect the call owner's route after device/capability loss and before unmuting. Verify it did not silently select a physical mic or unintended output/call. Record safe restoration, or keep muted/end the test; no automatic mic/output fallback. |

Snapshot and restore **only changes explicitly made for this test**, with approval.
End the call and clean up normal owned resources before restoring routes. If the
experiment crashes or teardown fails, keep the endpoint informed and the call
muted until the approved recovery is complete. Do not restore unrelated system
settings or revert pre-existing operator choices.

## Offline evidence CLI

```sh
mkdir -p experiments/driverless-audio/evidence
python3 experiments/driverless-audio/evidence.py template experiments/driverless-audio/evidence/matrix.json
python3 experiments/driverless-audio/evidence.py validate experiments/driverless-audio/evidence/matrix.json
python3 experiments/driverless-audio/evidence.py compare experiments/driverless-audio/evidence/matrix.json
```

`create` aliases `template`, exclusively creates a new file, and initializes all
observations and targeting to unknown/not-run. It never invents a failure or
success. Dry-run comparison is inconclusive. Edit the document offline after
actual observations; set `evidence_kind` to `live` only for a live record.
`test_only` records can never qualify. The recorder performs no live automation
and launch flags do not substitute for consent evidence.

Schema 1 has exactly three allowed lanes and two allowed call types. Each
session carries host metadata, artifact identity, consent, observed targeting
(`observed_device_route` or `observed_untargeted_service`) and all ten checkpoints.
States are `unknown`, `not_run`, `pass`, `fail`, or `na`; NA does not satisfy a
required checkpoint. Every observed pass/fail needs a nonempty observation and
an existing nonempty local evidence file, with `evidence_ref` relative to the
matrix directory and its `evidence_sha256`. Several checkpoints may refer to the
same recording: put the relevant timestamp and observed outcome in each observation.
The same consent record may cover multiple sessions. Every populated reference is
verified, even on an unrun row; only an unobserved `unknown`/`unknown` reference and
hash pair is exempt. Repeated content does not substitute for a distinct observation.
Evidence is capped at 64 MiB per file, the matrix at 1 MiB. External references,
path escapes, hash mismatches, duplicate keys/rows, unsupported schema, invalid
enumerations, and unchanged placeholder fields are rejected. File contents are
not guessed to be authentic from their wording; label synthetic records `test_only`.

Consent is `recorded` only with an operator and an evidence file covering every
required scope: `endpoint`, `local_playback`, `microphone_control`, `route_changes`,
`permission_changes`, `audio_capture`, `app_restart`, `probe_crash`, and `recovery`.
Use that exact list in `consent.scopes`; these values record approval, never grant it.
Additional recording consent belongs in that record if recording is used. Observations require actual host version/build, a timezone-bearing live
capture timestamp, signed artifact identity, and observed targeting. Do not
include secrets, accounts or unapproved recordings in shared evidence.

Comparison is per candidate against the paired baseline across both call types.
Any missing/unrun/NA requirement or missing modality/baseline is inconclusive.
With a complete candidate/baseline matrix, a failing candidate is `cannot-replace`;
a failing baseline prevents qualification. Only all required real passes yield
`candidate-for-integration`: **passes this recorded matrix, not production proof**.
The other candidate is reported separately with explicit gaps and failures.

No offline validator can certify that an operator is truthful or that a recording
supports a claim. Hashes establish content identity, not authenticity. A human
review of consent, provenance, observations and underlying recordings is still
required before integration. Tests create clearly test-only synthetic fixtures in
throwaway directories, including a live-shaped fixture to exercise the comparator;
none is checked in or presented as live evidence.

## Primary sources

The implementation was checked against installed Apple SDK headers
`AVAudioApplication.h`, `AVAudioSession.h`, `AVAudioSessionTypes.h`,
`CATapDescription.h`, `AudioHardware.h`, and `AudioHardwareTapping.h`.

- [Adding synthesized speech to calls](https://developer.apple.com/documentation/avfaudio/adding-synthesized-speech-to-calls), including its [official source archive](https://docs-assets.developer.apple.com/published/77a3397c5287/AddingSynthesizedSpeechToCalls.zip), especially `CallAudio.swift`. The prose links to record permission in one place, but the sample source and headers use **requestMicrophoneInjectionPermission**, as does this probe.
- [Microphone injection permission](https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestmicrophoneinjectionpermission(completionhandler:)) and [preferred microphone injection mode](https://developer.apple.com/documentation/avfaudio/avaudiosession/setpreferredmicrophoneinjectionmode(_:)).
- [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps) describes public taps and aggregate inputs. Its sample-project SDK metadata is newer than the underlying macOS 14.2 C API floor; these probes do not copy newer convenience APIs.
- [AudioHardwareCreateProcessTap](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:)) and [CATapDescription](https://developer.apple.com/documentation/coreaudio/catapdescription). Process taps are unavailable to Catalyst; the native target is separate for that reason.
