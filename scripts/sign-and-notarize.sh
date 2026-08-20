#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${OUTPUT_DIR:-/tmp}"
archive_path="${output_dir}/openclaw-facetime-macos-arm64.zip"
receipt_path="${archive_path}.notarization.json"
notary_dir="$(mktemp -d "${TMPDIR:-/tmp}/openclaw-facetime-notary.XXXXXX")"
api_key_file="${notary_dir}/AuthKey.p8"
notary_log_file="${notary_dir}/notary-log.json"
expected_team_id="${EXPECTED_TEAM_ID:-}"

discard_directory() {
  local target="$1"
  [[ -d "${target}" ]] || return 0
  if [[ -x /usr/bin/trash ]]; then
    /usr/bin/trash "${target}"
  else
    /usr/bin/python3 -c 'import shutil, sys; shutil.rmtree(sys.argv[1])' "${target}"
  fi
}

cleanup() {
  if [[ -e "${api_key_file}" ]]; then
    : > "${api_key_file}"
  fi
  discard_directory "${notary_dir}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [[ -z "${CODESIGN_IDENTITY:-}" || "${CODESIGN_IDENTITY}" == "-" ]]; then
  echo "Set CODESIGN_IDENTITY to a Developer ID Application identity." >&2
  exit 1
fi
if [[ ! "${expected_team_id}" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "Set EXPECTED_TEAM_ID to the 10-character Apple Developer Team ID." >&2
  exit 1
fi
if [[ -z "${APP_STORE_CONNECT_API_KEY_P8:-}" ||
      -z "${APP_STORE_CONNECT_KEY_ID:-}" ||
      -z "${APP_STORE_CONNECT_ISSUER_ID:-}" ]]; then
  echo "Missing APP_STORE_CONNECT_* env vars (API key, key id, issuer id)." >&2
  exit 1
fi

umask 077
printf '%s' "${APP_STORE_CONNECT_API_KEY_P8}" | sed 's/\\n/\
/g' > "${api_key_file}"

OUTPUT_DIR="${output_dir}" \
  CODESIGN_IDENTITY="${CODESIGN_IDENTITY}" \
  FACETIME_HELPER_CONFIGURATION=release \
  "${repo_root}/scripts/build-native-release.sh"

REQUIRE_DEVELOPER_ID=1 EXPECTED_TEAM_ID="${expected_team_id}" \
  "${repo_root}/scripts/verify-native-release.sh" "${archive_path}"

notary_result="$(xcrun notarytool submit "${archive_path}" \
  --key "${api_key_file}" \
  --key-id "${APP_STORE_CONNECT_KEY_ID}" \
  --issuer "${APP_STORE_CONNECT_ISSUER_ID}" \
  --wait \
  --output-format json)"
notary_status="$(printf '%s' "${notary_result}" | /usr/bin/python3 -c \
  'import json, sys; print(json.load(sys.stdin).get("status", ""))')"
notary_id="$(printf '%s' "${notary_result}" | /usr/bin/python3 -c \
  'import json, sys; print(json.load(sys.stdin).get("id", ""))')"
if [[ "${notary_status}" != "Accepted" ]]; then
  echo "Apple notarization failed with status: ${notary_status:-unknown}" >&2
  if [[ -n "${notary_id}" ]]; then
    xcrun notarytool log "${notary_id}" \
      --key "${api_key_file}" \
      --key-id "${APP_STORE_CONNECT_KEY_ID}" \
      --issuer "${APP_STORE_CONNECT_ISSUER_ID}" >&2 || true
  fi
  exit 1
fi

if [[ -z "${notary_id}" ]]; then
  echo "Apple notarization returned Accepted without a submission id" >&2
  exit 1
fi
xcrun notarytool log "${notary_id}" "${notary_log_file}" \
  --key "${api_key_file}" \
  --key-id "${APP_STORE_CONNECT_KEY_ID}" \
  --issuer "${APP_STORE_CONNECT_ISSUER_ID}"
/usr/bin/python3 - "${notary_log_file}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    result = json.load(handle)

if result.get("status") != "Accepted":
    raise SystemExit("notarization log does not confirm Accepted status")
issues = result.get("issues") or []
errors = [issue for issue in issues if issue.get("severity") == "error"]
if errors:
    raise SystemExit(f"notarization log contains {len(errors)} error issue(s)")
warnings = [issue for issue in issues if issue.get("severity") == "warning"]
print(f"Notarization log verified ({len(warnings)} warning issue(s))")
PY

archive_sha256="$(/usr/bin/shasum -a 256 "${archive_path}" | /usr/bin/awk '{print $1}')"
/usr/bin/python3 - "${notary_log_file}" "${notary_dir}/notarization-receipt.json" "${archive_sha256}" "${notary_id}" <<'PY'
import json
import os
import sys

log_path, receipt_path, archive_sha256, submission_id = sys.argv[1:]
with open(log_path, encoding="utf-8") as handle:
    log = json.load(handle)
issues = log.get("issues") or []
receipt = {
    "archive": "openclaw-facetime-macos-arm64.zip",
    "archive_sha256": archive_sha256,
    "status": log.get("status"),
    "submission_id": submission_id,
    "issues": issues,
}
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
descriptor = os.open(receipt_path, flags, 0o600)
with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
    json.dump(receipt, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
/bin/mv -f "${notary_dir}/notarization-receipt.json" "${receipt_path}"

REQUIRE_DEVELOPER_ID=1 EXPECTED_TEAM_ID="${expected_team_id}" \
  REQUIRE_NOTARIZATION_RECEIPT=1 \
  "${repo_root}/scripts/verify-native-release.sh" "${archive_path}"

printf 'Signed and notarized: %s\n' "${archive_path}"
printf 'Notarization receipt: %s\n' "${receipt_path}"
