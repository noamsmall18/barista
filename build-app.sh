#!/bin/sh
# Builds Barista and Marketbar from source.
#
# Both ship from one codebase and one binary; the app bundle they launch from
# decides which one they are. Marketbar registers only the market terminal.
#
# A locally built app is never given the quarantine flag that macOS applies to
# downloads, so it runs without Gatekeeper complaining and without anyone paying
# for a Developer ID. That is why building from source is the recommended
# install route rather than a workaround.
#
#   ./build-app.sh                    build both into ./dist
#   ./build-app.sh --install          build both, install both, launch Marketbar
#   ./build-app.sh marketbar          build only Marketbar
#   ./build-app.sh marketbar --install
#   ./build-app.sh barista --install
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN="$ROOT/.build/release/Barista"

WHICH="both"
INSTALL="no"
for arg in "$@"; do
    case "$arg" in
        barista|marketbar|both) WHICH="$arg" ;;
        --install) INSTALL="yes" ;;
    esac
done

command -v swift >/dev/null 2>&1 || {
    echo "error: swift not found. Install Apple's Command Line Tools:"
    echo "         xcode-select --install"
    exit 1
}

echo "==> Building (about a minute the first time)"
swift build -c release --package-path "$ROOT"

# bundle <AppName> <Info.plist> <executable name>
bundle() {
    name="$1"; plist="$2"; exe="$3"
    app="$ROOT/dist/$name.app"
    echo "==> Assembling $name.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$BIN" "$app/Contents/MacOS/$exe"
    cp "$plist" "$app/Contents/Info.plist"
    [ -f "$ROOT/AppIcon.icns" ] && cp "$ROOT/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
    codesign --force --deep --sign - \
        --entitlements "$ROOT/Barista/Barista.entitlements" "$app" 2>/dev/null \
      || codesign --force --deep --sign - "$app"
    echo "    $app"
}

[ "$WHICH" = "both" ] || [ "$WHICH" = "barista" ] &&
    bundle "Barista" "$ROOT/Barista/Info.plist" "Barista"
[ "$WHICH" = "both" ] || [ "$WHICH" = "marketbar" ] &&
    bundle "Marketbar" "$ROOT/Barista/Info-Marketbar.plist" "Marketbar"

if [ "$INSTALL" = "yes" ]; then
    install_one() {
        name="$1"
        [ -d "$ROOT/dist/$name.app" ] || return 0
        echo "==> Installing $name to /Applications"
        osascript -e "quit app \"$name\"" 2>/dev/null || true
        pkill -x "$name" 2>/dev/null || true
        sleep 1
        rm -rf "/Applications/$name.app"
        cp -R "$ROOT/dist/$name.app" "/Applications/$name.app"
    }
    [ "$WHICH" = "both" ] || [ "$WHICH" = "barista" ] && install_one "Barista"
    [ "$WHICH" = "both" ] || [ "$WHICH" = "marketbar" ] && install_one "Marketbar"

    # Marketbar is the one most people want, so it is what gets opened.
    if [ -d "/Applications/Marketbar.app" ]; then
        open -a /Applications/Marketbar.app
        echo "==> Marketbar is running. Look for it in your menu bar."
    elif [ -d "/Applications/Barista.app" ]; then
        open -a /Applications/Barista.app
        echo "==> Barista is running. Look for it in your menu bar."
    fi
else
    echo "    Drag to /Applications, or re-run with --install"
fi
