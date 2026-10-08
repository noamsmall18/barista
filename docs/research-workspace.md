# Marketbar research desk

The research desk works with Marketbar and Barista completely closed. Its own
background process serves the browser and runs the same public-data services,
quote refresh, earnings calendar, and portfolio history. It never creates a
menu-bar item, settings window, or application delegate.

When the menu-bar app is also running, both processes record portfolio history
into the same preferences. Each write re-reads the stored history and adds its
own sample on top, so neither process drops the other's points, and a deleted
portfolio's history stays deleted (its id is kept in
`barista.portfolioHistory.forgotten`).

For a Marketbar workspace with no menu-bar app installed:

```sh
./build-research.sh
./install-research.sh
./open-research.sh
```

This builds only `dist/MarketbarResearch.bundle` and installs the headless service
at `~/Library/Application Support/Marketbar/Research/Service.bundle`. The helper
has its own bundle identifier and explicitly reads the existing Marketbar
preferences domain. It is a headless bundle, not a second app. The installer
registers `com.noam.marketbar.research` in your user LaunchAgents, so macOS starts
the service at login and restarts it if it crashes. Both menu-bar apps can be
removed; the research service has its own executable and web assets. Opening the
launcher creates a browser window and reuses the running service. Closing the
browser leaves it available for the next visit.

If you also use a menu-bar app, **Open Research Workspace** in its ticker dropdown
opens the same independent service. `./build-app.sh --install` embeds companions
in the canonical installed apps; a build-only run creates no `.app` copies.
The standalone build and install commands above install only Marketbar research.

The native app allows one running instance per product. Opening another build
copy redirects to the verified `/Applications/Marketbar.app` before loading
settings. Build-only verification creates no app bundles; installation updates
that one app and removes temporary staging. The research service has its own
process and lifetime.

All five workspaces, company lookup, live quotes, price history, SEC financials,
analyst expectations, news, notebooks, evidence, research questions, valuation,
comparisons, and exports use the independent service. Network access and public
provider availability are still required for fresh external data.

Holdings, cash, recorded trades, and the active portfolio use the flavor's saved
app settings; research remains read-only with respect to that ledger. The helper
checks those settings every second and continues monitoring them while the app is
closed. Research annotations and additional companies have their own preferences
key. Both flavors keep separate settings.

## Five workspaces

**Today** is the daily research agenda. It prioritizes reviews due in the Mac's
local date, upcoming earnings, unanswered research questions, and observed price
moves of at least 2%. These are prompts to investigate, not trading signals.
It also brings back the selected thesis and recent saved research.

**Companies** is a split research desk: a searchable universe, a company dossier,
and a working notebook. The dossier has Overview, Financials, The Street,
Valuation lab, and News & dates tabs. The notebook stays alongside the evidence
on wide screens and follows the dossier on narrow screens.

Use **Add company** or the command search's **Research this ticker** button to
investigate an exact equity ticker beyond the portfolio watchlist. Yahoo must
identify it as an equity and return observed price bars. These entries never
create holdings, trades, or menu-bar watchlist items. Up to 100 additional tickers
persist on the Mac. Remove an entry with **Remove** in its company toolbar; saved
research remains on the thesis board and can reopen its dossier.

**Compare** combines the portfolio watchlist and independent research universe.
Select two to four equities to compare observed prices and latest annual reported
business metrics. Each SEC observation carries its own fiscal period, unit, and
filing date. Reporting periods are not artificially synchronized. No missing
value becomes zero, and no currency conversion or automatic metric ranking is
performed. The CSV export retains those period and unit labels.

**Portfolio** contains the financial monitoring tools: live and regular-session
values, allocation, concentration, session contributors, a price-shock explorer,
portfolio history, and recorded trade activity. Research-only companies have no
portfolio value or contribution and never enter these aggregate calculations.

**Theses** shows the research pipeline: Inbox, Researching, Ready to review,
Monitoring, and optionally Archived. Change stages on the cards or in the company
notebook. Search covers symbol, thesis, risks, and catalysts. Saved companies
remain available even when they leave the active portfolio's universe.

## Research workflow

A company notebook contains thesis, risks/invalidation, catalysts, stage,
conviction, and a next review date. Add completable research questions; open
questions appear on Today and counts appear on the board.

The evidence file separates support, challenges, and questions. Keep a headline
or a reported financial observation using its **Keep evidence** action, then
review the observation and source in the capture dialog. Or add a personal
observation with an optional HTTPS source link. Capture is always an explicit
user action; provider content does not automatically become thesis evidence.
Each company can retain 100 evidence items and 100 research questions.

**Export memo** creates a Markdown company memo with reasoning, evidence, open
and completed questions, review metadata, saved valuation assumptions, and
currently loaded reported financial/quote context. **Export all research** on the
thesis board creates a research book including saved companies outside the
current universe. Both exports include unsaved notebook drafts.

## Valuation lab

The lab is an editable annual EPS × terminal P/E model for USD company equities.
Enter a nonnegative EPS basis or explicitly use the first available annual
consensus from Nasdaq. Choose a 1, 2, 3, or 5 year horizon and annual EPS growth
and terminal multiples for bear, base, and bull scenarios. Starter assumptions
are labeled editable placeholders, not recommendations.

For each scenario:

`terminal EPS = basis EPS × (1 + annual growth / 100)^years`

`terminal share price = terminal EPS × terminal P/E`

