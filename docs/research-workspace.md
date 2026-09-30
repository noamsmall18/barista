# Portfolio research workspace

Marketbar answers a quick question in the menu bar: what is happening to the
portfolio right now? The browser companion expands that into three questions:
what moved, where is the exposure, and what should be investigated next?

The app is the portfolio's source of truth. Opening **Open Research Workspace**
in the ticker dropdown starts a loopback-only server with a random session URL.
The page follows the same selected portfolio, holdings, ledger, quotes, and cash.
Switch portfolios or edit holdings in the app and the browser follows automatically.

## Visual direction

Graphite surfaces, champagne accents, readable numerical alignment, and restrained
positive/negative colors. Desktop uses a persistent navigation rail; narrow layouts
use compact top navigation and stacked panels. Charts support pointer inspection
and arrow-key inspection. Reduced-motion preferences are respected.

## Information

- Live value, regular-session P/L, extended-hours P/L, cost-basis returns and cash.
- Portfolio history with an optional rebased SPY comparison.
- Exposure weights, session contributors and a searchable holdings/watchlist table.
- Per-security price history, valuation/price statistics and research source links.
- SEC annual/quarterly financials and ratios, upcoming earnings, Yahoo headlines.
- Recent recorded trades from the existing portfolio ledger.

The page syncs with the app every second while visible. Equities poll as fast as
2 seconds during regular trading while the page is open; extended hours remain
at least 15 seconds, closed equities 300 seconds, and crypto 10 seconds. Slow GET
requests are coalesced, and provider backoff is retained. This is polling, not an
exchange streaming feed. Received times and stale/failure states remain visible.

Missing holdings are explicitly named. Missing cost basis is not treated as zero.
Aggregate values and charts are withheld when held quote currencies differ from
USD because the app does not perform FX conversion. Historical portfolio values
include cash and position changes, and are not time-weighted investment returns.

## Native dropdown

The dropdown uses a nonactivating NSPanel with all-Spaces and full-screen support.
It stays visible when another app owns focus, and closes on outside clicks, Escape,
or a Space change. Portfolio settings and storage are unchanged.

## Validation

- `./build-app.sh marketbar` builds and signs the app bundle.
- `node --test Tests/Web/dashboard.test.cjs` checks rendering, escaping, empty
  portfolios, mixed-currency handling, and stale/backoff messaging.
- `swift test` includes session request authorization and panel placement tests.
  On the current machine XCTest is unavailable in Command Line Tools; the full
  Xcode toolchain requires administrator license acceptance.
- Browser checks cover desktop/mobile overflow, chart keyboard inspection, and
  console errors. Native menu-bar interaction must also be checked on the actual
  macOS desktop and full-screen Spaces; the current automation cannot expose the
  menu-bar item for that click test.
