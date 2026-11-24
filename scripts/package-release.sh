#!/bin/sh
# Builds a downloadable release zip of Marketbar (or Barista) in dist/.
#
#   scripts/package-release.sh              -> dist/Marketbar-<version>.zip
#   scripts/package-release.sh barista      -> dist/Barista-<version>.zip
#
# Builds a universal binary (Apple silicon + Intel) with just the Command Line
# Tools. The .app is assembled in a private temporary folder and deleted after
# zipping, so no extra app copy is left anywhere (see AGENTS.md). Nothing is
# installed, launched or uploaded.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHICH="${1:-marketbar}"
case "$WHICH" in
    marketbar) NAME="Marketbar"; PLIST="$ROOT/Barista/Info-Marketbar.plist"; EXE="Marketbar" ;;
    barista)   NAME="Barista";   PLIST="$ROOT/Barista/Info.plist";           EXE="Barista" ;;
    *) echo "error: unknown product: $WHICH (marketbar or barista)" >&2; exit 1 ;;
esac
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' 0
trap 'exit 1' HUP INT TERM

# `swift build --arch a --arch b` needs full Xcode's xcbuild, so build each
# architecture on its own (works with just the Command Line Tools) and merge.
echo "==> Building $NAME $VERSION for Apple silicon"
swift build -c release --package-path "$ROOT" --triple arm64-apple-macosx13.0
echo "==> Building $NAME $VERSION for Intel"
swift build -c release --package-path "$ROOT" --triple x86_64-apple-macosx13.0
BIN="$STAGE/Barista"
lipo -create \
    "$ROOT/.build/arm64-apple-macosx/release/Barista" \
    "$ROOT/.build/x86_64-apple-macosx/release/Barista" \
    -output "$BIN"
ARCHS="universal ($(lipo -archs "$BIN"))"

"$ROOT/scripts/assemble-app.sh" "$BIN" "$NAME" "$PLIST" "$EXE" "$STAGE/$NAME.app"

mkdir -p "$ROOT/dist"
ZIP="$ROOT/dist/$NAME-$VERSION.zip"
rm -f "$ZIP"
# ditto keeps the bundle structure, symlinks and signature intact.
ditto -c -k --keepParent "$STAGE/$NAME.app" "$ZIP"

echo "==> $ZIP"
echo "    $ARCHS, $(du -h "$ZIP" | cut -f1 | tr -d ' '), sha256 $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
