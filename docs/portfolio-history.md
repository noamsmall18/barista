# Portfolio history

History uses trading observations rather than elapsed wall-clock time. The
native dropdown, Marketbar window and research chart use the same presentation.
Equity refreshes during weekends and scheduled exchange holidays are excluded;
pre-market and after-hours observations remain. The calendar uses New York time,
including daylight saving and early closes. Sunday-night/overnight observations
require a fresh timestamped provider bar; receiving a cached quote again is not
evidence of overnight trading. Portfolios holding crypto retain continuous
observations.

Scheduled sessions follow the [NYSE calendar](https://www.nyse.com/markets/hours-calendars).
The optional overnight window supports [Sunday evening trading](https://robinhood.com/us/en/support/articles/24-hour-market/)
when the data feed actually supplies it. This does not add an overnight quote
provider or coverage of every international exchange or unscheduled closure.

## Default view and Raw

The default historical view shows market movement, rebased to the latest
recorded portfolio total. New observations store the quantities, cash and held
prices used to calculate the value. When holdings or cash change, the previous
holdings are valued at the same new prices; the difference is recorded as a
flow, separate from market movement. A linked return chain removes those flows
from the chart. This is an estimate based on observation times, not a broker's
audited time-weighted return. Existing points without composition metadata keep
their original movements; old edits cannot reliably be inferred after the fact.

Quantity/cash edits must remain stable for two minutes before entering history.
A typo corrected during that interval never becomes a stored observation. Cost
basis changes do not change portfolio value. Invalid numeric input is rejected
instead of converting it to a zero position or cash balance. Snapshot recording
also requires every held position to have a finite positive, recent USD quote;
partial loading, stale caches and incomparable currencies cannot create losses.

A conservative display filter hides an isolated spike/dip spanning one or two
observations only when two observations on each side confirm a return to a
closely matching level. It compares values rather than elapsed time, so the same
rule applies to intraday, hourly and daily history, including across sessions.
The excursion must exceed $1 and 0.25% of the surrounding value; variation within
the surrounding readings and within the excursion must be less than 15% of its
size. Endpoints, unconfirmed recoveries, sustained moves (three or more readings),
and known flows or composition changes remain visible.
Price history alone cannot distinguish every real flash move from a bad print.
**Raw** exposes those observations and actual recorded totals, including edits.
Filtering and flow adjustment never rewrite the original stored values.

The 1D view prefers recorded observations in the latest session, so a later
holding edit cannot reprice the morning's chart. Until two recorded observations
exist, it falls back to a clearly labeled current-holdings estimate using actual
provider bar times. It does not invent minute bars across closed periods. Raw is
available for recorded history ranges (1W and longer); the native hover readout
can also show the original total for adjusted 1D observations. Benchmarks are
withheld outside their observed timestamp coverage.

## Storage and interaction

Sampling uses fixed ten-minute clock buckets so frequent updates cannot keep
moving the same sample forever. Recent observations retain full detail; older
points are compacted hourly, then daily. Daily history is no longer discarded at
120 days, so 6M and All can continue accumulating. This cannot recover history
that an earlier version already discarded. Flow observations and their immediate
predecessors survive compaction so returns remain correct.

The native app and independent research service reload the latest store while
holding a per-product file lock before each mutation. Reads also refresh from the
shared store. One process cannot overwrite newer observations from the other
using an old in-memory snapshot. Product preferences remain separate.

Hover shows exchange date/time and the adjusted value; when it differs, the
native readout also shows the recorded total. Native charts support Left/Right,
Home/End and Escape. Web pointer/keyboard inspection uses the same compressed
coordinates as the drawn portfolio path. Actual timestamps remain available.

## Verification

Run Swift checks with `BARISTA_TEST_MODE=1` and the installed Xcode toolchain;
all history fixtures use in-memory preferences and disposable holdings. Tests
cover weekends, holidays, early closes, DST, crypto, overnight samples, frequent
refreshes, daily and cross-session isolated dips/spikes, repeated bad readings,
cadence independence, sustained losses, flow adjustment, typo reversal,
missing/stale quotes, removed symbols, shared writers, retention, keyboard
inspection and actual dropdown/window Raw controls. Web tests exercise rendered
paths across a weekend and restoration of the recorded values.
