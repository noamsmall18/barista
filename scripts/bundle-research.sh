#!/bin/sh
# Shared packaging for a headless helper; no additional Swift target/dependency.
set -eu
RESEARCH_BIN="$1"
RESEARCH_BUNDLE="$2"
RESEARCH_PRODUCT="$3"
RESEARCH_PLIST="$4"
RESEARCH_SOURCE="$5"
mkdir -p "$RESEARCH_BUNDLE/Contents/MacOS" "$RESEARCH_BUNDLE/Contents/Resources"
cp "$RESEARCH_BIN" "$RESEARCH_BUNDLE/Contents/MacOS/${RESEARCH_PRODUCT}Research"
cp "$RESEARCH_PLIST" "$RESEARCH_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ${RESEARCH_PRODUCT}Research" "$RESEARCH_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $RESEARCH_PRODUCT Research" "$RESEARCH_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $RESEARCH_PRODUCT Research" "$RESEARCH_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :BAResearchHelper bool true" "$RESEARCH_BUNDLE/Contents/Info.plist"
case "$RESEARCH_BUNDLE" in
    *.bundle) /usr/libexec/PlistBuddy -c 'Set :CFBundlePackageType BNDL' "$RESEARCH_BUNDLE/Contents/Info.plist" ;;
esac
cp -R "$RESEARCH_SOURCE/Web" "$RESEARCH_BUNDLE/Contents/Resources/Web"
codesign --force --sign - "$RESEARCH_BUNDLE" 2>/dev/null
