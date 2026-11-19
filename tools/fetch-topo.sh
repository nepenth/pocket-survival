#!/bin/bash
# Downloads the latest topo overlay built by the "Topo overlay" workflow into content/maps/
# (external SSD): contours.pmtiles, hillshade.pmtiles, topo.json. Then: tools/push-content.sh maps
set -euo pipefail
cd "$(dirname "$0")/.."
[ -L content ] && [ -d content/ ] || { echo "content/ isn't linked to the external SSD (is it plugged in?)."; exit 1; }
RUN=$(gh run list --workflow topo.yml --status success --limit 1 --json databaseId --jq '.[0].databaseId')
[ -n "$RUN" ] || { echo "No successful topo build yet (run the 'Topo overlay' workflow)."; exit 1; }
TMP=content/maps/.topo-download; rm -rf "$TMP"
gh run download "$RUN" -n topo-new-england -D "$TMP"
for f in "$TMP"/*; do pmtiles verify "$f" >/dev/null 2>&1 || [ "${f##*.}" != pmtiles ] || { echo "bad file: $f"; exit 1; }; done
mv "$TMP"/* content/maps/ && rmdir "$TMP"
ls -lh content/maps/contours.pmtiles content/maps/hillshade.pmtiles content/maps/topo.json
