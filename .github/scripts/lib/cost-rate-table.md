# Cost Rate Table — Maintainer Guide

Companion doc for [`cost-rate-table.json`](cost-rate-table.json). Explains how to keep the
table current, and the reasoning behind two convention choices that are easy to get wrong
when copy-pasting a new row.

## Update procedure

When a PR's Cost Pattern block shows a null or `—` USD cell, or the rendered null-event
Note names an unknown model, use this flow. One entry condition worth recognizing on
sight (issue #905): the **total** row can show `—` while individual **per-port** rows
still show real numbers. This happens when one event in the session carries an
unrecognized model — the totals rollup one-way-latches `totals.cost_estimate_usd` to
null the moment it sees that event — while other, priced events in the same session
still contribute non-null numbers to their own port buckets. A blank total next to
populated port rows is not a rendering bug; it means **at least one** unresolvable
model showed up somewhere in the session — the latch fires on the first such event and
stays latched, so a session with two or more unresolvable models produces the identical
blank total as a session with exactly one. And port rows still show numbers — but the
port that contained the unresolved-model event is itself understated by that event's
cost, so summing the port column does not recover the true total: `Add-NullCostEventToBucket`
(`cost-attribution.ps1:470`) only nulls a port bucket if it is still exactly `0.0` at the
moment the unresolved event lands; a bucket that already accumulated priced cost keeps
that prior (now understated) number instead of going null. Concretely, a port with a
priced event ($5.0175 real) followed by one unresolved-model event on 500k+ tokens still
shows `$0.0175` — a ~287x understatement — with no visual signal that it's wrong.

When `totals.cost_estimate_usd` latches to null, the run also drops out of downstream
cost tracking with no explicit flag: `cost-baseline-harvest.ps1:632` skips any entry whose
`totals.cost_estimate_usd` is null when building the rolling baseline sample, so the PR is
silently evicted from the rolling baseline rather than recorded at $0; and
`cost-anomaly.ps1:351` skips the total-cost metric for that run the same way, with no
"could not evaluate" record. Below three baseline samples, the median comparison silently
disappears from the PR body. Per maintainer disposition, this is accepted as a documented
limitation rather than a code fix in this round: the schema's `excluded_from_rolling_baseline`
field does **not** currently reflect this specific exclusion reason — it is computed from
session-completeness signals only, unrelated to cost-attribution — so a latched-null PR may
show `excluded_from_rolling_baseline: false` while still being dropped from the baseline
sample. Wiring that field to also reflect a null-cost exclusion is out of scope here.

1. Open the PR's Cost Pattern Note. When the walker cannot price an event, the Note names
   the exact model(s) responsible (sanitized for safe display), provider-qualified — for example
   `` `claude/some-new-model` `` or `` `copilot/some-new-model` ``.
2. **The printed `{provider}/{model}` string is NOT the JSON key to use.** The lookup key
   the walker actually builds at runtime is `(provider, model)`, resolved from each rate
   entry's `provider` field (defaults to `claude` when absent) and `model` field (defaults
   to the JSON key itself when absent) — see `Get-CostRateLookupKey`
   (`cost-attribution.ps1:295`) and `New-CostRateTableEntry` (`cost-attribution.ps1:306`).
   Which JSON shape to add depends on the printed provider:
   - **`claude/{model}`** (the common case): key the new row by the **bare model name only**
     — drop the `claude/` prefix. Do not add explicit `model`/`provider` fields; both default
     correctly (`provider` -> `claude`, `model` -> the JSON key). Compare the existing
     `claude-sonnet-5` / `claude-opus-4-7` rows in `cost-rate-table.json`, which follow this
     exact shape. Keying the row by the full `claude/{model}` string instead is the bug this
     procedure previously described — it produces a lookup key of `claude\nclaude/{model}`,
     which the walker's `claude\n{model}` never matches, so the row silently never resolves.
   - **`{other-provider}/{model}`** (e.g. `copilot/{model}`): use a synthetic JSON key (see
     the `copilot-*` rows in `cost-rate-table.json`, e.g. `copilot-claude-sonnet-4-6`) plus
     explicit `model` and `provider` fields carrying the exact values from the printed
     string. The provider prefix is load-bearing here because the same bare model name can
     legitimately exist under two different providers with two different rate rows (see
     `copilot-claude-sonnet-4-6` vs. the Claude-native `claude-sonnet-4-6` entry — same
     model string, different provider, different rates).
3. Add a new entry to `cost-rate-table.json` under `rates`, keyed as determined above, with
   all four rate fields populated:
   - `input_per_mtok`
   - `output_per_mtok`
   - `cache_creation_per_mtok`
   - `cache_read_per_mtok`

   All four fields must be non-null numbers. `Get-CostEstimateFromUsage` returns a null cost
   estimate if any one of the four is null — a partially-filled row reproduces the same
   null-USD symptom this table exists to prevent.
4. Refresh the top-level `rates_as_of` date to the day you verified the rates.
5. Re-run the Pester suite (`Invoke-Pester .github/scripts/Tests/cost-rate-table.Tests.ps1`
   at minimum; the full suite listed in the plan's Verification section for anything
   touching consumer code) to confirm the new row parses and resolves.

This is intentionally a copy-paste fix with no source reading required beyond picking the
right shape from step 2 above: the Note already names the model, and step 2 tells you which
of the two JSON shapes to use.

## Cache-write convention

`cache_creation_per_mtok` is set to **2× the input rate** — the published 1-hour cache-write
rate — rather than the 1.25× rate that applies to 5-minute cache writes. This project's
sessions are dominated by cache writes using a 1-hour time to live (TTL), so the 1-hour rate
is the representative default for every entry in this table.

