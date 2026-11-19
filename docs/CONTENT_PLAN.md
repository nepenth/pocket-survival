# Content plan: what goes on the phone, and how it gets there

Researched 2026-11-19. Every size below was checked in the Kiwix catalog (`library.kiwix.org`) or on the
download server.

**Target:** iPhone 11 with 128 GB of storage.
**Proposed size:** the core set is about **30 GB**, with optional extras on top.

## 1. Library (ZIM archives)

### Core: the brief's 11 archives (8.3 GB) plus these
| Archive | Size | Why |
|---|---|---|
| `wikipedia_en_all_mini_2026-09.zim` | 14.39 GB | Every English article, reduced to its lead section and infobox, with no images. The general knowledge base. |
| `mdwiki_en_all_maxi_2025-11.zim` | 2.30 GB | MDWiki: medical articles curated by Wikipedia's medicine editors, with images. The best single medical source here. |
| `ready.gov_en_all_2026-10.zim` | 2.06 GB | US government disaster guides (FEMA): hazards, kits, evacuation. Part of Kiwix's own "Preppers" bundle. |
| `zimgit-knots_en_2024-08.zim` | 0.03 GB | A Library of Knots. Tiny and practical. |
| `diy.stackexchange.com_en_all_2026-10.zim` | 2.09 GB | Home Improvement Q&A: plumbing, electrical, structural repairs. |
| `gardening.stackexchange.com_en_all_2026-10.zim` | 0.93 GB | Growing food. |
| `mechanics.stackexchange.com_en_all_2026-10.zim` | 0.34 GB | Vehicle repair. |
| `cooking.stackexchange.com_en_all_2026-10.zim` | 0.24 GB | Food handling and preservation questions. |

That's about **22.4 GB** on top of the brief's 8.3 GB.

### Optional, depending on space and interest
| Archive | Size | Notes |
|---|---|---|
| `wikipedia_en_all_nopic_2026-06.zim` | 52.69 GB | Full-text Wikipedia, no images. Upgrades the "mini" archive (it replaces it) if the phone has room. |
| `wikibooks_en_all_nopic_2026-10.zim` | 3.54 GB | Includes the Wikibooks Cookbook, First Aid and how-to books. |
| `gutenberg_en_lcc-s_2026-11a.zim` | 3.42 GB | Project Gutenberg, Library of Congress class S (agriculture: farming, animal husbandry, food preservation). |
| `gutenberg_en_lcc-r_2026-11a.zim` | 1.53 GB | Gutenberg class R (medicine; old, but covers care without modern tools). |
| `energypedia_en_all_nopic_2026-06.zim` | 0.72 GB | Off-grid energy: solar, small hydro, cookstoves. |
| `wikivoyage_en_all_nopic_2026-09.zim` | 0.27 GB | Regional and travel information. |
| `theworldfactbook_en_all_2026-02.zim` | 0.41 GB | CIA World Factbook (2020 data). |
| `trueprepper.com_en_all_2026-05.zim` / `urban-prepper_en_all_2026-08.zim` | 1.42 / 2.25 GB | Prepper sites from Kiwix's preppers selection. Mostly video, so a lot of space per useful fact. |

Kiwix publishes a SHA-256 for every file, and its mirrors support resumable (range) downloads. The
14.4 GB Wikipedia file was checked: HTTP 200, `accept-ranges: bytes`.

### How the phone reads ZIMs (change from the brief)
The brief recommends the kiwix-js web reader. Its own README rules it out on this phone:
- ZIM files must be chosen through the browser's file picker. On iOS that copies each file, so the
  14 GB Wikipedia file would be duplicated.
- It can't read archives from a URL.
- Full-text search needs iOS 15 or later.

**Recommendation:** build Kiwix's own C++ library (**libkiwix**, the engine behind kiwix-serve and the
official Kiwix apps) into Pocket Mirror. Run its built-in server inside the app, so the phone serves the
library exactly like the island's kiwix-serve does:
- browse every ZIM
- full-text and title search
- the same URLs and look as the island

Kiwix's prebuilt Apple package targets iOS 15 (`kiwix-build`, `min_iphoneos_version = "15.0"`). We'd build it in
CI with the minimum lowered to 14.0, the same approach used for llama.cpp. If that fails on iOS 14, the
fallback is a small Swift ZIM reader written for this app, with title search only.

## 2. Maps

**Recommendation:** **Protomaps PMTiles**, drawn with **Leaflet + protomaps-leaflet**.
- **One file per area.** It's cut from the free daily OpenStreetMap planet build with one command:
  `pmtiles extract <planet> state.pmtiles --bbox=… --maxzoom=15`. `--dry-run` shows the size first.
  No tilemaker run and no millions of small tile files.
- **Read through byte ranges.** The app's server already handles them, with tests.
- **Drawn without WebGL.** protomaps-leaflet draws on Canvas, which is safe on iOS 14. MapLibre GL v3+
  moved to WebGL2, which is risky on iOS 14.
- **GPS dot** through the app's location bridge, which is already built.
- **Layers:**
  - the chosen region in full detail, up to zoom 15 (street level)
  - a US backdrop up to about zoom 8
- **Area: New England** (ME, NH, VT, MA, RI, CT). Sizes were measured with
  `pmtiles extract --dry-run` against the 2026-11-18 world build (basemap v4.15.2), reading only the
  file indexes:

  | Layer | Area (bbox W,S,E,N) | Zooms | Size |
  |---|---|---|---|
  | **New England, street level** | -73.75,40.95,-66.85,47.50 | 0–15 | **1.2 GB** |
  | **Wider Northeast**: NY, NJ, PA, southern Quebec and New Brunswick (roads and towns for routes out of the region) | -80.6,39.5,-63.5,48.5 | 0–12 | 416 MB |
  | **Continental US and southern Canada backdrop** | -125,24,-66,50 | 0–9 | 164 MB |

  That's **about 1.8 GB** in total; zoom 15 is the most detailed level in this map data. Smaller
  alternatives for New England: zoom 14 is 549 MB and zoom 13 is 266 MB. The map page stacks the three
  layers, using the most detailed one that covers the view.
