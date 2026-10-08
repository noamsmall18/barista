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
#   ./build-app.sh                    compile only; create no app copies
#   ./build-app.sh --install          update the canonical installed apps
#   ./build-app.sh marketbar          build only Marketbar
#   ./build-app.sh marketbar --install
#   ./build-app.sh barista --install
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN="$ROOT/.build/release/Barista"

WHICH="both"
INSTALL="no"
LAUNCH="no"
for arg in "$@"; do
    case "$arg" in
        barista|marketbar|both) WHICH="$arg" ;;
        --install) INSTALL="yes" ;;
        --launch) LAUNCH="yes" ;;
        *) echo "error: unknown argument: $arg" >&2; exit 1 ;;
    esac
done

command -v swift >/dev/null 2>&1 || {
    echo "error: swift not found. Install Apple's Command Line Tools:"
    echo "         xcode-select --install"
    exit 1
}

echo "==> Building (about a minute the first time)"
swift build -c release --package-path "$ROOT" ${BARISTA_SWIFT_BUILD_FLAGS:-}

# Build-only checks never assemble another Finder-launchable app.
if [ "$INSTALL" != "yes" ]; then
    [ "$LAUNCH" = "no" ] || { echo "error: --launch requires --install" >&2; exit 1; }
    echo "==> Compiled successfully. No app copies created."
    echo "    Update the installed app with ./build-app.sh $WHICH --install"
    exit 0
fi

APPLICATIONS_DIR="/Applications"
if [ -n "${BARISTA_APPLICATIONS_DIR:-}" ]; then
    [ "${BARISTA_TEST_MODE:-}" = "1" ] || {
        echo "error: alternate installation directories are allowed only in isolated tests" >&2
        exit 1
    }
    APPLICATIONS_DIR="$BARISTA_APPLICATIONS_DIR"
fi
mkdir -p "$APPLICATIONS_DIR"
STAGE="$(mktemp -d "$APPLICATIONS_DIR/.barista-install.XXXXXX")"
ROLLBACK_FROM=""
ROLLBACK_TO=""
cleanup() {
    if [ -n "$ROLLBACK_FROM" ] && [ -d "$ROLLBACK_FROM" ] && [ ! -e "$ROLLBACK_TO" ]; then
        mv "$ROLLBACK_FROM" "$ROLLBACK_TO"
    fi
    rm -rf "$STAGE"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

# Stage privately, verify, then move into the one canonical installed location.
install_one() {
    name="$1"; plist="$2"; exe="$3"
    app="$STAGE/$name.app"
    destination="$APPLICATIONS_DIR/$name.app"
    expected="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
    if [ -e "$destination" ]; then
        existing="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")"
        [ "$existing" = "$expected" ] || {
            echo "error: refusing to replace unrelated app at $destination" >&2
            exit 1
        }
    fi
    echo "==> Preparing $name update"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$BIN" "$app/Contents/MacOS/$exe"
    cp "$plist" "$app/Contents/Info.plist"
    cp -R "$ROOT/Barista/Web" "$app/Contents/Resources/Web"
    "$ROOT/scripts/bundle-research.sh" "$BIN" "$app/Contents/Resources/Research.bundle" "$name" "$plist" "$ROOT/Barista"
    if [ "$name" = "Marketbar" ]; then
        cp "$ROOT/Branding/MarketbarIcon.icns" "$app/Contents/Resources/AppIcon.icns"
    elif [ -f "$ROOT/AppIcon.icns" ]; then
        cp "$ROOT/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
    fi
    codesign --force --deep --sign - --entitlements "$ROOT/Barista/Barista.entitlements" "$app" 2>/dev/null \
        || codesign --force --deep --sign - "$app"
    codesign --verify --deep --strict "$app"

    # Tests never stop or launch a real app. Preserve the independent research
    # helper, which uses a different executable and does not own a menu-bar item.
    was_running="no"
    if [ "${BARISTA_TEST_MODE:-}" != "1" ] && pgrep -x "$exe" >/dev/null; then
        was_running="yes"
        pkill -TERM -x "$exe"
        attempts=0
        while pgrep -x "$exe" >/dev/null; do
            attempts=$((attempts + 1))
            [ "$attempts" -lt 50 ] || { echo "error: $name did not quit; installed app left intact" >&2; exit 1; }
            sleep 0.2
        done
    fi
    if [ -e "$destination" ]; then
        ROLLBACK_FROM="$STAGE/$name.previous.bundle"
        ROLLBACK_TO="$destination"
        mv "$destination" "$ROLLBACK_FROM"
    fi
    if ! mv "$app" "$destination"; then
        echo "error: couldn't install $name; restoring the previous app" >&2
        exit 1
    fi
    ROLLBACK_FROM=""
    ROLLBACK_TO=""
    echo "==> Updated $destination (one installed copy)"
    if [ "${BARISTA_TEST_MODE:-}" != "1" ] && { [ "$LAUNCH" = "yes" ] || [ "$was_running" = "yes" ]; }; then
        open "$destination"
    fi
}

if [ "$WHICH" = "both" ] || [ "$WHICH" = "barista" ]; then
    install_one "Barista" "$ROOT/Barista/Info.plist" "Barista"
fi
if [ "$WHICH" = "both" ] || [ "$WHICH" = "marketbar" ]; then
    install_one "Marketbar" "$ROOT/Barista/Info-Marketbar.plist" "Marketbar"
fi
