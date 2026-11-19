#!/bin/bash
# Builds Kiwix's C++ engine (libkiwix, with libzim, xapian, icu, libmicrohttpd, libcurl, zstd, xz...) as
# one static library for the iPhone 11 on iOS 14, packaged as CoreKiwix.xcframework.
#
# kiwix-build (Kiwix's own build tool, pinned below) targets iOS 15.0 for Apple; the only change made
# here is lowering that minimum to 14.0 in the downloaded copy of the tool. Every object file is then
# checked for its minimum iOS version.
#
# Output: apps/PocketMirror/build/kiwix/CoreKiwix.xcframework   (git-ignored; CI caches it)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../build/kiwix"
WORK="${KIWIX_WORK:-$HERE/../build/kiwix-work}"
KIWIX_BUILD_TAG="${KIWIX_BUILD_TAG:-r_115}"
mkdir -p "$OUT" "$WORK"
cd "$WORK"

if [ ! -d kiwix-build ]; then
  git clone --quiet --depth 1 --branch "$KIWIX_BUILD_TAG" https://github.com/kiwix/kiwix-build.git
fi
APPLE_PY=kiwix-build/kiwixbuild/configs/apple.py
sed -i '' 's/min_iphoneos_version = "15.0"/min_iphoneos_version = "14.0"/' "$APPLE_PY"
grep -q 'min_iphoneos_version = "14.0"' "$APPLE_PY" || { echo "error: couldn't lower the iOS minimum in $APPLE_PY"; exit 1; }

python3 -m venv venv
# shellcheck disable=SC1091
source venv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet ./kiwix-build

kiwix-build --config ios_arm64 --hide-progress libkiwix

INSTALL="$WORK/BUILD_ios_arm64/INSTALL"
echo "== static libraries built:"; ls -l "$INSTALL/lib"/*.a

# Every object must target iOS 14.0 or lower (same rule as ci/verify-ios14.sh for app binaries).
bad=$(for a in "$INSTALL"/lib/*.a; do
        otool -l "$a" 2>/dev/null | awk '/cmd LC_BUILD_VERSION/{b=1} b && /minos/{print $2; b=0} /LC_VERSION_MIN_IPHONEOS/{v=1} v && /version/{print $2; v=0}'
      done | sort -u | awk '{ split($1, p, "."); if (p[1] + 0 > 14) print }')
if [ -n "$bad" ]; then echo "error: objects target iOS $bad"; exit 1; fi
echo "== all objects target iOS 14.0 or lower"

# One static library from all of them, plus the headers the app's wrapper includes.
rm -rf "$OUT/CoreKiwix.xcframework" "$OUT/staging"; mkdir -p "$OUT/staging/include"
libtool -static -o "$OUT/staging/libCoreKiwix.a" "$INSTALL"/lib/*.a 2>&1 | grep -v "has no symbols" || true
cp -R "$INSTALL/include/." "$OUT/staging/include/"
xcodebuild -create-xcframework \
  -library "$OUT/staging/libCoreKiwix.a" -headers "$OUT/staging/include" \
  -output "$OUT/CoreKiwix.xcframework"
rm -rf "$OUT/staging"
echo "kiwix-build $KIWIX_BUILD_TAG" > "$OUT/CoreKiwix.xcframework/BUILD_INFO"
( cd "$WORK/BUILD_ios_arm64" && for d in */; do [ -d "$d/.git" ] && echo "$d $(git -C "$d" rev-parse --short HEAD)"; done ) >> "$OUT/CoreKiwix.xcframework/BUILD_INFO" 2>/dev/null || true
du -sh "$OUT/CoreKiwix.xcframework"
