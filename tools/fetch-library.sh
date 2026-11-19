#!/bin/bash
# Downloads the Pocket Mirror library (ZIM archives listed in tools/library-catalog.txt) into
# content/library/ on the external SSD, resuming partial downloads and checking each file against the
# SHA-256 that Kiwix publishes next to it. Then: tools/push-content.sh library
# Usage: tools/fetch-library.sh [core|optional|all]     (default: core)
set -euo pipefail
cd "$(dirname "$0")/.."
SET="${1:-core}"
MIRROR="https://download.kiwix.org/zim"
OUT="content/library"

# content/ must be the SSD, never the laptop's own disk.
[ -L content ] && [ -d content/ ] || { echo "content/ isn't linked to the external SSD (is it plugged in?)."; exit 1; }
mkdir -p "$OUT"

total=0; ok=0
while IFS='|' read -r set zpath title; do
  set=$(echo "$set" | xargs); zpath=$(echo "$zpath" | xargs); title=$(echo "$title" | xargs)
  [ -z "$zpath" ] && continue
  [ "$SET" = all ] || [ "$set" = "$SET" ] || continue
  total=$((total + 1))
  file="${zpath##*/}"
  echo "== $title ($file)"
  expected=$(curl -sfL -A "pocket-survival" "$MIRROR/$zpath.sha256" | awk '{print $1}')
  [ ${#expected} -eq 64 ] || { echo "   no checksum published; skipping"; continue; }
  if [ -f "$OUT/$file" ] && [ "$(shasum -a 256 "$OUT/$file" | awk '{print $1}')" = "$expected" ]; then
    echo "   already downloaded and verified"; ok=$((ok + 1)); continue
  fi
  # -C - resumes a partial .part file; mirrors support byte ranges.
  for attempt in 1 2 3; do
    if curl -fL -A "pocket-survival" --retry 5 --retry-delay 10 -C - --progress-bar -o "$OUT/$file.part" "$MIRROR/$zpath"; then break; fi
    echo "   download interrupted (attempt $attempt), resuming..."; sleep 10
  done
  actual=$(shasum -a 256 "$OUT/$file.part" | awk '{print $1}')
  if [ "$actual" = "$expected" ]; then
    mv "$OUT/$file.part" "$OUT/$file"; ok=$((ok + 1)); echo "   verified"
  else
    echo "   CHECKSUM MISMATCH; deleting the partial file so it downloads fresh next time"; rm -f "$OUT/$file.part"
  fi
done < <(grep -v '^\s*#' tools/library-catalog.txt | grep '|')

# Manifest for the app's launcher: titles and sizes of what's present.
python3 - "$OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
titles = {}
for line in open("tools/library-catalog.txt"):
    if "|" in line and not line.lstrip().startswith("#"):
        _, p, t = [x.strip() for x in line.split("|")]
        titles[p.rsplit("/", 1)[-1]] = t
items = [{"file": f, "title": titles.get(f, f), "bytes": os.path.getsize(os.path.join(out, f))}
         for f in sorted(os.listdir(out)) if f.endswith(".zim")]
json.dump({"archives": items}, open(os.path.join(out, "library.json"), "w"), indent=1)
print(f"library.json: {len(items)} archives, {sum(i['bytes'] for i in items) / 1e9:.1f} GB")
PY
echo "$ok of $total archives present and verified in $OUT"
[ "$ok" = "$total" ]
