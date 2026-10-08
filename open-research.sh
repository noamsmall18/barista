#!/bin/sh
# Open the live research workspace without starting Marketbar or Barista.
set -eu
RESEARCH_ROOT="$(cd "$(dirname "$0")" && pwd)"
RESEARCH_PRODUCT=Marketbar
case "${1:-}" in
    marketbar) shift ;;
    barista) RESEARCH_PRODUCT=Barista; shift ;;
esac
RESEARCH_EXE="$HOME/Library/Application Support/$RESEARCH_PRODUCT/Research/Service.bundle/Contents/MacOS/${RESEARCH_PRODUCT}Research"
if [ ! -x "$RESEARCH_EXE" ]; then
    RESEARCH_EXE="$RESEARCH_ROOT/dist/${RESEARCH_PRODUCT}Research.bundle/Contents/MacOS/${RESEARCH_PRODUCT}Research"
fi
if [ ! -x "$RESEARCH_EXE" ]; then
    RESEARCH_EXE="/Applications/$RESEARCH_PRODUCT.app/Contents/Resources/Research.bundle/Contents/MacOS/${RESEARCH_PRODUCT}Research"
fi
if [ ! -x "$RESEARCH_EXE" ]; then
    echo "Build the research service first: ./build-research.sh" >&2
    exit 1
fi
nohup "$RESEARCH_EXE" "$@" >"${TMPDIR:-/tmp}/${RESEARCH_PRODUCT}-research.log" 2>&1 </dev/null &
echo "$RESEARCH_PRODUCT research launched independently."
