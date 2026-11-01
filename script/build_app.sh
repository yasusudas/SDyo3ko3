#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"
BUILD_CONFIGURATION="${CONFIGURATION:-release}"
swift build -c "$BUILD_CONFIGURATION" --product yo3komi
BIN_DIR="$(swift build -c "$BUILD_CONFIGURATION" --show-bin-path)"
APP_BUNDLE="$PROJECT_ROOT/dist/yo3komi.app"
# Only replace this project's generated bundle.
if [[ -d "$APP_BUNDLE" ]]; then rm -rf "$APP_BUNDLE"; fi
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_DIR/yo3komi" "$APP_BUNDLE/Contents/MacOS/yo3komi"
if [[ -f "$PROJECT_ROOT/Resources/AppIcon.icns" ]]; then cp "$PROJECT_ROOT/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"; fi
for LOCALIZATION in "$PROJECT_ROOT"/Resources/*.lproj; do
    if [[ -d "$LOCALIZATION" ]]; then /usr/bin/ditto "$LOCALIZATION" "$APP_BUNDLE/Contents/Resources/$(basename "$LOCALIZATION")"; fi
done
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
chmod +x "$APP_BUNDLE/Contents/MacOS/yo3komi"
/usr/bin/codesign --force --sign - --timestamp=none "$APP_BUNDLE"
/usr/bin/codesign --verify --strict "$APP_BUNDLE"
/usr/bin/plutil -lint "$APP_BUNDLE/Contents/Info.plist"
printf 'Built: %s\n' "$APP_BUNDLE"