A sensitivity matrix varies the base growth and multiple. Prices are illustrative
terminal outcomes, not discounted present values or forecasts. Dividends,
dilution, and discounting are excluded. Analyst adjusted EPS can differ from
SEC GAAP EPS. Invalid inputs, crypto, and non-USD quotes do not produce results.
Save the model with **Save assumptions to thesis**. Unsaved model edits survive
company switches in the current page and trigger a close warning; they do not
persist across an app/browser restart until explicitly saved.

## Data and calculation boundaries

The portfolio follows saved settings changes every second. Quotes keep refreshing
in the independent service while the app is closed.
Existing quote cadence/backoff is preserved: equities can poll every 2 seconds
in regular hours; extended hours at least 15 seconds, closed equities 300
seconds, and crypto 10 seconds. These are public feed polls, not exchange streams.
Independent research quotes use the latest observed one-minute price bar and
are labeled **observed bar change** with the bar's timestamp. The selected
research-only ticker refreshes at most once per minute or on explicit Refresh;
failed attempts are throttled too.

Mixed-currency held portfolios withhold aggregate charts, totals, and weights
because Marketbar does not convert FX. Missing prices and cost basis remain
explicit. Capital allocation includes cash; effective positions use the inverse
sum of squared holding weights excluding cash. Shock arithmetic holds cash and
quantities constant and excludes unpriced positions. Historical portfolio values
include holding/cash changes and are not deposit-adjusted investment returns.

Comparison price charts require the same quote currency. Histories are rebased
to each security's first observed close in a shared window without extrapolation.
They exclude dividends. Financial changes compare consecutive reported periods;
percentages are withheld for nonpositive baselines. SEC metrics can have different
period ends. Nasdaq targets are analyst opinions and coverage varies. Company
feeds can fail or be unavailable independently of prices.

## Navigation and visual system

The desk uses warm paper surfaces, a dark green market rail, editorial serif
headings, aligned numeric readouts, and terracotta accents. Wide company desks
use three panes; compact desktops and mobile stack the notebook and turn the
universe into a horizontally scrolling strip. Tables and company tabs scroll
within their own containers on small screens.

Cmd/Ctrl+K opens company search. Option+1–5 switches workspaces. `/` opens the
comparison universe and focuses its filter. Company tabs support Left/Right,
Home, and End; charts support pointer inspection and Left/Right, Home, and End.
Navigation supports browser Back. Visible focus, semantic labels, a skip link,
and reduced-motion preferences are included. Favorites, selected security,
additional research symbols, chart preferences, and compact density persist.

## Storage and request boundary

`marketbar.researchWorkspace.v1` belongs to the selected app flavor's preferences
domain, separate from portfolio and ledger configuration. Existing three-field
notebooks remain compatible. Legacy writes merge without removing evidence,
questions, metadata, or valuation assumptions. Structured input validation checks
field bounds, enums, actual booleans, calendar dates, source links, unique record
identifiers, numeric assumptions, and research ticker syntax before atomic save.

Notebook saves are serialized. A newer edit survives an older save finishing.
Failed drafts are backed up in local storage for the current loopback origin and
included in exports. Reopening research normally reuses the same origin, so failed drafts remain
recoverable after service restarts. Each flavor stores a capability URL in
`~/Library/Application Support/<Flavor>/Research/session.json` with mode 0600,
inside a 0700 directory. A kernel file lock permits only one helper per flavor.
The port and secret are reused across restarts; if another process has claimed
the port, the helper chooses a new port and opens the new URL. Local-storage
failed drafts remain attached to their old origin in that exceptional case.

The only write endpoint is `POST /<session-token>/workspace`. It requires exact
loopback Host and Origin, JSON content type, and a bounded complete body. All
portfolio endpoints remain read-only. Research GET routes accept bounded equity
ticker syntax and use existing public-source services. CSV text cells neutralize
spreadsheet formula prefixes. No external packages, scripts, or fonts are used.

## Verification

```sh
node --test Tests/Web/*.test.cjs
swiftc Barista/Widgets/Finance/ResearchWorkspaceRequest.swift \
  Barista/Widgets/Finance/ResearchWorkspaceDefaults.swift \
  Barista/Widgets/Finance/ResearchWorkspaceStore.swift \
  Tests/ResearchWorkspaceSmoke.swift -o /tmp/research-smoke
/tmp/research-smoke
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test
./build-research.sh
node --test Tests/ResearchWorkspaceIntegration.cjs
./open-research.sh
node Tests/Web/preview-server.cjs
```

The preview at `http://127.0.0.1:4178/` visibly identifies sample data. It uses
illustrative quotes and research with an in-memory workspace; it never reads app
preferences or contacts financial providers. Native smoke checks run shipped
request and storage code with an in-memory UserDefaults substitute. They
supplement XCTest. Use the installed Xcode toolchain for XCTest; Command Line
Tools alone may not contain that framework.

The standalone integration check uses a temporary helper bundle and preferences
domain. It verifies real HTTP assets, same-origin writes, full notebook/model
persistence, config changes from another process, multiple launchers, service
restart with the same URL, and all five provider routes. Set
`RESEARCH_REQUIRE_LIVE=1` to require observed provider data as well as endpoint
availability. Run with `RESEARCH_PRODUCT=Barista` to check that flavor too.

The menu-bar research action launches the separate helper instead of hosting the
server inside the widget. Full-screen/Spaces interaction should be checked on the actual macOS
desktop when changing those native paths.
