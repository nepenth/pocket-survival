#!/bin/bash
# Cuts the offline map files for Pocket Mirror from the Protomaps daily OpenStreetMap build.
# Output: content/maps/*.pmtiles (git-ignored). Copy content/ into the app with Finder afterwards.
# Requires the pmtiles CLI (brew install pmtiles). Only the needed byte ranges are downloaded.
# Usage: tools/cut-maps.sh [YYYYMMDD]   (default: latest build)
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD="${1:-$(curl -sL https://build-metadata.protomaps.dev/builds.json | python3 -c 'import json,sys; print(json.load(sys.stdin)[-1]["key"].split(".")[0])')}"
SRC="https://build.protomaps.com/$BUILD.pmtiles"
OUT=content/maps
mkdir -p "$OUT"
echo "Protomaps build $BUILD"

# name | bbox (W,S,E,N) | max zoom | description
LAYERS=(
  "new-england|-73.75,40.95,-66.85,47.50|15|New England (ME NH VT MA RI CT), street level"
  "northeast|-80.6,39.5,-63.5,48.5|12|Wider Northeast: NY NJ PA, southern Quebec and New Brunswick"
  "north-america|-125,24,-66,50|9|Continental US and southern Canada backdrop"
)
for layer in "${LAYERS[@]}"; do
  IFS='|' read -r name bbox zoom desc <<<"$layer"
  echo "== $name ($desc), zoom 0-$zoom"
  pmtiles extract "$SRC" "$OUT/$name.pmtiles.part" --bbox="$bbox" --maxzoom="$zoom" --download-threads=4
  pmtiles verify "$OUT/$name.pmtiles.part"
  mv "$OUT/$name.pmtiles.part" "$OUT/$name.pmtiles"
done
{
  echo "{\"build\": \"$BUILD\", \"source\": \"$SRC\", \"layers\": ["
  first=1
  for layer in "${LAYERS[@]}"; do
    IFS='|' read -r name bbox zoom desc <<<"$layer"
    [ $first = 1 ] || echo ","; first=0
    printf '  {"name": "%s", "file": "%s.pmtiles", "bbox": [%s], "maxzoom": %s, "description": "%s", "bytes": %s}' \
      "$name" "$name" "$bbox" "$zoom" "$desc" "$(stat -f %z "$OUT/$name.pmtiles")"
  done
  echo; echo "]}"
} > "$OUT/maps.json"
ls -lh "$OUT"
