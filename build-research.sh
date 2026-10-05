#!/bin/sh
# Build Marketbar research directly, without producing either menu-bar app.
set -eu
RESEARCH_ROOT="$(cd "$(dirname "$0")" && pwd)"
swift build -c release --package-path "$RESEARCH_ROOT" ${BARISTA_SWIFT_BUILD_FLAGS:-}
RESEARCH_BUNDLE="$RESEARCH_ROOT/dist/MarketbarResearch.bundle"
rm -rf "$RESEARCH_BUNDLE"
"$RESEARCH_ROOT/scripts/bundle-research.sh" "$RESEARCH_ROOT/.build/release/Barista" "$RESEARCH_BUNDLE" Marketbar "$RESEARCH_ROOT/Barista/Info-Marketbar.plist" "$RESEARCH_ROOT/Barista"
echo "Built independent Marketbar research: $RESEARCH_BUNDLE"
echo "Install with ./install-research.sh, then open with ./open-research.sh"
