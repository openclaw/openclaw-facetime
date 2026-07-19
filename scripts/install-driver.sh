#!/bin/sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_driver="$here/native-driver/.build/OpenClawBridge.driver"
installed_driver="/Library/Audio/Plug-Ins/HAL/OpenClawBridge.driver"

remove_installed_tree() {
  target=$1
  if test -x /usr/bin/trash; then
    sudo /usr/bin/trash "$target"
  else
    # macOS 14 and 15 do not ship trash. Xcode provides /usr/bin/python3.
    sudo /usr/bin/python3 -c 'import shutil, sys; shutil.rmtree(sys.argv[1])' "$target"
  fi
}

if ! test -d "$source_driver"; then
  "$here/scripts/build-driver.sh"
fi

if test -e "$installed_driver"; then
  remove_installed_tree "$installed_driver"
fi
sudo /usr/bin/ditto "$source_driver" "$installed_driver"
sudo /usr/sbin/chown -R root:wheel "$installed_driver"
sudo /bin/chmod -R go-w "$installed_driver"
coreaudiod_pids=$(/usr/bin/pgrep -x coreaudiod || true)
for coreaudiod_pid in $coreaudiod_pids; do
  # launchd immediately recreates coreaudiod. This is the activation flow
  # documented by BlackHole and works with SIP enabled, unlike kickstart -k.
  sudo /bin/kill -9 "$coreaudiod_pid"
done

printf 'Installed OpenClaw-Mic and OpenClaw-Feed. Reconnect any active FaceTime call.\n'
