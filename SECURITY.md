# Security policy

Report vulnerabilities privately through
[GitHub Security Advisories](https://github.com/openclaw/openclaw-facetime/security/advisories/new)
or email [security@openclaw.ai](mailto:security@openclaw.ai). Do not publish
exploit details or credentials in an issue or pull request.

Include the affected native version or commit, macOS version, a minimal
reproduction, demonstrated impact, and redacted evidence. Remove Apple IDs,
phone numbers, call identifiers, IPC keys, signing material, and private paths.

## Scope

This repository owns the native capture executable, injected helper, local IPC
authentication, build and installation scripts, and release artifacts. Report
OpenClaw plugin configuration, tool, or runtime issues through
[OpenClaw's security policy](https://github.com/openclaw/openclaw/security/policy).

The integration uses private Apple APIs and debugger attachment on a dedicated
Mac. Read the documented
[setup and recovery tradeoffs](https://docs.openclaw.ai/plugins/facetime-recovery).
Report concrete violations of the documented boundaries, including unauthorized
call control, audio exposure, credential disclosure, or artifact substitution.

## Supported versions and checks

Use the latest published native release with a compatible OpenClaw plugin.
During pre-release development, report against current `main`; there are no
separate maintenance branches.

CI runs the test harness, native checks, and archive verification. CodeQL scans
Swift, TypeScript, Ruby, and GitHub Actions. CodeQL does not support Objective-C,
so a clean scan does not cover the injected helper; that boundary requires its
authentication tests, native builds, and source review. See
[CodeQL language support](https://codeql.github.com/docs/codeql-overview/supported-languages-and-frameworks/).
