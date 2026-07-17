# Cost Rate Table — Maintainer Guide

Companion doc for [`cost-rate-table.json`](cost-rate-table.json). Explains how to keep the
table current, and the reasoning behind two convention choices that are easy to get wrong
when copy-pasting a new row.

## Update procedure

When a PR's Cost Pattern block shows a null or `—` USD cell, or the rendered null-event
Note names an unknown model, use this flow:

1. Open the PR's Cost Pattern Note. When the walker cannot price an event, the Note names
   the exact model(s) responsible (sanitized for safe display), provider-qualified — for example
   `` `claude/some-new-model` `` or `` `copilot/some-new-model` ``.
2. **The printed `{provider}/{model}` string is NOT the JSON key to use.** The lookup key
   the walker actually builds at runtime is `(provider, model)`, resolved from each rate
   entry's `provider` field (defaults to `claude` when absent) and `model` field (defaults
   to the JSON key itself when absent) — see `New-CostRateTableEntry` and
   `Get-CostRateLookupKey` (`cost-attribution.ps1:256-288`). Which JSON shape to add depends
   on the printed provider:
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
though. `Get-EventProvider` (`cost-attribution.ps1:253-272`) only accepts providers listed in
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
