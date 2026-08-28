#!/bin/bash
# Build Release and install to /Applications with launch-safe ad-hoc signing.
#
# Why the re-sign step: ad-hoc Release builds keep hardened runtime enabled,
# and its library validation refuses the embedded WebRTC.framework ("different
# Team IDs" dyld crash at launch). Re-signing without --options runtime matches
# what Xcode does automatically for ad-hoc Debug builds.
set -euo pipefail

cd "$(dirname "$0")/.."

DERIVED=build/release-local
APP="$DERIVED/Build/Products/Release/Overlook.app"
DEST=/Applications/Overlook.app

xcodebuild -project Overlook.xcodeproj -scheme Overlook \
  -configuration Release -derivedDataPath "$DERIVED" build

codesign --force -s - "$APP/Contents/Frameworks/WebRTC.framework"
codesign --force -s - --preserve-metadata=entitlements "$APP"
codesign --verify --strict "$APP"

if pgrep -x Overlook >/dev/null; then
  echo "Overlook is running — quit it first (or: killall Overlook)" >&2
  exit 1
fi

rm -rf "$DEST"
cp -R "$APP" "$DEST"

open "$DEST"
sleep 5
if pgrep -x Overlook >/dev/null; then
  echo "Deployed and launched OK: $DEST"
else
  echo "App crashed after launch — check ~/Library/Logs/DiagnosticReports" >&2
  exit 1
fi
