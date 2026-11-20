#!/bin/bash
# Builds content/maps/routing.bin, the offline road and trail network Pocket Mirror's map uses for
# directions (walking and driving), from the same Geofabrik OpenStreetMap extracts as the place
# index (tools/build-places.sh downloads them). Needs osmium-tool and Python 3 with numpy.
# Work files stay on the SSD in pocket-survival-src/routing.
# Usage: tools/build-routing.sh
set -euo pipefail
cd "$(dirname "$0")/.."
[ -L content ] && [ -d content/ ] || { echo "content/ isn't linked to the external SSD (is it plugged in?)."; exit 1; }
SRC=/Volumes/DevScratch/pocket-survival-src/osm
WORK=/Volumes/DevScratch/pocket-survival-src/routing
mkdir -p "$WORK" content/maps

STATES="connecticut maine massachusetts new-hampshire rhode-island vermont"
for s in $STATES; do [ -s "$SRC/$s.osm.pbf" ] || { echo "Missing $SRC/$s.osm.pbf: run tools/build-places.sh first."; exit 1; }; done

echo "== Merge the six states"
osmium merge --overwrite -o "$WORK/ne.osm.pbf" $(for s in $STATES; do echo "$SRC/$s.osm.pbf"; done)

echo "== Roads, tracks and paths"
osmium tags-filter --overwrite -o "$WORK/ways-all.osm.pbf" "$WORK/ne.osm.pbf" \
  w/highway=motorway,trunk,primary,secondary,tertiary,unclassified,residential,motorway_link,trunk_link,primary_link,secondary_link,tertiary_link,living_street,service,road,track,path,footway,pedestrian,steps,bridleway,cycleway
# Sidewalks and crossings run beside roads people can walk anyway; driveways and parking aisles
# only lead to one building. Leaving them out halves the network.
osmium tags-filter --overwrite -i -o "$WORK/ways.osm.pbf" "$WORK/ways-all.osm.pbf" \
  w/footway=sidewalk,crossing w/service=driveway,parking_aisle,drive-through w/area=yes
osmium cat --overwrite -f opl -o "$WORK/ways.opl" "$WORK/ways.osm.pbf"

echo "== Graph"
python3 tools/routing_graph.py "$WORK/ways.opl" content/maps/routing.bin
rm -f "$WORK/ways.opl" "$WORK/ways-all.osm.pbf"
ls -lh content/maps/routing.bin
