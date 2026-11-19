#!/bin/bash
# Copies content folders (e.g. maps) from content/ into Pocket Mirror on the iPhone over the USB
# cable. No Finder, no sync. Works for TrollStore installs too (those don't appear in Finder's
# Files tab or in usbmux file sharing).
#
# How: iproxy (libimobiledevice) forwards a Mac port over USB to Pocket Mirror's built-in server on
# the phone, and each file is sent with an HTTP PUT. The server writes to a hidden temporary file and
# renames it when complete, so an interrupted copy never leaves a broken file.
#
# On the phone first: open Pocket Mirror and turn on Accept Uploads (keep the app on screen).
# Usage: tools/push-content.sh maps [library books ...]
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -gt 0 ] || { echo "usage: $0 <folder under content/> [...]"; exit 2; }
LOCAL_PORT=18090
BASE="http://127.0.0.1:$LOCAL_PORT"

if [ -n "${POCKET_BASE:-}" ]; then
  BASE="$POCKET_BASE"   # testing: send to a server on this Mac instead of the phone
else
  idevice_id -l | grep -q . || { echo "No iPhone found. Connect it with the cable, unlock it and tap Trust."; exit 1; }
  iproxy "$LOCAL_PORT:8090" >/dev/null 2>&1 & PROXY=$!
  trap 'kill $PROXY 2>/dev/null || true' EXIT
  for _ in $(seq 30); do curl -s -o /dev/null -m 2 "$BASE/" && break; sleep 0.3; done
fi
curl -s -o /dev/null -m 3 "$BASE/" || { echo "Can't reach Pocket Mirror. Open it on the phone (keep it on screen) and try again."; exit 1; }

# Reads 1 MiB at an offset, locally and from the phone, and compares checksums.
same_window() { # file urlpath offset
  local a b
  a=$(dd if="$1" bs=1048576 skip="$(( $3 / 1048576 ))" count=1 status=none | shasum -a 256)
  b=$(curl -s -r "$3-$(( $3 + 1048575 ))" "$BASE$2" | shasum -a 256)
  [ "$a" = "$b" ]
}

for folder in "$@"; do
  src="content/$folder"
  [ -d "$src" ] || { echo "No such folder: $src"; exit 1; }
  echo "== $folder"
  # Largest first and the small manifest (maps.json) last, so the app never sees a manifest
  # that points at files not yet copied.
  for f in $(ls -S "$src"); do
    [ -f "$src/$f" ] || continue
    size=$(stat -f %z "$src/$f")
    path="/$folder/$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$f")"
    echo "  $f ($((size / 1000000)) MB)"
    start=$(date +%s)
    if ! curl --fail --progress-bar -o /tmp/pocket-push.$$ -T "$src/$f" "$BASE$path"; then
      echo "    FAILED: $(cat /tmp/pocket-push.$$ 2>/dev/null)"
      echo "    Is Pocket Mirror open with Accept Uploads on?"
      exit 1
    fi
    code=$(curl -s -o /dev/null -w '%{http_code}' -I "$BASE$path")
    phone_size=$(curl -s -I "$BASE$path" | tr -d '\r' | awk 'tolower($1)=="content-length:" {print $2}')
    if [ "$code" != "200" ] || [ "$phone_size" != "$size" ]; then
      echo "    FAILED: phone has ${phone_size:-nothing} bytes, expected $size. Is Accept Uploads on?"
      exit 1
    fi
    # Spot-check content at the start, middle and end.
    for off in 0 $(( size / 2 / 1048576 * 1048576 )) $(( (size > 1048576 ? size - 1048576 : 0) / 1048576 * 1048576 )); do
      same_window "$src/$f" "$path" "$off" || { echo "    FAILED: content differs at byte $off"; exit 1; }
    done
    secs=$(( $(date +%s) - start )); [ "$secs" -gt 0 ] || secs=1
    echo "    copied and checked in ${secs}s ($(( size / secs / 1000000 )) MB/s)"
  done
done
rm -f /tmp/pocket-push.$$
echo "All copied. You can turn Accept Uploads off again."
