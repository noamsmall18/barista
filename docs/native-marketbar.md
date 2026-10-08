# Native Marketbar window and ticker details

Marketbar opens its own `MarketbarWindowController` from the Dock, Cmd+, and the
menu-bar Customize action. Barista continues to open its widget settings window.
Marketbar also opens this window on its first launch rather than the Barista
onboarding flow.

The portfolio page provides portfolio switching and management, live value and
change versus previous close, cash editing, historical value ranges, and a
watchlist with position editing. Double-click a loaded quote for ticker details.
Missing quotes are shown explicitly and excluded from the reported total.
Enable **All Portfolios** in the sidebar (or **Show All Portfolios** in the
menu-bar dropdown settings) for a separate, automatic combined view. It sums
holdings, cash including negative balances, and realized gains across every
portfolio. Repeated symbols become one position with a weighted average cost;
if any contributing shares lack a cost, that symbol's combined cost stays
unknown. Select an individual portfolio to edit positions, cash, or trades.
Turning the view off returns to the previous individual portfolio and preserves
all accounts. The view does not use one of the six portfolio slots. Today's
chart uses current combined holdings; recorded combined history starts when
the view is enabled and resumes when re-enabled.
The Menu bar page controls display mode, colors, extended hours, width, scrolling
speed, and launch at login.

Ticker details share the same implementation in both products. A fixed quote
header stays visible above Overview, Financials, and Headlines tabs. Chart range
and scroll position survive quote updates. Financials and headlines load on
demand. Parent dropdowns defer row rebuilding while details or text editors are
open, catch up after dismissal, and close child popovers when detached. Invalid
position or cash entries are rejected rather than interpreted as zero. Buys
deduct their full cost from current cash. If a buy exceeds cash, the app shows
the resulting negative balance and lets you cancel or explicitly record the
buy anyway. The shortfall remains in cash and is deducted from portfolio value;
the override never adds a deposit.

## Refresh and energy behavior

Standard mode honors the configured stock interval and market-session schedule.
Optional Ultra-fast mode adds two-second stock polling during market hours and
a free Kraken stream for supported USD crypto, with REST fallback and provider
cooldowns. See [free fast refresh](free-fast-refresh.md). Open ticker details retain their
previous fast quote cadence through the widget's single poller; the last detail
closing restores the ordinary schedule. The research workspace is unchanged.

- The app window observes the ticker's existing quote stream, with no polling
  timer of its own. Updates stop while the window is closed or minimized.
- Details lease fast quotes from the existing poller rather than starting a
  duplicate full-fetch timer. Their own timer updates only the visible overview
  chart, honoring the range's cache lifetime.
- Quote and portfolio-history persistence batch sibling responses over 250 ms;
  pending persistence flushes when the widget stops. Live prices update before
  that persistence work.
- The scrolling ticker rasterizes text when it changes. Core Animation moves two
  cached layers at the previous speed and loop pause. Fitting, detached, hidden,
  zero-speed, and reduced-motion tickers do not animate.
- Barista's existing settings timer skips active text editors and modal dialogs,
  and its rebuild preserves scroll position and follows the resized window width.

These remove redundant work; no battery-life percentage has been measured.

## Verification

Run `swift test` using an Xcode toolchain with XCTest available. The suite includes
native UI tests for clicking a ticker, navigating detail tabs, closing nested
popovers, preserving an app-window draft and table selection, and changing the
live status item through the production dropdown action and dismissal path.
Tests use demo quotes and disable remote detail requests.

Use `./build-app.sh` to compile without creating app copies, and
`./build-app.sh marketbar --install` to update `/Applications/Marketbar.app`.
Installation uses temporary staging that is removed on success or failure;
the app redirects alternate copies to the verified installed app before loading
preferences. For real screen
captures, use `./take-screenshots.sh`. Optional view-rendering previews from UI
tests can be saved with `BARISTA_UI_PREVIEW_DIR=/tmp/barista-previews swift test`;
AppKit layer-backed surfaces may not appear correctly in those bitmap previews.
