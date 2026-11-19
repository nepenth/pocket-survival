# Roadmap

## Pocket Mirror (from the "Pocket Mirror" implementation brief)

**Goal:** on the iPhone 11, in airplane mode, one app shows a big-button launcher with these sections:
- **Maps:** a chosen region in detail, plus a low-zoom country backdrop, with the GPS position and visible OSM attribution.
- **Library:** an 8.3 GB set of ZIM archives you can search.
- **Guide:** the survival guide.
- **Books:** PDF and EPUB reference books.
- **Assistant:** a button that opens Pocket Assistant.

**Shape:**
- **The app** (`apps/PocketMirror`, iOS 14.0, unsigned):
  - a small embedded HTTP server on `127.0.0.1:8090`, with correct byte-range support
  - a WKWebView that shows the content
  - folder selection with security-scoped bookmarks
  - a LAN-sharing toggle (default off)
- **The content bundle** (`bundle/`, sources only):
  - a launcher page
  - vendored kiwix-js (the ZIM reader) and Leaflet or MapLibre, with pinned versions
  - the guide pages
- **Built locally** (`content/`, git-ignored):
  - ZIM files fetched by exact name, with checksums
  - map tiles generated with tilemaker from a Geofabrik extract
  - the books
  - all of it copied to the phone with Finder or the Files app

**Phases:**
1. **App skeleton and server.**
   - Embedded server with tested byte ranges: mid-file, suffix and open-ended ranges on a multi-GB file.
   - Folder picker with saved bookmarks, WKWebView, LAN toggle.
   - CI workflow with the iOS 14 checks.
   - Done when a test bundle opens on the phone in airplane mode.
2. **Library.**
   - kiwix-js against the local ZIMs.
   - Search works on the phone, including on the 3.6 GB iFixit archive.
3. **Maps.**
   - Tile pipeline for the chosen region, served offline, with the GPS dot and attribution.
   - Raster or vector tiles, decided after testing on iOS 14.
4. **Guide and books, then the launcher.**
   - Launcher styled to match the island dashboard.
   - Assistant button opens Pocket Assistant through a URL scheme.

**Owner inputs needed:**
- Access to the guide and book files (or approval to rebuild them from the upstream project).
- Whether to add the 14.4 GB Wikipedia "mini" archive.
