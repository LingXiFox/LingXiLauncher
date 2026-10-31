#!/usr/bin/env bash
# Builds LingXiMac and assembles a launchable .app bundle (ad-hoc signed).
# Usage: Scripts/build-app.sh [--release|--debug]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="release"
if [[ "${1:-}" == "--debug" ]]; then
  CONFIGURATION="debug"
fi

cd "$ROOT"
swift build -c "$CONFIGURATION" --product LingXiMac

APP="$ROOT/dist/LingXiMac.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/$CONFIGURATION/LingXiMac" "$APP/Contents/MacOS/LingXiMac"
cp "$ROOT/Apps/LingXiMac/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Apps/LingXiMac/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
chmod +x "$APP/Contents/MacOS/LingXiMac"

# Ad-hoc signing is required for a usable local bundle. A signing failure must never produce
# a bundle that is silently treated as releasable.
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "Built: $APP"
