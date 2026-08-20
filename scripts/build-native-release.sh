#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="$("${repo_root}/scripts/native-version.sh")"

output_dir="${OUTPUT_DIR:-${repo_root}/bin}"
archive_name="openclaw-facetime-macos-arm64.zip"
archive_path="${output_dir}/${archive_name}"
checksum_path="${archive_path}.sha256"
codesign_identity="${CODESIGN_IDENTITY:--}"
capture_entitlements="${repo_root}/native/Resources/facetime-audio-capture.entitlements"
scratch_path="${SWIFT_SCRATCH_PATH:-${repo_root}/native/.build/release-arm64}"
dist_dir="$(mktemp -d "${TMPDIR:-/tmp}/openclaw-facetime-dist.XXXXXX")"
artifact_dir="$(mktemp -d "${TMPDIR:-/tmp}/openclaw-facetime-artifacts.XXXXXX")"

discard_path() {
  local target="$1"
  [[ -e "${target}" ]] || return 0
  if [[ -x /usr/bin/trash ]]; then
    /usr/bin/trash "${target}"
  elif [[ -d "${target}" ]]; then
    /usr/bin/python3 -c 'import shutil, sys; shutil.rmtree(sys.argv[1])' "${target}"
  else
    /usr/bin/python3 -c 'import os, sys; os.unlink(sys.argv[1])' "${target}"
  fi
}

cleanup() {
  discard_path "${dist_dir}" >/dev/null 2>&1 || true
  discard_path "${artifact_dir}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

swift build \
  --package-path "${repo_root}/native" \
  -c release \
  --product facetime-audio-capture \
  --arch arm64 \
  --scratch-path "${scratch_path}"
product_dir="$(swift build \
  --package-path "${repo_root}/native" \
  -c release \
  --arch arm64 \
  --scratch-path "${scratch_path}" \
  --show-bin-path)"

/usr/bin/plutil -lint "${capture_entitlements}" >/dev/null

/usr/bin/ditto "${product_dir}/facetime-audio-capture" \
  "${dist_dir}/facetime-audio-capture"

while IFS= read -r rpath; do
  case "${rpath}" in
    /Applications/Xcode.app/*|/Library/Developer/*)
      /usr/bin/install_name_tool -delete_rpath "${rpath}" \
        "${dist_dir}/facetime-audio-capture"
      ;;
  esac
done < <(
  /usr/bin/otool -l "${dist_dir}/facetime-audio-capture" |
    awk '/LC_RPATH/{getline; getline; print $2}'
)

if [[ "${codesign_identity}" == "-" ]]; then
  /usr/bin/codesign --force --options runtime --sign - \
    --entitlements "${capture_entitlements}" \
    --identifier ai.openclaw.facetime-audio-capture \
    "${dist_dir}/facetime-audio-capture"
else
  /usr/bin/codesign --force --timestamp --options runtime \
    --sign "${codesign_identity}" \
    --entitlements "${capture_entitlements}" \
    --identifier ai.openclaw.facetime-audio-capture \
    "${dist_dir}/facetime-audio-capture"
fi

FACETIME_HELPER_CONFIGURATION=release \
  CODESIGN_IDENTITY="${codesign_identity}" \
  "${repo_root}/scripts/compile-helper-macabi.sh" \
  "${dist_dir}/FaceTimeHelper.dylib"
/bin/mv "${dist_dir}/FaceTimeHelper.dylib.build-id" \
  "${dist_dir}/FaceTimeHelper.build-id"

printf '%s\n' "${version}" > "${dist_dir}/VERSION"
/usr/bin/ditto "${repo_root}/LICENSE" "${dist_dir}/LICENSE"
/usr/bin/ditto "${repo_root}/THIRD_PARTY_NOTICES.md" "${dist_dir}/THIRD_PARTY_NOTICES.md"

/usr/bin/codesign --verify --strict --verbose=2 "${dist_dir}/facetime-audio-capture"
/usr/bin/codesign --verify --strict --verbose=2 "${dist_dir}/FaceTimeHelper.dylib"

mkdir -p "${output_dir}"
(
  cd "${dist_dir}"
  /usr/bin/ditto --norsrc -c -k . "${artifact_dir}/${archive_name}"
)
(
  cd "${artifact_dir}"
  /usr/bin/shasum -a 256 "${archive_name}" > "${archive_name}.sha256"
)
/bin/mv -f "${artifact_dir}/${archive_name}" "${archive_path}"
/bin/mv -f "${artifact_dir}/${archive_name}.sha256" "${checksum_path}"

"${repo_root}/scripts/verify-native-release.sh" "${archive_path}"
printf 'Built %s\n' "${archive_path}"
printf 'Checksum %s\n' "${checksum_path}"
