#!/bin/sh
# Walks through the screenshots the README and release page need.
#
# This has to be run by you rather than by a tool: capturing the screen is gated
# behind macOS's Screen Recording permission, and opening a menu bar popover
# reliably from a script is fragile. You click, this handles naming, sizing and
# placement.
#
#   ./take-screenshots.sh
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/docs/screenshots"
mkdir -p "$OUT"

shoot() {
    name="$1"; desc="$2"; hint="$3"
    echo ""
    echo "────────────────────────────────────────────────────────"
    echo "  $desc"
    echo "  $hint"
    echo ""
    printf "  Press return when it is on screen (or s to skip): "
    read answer
    [ "$answer" = "s" ] && { echo "  skipped"; return 0; }
    echo "  Crosshair: drag a box, or press SPACE then click a window."
    screencapture -i "$OUT/$name.png" || true
    if [ -f "$OUT/$name.png" ]; then
        # Retina shots come out at 2x and are needlessly heavy on a README.
        width=$(sips -g pixelWidth "$OUT/$name.png" | awk '/pixelWidth/{print $2}')
        if [ "$width" -gt 1400 ]; then
            sips --resampleWidth 1400 "$OUT/$name.png" >/dev/null
            echo "  scaled down to 1400px wide"
        fi
        echo "  saved: docs/screenshots/$name.png ($(sips -g pixelWidth -g pixelHeight "$OUT/$name.png" | awk '/pixel/{printf "%s ", $2}')px)"
    else
        echo "  nothing captured"
    fi
}

echo "Marketbar screenshots"
echo "Open Marketbar from your menu bar before starting."

shoot "portfolio" \
  "1. THE PORTFOLIO PANEL  (the important one)" \
  "Click the Marketbar item so the panel is open. Show both portfolios, the day's move, and the After hours line if the market is closed."

shoot "menubar" \
  "2. THE MENU BAR ITSELF" \
  "Tight crop of just the menu bar showing the live value. Small and wide."

shoot "research" \
  "3. THE RESEARCH POPOVER" \
  "Click a symbol row to open research. Balance sheet, bull/bear, charts."

shoot "chart" \
  "4. A ROW SPARKLINE" \
  "Close crop of one symbol's row. Best after hours or pre-market, so the dashed extended-hours tail shows."

echo ""
echo "────────────────────────────────────────────────────────"
echo "Done. Captured:"
ls -1 "$OUT" 2>/dev/null | sed 's/^/  /'
echo ""
echo "The README already references these paths, so they will appear once"
echo "they exist. Commit them with:"
echo "  git add docs/screenshots && git commit -m 'Add screenshots' && git push"
