#!/bin/sh
# Assembles and ad-hoc signs one app bundle from a built binary.
# Shared by build-app.sh (install) and scripts/package-release.sh (release zip),
# so an installed app and a downloaded one are built the same way.
#
#   scripts/assemble-app.sh BIN NAME PLIST EXECUTABLE DESTINATION.app
set -eu

BIN="$1"; NAME="$2"; PLIST="$3"; EXE="$4"; APP="$5"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXE"
cp "$PLIST" "$APP/Contents/Info.plist"
cp -R "$ROOT/Barista/Web" "$APP/Contents/Resources/Web"
"$ROOT/scripts/bundle-research.sh" "$BIN" "$APP/Contents/Resources/Research.bundle" "$NAME" "$PLIST" "$ROOT/Barista"
if [ "$NAME" = "Marketbar" ]; then
    cp "$ROOT/Branding/MarketbarIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
elif [ -f "$ROOT/AppIcon.icns" ]; then
    cp "$ROOT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
codesign --force --deep --sign - --entitlements "$ROOT/Barista/Barista.entitlements" "$APP" 2>/dev/null \
    || codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
