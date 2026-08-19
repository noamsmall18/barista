#!/bin/sh
# Builds Barista.app from source.
#
# A locally built app is never given the quarantine flag that macOS applies to
# downloads, so it runs without Gatekeeper complaining and without anyone paying
# for a Developer ID. That is why building from source is the recommended
# install route rather than a workaround.
#
#   ./build-app.sh            build into ./dist
#   ./build-app.sh --install  build, then move it into /Applications and open it
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/dist/Barista.app"
BIN="$ROOT/.build/release/Barista"

command -v swift >/dev/null 2>&1 || {
    echo "error: swift not found. Install Apple's Command Line Tools:"
    echo "         xcode-select --install"
    exit 1
}

echo "==> Building (this takes about a minute the first time)"
swift build -c release --package-path "$ROOT"

echo "==> Assembling Barista.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Barista"
cp "$ROOT/Barista/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/AppIcon.icns" ] && cp "$ROOT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature. Enough for macOS to run a locally built app; it is not a
# Developer ID and does not make the app distributable as a download.
echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - \
    --entitlements "$ROOT/Barista/Barista.entitlements" "$APP" 2>/dev/null \
  || codesign --force --deep --sign - "$APP"

echo "==> Built: $APP"

if [ "$1" = "--install" ]; then
    echo "==> Installing to /Applications"
    osascript -e 'quit app "Barista"' 2>/dev/null || true
    pkill -x Barista 2>/dev/null || true
    sleep 1
    rm -rf /Applications/Barista.app
    cp -R "$APP" /Applications/Barista.app
    open -a /Applications/Barista.app
    echo "==> Barista is running. Look for it in your menu bar."
else
    echo "    Drag it to /Applications, or re-run with --install"
fi
