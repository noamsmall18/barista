#!/bin/sh
# Install only Marketbar's research service. No menu-bar app is installed/launched.
set -eu
RESEARCH_ROOT="$(cd "$(dirname "$0")" && pwd)"
RESEARCH_SOURCE="$RESEARCH_ROOT/dist/MarketbarResearch.bundle"
if [ ! -d "$RESEARCH_SOURCE" ]; then
    "$RESEARCH_ROOT/build-research.sh"
fi
RESEARCH_DIRECTORY="$HOME/Library/Application Support/Marketbar/Research"
RESEARCH_TARGET="$RESEARCH_DIRECTORY/Service.bundle"
RESEARCH_AGENT="$HOME/Library/LaunchAgents/com.noam.marketbar.research.plist"
RESEARCH_LABEL="gui/$(id -u)/com.noam.marketbar.research"
mkdir -p "$RESEARCH_DIRECTORY" "$HOME/Library/LaunchAgents"
chmod 700 "$RESEARCH_DIRECTORY"
# Stop only this service's own registered job when upgrading.
launchctl bootout "$RESEARCH_LABEL" 2>/dev/null || true
# Also close a manually started helper before replacing its resource bundle.
"$RESEARCH_SOURCE/Contents/MacOS/MarketbarResearch" --stop

rm -rf "$RESEARCH_TARGET"
cp -R "$RESEARCH_SOURCE" "$RESEARCH_TARGET"
/usr/libexec/PlistBuddy -c 'Clear dict' "$RESEARCH_AGENT" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :Label string com.noam.marketbar.research' "$RESEARCH_AGENT"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments array' "$RESEARCH_AGENT"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $RESEARCH_TARGET/Contents/MacOS/MarketbarResearch" "$RESEARCH_AGENT"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments:1 string --no-open' "$RESEARCH_AGENT"
/usr/libexec/PlistBuddy -c 'Add :RunAtLoad bool true' "$RESEARCH_AGENT"
/usr/libexec/PlistBuddy -c 'Add :KeepAlive bool true' "$RESEARCH_AGENT"
/usr/libexec/PlistBuddy -c "Add :StandardOutPath string $RESEARCH_DIRECTORY/service.log" "$RESEARCH_AGENT"
/usr/libexec/PlistBuddy -c "Add :StandardErrorPath string $RESEARCH_DIRECTORY/service-error.log" "$RESEARCH_AGENT"
chmod 600 "$RESEARCH_AGENT"
launchctl bootstrap "gui/$(id -u)" "$RESEARCH_AGENT"
echo 'Standalone Marketbar research installed. Run ./open-research.sh to open it.'
