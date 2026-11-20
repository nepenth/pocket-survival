#!/bin/bash
# Downloads the reference books for Pocket Mirror into content/books/ on the external SSD.
# Only works that are public domain (US government) or published free for personal use
# (Hesperian's open copyright). Each file must be a real PDF; a SHA-256 list is written so the copy
# on the phone can be checked later. Then: tools/push-content.sh books
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="content/books"
[ -L content ] && [ -d content/ ] || { echo "content/ isn't linked to the external SSD (is it plugged in?)."; exit 1; }
mkdir -p "$OUT"
UA="pocket-survival"
ok=0; fail=0

get() { # folder file url
  local dir="$OUT/$1" dest="$OUT/$1/$2"
  mkdir -p "$dir"
  if [ -s "$dest" ] && head -c 5 "$dest" | grep -q '%PDF-'; then ok=$((ok + 1)); return; fi
  if curl -sfL -A "$UA" --retry 3 -o "$dest.part" "$3" && head -c 5 "$dest.part" | grep -q '%PDF-'; then
    mv "$dest.part" "$dest"; ok=$((ok + 1)); echo "  ok   $1/$2"
  else
    rm -f "$dest.part"; fail=$((fail + 1)); echo "  FAIL $1/$2  <- $3"
  fi
}

MM="https://archive.org/download/MManuals"
echo "== US Army field manuals (public domain)"
get army "Survival (FM 3-05.70).pdf"                         "$MM/Fm3-05.70Survival.pdf"
get army "Survival, Evasion and Recovery (FM 21-76-1).pdf"   "$MM/Fm21-76-1Survival-evasion-recoveryManual1999.pdf"
get army "First Aid (FM 4-25.11).pdf"                        "$MM/Fm4-25-11FirstAid.pdf"
get army "Map Reading and Land Navigation (FM 3-25.26).pdf"  "$MM/Fm3-25.26MapReadingAndLandNavigation.pdf"
get army "Basic Cold Weather Manual (FM 31-70).pdf"          "$MM/Fm31-70BasicColdWeatherManual.pdf"
get army "Survival in Cold Weather (TC 21-3).pdf"            "$MM/Tc21-3UsArmySurvivalInColdWeather1986.pdf"
get army "Field Hygiene and Sanitation (FM 21-10).pdf"       "$MM/Fm21-10UsArmyFieldHygeineSanitation.pdf"
get army "Military Mountaineering (FM 3-97.61).pdf"          "$MM/Fm3-97UsArmyMilitaryMountaineering2002.pdf"

echo "== US government guides (public domain)"
get fema "Are You Ready - Guide to Citizen Preparedness (FEMA 2020).pdf" \
    "https://www.ready.gov/sites/default/files/2021-03/are-you-ready-guide.pdf"
get epa "Emergency Disinfection of Drinking Water (EPA 2006).pdf" "$MM/Epa_emergency-disinfection-drinkingWater-2006.pdf"
NCHFP="https://nchfp.uga.edu/papers/guide"
get "usda-home-canning" "0 Introduction.pdf" "$NCHFP/INTRO_HomeCanrev0715.pdf"
for g in 1 2 3 4 5 6 7; do
  get "usda-home-canning" "$g Guide $g.pdf" "$NCHFP/GUIDE0${g}_HomeCan_rev0715.pdf"
done

