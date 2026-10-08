# Free fast refresh

Enable **Ultra-fast** in the market dropdown's Refresh section or the native
Marketbar portfolio window. The **Menu bar → Data & refresh** page also exposes
the setting. It is saved separately for Barista and Marketbar; existing settings
default to Standard mode.

## What gets faster

Equities use Yahoo Finance's existing chart source. Ultra-fast requests a fresh
quote every two seconds during regular trading and every six seconds during
extended hours. Closed markets slow to five minutes. Faster requests cannot make
the upstream data newer: this is best-effort polling, not an exchange stock feed
or a guarantee of real-time prices.

Supported USD crypto pairs use Kraken's public WebSocket v2 ticker, which pushes
updates on trades. No account, API key, subscription, or added dependency is
needed. Kraken prices are from that exchange and can differ from CoinGecko's
aggregate prices. Unsupported coins and non-USD currencies stay on REST.

The stream mapping includes BTC, ETH, SOL, ADA, DOGE, XRP, DOT, AVAX, LINK, LTC,
UNI, ATOM, XLM, and SUI. Availability can change at the provider. A disconnected
or quiet stream falls back to the existing REST source; rate limits can still
delay those fallback quotes.

Standard mode follows the configured stock interval and reduces polling outside
market hours. Crypto REST requests are spaced at least 15 seconds apart. A pair
with no stream update for 60 seconds becomes eligible for REST fallback.
Requests for the same quote share work;
changing modes does not create another stock polling loop.

Provider rate-limit responses trigger exponential cooldown, including the
provider's `Retry-After` delay. Pressing Refresh does not bypass an active
cooldown. Turning Ultra-fast off closes the stream and restores Standard mode.
Faster polling uses more network traffic and energy.

## Native window improvements

The portfolio view now includes market ETF quotes, cost-based returns, allocation
context, searchable/sortable watchlists, row sparklines, and position values.
Missing data is shown explicitly. Editing a watchlist draft and selecting a row
survive quote updates. Aggregate return/allocation figures are withheld when
currencies cannot be combined without conversion.

## Cash-funded trades

Recording a Buy spends its quantity × price from the active portfolio's current
USD cash. A Sell credits its proceeds. A purchase that exceeds available cash is
rejected without changing holdings, cash, or the watchlist. The position dialog
shows the cost and cash remaining before saving.

Set remains a manual correction for positions already owned; it does not record
a purchase or transfer cash. Old trades load with their existing saved cash,
without a retroactive charge. New trades save their cash effect, so restoring the
portfolio does not apply it twice. Deleting a funded trade reverses its cash
effect, unless doing so would orphan a later sale or undo money already spent.
Foreign-currency trades require conversion and are rejected until that is
supported.

## Provider references

- [Kraken public ticker schema](https://docs.kraken.com/exchange/api-reference/spot-websocket-v2/ticker)
  documents trade-driven ticker updates, snapshots, and subscription responses.
- [Kraken WebSocket FAQ](https://support.kraken.com/articles/360022326871-kraken-websocket-api-frequently-asked-questions)
  describes the public market data feeds.
- [CoinGecko public API limits](https://support.coingecko.com/hc/en-us/articles/4538771776153-What-is-the-rate-limit-for-CoinGecko-API-public-plan)
  explains that unauthenticated access can be limited to 5–15 requests a minute.

## Verification

The Swift suite covers refresh setting migration, schedule rules, stream parsing,
watchlist ordering, HTTP request coalescing and cache bypass, provider cooldown
headers, and native controls. Existing tests exercise live status-item changes
made through the dropdown and dismissal path. Web research tests remain in
`Tests/Web/`.
