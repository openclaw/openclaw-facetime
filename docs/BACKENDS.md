# Runtime backend selection

Both `FaceTimeHelper.dylib` and `facetime-audio-capture` remain supported native
artifacts. The seven-file archive, helper authentication, and native protocol
version are unchanged. Injection supplies private call control; Core Audio
capture runs out of process in either mode.

The native executable can select the call-control backend at setup time:

```sh
facetime-audio-capture --select-backend --app FaceTime
facetime-audio-capture --select-backend --app Phone
```

This is an operation, not a read-only status command: on an eligible system it
attempts to load the shipped helper into the already-running app. Run it only
when no managed call or previous helper session is active. The Gateway must
already have created its private 0600 `helper-ipc-key` and be listening for the
helper. The dylib is resolved beside the real capture executable, including
when that executable was reached through a Homebrew symlink. Missing assets,
credentials, apps, or authorization select out-of-process mode.

Example on a stock Mac:

```json
{"backend":"out-of-process","reason":"sip-enabled","sipDebugging":"enabled","captureExecutable":"facetime-audio-capture"}
```

Selection uses the current runtime state:

1. Read `csrutil status`. Enabled debugging restrictions, an unsuccessful
   command, or unrecognized output select out-of-process capture without
   invoking a debugger or reading the helper credential. An explicit custom
   debugging restriction takes precedence over the overall SIP summary.
2. With debugging restrictions disabled (including full SIP disablement),
   check existing Developer Tools authorization. No authorization means
   out-of-process mode.
3. Verify the running app has the expected Apple signing identity, stage the
   shipped dylib with a unique one-use authentication sidecar, and make one
   bounded LLDB load attempt. Only a successful initialization selects
   `injected`. A loader rejection, attach failure, timeout, or missing
   prerequisite selects `out-of-process` with `helper-unavailable`.

Every result is JSON on stdout; selection exits successfully for either
backend. Invalid arguments exit 2. Checks are bounded to five seconds each and
attachment to 90 seconds. No SIP, boot argument, AMFI, library-validation, TCC,
or Developer Tools setting is changed. LLDB init files are disabled.

## SIP and library validation are separate

Apple's [SIP runtime protection documentation][sip] explains that attaching to
protected system processes is denied even to root. Removing that restriction
allows an attempt; it does not prove that a particular dylib can load.

Apple's [library-validation documentation][lv] says that protected applications
can load libraries signed by Apple or by the application's own Team ID, absent
an applicable exception. Our Foundation Developer ID is not Apple's platform
signature. Adding an entitlement to the helper cannot change the host app's
entitlements. The reported `mapping process is a platform binary, but mapped
file is not` failure is therefore a real loader boundary, not proof that the
helper should be deleted from every system.

**Full SIP disablement alone is not a sufficient compatibility test.** Injection
can work only when debugger authorization and the target's effective
AMFI/library-validation policy both permit the helper. Apple's public docs do
not promise that a particular combination of undocumented boot arguments
relaxes that policy on every macOS version. The selector does not infer success
from boot-argument text, a global library-validation preference, or an OS version
number: it asks the actual loader and checks initialization. Systems where that
succeeds keep using the helper; all others keep the capture path available.

No fully disabled-SIP or relaxed-AMFI host was used to validate this change.
The permissive branch is tested with synthetic loader outcomes; this is not a
claim of live compatibility on every macOS build. Do not weaken system policy
to satisfy the selector. Use the out-of-process result with existing settings.

[sip]: https://developer.apple.com/library/archive/documentation/Security/Conceptual/System_Integrity_Protection_Guide/RuntimeProtections/RuntimeProtections.html
[lv]: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation

## OpenClaw host integration

The canonical plugin owns setup, caller admission, and the selected backend's
lifecycle. Consume the selection once before a new session, separately for
FaceTime and Phone, and retain that choice until teardown. This native command
does not change an installed OpenClaw plugin's runtime policy by itself.

- For `injected`, complete the existing authenticated helper/build-ID handshake
  before using call-control events or commands. A loader result is not caller
  authentication. If the handshake fails, abandon that setup and reconcile
  any existing helper session before choosing another backend.
- For `out-of-process`, use operator-assisted connection and the host's explicit
  admission flow, then launch `facetime-audio-capture` normally. The process tap
  neither identifies the remote caller nor implements answer/dial/hangup RPCs.
  Never synthesize an allowlisted caller from a process name or audio activity.
- Both paths retain the paired input device, output-route checks, process
  suppression, and capture shutdown protocol. Do not switch backends during
  an active call or turn a capture failure into an automatic unsuppressed call.

The native selector does not start PCM capture. A host starts the ordinary
capture command after admitting and connecting the call. Existing capture
arguments and the authenticated helper protocol remain compatible.

Manual `scripts/inject-helper.sh` remains an injection-only development tool:
it fails when injection is unavailable and does not silently start a capture
session. Native archives continue to build, sign, notarize, and verify both
binaries.
