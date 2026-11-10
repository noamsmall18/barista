#!/bin/sh
# One entry point for every check in this repo.
#
#   ./test.sh                 Swift unit/UI tests, then the web tests
#   ./test.sh swift [FILTER]  Swift tests only, optionally just matching ones
#   ./test.sh web             Research-workspace JavaScript tests
#   ./test.sh integration     Shipped research helper (run ./build-research.sh first)
#   ./test.sh all             Everything above
#   ./test.sh --previews      Add to any Swift run: save UI previews as PNGs
#
# Tests never touch real portfolios: BARISTA_TEST_MODE=1 is always set, which
# uses in-memory preferences and blocks app startup and migration.
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
export BARISTA_TEST_MODE=1

MODE="default"
FILTER=""
PREVIEWS="no"
for arg in "$@"; do
    case "$arg" in
        swift|web|integration|all) MODE="$arg" ;;
        --previews) PREVIEWS="yes" ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "error: unknown option: $arg (try ./test.sh --help)" >&2; exit 2 ;;
        *) FILTER="$arg" ;;
    esac
done
[ -z "$FILTER" ] || [ "$MODE" != "default" ] || MODE="swift"

# XCTest ships with Xcode, not the Command Line Tools. Use Xcode automatically
# when the active toolchain can't run the suite.
use_xcode_toolchain() {
    [ -z "${DEVELOPER_DIR:-}" ] || return 0
    case "$(xcode-select -p 2>/dev/null)" in *CommandLineTools*) ;; *) return 0 ;; esac
    for app in /Applications/Xcode.app /Applications/Xcode-beta.app; do
        if [ -d "$app/Contents/Developer" ]; then
            export DEVELOPER_DIR="$app/Contents/Developer"
            return 0
        fi
    done
    echo "error: Swift tests need Xcode (XCTest is not in the Command Line Tools)." >&2
    return 1
}

LOG="$(mktemp -t barista-test)"
trap 'rm -f "$LOG" "$LOG.retry"' 0
FAILED=""

run_swift() {
    use_xcode_toolchain || return 1
    if [ "$PREVIEWS" = "yes" ]; then
        export BARISTA_UI_PREVIEW_DIR="${BARISTA_UI_PREVIEW_DIR:-$ROOT/.build/ui-previews}"
        rm -rf "$BARISTA_UI_PREVIEW_DIR"
    fi
    echo "==> Swift tests${FILTER:+ matching '$FILTER'}"
    if [ -n "$FILTER" ]; then swift test --filter "$FILTER" >"$LOG" 2>&1; else swift test >"$LOG" 2>&1; fi
    status=$?
    grep -E "error:|✘" "$LOG" | sed 's/^/    /'
    # Tests that drive a real menu-bar popover can lose it when another app
    # takes focus mid-run. Rerun failures once on their own, and say so; a test
    # that fails twice is a real failure.
    failures="$(sed -n "s/^Test Case '-\[BaristaTests\.\([A-Za-z0-9_]*\) \([A-Za-z0-9_]*\)\]' failed.*/\1\/\2/p" "$LOG" | sort -u)"
    if [ -n "$failures" ]; then
        still=""
        for name in $failures; do
            if swift test --filter "BaristaTests.$name\$" >"$LOG.retry" 2>&1; then
                echo "    flaky: $name failed in the full run, passed alone"
            else
                still="$still $name"
            fi
        done
        if [ -n "$still" ]; then
            echo "    FAILED:$still"
            return 1
        fi
        status=0
        total="$(sed -n 's/.*Executed \([0-9]*\) tests.*/\1/p' "$LOG" | tail -1)"
        echo "    $total XCTest tests passed, $(echo "$failures" | wc -l | tr -d ' ') of them only on rerun"
        grep -E "Test run with" "$LOG" | tail -1 | sed 's/^[[:space:]]*/    /'
    else
        grep -E "Executed [0-9]+ tests|Test run with" "$LOG" | tail -2 | sed 's/^[[:space:]]*/    /'
    fi
    if [ "$status" -ne 0 ]; then tail -20 "$LOG"; return 1; fi
    [ "$PREVIEWS" = "no" ] || echo "    previews: $BARISTA_UI_PREVIEW_DIR"
}

need_node() {
    command -v node >/dev/null 2>&1 || { echo "error: node not found; web tests need Node 18+." >&2; return 1; }
}

run_web() {
    need_node || return 1
    echo "==> Web tests"
    node --test Tests/Web/*.test.cjs >"$LOG" 2>&1 || { cat "$LOG"; return 1; }
    grep -E "^(#|ℹ) (tests|pass|fail)" "$LOG" | sed -E 's/^(#|ℹ) /    /' | tr '\n' ' '; echo
}

run_integration() {
    need_node || return 1
    echo "==> Research helper integration"
    [ -d "$ROOT/dist/MarketbarResearch.bundle" ] || { echo "error: run ./build-research.sh first." >&2; return 1; }
    # The real helper refuses to start in test mode. This check isolates itself
    # instead: a temporary bundle identity, preferences domain and session folder.
    env -u BARISTA_TEST_MODE node --test Tests/ResearchWorkspaceIntegration.cjs >"$LOG" 2>&1 || { cat "$LOG"; return 1; }
    grep -E "^(#|ℹ) (tests|pass|fail)" "$LOG" | sed -E 's/^(#|ℹ) /    /' | tr '\n' ' '; echo
}

step() { "run_$1" || FAILED="$FAILED $1"; }

case "$MODE" in
    default) step swift; step web ;;
    all) step swift; step web; step integration ;;
    *) step "$MODE" ;;
esac

if [ -n "$FAILED" ]; then
    echo "==> FAILED:$FAILED"
    exit 1
fi
echo "==> All checks passed"
