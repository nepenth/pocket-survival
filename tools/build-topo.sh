#!/bin/bash
# Builds the topo overlay for Pocket Mirror's map from USGS 3DEP elevation data (public domain):
#   contours.pmtiles   contour lines every 40 ft (index lines every 200 ft), vector, zoom 9-14
#   hillshade.pmtiles  shaded relief, raster (JPEG), zoom up to 12
# Runs in CI (.github/workflows/topo.yml, Ubuntu with GDAL + tippecanoe); output goes to $OUT.
# Region: New England, the same box as the street-level map.
set -euo pipefail
OUT="${OUT:-out}"; WORK="${WORK:-work}"
W=-73.75; S=40.95; E=-66.85; N=47.50
mkdir -p "$OUT" "$WORK/dem" "$WORK/contours"

echo "== USGS 3DEP 1 arc-second tiles"
for lat in 42 43 44 45 46 47 48; do
  for lon in 67 68 69 70 71 72 73 74; do
    t="n${lat}w0${lon}"
    curl -sf -o "$WORK/dem/$t.tif" \
      "https://prd-tnm.s3.amazonaws.com/StagedProducts/Elevation/1/TIFF/current/$t/USGS_1_$t.tif" \
      && echo "  $t" || rm -f "$WORK/dem/$t.tif"   # 404 = open ocean
  done
done
gdalbuildvrt -q "$WORK/dem.vrt" "$WORK"/dem/*.tif

echo "== Contours (feet), one elevation tile at a time in parallel"
contour_tile() {
  t="$1"; base="$(basename "$t" .tif)"
  gdal_calc.py --quiet -A "$t" --outfile="$WORK/contours/$base.ft.tif" --calc="A*3.28084" \
    --type=Float32 --NoDataValue=-99999 --co COMPRESS=DEFLATE
  gdal_contour -q -a ele_ft -i 40 -f GeoJSONSeq "$WORK/contours/$base.ft.tif" "$WORK/contours/$base.geojsonseq"
  rm -f "$WORK/contours/$base.ft.tif"
}
export -f contour_tile; export WORK
ls "$WORK"/dem/*.tif | xargs -P "$(nproc)" -I{} bash -c 'contour_tile "$@"' _ {}

# Round elevations, mark 200 ft index lines, drop the sea-level line.
python3 - "$WORK/contours" "$WORK/contours.geojsonseq" <<'PY'
import glob, json, sys
n = 0
with open(sys.argv[2], "w") as out:
    for path in sorted(glob.glob(sys.argv[1] + "/*.geojsonseq")):
        for line in open(path):
            line = line.strip().lstrip("\x1e")
            if not line:
                continue
            f = json.loads(line)
            ele = int(round(f["properties"]["ele_ft"]))
            if ele <= 0:
                continue
            idx = 1 if ele % 200 == 0 else 0
            f["properties"] = {"ele": ele, "idx": idx}
            if idx:
                f["properties"]["label"] = f"{ele:,}"   # map labels must be text
            out.write(json.dumps(f, separators=(",", ":")) + "\n")
            n += 1
print(f"{n} contour lines")
PY

tippecanoe -q -f -o "$WORK/contours.mbtiles" -l contours -Z9 -z14 --simplification=6 \
  --drop-densest-as-needed --extend-zooms-if-still-dropping -P \
  -j '{ "contours": [ "any", [ ">=", "$zoom", 12 ], [ "==", "idx", 1 ] ] }' \
  --clip-bounding-box="$W,$S,$E,$N" "$WORK/contours.geojsonseq"
pmtiles convert "$WORK/contours.mbtiles" "$OUT/contours.pmtiles"

echo "== Hillshade"
gdalwarp -q -t_srs EPSG:3857 -te_srs EPSG:4326 -te $W $S $E $N -tr 30 30 -r bilinear \
  -co COMPRESS=DEFLATE -co TILED=YES -co BIGTIFF=YES -multi -wo NUM_THREADS=ALL_CPUS \
  "$WORK/dem.vrt" "$WORK/dem3857.tif"
gdaldem hillshade -q -multidirectional -z 2 -compute_edges -co COMPRESS=DEFLATE -co TILED=YES -co BIGTIFF=YES \
  "$WORK/dem3857.tif" "$WORK/hillshade.tif"
gdal_translate -q -of MBTILES -co TILE_FORMAT=JPEG -co QUALITY=70 -co ZOOM_LEVEL_STRATEGY=UPPER \
  -co NAME="Hillshade (USGS 3DEP)" "$WORK/hillshade.tif" "$WORK/hillshade.mbtiles"
gdaladdo -q -r average "$WORK/hillshade.mbtiles" 2 4 8 16 32 64 128
pmtiles convert "$WORK/hillshade.mbtiles" "$OUT/hillshade.pmtiles"

cat > "$OUT/topo.json" <<EOF
{"source": "USGS 3DEP 1 arc-second elevation (public domain)", "bbox": [$W, $S, $E, $N],
 "contours": {"file": "contours.pmtiles", "interval_ft": 40, "index_ft": 200, "minzoom": 9, "maxzoom": 14},
 "hillshade": {"file": "hillshade.pmtiles", "maxzoom": 13}}
EOF
ls -lh "$OUT"
