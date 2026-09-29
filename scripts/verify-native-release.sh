#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <openclaw-facetime-macos-arm64.zip>" >&2
  exit 2
fi

archive_path="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
checksum_path="${archive_path}.sha256"
receipt_path="${archive_path}.notarization.json"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/openclaw-facetime-check.XXXXXX")"
capture_entitlements="${check_dir}/facetime-audio-capture.entitlements"
trap 'if [[ -x /usr/bin/trash ]]; then /usr/bin/trash "${check_dir}" >/dev/null 2>&1 || true; else /usr/bin/python3 -c '\''import shutil,sys; shutil.rmtree(sys.argv[1])'\'' "${check_dir}" >/dev/null 2>&1 || true; fi' EXIT

[[ -f "${archive_path}" ]] || { echo "Release archive not found: ${archive_path}" >&2; exit 1; }
[[ -f "${checksum_path}" ]] || { echo "Release checksum not found: ${checksum_path}" >&2; exit 1; }
read -r expected_checksum checksum_filename checksum_extra < <(awk 'NF { print; exit }' "${checksum_path}")
[[ "${expected_checksum}" =~ ^[0-9a-f]{64}$ ]] || { echo "Invalid release checksum" >&2; exit 1; }
[[ "${checksum_filename}" == "$(basename "${archive_path}")" && -z "${checksum_extra:-}" ]] || {
  echo "Release checksum must name $(basename "${archive_path}")" >&2; exit 1;
}
actual_checksum="$(/usr/bin/shasum -a 256 "${archive_path}" | awk '{print $1}')"
[[ "${actual_checksum}" == "${expected_checksum}" ]] || { echo "Release checksum mismatch" >&2; exit 1; }

if [[ "${REQUIRE_NOTARIZATION_RECEIPT:-0}" == "1" ]]; then
  /usr/bin/python3 - "${receipt_path}" "$(basename "${archive_path}")" "${actual_checksum}" <<'PY'
import json, re, sys
path, archive, digest = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    receipt = json.load(handle)
if set(receipt) != {"archive", "archive_sha256", "issues", "status", "submission_id"}:
    raise SystemExit("notarization receipt has an unexpected schema")
if receipt["archive"] != archive or receipt["archive_sha256"] != digest or receipt["status"] != "Accepted":
    raise SystemExit("notarization receipt does not match an accepted archive")
if not re.fullmatch(r"[0-9a-fA-F-]{36}", receipt["submission_id"]):
    raise SystemExit("notarization receipt has an invalid submission id")
if not isinstance(receipt["issues"], list) or any(isinstance(x, dict) and x.get("severity") == "error" for x in receipt["issues"]):
    raise SystemExit("notarization receipt contains invalid issues")
PY
fi

expected_listing="$(printf '%s\n' LICENSE THIRD_PARTY_NOTICES.md VERSION facetime-audio-capture)"
actual_listing="$(/usr/bin/zipinfo -1 "${archive_path}" | LC_ALL=C sort)"
[[ "${actual_listing}" == "${expected_listing}" ]] || {
  echo "Release archive contents do not match the capture-only four-file contract" >&2; exit 1;
}
/usr/bin/ditto -x -k "${archive_path}" "${check_dir}"
for file in LICENSE THIRD_PARTY_NOTICES.md VERSION facetime-audio-capture; do
  [[ ! -L "${check_dir}/${file}" && -f "${check_dir}/${file}" ]] || {
    echo "Release archive must contain regular non-symlink ${file}" >&2; exit 1;
  }
done
[[ -x "${check_dir}/facetime-audio-capture" ]] || { echo "Capture executable is not executable" >&2; exit 1; }
[[ "$(tr -d '[:space:]' < "${check_dir}/VERSION")" == "$("${repo_root}/scripts/native-version.sh")" ]] || {
  echo "Release archive version does not match version.env" >&2; exit 1;
}
if /usr/bin/otool -L "${check_dir}/facetime-audio-capture" | tail -n +2 | grep -Eq '(^|[[:space:]])(/Users/|/tmp/|/private/var/|/Applications/Xcode|/Library/Developer)'; then
  echo "Capture executable contains a build-machine dependency path" >&2; exit 1;
fi
/usr/bin/lipo -archs "${check_dir}/facetime-audio-capture" | tr ' ' '\n' | grep -Fxq arm64 || {
  echo "Capture executable is missing arm64" >&2; exit 1;
}
/usr/bin/codesign --verify --strict --verbose=4 "${check_dir}/facetime-audio-capture"
/usr/bin/codesign --display --entitlements "${capture_entitlements}" --xml "${check_dir}/facetime-audio-capture" >/dev/null 2>&1
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.audio-input' "${capture_entitlements}" 2>/dev/null)" == "true" ]] || {
  echo "Capture executable is missing audio-input entitlement" >&2; exit 1;
}
if [[ "${REQUIRE_DEVELOPER_ID:-0}" == "1" ]]; then
  expected_team_id="${EXPECTED_TEAM_ID:-}"
  [[ "${expected_team_id}" =~ ^[A-Z0-9]{10}$ ]] || { echo "EXPECTED_TEAM_ID is invalid" >&2; exit 1; }
  requirement="anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"${expected_team_id}\""
  /usr/bin/codesign --verify --strict --test-requirement="=${requirement}" "${check_dir}/facetime-audio-capture"
fi
if [[ "${REQUIRE_NOTARIZED_GATEKEEPER:-0}" == "1" ]]; then
  /usr/bin/codesign --verify --strict --check-notarization -R="notarized" "${check_dir}/facetime-audio-capture"
fi
printf 'Verified %s\n' "${archive_path}"
