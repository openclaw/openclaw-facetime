#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <output-dylib>" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper_dir="${repo_root}/helper"
output_dylib="$1"
output_build_id="${output_dylib}.build-id"
developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
sdk_root="${developer_dir}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
clang_bin="${developer_dir}/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
configuration="${FACETIME_HELPER_CONFIGURATION:-debug}"
codesign_identity="${CODESIGN_IDENTITY:--}"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/openclaw-facetime-helper.XXXXXX")"
build_header="${build_dir}/OpenClawFaceTimeHelperBuild.h"
helper_arches=(arm64e arm64)

cleanup() {
  if [[ -x /usr/bin/trash ]]; then
    /usr/bin/trash "${build_dir}" >/dev/null 2>&1 || true
  else
    /usr/bin/python3 -c 'import shutil, sys; shutil.rmtree(sys.argv[1])' \
      "${build_dir}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ ! -x "${clang_bin}" || ! -d "${sdk_root}" ]]; then
  echo "Full Xcode is required at ${developer_dir}" >&2
  exit 1
fi
if [[ "${configuration}" != "debug" && "${configuration}" != "release" ]]; then
  echo "FACETIME_HELPER_CONFIGURATION must be debug or release" >&2
  exit 2
fi

build_id="$(FACETIME_HELPER_CONFIGURATION="${configuration}" \
  "${repo_root}/scripts/helper-build-id.sh")"
printf '#define OPENCLAW_FACETIME_HELPER_BUILD_ID "%s"\n' "${build_id}" > "${build_header}"

compile_flags=()
if [[ "${configuration}" == "debug" ]]; then
  compile_flags+=("-DDEBUG=1")
else
  compile_flags+=("-DNDEBUG=1")
fi

mkdir -p "$(dirname "${output_dylib}")"
arch_outputs=()
for helper_arch in "${helper_arches[@]}"; do
  arch_output="${build_dir}/FaceTimeHelper-${helper_arch}.dylib"
  DEVELOPER_DIR="${developer_dir}" "${clang_bin}" \
    -target "${helper_arch}-apple-ios15.0-macabi" \
    -dynamiclib \
    -install_name "@rpath/FaceTimeHelper.dylib" \
    -isysroot "${sdk_root}" \
    -fobjc-arc \
    -fmodules \
    -include "${build_header}" \
    -ObjC \
    "${compile_flags[@]}" \
    -I "${helper_dir}/FaceTimeHelper" \
    -I "${helper_dir}/FaceTimeHelper/FaceTime" \
    -I "${helper_dir}/FaceTimeHelper/ZKSwizzle" \
    -iframework /System/Library/PrivateFrameworks \
    "${helper_dir}/FaceTimeHelper/ActionAuthentication.m" \
    "${helper_dir}/FaceTimeHelper/FaceTimeHelper.m" \
    "${helper_dir}/FaceTimeHelper/NetworkController.m" \
    "${helper_dir}/FaceTimeHelper/CTBlockDescription.m" \
    "${helper_dir}/FaceTimeHelper/ZKSwizzle/ZKSwizzle.m" \
    -framework Foundation \
    -framework CoreServices \
    -framework Security \
    -framework TelephonyUtilities \
    -framework IMCore \
    -o "${arch_output}"
  arch_outputs+=("${arch_output}")
done
/usr/bin/lipo -create "${arch_outputs[@]}" -output "${output_dylib}"

if [[ "${codesign_identity}" == "-" ]]; then
  /usr/bin/codesign --force --sign - \
    --identifier ai.openclaw.facetime.helper \
    "${output_dylib}"
else
  /usr/bin/codesign --force --timestamp --options runtime \
    --sign "${codesign_identity}" \
    --identifier ai.openclaw.facetime.helper \
    "${output_dylib}"
fi

printf '%s\n' "${build_id}" > "${output_build_id}"
/usr/bin/codesign --verify --strict --verbose=2 "${output_dylib}"
for helper_arch in "${helper_arches[@]}"; do
  if ! /usr/bin/lipo -archs "${output_dylib}" | tr ' ' '\n' | grep -Fxq "${helper_arch}"; then
    echo "FaceTimeHelper.dylib is missing its required ${helper_arch} slice" >&2
    exit 1
  fi
done

printf 'Built %s\n' "${output_dylib}"
printf 'Build identity: %s\n' "${build_id}"
