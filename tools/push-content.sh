#!/bin/bash
# Copies content folders (e.g. maps) from content/ into Pocket Mirror's Documents folder on the
# iPhone over the USB cable, using libimobiledevice's afcclient (brew install libimobiledevice).
# No Finder, no iTunes-style sync. The phone must be unlocked and trust this Mac.
#
# Usage: tools/push-content.sh maps [library books ...]
set -euo pipefail
cd "$(dirname "$0")/.."
APP_ID="net.pocketsurvival.mirror"
[ $# -gt 0 ] || { echo "usage: $0 <folder under content/> [...]"; exit 2; }

idevice_id -l | grep -q . || { echo "No iPhone found. Connect it with the cable, unlock it and tap Trust."; exit 1; }
afc() { afcclient --documents "$APP_ID" "$@"; }
afc ls / >/dev/null 2>&1 || { echo "Can't open Pocket Mirror's folder. Is Pocket Mirror 0.1.0 or later installed?"; exit 1; }

for folder in "$@"; do
  src="content/$folder"
  [ -d "$src" ] || { echo "No such folder: $src"; exit 1; }
  echo "== $folder"
  afc mkdir "/$folder" >/dev/null 2>&1 || true
  # Small files (the manifest) last, so the app never sees a manifest before its data files.
  for f in $(ls -S "$src"); do
    size=$(stat -f %z "$src/$f")
    printf "  %-28s %8s MB ... " "$f" "$((size / 1000000))"
    start=$(date +%s)
    afc put -f "$src/$f" "/$folder/$f" >/dev/null
    secs=$(( $(date +%s) - start ))
    echo "done in ${secs}s"
  done
  echo "  On the phone:"; afc ls "/$folder" | sed 's/^/    /'
done
echo "All copied. Open Pocket Mirror › Open Mirror › Maps."