echo "== Engineering: US Army engineer and technical manuals (public domain)"
get engineering "Engineer Field Data (FM 5-34, 1999).pdf" "https://archive.org/download/fm-5-34-engineer-field-data-w-change-3-1999/FM%205-34%20Engineer%20Field%20Data%20w-change%203%20%201999.pdf"
get engineering "General Engineering (FM 3-34.400).pdf" "https://archive.org/download/MManuals/Fm3-34-400GeneralEngineering.pdf"
get engineering "Prime Power Operations (FM 3-34.480).pdf" "https://archive.org/download/MManuals/Fm3-34-480EngineerPrimePowerOperations.pdf"
get engineering "Electrical Systems (FM 5-424).pdf" "https://archive.org/download/fm-5-424-theater-of-operations-electrical-systems-1997/FM%205-424%20Theater%20Of%20Operations%20Electrical%20Systems%20%201997.pdf"
get engineering "Grounding and Bonding (TM 5-690).pdf" "https://archive.org/download/MManuals/Tm5-690GroundingAndBondingInC4isrFacilitiesempProtection.pdf"
get engineering "Well-Drilling Operations (FM 5-484).pdf" "https://archive.org/download/FM_5_484_M_P_W_D_O_1994/FM%205-484%20Multiservice%20Procedures%20for%20Well-Drilling%20Operations%20%281994%29.pdf"
get engineering "Water Supply Sources (TM 5-813).pdf" "https://archive.org/download/MManuals/Tm5-813usArmyWaterSupplySourcesGeneralConsider1987.pdf"
get engineering "Small Water Systems (Corps of Engineers).pdf" "https://archive.org/download/MManuals/UsArmyCorpsOfEngineersSmallWaterSystems1999.pdf"
get engineering "Rigging Techniques (FM 5-125).pdf" "https://archive.org/download/fm-5-125-rigging-techniques-procedures-and-applications-1995/FM%205-125%20Rigging%20Techniques%2C%20Procedures%2C%20And%20Applications%20%201995.pdf"
get engineering "Concrete and Masonry (FM 5-428).pdf" "https://archive.org/download/fm-5-428-concrete-and-masonry-1998/FM%205-428%20Concrete%20and%20Masonry%201998.pdf"
get engineering "Construction Print Reading (EN0113).pdf" "https://archive.org/download/MManuals/ConstructionPrintReadingEn0113.pdf"
get engineering "Welding Theory and Application (TM 9-237).pdf" "https://archive.org/download/TM9-237/TM9-237.pdf"
get engineering "Welding Design, Procedures and Inspection (TM 5-805).pdf" "https://archive.org/download/MManuals/Tm5-805UsArmyWeldingDesignProceduresInspection1985.pdf"
get engineering "Field Antenna Handbook (MCRP 6-22D).pdf" "https://archive.org/download/MManuals/Mcrp6-22dUsmc-fieldAntenna-handbook.pdf"
get engineering "Radio Wave Propagation and Antennas.pdf" "https://archive.org/download/MManuals/UsArmyElectronicRadioWavePropagationAntennas1986.pdf"
get engineering "Tactical Radio Operations (FM 6-02.53).pdf" "https://archive.org/download/MManuals/Fm6-02-53TacticalRadioOperations.pdf"
echo "== Engineering classics and appropriate technology (public domain)"
get engineering-classics "Village Technology Handbook (VITA, USAID).pdf" "https://archive.org/download/pnaas277/pnaas277.pdf"
get engineering-classics "Audels Engineers and Mechanics Guide, vol 1 (1921).pdf" "https://archive.org/download/audelsengineers01unkngoog/audelsengineers01unkngoog.pdf"
get engineering-classics "Audels Engineers and Mechanics Guide, vol 2 (1921).pdf" "https://archive.org/download/audelsengineers00unkngoog/audelsengineers00unkngoog.pdf"
get engineering-classics "Audels Engineers and Mechanics Guide, vol 3 (1921).pdf" "https://archive.org/download/audelsengineers03grahgoog/audelsengineers03grahgoog.pdf"
get engineering-classics "Audels Engineers and Mechanics Guide, vol 5 (1921).pdf" "https://archive.org/download/audelsengineers05grahgoog/audelsengineers05grahgoog.pdf"
get engineering-classics "Audels Gas Engine Manual (1908).pdf" "https://archive.org/download/audelsgasengine00unkngoog/audelsgasengine00unkngoog.pdf"
get engineering-classics "Solar Hot Water (NREL).pdf" "https://archive.org/download/MManuals/Nrel_Learning-SolarHotWater.pdf"

echo "== Hesperian Health Guides (free for personal use under Hesperian's open copyright)"
hesperian() { # code folder
  local base="https://hesperian.org/wp-content/uploads/pdf/en_$1/en_$1" i
  get "$2" "00 Front matter.pdf" "${base}_fm.pdf"
  for i in $(seq -w 1 40); do
    curl -sfI -A "$UA" "${base}_$i.pdf" >/dev/null || break
    get "$2" "$i Chapter $i.pdf" "${base}_$i.pdf"
  done
  for tail in bm ob; do
    curl -sfI -A "$UA" "${base}_$tail.pdf" >/dev/null && get "$2" "99 Back matter ($tail).pdf" "${base}_$tail.pdf"
  done
  return 0
}
hesperian wtnd_2025 "Where There Is No Doctor (Hesperian 2025)"
hesperian wwhnd_2024 "Where Women Have No Doctor (Hesperian 2024)"

echo "== Index for the Books page (books.json)"
swift tools/build-books-index.swift "$OUT" 2>&1 | grep -v "CoreGraphics PDF"
( cd "$OUT" && find . -name '*.pdf' -type f | sort | while read -r f; do shasum -a 256 "$f"; done ) > "$OUT/SHA256SUMS"
echo "$ok files present, $fail failed; $(du -sh "$OUT" | cut -f1) in $OUT"
[ "$fail" = 0 ]
