# FaceTime Helper

Standalone macOS helper bundle for FaceTime call-control events.

The helper connects only to the OpenClaw `facetime` plugin over mutually
authenticated, bounded newline-delimited JSON on:

```text
localhost:45670 + uid - 501
```

The helper generates a fresh connection nonce, authenticates the Gateway before
accepting commands, and MACs every strictly sequenced action, response, and
event to its direction and connection epoch. It emits `ft-call-status-changed`
events and accepts actions such as `answer-call` and `leave-call`.

The network client uses Foundation streams and has no third-party build
dependencies. This repository builds and releases the signed helper; the
OpenClaw plugin stages it and supervises injection into FaceTime and Phone.
`scripts/build-helper-macabi.sh` and `scripts/inject-helper.sh` are the manual
native development commands.

The OpenClaw helper modifications are distributed from this repository under
the MIT license. Incorporated and adapted BlueBubbles portions retain the
license and notice in `../THIRD_PARTY_NOTICES.md`.

Authenticated call-control commands reject missing, empty, or non-string
`callUUID` values with the existing `absent` outcome before call lookup.
Malformed handshake and envelope string fields fail authentication without
invoking string methods on untrusted JSON types.

Unknown authenticated action names receive an `Unknown action` transaction
error, allowing callers to detect plugin/helper version skew immediately.

If outbound acknowledgement raises after a call is safely muted, the reply
retains the dial and carrier identity and marks the result ambiguous so the
Gateway can reconcile it. The acknowledgement failure does not hang up that
safely muted call.

Reinjection transfers call-status polling and notification ownership to the
replacement helper. Restart FaceTime or Phone once when upgrading an already
injected helper from a version older than this ownership handoff; those images
cannot cancel their existing timers.
