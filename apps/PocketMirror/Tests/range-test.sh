#!/bin/bash
# Builds MirrorServer for macOS and checks byte-range behaviour against a multi-GB file.
# Runs in CI and locally: apps/PocketMirror/Tests/range-test.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../PocketMirror/Server"
WORK="$(mktemp -d)"
PORT=18090
SERVER_PID=""; trap '[ -n "$SERVER_PID" ] && kill $SERVER_PID 2>/dev/null || true; rm -rf "$WORK"' EXIT

swiftc -O -o "$WORK/rangetest" "$SRC/HTTPCore.swift" "$SRC/MirrorServer.swift" "$HERE/RangeTest/main.swift"

ROOT="$WORK/root"; mkdir -p "$ROOT/sub dir" "$ROOT/empty"
echo '<h1>hello</h1>' > "$ROOT/index.html"
echo 'nested' > "$ROOT/sub dir/note.txt"
echo 'secret' > "$WORK/outside.txt"
# 3 GiB sparse file (no disk used) with known 64-byte markers near the start, past 2 GiB, and at the end.
BIG="$ROOT/big.zim"; SIZE=$((3 * 1024 * 1024 * 1024))
mkfile -n "$SIZE" "$BIG" 2>/dev/null || truncate -s "$SIZE" "$BIG"
put() { printf '%s' "$2" | dd of="$BIG" bs=1 seek="$1" conv=notrunc status=none; }
MID=$((2 * 1024 * 1024 * 1024 + 12345))   # beyond 2^31: catches 32-bit offset bugs
put 1000 "START-MARKER-0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOP"
put "$MID" "MIDDLE-MARKER-0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN"
put $((SIZE - 64)) "END-MARKER-0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"

# Second root, searched after the first (in the app: built-in pages after the content folder).
WEB="$WORK/web"; mkdir -p "$WEB/maps" "$WEB/sub dir"
echo 'built-in maps page' > "$WEB/maps/index.html"
echo 'built-in only' > "$WEB/app.js"
echo 'should be hidden' > "$WEB/index.html"
echo 'built-in index for sub dir' > "$WEB/sub dir/index.html"
mkdir -p "$ROOT/maps"; echo 'map data' > "$ROOT/maps/area.pmtiles"

"$WORK/rangetest" "$ROOT:$WEB" "$PORT" & SERVER_PID=$!
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done
BASE="http://127.0.0.1:$PORT"

fail=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$2] got [$3]"; fail=1; fi
}
status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
header() { curl -s -D - -o /dev/null "${@:2}" | tr -d '\r' | awk -v h="$1" 'tolower($0) ~ "^"tolower(h)":" {sub(/^[^:]*: */,""); print}'; }
expect_bytes() { dd if="$BIG" bs=1 skip="$1" count="$2" status=none; }

check "index.html served at /"          "<h1>hello</h1>" "$(curl -s "$BASE/")"
check "full GET status"                  "200" "$(status "$BASE/index.html")"
check "Accept-Ranges advertised"         "bytes" "$(header Accept-Ranges "$BASE/big.zim" -I)"
check "HEAD Content-Length (3 GiB)"      "$SIZE" "$(header Content-Length "$BASE/big.zim" -I)"
check "mid-file range status"            "206" "$(status -r $MID-$((MID + 63)) "$BASE/big.zim")"
check "mid-file range Content-Range"     "bytes $MID-$((MID + 63))/$SIZE" "$(header Content-Range "$BASE/big.zim" -r $MID-$((MID + 63)))"
check "mid-file range bytes"             "$(expect_bytes $MID 64)" "$(curl -s -r $MID-$((MID + 63)) "$BASE/big.zim")"
check "start range bytes"                "$(expect_bytes 1000 64)" "$(curl -s -r 1000-1063 "$BASE/big.zim")"
check "suffix range Content-Range"       "bytes $((SIZE - 64))-$((SIZE - 1))/$SIZE" "$(header Content-Range "$BASE/big.zim" -H 'Range: bytes=-64')"
check "suffix range bytes"               "$(expect_bytes $((SIZE - 64)) 64)" "$(curl -s -H 'Range: bytes=-64' "$BASE/big.zim")"
check "open-ended range bytes"           "$(expect_bytes $((SIZE - 64)) 64)" "$(curl -s -r $((SIZE - 64))- "$BASE/big.zim")"
check "open-ended range length"          "64" "$(header Content-Length "$BASE/big.zim" -r $((SIZE - 64))-)"
check "end clamped to file size"         "bytes $((SIZE - 10))-$((SIZE - 1))/$SIZE" "$(header Content-Range "$BASE/big.zim" -r $((SIZE - 10))-$((SIZE + 1000)))"
check "range past end -> 416"            "416" "$(status -r $SIZE-$((SIZE + 10)) "$BASE/big.zim")"
check "416 Content-Range"                "bytes */$SIZE" "$(header Content-Range "$BASE/big.zim" -r $SIZE-)"
check "1 MiB range crossing 2 GiB"       "1048576" "$(curl -s -r $((MID - 524288))-$((MID + 524287)) "$BASE/big.zim" | wc -c | tr -d ' ')"
check "space in path"                    "nested" "$(curl -s "$BASE/sub%20dir/note.txt")"
check "directory without slash -> 301"   "301" "$(status "$BASE/sub%20dir")"
check "listing for folder without index" "200" "$(status "$BASE/empty/")"
check "missing file -> 404"              "404" "$(status "$BASE/nope.txt")"
check "path traversal refused"           "403" "$(status --path-as-is "$BASE/../outside.txt")"
check "encoded traversal refused"        "403" "$(status --path-as-is "$BASE/%2e%2e/outside.txt")"
check "POST -> 405"                      "405" "$(status -X POST "$BASE/index.html")"
check "keep-alive: 2 requests, 1 connection" "2" "$(curl -s -v "$BASE/index.html" "$BASE/sub%20dir/note.txt" 2>&1 | grep -c 'Re-using existing connection\|Reusing existing' | awk '{print $1+1}')"
check "2 roots: file only in second root" "built-in only" "$(curl -s "$BASE/app.js")"
check "2 roots: first root wins"          "<h1>hello</h1>" "$(curl -s "$BASE/index.html")"
check "2 roots: folder index from 2nd"    "built-in maps page" "$(curl -s "$BASE/maps/")"
check "2 roots: data file in 1st's folder" "map data" "$(curl -s "$BASE/maps/area.pmtiles")"
check "2 roots: folder with index wins"   "built-in index for sub dir" "$(curl -s "$BASE/sub%20dir/")"
check "LAN off: bound to loopback only"  "127.0.0.1:$PORT" "$(lsof -nP -a -p $SERVER_PID -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9; exit}')"

# LAN on: same server bound to all interfaces.
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null || true
"$WORK/rangetest" "$ROOT:$WEB" "$PORT" lan & SERVER_PID=$!
for _ in $(seq 50); do curl -s -o /dev/null "$BASE/" && break; sleep 0.1; done
check "LAN on: bound to all interfaces"  "*:$PORT" "$(lsof -nP -a -p $SERVER_PID -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9; exit}')"

exit $fail
