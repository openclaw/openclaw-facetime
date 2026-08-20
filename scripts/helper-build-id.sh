#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper_dir="${repo_root}/helper/FaceTimeHelper"
configuration="${FACETIME_HELPER_CONFIGURATION:-debug}"

if [[ "${configuration}" != "debug" && "${configuration}" != "release" ]]; then
  echo "FACETIME_HELPER_CONFIGURATION must be debug or release" >&2
  exit 2
fi

{
  printf 'openclaw-facetime-helper-build-v2\n'
  printf 'targets=arm64e-apple-ios15.0-macabi,arm64-apple-ios15.0-macabi\n'
  printf 'configuration=%s\n' "${configuration}"
  find "${helper_dir}" -type f -print | LC_ALL=C sort | while IFS= read -r source_file; do
    relative_path="${source_file#"${repo_root}/"}"
    printf '%s  %s\n' "$(shasum -a 256 "${source_file}" | awk '{print $1}')" "${relative_path}"
  done
  printf '%s  %s\n' \
    "$(shasum -a 256 "${repo_root}/scripts/compile-helper-macabi.sh" | awk '{print $1}')" \
    "scripts/compile-helper-macabi.sh"
  printf '%s  %s\n' \
    "$(shasum -a 256 "${repo_root}/helper-endpoint.json" | awk '{print $1}')" \
    "helper-endpoint.json"
} | shasum -a 256 | awk '{print $1}'
