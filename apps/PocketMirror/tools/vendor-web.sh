#!/bin/bash
# Fetches the pinned web libraries used by Pocket Mirror's built-in pages into PocketMirror/Web/vendor/
# (committed). Re-run only to change a pinned version, then re-check Safari 14 compatibility:
# no class static blocks, .at(), structuredClone, Object.hasOwn, findLast, OffscreenCanvas, and any
# DecompressionStream use must be guarded (it is iOS 16.4+).
set -euo pipefail
cd "$(dirname "$0")/../PocketMirror/Web/vendor"
LEAFLET=1.9.4
PROTOMAPS_LEAFLET=5.1.0   # bundles pmtiles 4.x and fflate (gzip fallback for iOS < 16.4)
PMTILES=4.5.0

rm -rf leaflet protomaps-leaflet pmtiles
mkdir -p leaflet/images protomaps-leaflet
for f in leaflet.js leaflet.css images/layers.png images/layers-2x.png images/marker-icon.png images/marker-icon-2x.png images/marker-shadow.png; do
  curl -sfL -o "leaflet/$f" "https://unpkg.com/leaflet@$LEAFLET/dist/$f"
done
curl -sfL -o leaflet/LICENSE "https://unpkg.com/leaflet@$LEAFLET/LICENSE"
curl -sfL -o protomaps-leaflet/protomaps-leaflet.js "https://unpkg.com/protomaps-leaflet@$PROTOMAPS_LEAFLET/dist/protomaps-leaflet.js"
curl -sfL -o protomaps-leaflet/LICENSE "https://unpkg.com/protomaps-leaflet@$PROTOMAPS_LEAFLET/LICENSE" || true
# pmtiles reader on its own, for raster (hillshade) layers via pmtiles.leafletRasterLayer
mkdir -p pmtiles
curl -sfL -o pmtiles/pmtiles.js "https://unpkg.com/pmtiles@$PMTILES/dist/pmtiles.js"
curl -sfL -o pmtiles/LICENSE "https://unpkg.com/pmtiles@$PMTILES/LICENSE" || true

cat > VERSIONS.md <<MD
# Vendored web libraries (pinned)

| Library | Version | Source |
|---|---|---|
| Leaflet | $LEAFLET | https://unpkg.com/leaflet@$LEAFLET/dist/ |
| protomaps-leaflet (bundles pmtiles and fflate) | $PROTOMAPS_LEAFLET | https://unpkg.com/protomaps-leaflet@$PROTOMAPS_LEAFLET/dist/ |
| pmtiles (raster layers) | $PMTILES | https://unpkg.com/pmtiles@$PMTILES/dist/ |

Both are used unmodified. Regenerate with \`apps/PocketMirror/tools/vendor-web.sh\`.
MD
find . -type f | sort | xargs ls -l | awk '{print $5, $9}'
