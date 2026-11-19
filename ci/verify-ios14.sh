#!/bin/bash
# Fails unless an unsigned .app bundle (and every Mach-O inside it) targets iOS 14.0.
# The target iPhone 11 is pinned to iOS 14.7.1, so nothing may raise the minimum.
# Usage: ci/verify-ios14.sh path/to/App.app
set -euo pipefail
APP="$1"
fail=0
MINOS_PLIST=$(plutil -extract MinimumOSVersion raw "$APP/Info.plist")
echo "Info.plist MinimumOSVersion: $MINOS_PLIST"
[ "$MINOS_PLIST" = "14.0" ] || { echo "::error::MinimumOSVersion is $MINOS_PLIST"; fail=1; }
while IFS= read -r f; do
  if file -b "$f" | grep -q "Mach-O"; then
    # LC_BUILD_VERSION reports "minos"; older LC_VERSION_MIN_IPHONEOS reports "version".
    minos=$(xcrun vtool -show-build "$f" | awk '$1=="minos" || $1=="version" {print $2; exit}')
    echo "${f#$APP/}: minos $minos"
    if [ -z "$minos" ] || [ "$(printf '%s\n14.0\n' "$minos" | sort -V | tail -1)" != "14.0" ]; then
      echo "::error::${f#$APP/} minos is ${minos:-missing} (must be <= 14.0)"; fail=1
    fi
  fi
done < <(find "$APP" -type f \( -perm -u+x -o -name "*.dylib" \))
exit $fail
