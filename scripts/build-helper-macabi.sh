#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${TMPDIR:-/tmp}/openclaw-facetime-macabi"
staged_dir="${HOME}/Library/Containers/com.apple.FaceTime/Data/tmp"
staged_dylib="${staged_dir}/FaceTimeHelper.dylib"
auth_dir="${HOME}/Library/Application Support/OpenClaw/FaceTime"
ipc_key_file="${auth_dir}/helper-ipc-key"
build_stamp_file="${auth_dir}/helper-build.sha256"
configuration="${FACETIME_HELPER_CONFIGURATION:-debug}"
if_needed=false

installed_native_dirs=()
if [[ -n "${OPENCLAW_FACETIME_NATIVE_DIR:-}" ]]; then
  installed_native_dirs+=("${OPENCLAW_FACETIME_NATIVE_DIR}")
fi
installed_native_dirs+=(
  "/opt/homebrew/opt/openclaw-facetime/libexec"
  "/usr/local/opt/openclaw-facetime/libexec"
)

if [[ "${1:-}" == "--if-needed" ]]; then
  if_needed=true
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--if-needed]" >&2
  exit 2
fi

mkdir -p "${build_dir}" "${staged_dir}" "${auth_dir}"
"${repo_root}/scripts/ensure-helper-ipc-key.sh" >/dev/null
ipc_key="$(tr -d '[:space:]' < "${ipc_key_file}")"
if [[ ! "${ipc_key}" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Invalid FaceTime helper IPC key at ${ipc_key_file}" >&2
  exit 1
fi

installed_dylib=""
source_hash=""
for native_dir in "${installed_native_dirs[@]}"; do
  candidate_dylib="${native_dir}/FaceTimeHelper.dylib"
  candidate_build_id="${native_dir}/FaceTimeHelper.build-id"
  if [[ -f "${candidate_dylib}" && -f "${candidate_build_id}" ]]; then
    candidate_hash="$(tr -d '[:space:]' < "${candidate_build_id}")"
    if [[ "${candidate_hash}" =~ ^[0-9a-f]{64}$ ]] &&
      /usr/bin/codesign --verify --strict "${candidate_dylib}" >/dev/null 2>&1 &&
      /usr/bin/strings "${candidate_dylib}" |
        /usr/bin/grep -Fx "${candidate_hash}" >/dev/null; then
      installed_dylib="${candidate_dylib}"
      source_hash="${candidate_hash}"
      break
    fi
  fi
done

if [[ -z "${source_hash}" ]]; then
  source_hash="$(FACETIME_HELPER_CONFIGURATION="${configuration}" \
    "${repo_root}/scripts/helper-build-id.sh")"
fi

if [[ "${if_needed}" == true &&
      -f "${staged_dylib}" &&
      -f "${build_stamp_file}" &&
      "$(tr -d '[:space:]' < "${build_stamp_file}")" == "${source_hash}" ]] &&
    /usr/bin/codesign --verify --strict "${staged_dylib}" >/dev/null 2>&1; then
  echo "${staged_dylib}"
  exit 0
fi

if [[ -n "${installed_dylib}" ]]; then
  /usr/bin/ditto "${installed_dylib}" "${build_dir}/FaceTimeHelper.dylib"
else
  FACETIME_HELPER_CONFIGURATION="${configuration}" \
    CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}" \
    "${repo_root}/scripts/compile-helper-macabi.sh" "${build_dir}/FaceTimeHelper.dylib"
fi

/usr/bin/ditto "${build_dir}/FaceTimeHelper.dylib" "${staged_dylib}"
/usr/bin/codesign --verify --strict "${staged_dylib}"
printf '%s\n' "${source_hash}" > "${build_stamp_file}"

echo "${staged_dylib}"