**Falsifier**: if 5-minute cache writes become a significant share of usage, this
single-rate convention understates or overstates cost depending on the real TTL mix. At
that point, split the schema into per-TTL cache-write fields (e.g.
`cache_creation_per_mtok_1h` / `cache_creation_per_mtok_5m`) and have the walker read the
per-TTL breakdown from the usage event instead of applying one aggregate rate.

## Standard-vs-introductory rate choice

`claude-sonnet-5` is priced at its **standard** rate (3.00 / 15.00 input/output per million
tokens (MTok)), not the temporary introductory rate. The introductory rate silently expires on
**2026-08-31**; pricing the table at that rate would re-stale it on that date with no
signal to any maintainer that a change occurred. Pricing at the standard rate keeps the
table correct on both sides of the expiry with zero maintenance.

If you are reconciling this table against an actual invoice before 2026-08-31, be aware the
introductory discount exists — invoiced amounts may run lower than this table's estimate
until the discount expires.

**Fast-mode falsifier** (same falsifier class as the cache-write TTL note above): Opus 5
fast mode bills at $10.00 / $50.00 input/output per MTok — double the $5.00 / $25.00
standard rate documented for `claude-opus-5` in this table — under the **same** model
string. The vendor's fast-mode table lists Claude Opus 5 and Claude Opus 4.8 together at
this same $10/$50 rate, so `claude-opus-4-8` (identical $5.00/$25.00/$10.00/$0.50 standard
rates in this table) carries the identical exposure and is named alongside `claude-opus-5`
here. The vendor source also states caching multipliers apply on top of fast-mode pricing,
not in place of it: under fast mode, `cache_creation_per_mtok` is $20.00 (not $10.00) and
`cache_read_per_mtok` is $1.00 (not $0.50) for both models — both also exactly 2x their
standard-rate value. This matters more than the input/output columns suggest: this repo's
own reference fixture (the `#813`-shaped fixture in `cost-attribution.Tests.ps1`) is
cache-read-dominated (tens of thousands of cache-read tokens against ~200 input tokens), so
for a session shaped like that fixture, the un-quantified cache columns are where nearly all
real spend actually lives. This table has no fast-mode-vs-standard distinction, so a session
that ran in fast mode prices at roughly half its actual billed rate with no signal that the
discount (or in this case, the premium) applied. If fast mode becomes a meaningful share of
usage, split the schema the same way the TTL falsifier proposes: add a fast-mode rate
variant and have the walker read which mode applied from the usage event, rather than
pricing every `claude-opus-5` / `claude-opus-4-8` event at the standard rate.

## Provider-extension procedure

The rate-table *schema* is already provider-aware: any rate entry may carry a `provider`
field, which defaults to `claude` when absent. Adding a rate row for a new provider's model
(for example, a future GPT/Codex entry) requires no *schema* change — it is just a new keyed
entry with its own four rate fields, following the pattern already used by the `copilot-*`
entries:

```json
"some-provider-model-id": {
  "model": "model-id-as-reported-by-provider",
  "provider": "some-provider",
  "input_per_mtok": 0.00,
  "output_per_mtok": 0.00,
  "cache_creation_per_mtok": 0.00,
  "cache_read_per_mtok": 0.00,
  "rate_source_url": "https://...",
  "rate_note": "optional context, e.g. why a rate is null"
}
```

Adding the rate row alone is not enough to make that provider's events actually resolve,
though. `Get-EventProvider` (`cost-attribution.ps1:219`) only accepts providers listed in
`$script:CostAttributionKnownEventProviders` (currently `@('claude', 'copilot')`, defined at
`cost-attribution.ps1:54`); an event whose provider is not on that allowlist falls through to
the `claude` default before the `(provider, model)` lookup ever runs, so a rate row for an
unrecognized provider would never resolve no matter how it is keyed. Making a genuinely new
provider's events resolve requires two real code changes in addition to the rate row:

1. An event-collection path that populates the event's `provider` field for that provider.
2. Adding the provider name to `$script:CostAttributionKnownEventProviders` in
   `cost-attribution.ps1`.

The JSON object key only has to be unique within `rates` — it is not itself the lookup key
the walker matches against. The actual runtime lookup key is built from the `provider` and
`model` fields (defaulting to `claude` and the JSON key respectively when absent), via
`Get-CostRateLookupKey`. For a `claude`-provider row with no explicit `model`/`provider`
fields, the JSON key and the effective model identifier happen to be the same string —
that is a consequence of the defaults, not a sign that the JSON key is read directly as the
lookup key. Any row that sets an explicit `provider` (as every `copilot-*` row does) must
also set `model` explicitly, since the lookup is computed from those two fields, not from
the map key text.

## Historical-repricing limitation

Re-walking an old session — for a baseline harvest, an attribution repair, or any other
retroactive re-render — prices that session at **current** rates, not the rates that were
live when the session actually ran. There is no point-in-time rate versioning in this
table; `rates_as_of` is a single global staleness signal, not a history.

This is a deliberate simplification. The `claude-opus-4-7` correction made by this issue is
a one-time fix of a prior copy error (the row was entered at 3× the correct rate), not an
in-horizon price change — re-walking old sessions with the corrected rate is the intended
outcome, since the old rate was simply wrong.

**Falsifier**: if a genuine in-horizon rate change occurs (the provider actually changes
published pricing while sessions from both before and after the change need accurate
historical costing), this simplification breaks — re-walks would misprice sessions from
before the change. At that point, add effective-date versioning to the rate table (e.g. an
array of dated rate entries per model, with the walker selecting the entry whose date range
covers the session) rather than continuing to price every re-walk at whatever the table
currently holds.
