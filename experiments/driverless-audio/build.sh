#!/bin/bash
set -euo pipefail
trap 'rc=$?; if (( rc != 0 )); then printf "[driverless-audio] FAILED (exit %s)\n" "$rc" >&2; fi' EXIT
cd "$(dirname "$0")"
identity=''
if (( $# != 0 )); then
  if [[ $# != 2 || $1 != --sign || $2 != 'Developer ID Application: '* ]]; then
    echo "Usage: $0 [--sign 'Developer ID Application: Name (TEAMID)']" >&2
    exit 2
  fi
  identity=$2
fi
sdk=$(xcrun --sdk macosx --show-sdk-path)
mkdir -p .build/module-cache .build/unsigned
out=.build/unsigned
app="$out/DriverlessInjectionProbe.app"
mkdir -p "$app/Contents/MacOS"
cp Resources/Catalyst-Info.plist "$app/Contents/Info.plist"
common=(-swift-version 6 -O -whole-module-optimization -sdk "$sdk" -module-cache-path "$PWD/.build/module-cache")
sources=(Sources/Contract.swift Sources/Control.swift Sources/Player.swift)
xcrun --sdk macosx swiftc "${common[@]}" -target arm64-apple-ios18.2-macabi \
  -F "$sdk/System/iOSSupport/System/Library/Frameworks" \
  -L "$sdk/System/iOSSupport/usr/lib" \
  -Xlinker -rpath -Xlinker /System/iOSSupport/System/Library/Frameworks \
  -Xlinker -no_adhoc_codesign "${sources[@]}" Sources/Catalyst.swift \
  -o "$app/Contents/MacOS/DriverlessInjectionProbe"
chmod a-x "$app/Contents/MacOS/DriverlessInjectionProbe"
xcrun --sdk macosx swiftc "${common[@]}" -target arm64-apple-macos14.2 \
  -Xlinker -no_adhoc_codesign \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Resources/Aggregate-Info.plist \
  "${sources[@]}" Sources/HAL.swift Sources/Aggregate.swift -o "$out/driverless-aggregate-probe"
chmod a-x "$app/Contents/MacOS/DriverlessInjectionProbe" "$out/driverless-aggregate-probe"
printf '%s\n' 'COMPILE ONLY — unsigned, not launchable. Never execute these artifacts.' > "$out/COMPILE_ONLY.txt"
python3 verify_artifacts.py "$out"
if [[ -n $identity ]]; then
  # Inventory only: no keychain unlock, import, ACL change, or automatic identity selection.
  identities=$(security find-identity -v -p codesigning)
  hash=$(printf '%s\n' "$identities" | python3 -c '
import re, sys
name = sys.argv[1]
matches = re.findall(r"\b([A-Fa-f0-9]{40})\s+\"" + re.escape(name) + r"\"", sys.stdin.read())
if len(matches) != 1: raise SystemExit("exactly one available Developer ID identity required")
print(matches[0])' "$identity")
  team=$(printf '%s\n' "$identity" | sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p')
  [[ -n $team ]] || { echo 'Developer ID team missing from identity' >&2; exit 1; }
  mkdir -p .build/signed
  # Recreate only these generated artifacts, keeping unsigned outputs separate.
  rm -rf .build/signed/DriverlessInjectionProbe.app
  ditto "$app" .build/signed/DriverlessInjectionProbe.app
  cp "$out/driverless-aggregate-probe" .build/signed/driverless-aggregate-probe
  chmod u+x .build/signed/DriverlessInjectionProbe.app/Contents/MacOS/DriverlessInjectionProbe .build/signed/driverless-aggregate-probe
  for artifact in .build/signed/DriverlessInjectionProbe.app .build/signed/driverless-aggregate-probe; do
    case "$artifact" in
      *.app) bundle_id=ai.openclaw.driverless-audio.catalyst ;;
      *) bundle_id=ai.openclaw.driverless-audio.aggregate ;;
    esac
    codesign --force --options runtime --timestamp --identifier "$bundle_id" --sign "$hash" "$artifact"
    codesign --verify --strict --verbose=2 "$artifact"
    details=$(codesign -dvv "$artifact" 2>&1)
    printf '%s\n' "$details" | python3 -c '
import sys
s = sys.stdin.read().splitlines()
assert "TeamIdentifier=" + sys.argv[1] in s, "signature team mismatch"
assert "Authority=" + sys.argv[2] in s, "signature authority mismatch"
assert "Identifier=" + sys.argv[3] in s, "signature identifier mismatch"
assert not any("Signature=adhoc" in x for x in s), "ad-hoc signature rejected"
' "$team" "$identity" "$bundle_id"
  done
  printf '%s\n' '[driverless-audio] Developer ID signatures verified; NOT launched, NOT notarized, NOT live proof.'
else
  printf '%s\n' '[driverless-audio] Both targets compiled unsigned; NOT launchable.'
fi
