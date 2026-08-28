#!/bin/bash
set -euo pipefail
trap 'rc=$?; if (( rc != 0 )); then printf "[driverless-audio] FAILED (exit %s)\n" "$rc" >&2; fi' EXIT
cd "$(dirname "$0")"
mkdir -p .build/tests .build/module-cache
bash -n build.sh check.sh
python3 -m unittest discover -s Tests -p 'test_*.py' -v
# This executable contains only pure contracts; neither audio probe is launched.
xcrun --sdk macosx swiftc -swift-version 6 -O -module-cache-path "$PWD/.build/module-cache" \
  Sources/Contract.swift Tests/ContractTests.swift -o .build/tests/contracts
.build/tests/contracts
./build.sh
printf '%s\n' '[driverless-audio] PASSED: pure tests + both compile-only targets; no probe launch or live evidence.'
