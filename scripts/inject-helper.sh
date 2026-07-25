#!/usr/bin/env bash
set -euo pipefail

derived_root="${HOME}/Library/Developer/Xcode/DerivedData"
staged_macabi="${HOME}/Library/Containers/com.apple.FaceTime/Data/tmp/FaceTimeHelper.dylib"
target_app="${FACETIME_HELPER_APP:-FaceTime}"

case "${target_app}" in
  FaceTime)
    target_bundle="com.apple.FaceTime"
    target_executable="/System/Applications/FaceTime.app/Contents/MacOS/FaceTime"
    ;;
  Phone)
    target_bundle="com.apple.mobilephone"
    target_executable="/System/Applications/Phone.app/Contents/MacOS/Phone"
    ;;
  *)
    echo "Unsupported helper app: ${target_app}. Use FaceTime or Phone." >&2
    exit 1
    ;;
esac

if ! DevToolsSecurity -status 2>/dev/null | grep -q "enabled"; then
  cat >&2 <<'EOF'
Developer Tools mode is disabled.

Run this once in an interactive Terminal, then rerun this script:

  sudo /usr/sbin/DevToolsSecurity -enable

EOF
  exit 1
fi

dylib="${FACETIME_HELPER_DYLIB:-}"
if [[ -z "${dylib}" ]]; then
  if [[ -f "${staged_macabi}" ]]; then
    dylib="${staged_macabi}"
  else
    dylib="$(find "${derived_root}" -path '*FaceTimeHelper.dylib' -type f -print 2>/dev/null | sort | tail -1)"
  fi
fi

if [[ -z "${dylib}" || ! -f "${dylib}" ]]; then
  cat >&2 <<EOF
FaceTimeHelper.dylib was not found under:

  ${staged_macabi}
  ${derived_root}

Build it first:

  pnpm build:helper:macabi

EOF
  exit 1
fi

target_tmp="${HOME}/Library/Containers/${target_bundle}/Data/tmp"
mkdir -p "${target_tmp}"
unique_dylib="${target_tmp}/FaceTimeHelper-$(date +%Y%m%d%H%M%S)-$$.dylib"
cp "${dylib}" "${unique_dylib}"
dylib="${unique_dylib}"

target_pid="${FACETIME_HELPER_PID:-}"
target_name="${target_app} app"

if [[ -z "${target_pid}" ]]; then
  target_pid="$(pgrep -f "${target_executable}" | head -1 || true)"
fi

if [[ -z "${target_pid}" ]]; then
  open -a "${target_app}"
  sleep 2
  target_pid="$(pgrep -f "${target_executable}" | head -1 || true)"
fi

if [[ -z "${target_pid}" && "${target_app}" == "FaceTime" ]]; then
  target_name="FaceTime conversation service"
  target_pid="$(pgrep -f '/com.apple.FaceTime.FTConversationService' | head -1 || true)"
fi

if [[ -z "${target_pid}" ]]; then
  echo "${target_app} is not running. Open ${target_app}, then rerun this script." >&2
  exit 1
fi

echo "Injecting ${dylib}"
echo "Target ${target_name} PID: ${target_pid}"

lldb -p "${target_pid}" \
  -o "expr (void*)dlopen(\"${dylib}\", 2)" \
  -o "expr (char*)dlerror()" \
  -o detach \
  -o quit
