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

cleanup() {
  if [[ -x /usr/bin/trash ]]; then
    /usr/bin/trash "${check_dir}" >/dev/null 2>&1 || true
  else
    /usr/bin/python3 -c 'import shutil, sys; shutil.rmtree(sys.argv[1])' \
      "${check_dir}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ ! -f "${archive_path}" ]]; then
  echo "Release archive not found: ${archive_path}" >&2
  exit 1
fi
if [[ ! -f "${checksum_path}" ]]; then
  echo "Release checksum not found: ${checksum_path}" >&2
  exit 1
fi
if [[ "$(awk 'NF { count += 1 } END { print count + 0 }' "${checksum_path}")" -ne 1 ]]; then
  echo "Release checksum must contain exactly one non-empty entry" >&2
  exit 1
fi
read -r expected_checksum checksum_filename checksum_extra < <(awk 'NF { print; exit }' "${checksum_path}")
if [[ ! "${expected_checksum}" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Release checksum contains an invalid SHA-256 digest" >&2
  exit 1
fi
if [[ "${checksum_filename}" != "$(basename "${archive_path}")" || -n "${checksum_extra:-}" ]]; then
  echo "Release checksum must name $(basename "${archive_path}")" >&2
  exit 1
fi
actual_checksum="$(/usr/bin/shasum -a 256 "${archive_path}" | awk '{print $1}')"
if [[ "${actual_checksum}" != "${expected_checksum}" ]]; then
  echo "Release checksum does not match $(basename "${archive_path}")" >&2
  exit 1
fi
printf '%s: OK\n' "$(basename "${archive_path}")"

if [[ "${REQUIRE_NOTARIZATION_RECEIPT:-0}" == "1" ]]; then
  /usr/bin/python3 - "${receipt_path}" "$(basename "${archive_path}")" "${actual_checksum}" <<'PY'
import json
import re
import sys

receipt_path, archive_name, archive_sha256 = sys.argv[1:]
try:
    with open(receipt_path, encoding="utf-8") as handle:
        receipt = json.load(handle)
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"invalid notarization receipt: {error}") from error
if set(receipt) != {"archive", "archive_sha256", "issues", "status", "submission_id"}:
    raise SystemExit("notarization receipt has an unexpected schema")
if receipt["archive"] != archive_name or receipt["archive_sha256"] != archive_sha256:
    raise SystemExit("notarization receipt does not match the release archive")
if receipt["status"] != "Accepted":
    raise SystemExit("notarization receipt does not report Accepted")
if not re.fullmatch(r"[0-9a-fA-F-]{36}", receipt["submission_id"]):
    raise SystemExit("notarization receipt has an invalid submission id")
if not isinstance(receipt["issues"], list):
    raise SystemExit("notarization receipt issues must be a list")
if any(isinstance(issue, dict) and issue.get("severity") == "error" for issue in receipt["issues"]):
    raise SystemExit("notarization receipt contains an error issue")
print(f"Notarization receipt verified: {receipt['submission_id']}")
PY
fi

expected_listing="$(printf '%s\n' \
  FaceTimeHelper.build-id \
  FaceTimeHelper.dylib \
  LICENSE \
  THIRD_PARTY_NOTICES.md \
  VERSION \
  facetime-audio-capture)"
actual_listing="$(/usr/bin/zipinfo -1 "${archive_path}" | LC_ALL=C sort)"
if [[ "${actual_listing}" != "${expected_listing}" ]]; then
  echo "Release archive contents do not match the six-file contract" >&2
  exit 1
fi

/usr/bin/ditto -x -k "${archive_path}" "${check_dir}"
required_files=(
  facetime-audio-capture
  FaceTimeHelper.dylib
  FaceTimeHelper.build-id
  VERSION
  LICENSE
  THIRD_PARTY_NOTICES.md
)
for required_file in "${required_files[@]}"; do
  if [[ -L "${check_dir}/${required_file}" || ! -f "${check_dir}/${required_file}" ]]; then
    echo "Release archive must contain a regular non-symlink ${required_file}" >&2
    exit 1
  fi
done

build_id="$(tr -d '[:space:]' < "${check_dir}/FaceTimeHelper.build-id")"
if [[ ! "${build_id}" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Release archive contains an invalid helper build identity" >&2
  exit 1
fi
expected_build_id="$(FACETIME_HELPER_CONFIGURATION=release \
  "${repo_root}/scripts/helper-build-id.sh")"
if [[ "${build_id}" != "${expected_build_id}" ]]; then
  echo "Release helper build identity does not match this source revision" >&2
  exit 1
fi
if ! /usr/bin/strings "${check_dir}/FaceTimeHelper.dylib" |
    grep -Fx "${build_id}" >/dev/null; then
  echo "Release helper does not embed its declared build identity" >&2
  exit 1
fi
version="$("${repo_root}/scripts/native-version.sh")"
archive_version="$(tr -d '[:space:]' < "${check_dir}/VERSION")"
if [[ "${archive_version}" != "${version}" ]]; then
  echo "Release archive version does not match version.env" >&2
  exit 1
fi
if [[ ! -x "${check_dir}/facetime-audio-capture" ]]; then
  echo "Capture executable lost its executable mode in the archive" >&2
  exit 1
fi
helper_install_name="$(/usr/bin/otool -D "${check_dir}/FaceTimeHelper.dylib" | tail -1)"
if [[ "${helper_install_name}" != "@rpath/FaceTimeHelper.dylib" ]]; then
  echo "Injected helper contains a non-portable install name: ${helper_install_name}" >&2
  exit 1
fi
for binary in facetime-audio-capture FaceTimeHelper.dylib; do
  if /usr/bin/otool -L "${check_dir}/${binary}" | tail -n +2 | \
      grep -Eq '(^|[[:space:]])(/Users/|/tmp/|/private/var/|/Applications/Xcode|/Library/Developer)'; then
    echo "${binary} contains a build-machine dependency path" >&2
    exit 1
  fi
  if /usr/bin/otool -l "${check_dir}/${binary}" | \
      awk '/LC_RPATH/{getline; getline; print $2}' | \
      grep -Eq '^(/Users/|/tmp/|/private/var/|/Applications/Xcode|/Library/Developer)'; then
    echo "${binary} contains a build-machine runtime search path" >&2
    exit 1
  fi
done
if ! /usr/bin/lipo -archs "${check_dir}/facetime-audio-capture" | tr ' ' '\n' | grep -Fxq arm64; then
  echo "Capture executable is missing its required arm64 slice" >&2
  exit 1
fi
for helper_arch in arm64e arm64; do
  if ! /usr/bin/lipo -archs "${check_dir}/FaceTimeHelper.dylib" | tr ' ' '\n' | grep -Fxq "${helper_arch}"; then
    echo "Injected helper is missing its required ${helper_arch} slice" >&2
    exit 1
  fi
done

/usr/bin/codesign --verify --strict --verbose=4 "${check_dir}/facetime-audio-capture"
/usr/bin/codesign --verify --strict --verbose=4 "${check_dir}/FaceTimeHelper.dylib"
/usr/bin/codesign --display --entitlements "${capture_entitlements}" --xml \
  "${check_dir}/facetime-audio-capture" >/dev/null 2>&1
if [[ "$(/usr/libexec/PlistBuddy \
  -c 'Print :com.apple.security.device.audio-input' \
  "${capture_entitlements}" 2>/dev/null)" != "true" ]]; then
  echo "Capture executable is missing its required audio-input entitlement" >&2
  exit 1
fi
if [[ "${REQUIRE_DEVELOPER_ID:-0}" == "1" ]]; then
  expected_team_id="${EXPECTED_TEAM_ID:-}"
  if [[ ! "${expected_team_id}" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "EXPECTED_TEAM_ID must be the 10-character Apple Developer Team ID" >&2
    exit 1
  fi
  requirement="anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"${expected_team_id}\""
  /usr/bin/codesign --verify --strict --test-requirement="=${requirement}" \
    "${check_dir}/facetime-audio-capture"
  /usr/bin/codesign --verify --strict --test-requirement="=${requirement}" \
    "${check_dir}/FaceTimeHelper.dylib"
fi
if [[ "${REQUIRE_NOTARIZED_GATEKEEPER:-0}" == "1" ]]; then
  # ZIPs cannot carry a stapled ticket. For command-line tools and libraries,
  # codesign asks Gatekeeper's online service for the code-signature ticket.
  /usr/bin/codesign --verify --strict --check-notarization \
    -R="notarized" \
    "${check_dir}/facetime-audio-capture"
  /usr/bin/codesign --verify --strict --check-notarization \
    -R="notarized" \
    "${check_dir}/FaceTimeHelper.dylib"
fi

printf 'Verified %s\n' "${archive_path}"
printf '  facetime-audio-capture: %s\n' "$(/usr/bin/lipo -archs "${check_dir}/facetime-audio-capture")"
printf '  FaceTimeHelper.dylib: %s\n' "$(/usr/bin/lipo -archs "${check_dir}/FaceTimeHelper.dylib")"
printf '  helper build identity: %s\n' "${build_id}"