- **Attribution:** "© OpenStreetMap contributors" on the map, as the OpenStreetMap license requires.

To check in phase 3:
- That protomaps-leaflet and the PMTiles reader run on iOS 14 Safari. Fallback: prerendered raster
  tiles in the same PMTiles container.
- An offline place-name search (towns, peaks, water) built from the same OpenStreetMap extract.

**Worth adding later:** USGS US Topo maps. They're public-domain topographic quadrangles with contours
and trails (GeoPDF, tens of MB each); a few quads for the areas and routes that matter would be enough.

## 3. Guide and books

**Survival guide:**
- The kit's own 27-section guide; I need the files from you.
- The **US Army Survival Manual FM 21-76 / FM 3-05.70**, public domain. It's already maintained as
  clean text in the CC0
  [Survival Manual](https://sspaeth.gitlab.io/survival-manual) project (the same text as the F-Droid
  app), so it can be bundled as HTML.

**Books (PDF):**
- **Hesperian Health Guides:** *Where There Is No Doctor*, *Where There Is No Dentist*,
  *Where Women Have No Doctor*. Free PDFs under Hesperian's open copyright, which allows personal use.
  For some kinds of adaptation and redistribution, Hesperian asks for permission first.
- **Public domain:** FM 4-25.11 *First Aid*, FEMA *Are You Ready?*, and the USDA *Complete Guide to
  Home Canning*.
- **Commercial books you own** (for example *The Knowledge* or the *SAS Survival Handbook*) can be
  added from your own copies. They're never fetched by the tools.

## 4. Getting content onto the phone (never bundled in the app)

Every source works from one **catalog file** in this repo (`content/catalog.json`). Each item has a
title, category, size, download URL, SHA-256 and destination folder (`library/`, `maps/`, `books/`, `guide/`).

1. **Mac and cable (fastest for bulk):**
   - `tools/fetch-content.sh` downloads the chosen catalog items into `content/` on the Mac, resuming
     interrupted downloads and checking each SHA-256.
   - Then drag them in through Finder → iPhone → Files → Pocket Mirror (iOS File Sharing is already
     enabled in the app).
   - USB 2 runs about 30–40 MB/s, so ~30 GB takes roughly 15–20 minutes.
2. **On the phone, over Wi-Fi:**
   - A Content screen in Pocket Mirror lists the catalog with sizes and free space.
   - Downloads use iOS background transfers, which keep going while the screen is locked or the app is
     closed and resume after interruptions.
   - Each file's SHA-256 is checked, and a Wi-Fi-only switch prevents downloads over mobile data.
3. **From the island, with no internet:** the same catalog can point at the island Pi's own files
   over its hotspot, so the phone can load or refresh content from the go-bag in the field.
4. **Wi-Fi upload from a computer** (WebDAV into the app). A later option, if the cable is inconvenient.

## 5. Ideas that tie the kit together

- **Assistant answers that cite the library.** Pocket Assistant could search the library (title
  search through Pocket Mirror's server) and quote the matching guide or article. Small models are much
  more reliable when they answer from a source than from memory.
- **One launcher.** Pocket Mirror's home page gets an "Ask the Assistant" button, and the Assistant
  gets an "Open in Library" link.
- **A readiness page.** Pocket Mirror shows what's on the phone, each item's date and checksum
  status, and free space: a pre-trip checklist.

## Sources

- **Kiwix catalog and downloads:**
  - [library.kiwix.org](https://library.kiwix.org) (OPDS catalog, queried for every size above)
  - [download.kiwix.org](https://download.kiwix.org/zim/)
- **Kiwix preppers selections:**
  - [For all preppers out there](https://hub.kiwix.org/weblog/2024/02/for-all-preppers-out-there/)
  - [Preppers bundle](https://get.kiwix.org/en/solutions/hotspots/content-bundles/preppers/)
- **ZIM readers:**
  - [kiwix-js README](https://github.com/kiwix/kiwix-js) (file picker only; full-text search needs iOS 15+)
  - [kiwix-js issue #595](https://github.com/kiwix/kiwix-js/issues/595)
  - [kiwix-build apple config](https://github.com/kiwix/kiwix-build/blob/main/kiwixbuild/configs/apple.py)
  - [kiwix-apple](https://github.com/kiwix/kiwix-apple)
- **Maps:**
  - [Protomaps getting started](https://docs.protomaps.com/guide/getting-started) (pmtiles extract)
  - [PMTiles for Leaflet](https://docs.protomaps.com/pmtiles/leaflet)
  - [protomaps-leaflet](https://www.npmjs.com/package/protomaps-leaflet)
  - [MapLibre WebGL2 change](https://googlemapsmania.blogspot.com/2023/05/maplibre-adds-webgl2-support.html)
- **Books and guides:**
  - [Survival Manual (CC0)](https://sspaeth.gitlab.io/survival-manual)
  - [SurvivalManual ebook](https://www.github.com/inferno986return/SurvivalManual-ebook)
  - [Where There Is No Doctor](https://en.wikipedia.org/wiki/Where_There_Is_No_Doctor)
  - [Hesperian 2024 front matter](https://hesperian.org/wp-content/uploads/pdf/en_wtnd_2024/en_wtnd_2024_fm.pdf)
