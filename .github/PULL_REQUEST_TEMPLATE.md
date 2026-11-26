## Change

<!-- Explain the native failure, capability, or release invariant. Link related issues.

In 1–3 plain sentences, say who is affected, what happens today, and why it
matters to them. For a bug, name the trigger if known. For a feature or internal
work, describe the need in the actual workflow without inventing harm.
Could a reader understand the problem without knowing your proposed fix?

Good: "Background checks can use up a new user's model allowance before they've
asked the assistant to monitor anything."
Bad: "Turn off periodic checks on fresh installs."

Start with the task someone is trying to complete, what gets in their way, and
what this change makes possible. Write for a reader who does not know the native
implementation; introduce helper names, protocols, and file paths after the
problem and value are clear. For maintenance-only changes, explain the affected
contributor or release workflow instead of inventing a user-facing impact.

For example, describe a native archive that cannot be verified for installation,
then explain the archive check being fixed—not just "update verify-native-release.sh".
-->

## Compatibility and security

<!-- Note plugin/native protocol, macOS, privileges, licensing, or artifact impact.

Explain what any changed requirement means for the person installing, operating,
or releasing the native components before naming the implementation details.
State when these boundaries are unchanged; do not imply that source checks
prove live-call behavior or that an ad-hoc archive is a signed release.
-->

## Validation

<!-- Give exact commands and results. Distinguish source checks, native builds, and live proof.

Lead with the observed outcome and what it demonstrates, then give the commands
and supporting evidence. For example, if observed: "The local archive passed
verification with the expected seven files; make native-archive and make
native-verify passed. This does not establish signing, notarization, or live-call
behavior." Report failures, skipped checks, and untested paths plainly. Use only
results from this change; a command list or CI link alone is not a result summary.
-->

- [ ] Relevant automated checks passed
- [ ] Live proof included when the FaceTime user path changes
- [ ] Shared native contracts coordinated with `openclaw/openclaw`, if changed
- [ ] Changelog updated for user-visible, compatibility, security, or release changes
- [ ] No credentials, call details, private paths, or generated artifacts included
