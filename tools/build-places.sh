#!/bin/bash
# Builds content/maps/places.json, the offline place-name index for Pocket Mirror's map search, from
# Geofabrik OpenStreetMap extracts (ODbL; attribution shown on the map). Needs osmium-tool
# (brew install osmium-tool). Raw extracts are kept on the SSD in pocket-survival-src/osm.
# Usage: tools/build-places.sh
set -euo pipefail
cd "$(dirname "$0")/.."
[ -L content ] && [ -d content/ ] || { echo "content/ isn't linked to the external SSD (is it plugged in?)."; exit 1; }
SRC=/Volumes/DevScratch/pocket-survival-src/osm
STATES="maine:ME new-hampshire:NH vermont:VT massachusetts:MA rhode-island:RI connecticut:CT"
mkdir -p "$SRC" content/maps

FILTER=(
  n/place=city,town,village,hamlet,locality,isolated_dwelling,island,islet
  nwr/natural=peak,saddle,spring,cave_entrance,water,bay,beach,cape,glacier
  nwr/water=lake,pond,reservoir,river
  w/waterway=river,stream,canal
  nwr/leisure=park,nature_reserve
  nwr/boundary=protected_area,national_park
  nwr/amenity=hospital,clinic,doctors,pharmacy,fire_station,police,shelter,drinking_water,townhall,ranger_station,water_point
  nwr/emergency=ambulance_station
  nwr/tourism=camp_site,alpine_hut,wilderness_hut,viewpoint
  n/highway=trailhead
  nwr/aeroway=aerodrome
  n/railway=station
  nwr/man_made=water_tower,tower
)

for pair in $STATES; do
  s=${pair%%:*}; abbr=${pair##*:}
  if [ ! -s "$SRC/$s.osm.pbf" ]; then
    curl -sfL -A "pocket-survival" -o "$SRC/$s.osm.pbf" "https://download.geofabrik.de/north-america/us/$s-latest.osm.pbf"
  fi
  osmium tags-filter --overwrite -o "$SRC/$s.filtered.osm.pbf" "$SRC/$s.osm.pbf" "${FILTER[@]}"
  osmium export --overwrite -f geojsonseq -o "$SRC/$s.geojsonseq" "$SRC/$s.filtered.osm.pbf" \
    --geometry-types=point,linestring,polygon
  echo "$abbr: $(wc -l < "$SRC/$s.geojsonseq") features"
done

python3 - "$SRC" content/maps/places.json $STATES <<'PY'
import json, math, sys, unicodedata
src, out, pairs = sys.argv[1], sys.argv[2], sys.argv[3:]

# kind -> (label, importance; higher ranks first when names match equally well)
KINDS = {
  "city": ("City", 10), "town": ("Town", 9), "village": ("Village", 7), "hamlet": ("Hamlet", 5),
  "locality": ("Place", 4), "isolated_dwelling": ("Place", 2), "island": ("Island", 6), "islet": ("Island", 3),
  "peak": ("Peak", 6), "saddle": ("Pass", 4), "spring": ("Spring", 5), "cave_entrance": ("Cave", 3),
  "lake": ("Lake", 6), "pond": ("Pond", 4), "reservoir": ("Reservoir", 5), "water": ("Water", 4),
  "river": ("River", 6), "stream": ("Stream", 3), "canal": ("Canal", 3),
  "bay": ("Bay", 5), "beach": ("Beach", 4), "cape": ("Cape", 5), "glacier": ("Glacier", 3),
  "park": ("Park", 4), "nature_reserve": ("Nature reserve", 5), "protected_area": ("Protected area", 5),
  "national_park": ("National park", 7),
  "hospital": ("Hospital", 9), "clinic": ("Clinic", 7), "doctors": ("Doctor", 5), "pharmacy": ("Pharmacy", 6),
  "fire_station": ("Fire station", 7), "police": ("Police", 7), "ambulance_station": ("Ambulance", 7),
  "shelter": ("Shelter", 6), "drinking_water": ("Drinking water", 5), "water_point": ("Water point", 5),
  "townhall": ("Town hall", 5), "ranger_station": ("Ranger station", 6),
  "camp_site": ("Campsite", 6), "alpine_hut": ("Hut", 6), "wilderness_hut": ("Hut", 6), "viewpoint": ("Viewpoint", 3),
  "trailhead": ("Trailhead", 6), "aerodrome": ("Airport", 6), "station": ("Station", 5),
  "water_tower": ("Water tower", 2), "tower": ("Tower", 2),
}
KEYS = ["place", "natural", "water", "waterway", "leisure", "boundary", "amenity", "emergency", "tourism",
        "highway", "aeroway", "railway", "man_made"]

def kind_of(p):
    for k in KEYS:
        v = p.get(k)
        if v in KINDS:
            if k == "natural" and v == "water" and p.get("water") in KINDS:
                return p["water"]
            return v
    return None

def centre(geom):
    t, c = geom["type"], geom["coordinates"]
    if t == "Point":
        return c[1], c[0]
    if t == "LineString":
        p = c[len(c) // 2]
        return p[1], p[0]
    rings = c if t == "Polygon" else [r for poly in c for r in poly[:1]]
    pts = [p for r in rings[:1] for p in r] if t == "Polygon" else [p for r in rings for p in r]
    return sum(p[1] for p in pts) / len(pts), sum(p[0] for p in pts) / len(pts)

kind_ids = {k: i for i, k in enumerate(KINDS)}
seen = {}   # (name, kind) -> list of [lat, lon] already kept (dedupe river/stream segments etc.)
items = []
for pair in pairs:
    s, abbr = pair.split(":")
    for line in open(f"{src}/{s}.geojsonseq", encoding="utf-8"):
        line = line.strip().lstrip("\x1e")
        if not line:
            continue
        f = json.loads(line)
        p = f.get("properties", {})
        name = p.get("name")
        k = kind_of(p)
        if not name or not k or not f.get("geometry"):
            continue
        lat, lon = centre(f["geometry"])
        key = (name.lower(), k)
        near = seen.setdefault(key, [])
        # Same name and kind within ~8 km is the same feature split into pieces.
        if any(abs(lat - a) < 0.07 and abs(lon - b) < 0.1 for a, b in near):
            continue
        near.append((lat, lon))
        ele = p.get("ele")
        try:
            ele = round(float(str(ele).split()[0].replace(",", ""))) if ele else None
        except ValueError:
            ele = None
        row = [name, kind_ids[k], round(lat, 5), round(lon, 5), abbr]
        if ele is not None:
            row.append(ele)
        items.append(row)

kinds = [[KINDS[k][0], KINDS[k][1]] for k in KINDS]
json.dump({"source": "OpenStreetMap contributors (ODbL), via Geofabrik", "kinds": kinds, "places": items},
          open(out, "w", encoding="utf-8"), ensure_ascii=False, separators=(",", ":"))
counts = {}
for r in items:
    counts[kinds[r[1]][0]] = counts.get(kinds[r[1]][0], 0) + 1
print(f"{len(items)} places -> {out}")
print(", ".join(f"{k} {v}" for k, v in sorted(counts.items(), key=lambda x: -x[1])))
PY
ls -lh content/maps/places.json
