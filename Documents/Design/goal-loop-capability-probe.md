# Goal-loop capability probe (#874 AC5)

Empirical probe of the seven capability unknowns (legs a–g) that gate the #874
goal-run harness's headless and budget arms, per 874-D9. Sibling to — and
deliberately modelled on — [goal-loop-platform-spike.md](goal-loop-platform-spike.md)
(#871), whose evidence-label taxonomy and "probes not completed" discipline this
document reuses.

## Platform build and limits

All findings below are against **`claude 2.1.150` (Claude Code)**, captured
2026-07-21. `observed` claims are **n=1** live observations against that build
unless a repeat count is stated. The version travels with the findings because
most surfaces described here are undocumented implementation detail that can
change without notice — see the [874-D12 drift-guard enumeration](#874-d12-platform-internal-dependency-enumeration).

Where a run happened matters and is recorded per leg: legs (a)–(d) and (f) ran
**headless** (`claude -p`) from `C:\Users\Micah`; leg (g) ran **interactively in
the Claude Code desktop app** (the owner's normal use case), which is a different
surface and is labelled as such.

## Evidence labels

Reused verbatim from the #871 spike so the two documents can be read together:

- `observed` — behaviour seen in a live run, with an artifact backing it.
- `documented` — read from published CLI help or vendor documentation. A vendor
  contract, but *not* a behaviour this probe watched happen.
- `static` — read out of the installed binary's strings.
- `inferred` — a conclusion drawn from the above, flagged as reasoning.

A leg that could not be run is recorded as an **explicit gap** with its reason,
never silently omitted.

## Results at a glance

| Leg | Question | Label | Outcome |
| --- | --- | --- | --- |
| (a) | headless launch | `observed` | Works, with three hard requirements (below) |
| (b) | terminal-outcome readability | `observed` (2/3 paths) / **partial gap** | Terminal `result` event parses; `judged-impossible` never produced live |
| (c) | `--max-budget-usd` breach | `observed` | **Report path** — structured terminal event, not silent kill. **Also surfaced a silent-zero `usage` defect — see [leg (c)](#leg-c--max-budget-usd-breach-behavior)** |
| (d) | `/goal` registration | `observed` | `goal` present in `system/init` `slash_commands` |
| (e) | supervisor force-halt | **explicit gap** | Not run — see [gaps](#explicit-gaps) |
| (f) | transcript usage-reader | `observed` (parse) / **partial gap** (live) | Reader validated on real data; live pre-termination poll not exercised |
| (g) | clean release | `observed` | **No system-rendered completion status line** |

**Four legs fully observed (a, c, d, g), two partial (b, f), one explicit gap (e).**

> **Most consequential finding**: the terminal `result` event's `usage` object
> reported **all zeros on a run that genuinely consumed 648 output tokens**
> (leg (c)). Any consumer trusting `result.usage` for token accounting will
> silently under-count. See [leg (c)](#leg-c--max-budget-usd-breach-behavior).

---

## Leg (a) — headless launch

**`observed`.** A headless invocation completed successfully and emitted a
well-formed terminal `result` event with `is_error: false`,
`total_cost_usd: 0.03742155`, `num_turns: 1`, and a `result` string closing with
the instructed `<goal-status>satisfied</goal-status>` tag. Artifact:
`leg-a-print.jsonl` (20210 bytes), empty stderr, exit 0.

Reaching that success required three discoveries, each seen as a distinct failing
run before the working invocation.

> **Artifact-retention caveat**: each probe run redirected over the *same* capture
> filenames, so only the final successful capture survives on disk. The three
> failure modes below were directly observed at the time, but their captures were
> **not retained** and are therefore **not independently re-verifiable** — they do
> not meet this document's own "`observed` … with an artifact backing it" bar as
> strictly as legs (a)-success, (c), (d), and (g) do. Treat them as reliable
> operational guidance, not as re-checkable evidence.

1. **`--verbose` is mandatory.** `--print` combined with
   `--output-format stream-json` is rejected outright without it:
   `Error: When using --print, --output-format=stream-json requires --verbose`.
   Exit 1, zero-byte capture. This confirms as `observed` what the run-book had
   only flagged as a low-confidence possibility.
2. **`--model` must be pinned.** An unpinned run inherited the ambient session's
   model (`fable`) and returned HTTP 404: *"There's an issue with the selected
   model (fable). It may not exist or you may not have access to it."* The
   headless arm cannot rely on the default. `--model sonnet` resolved to
   `claude-sonnet-4-6` on this build.
3. **The credential must reach the process as an environment variable.** A token
   present in an out-of-repo file but not exported produced HTTP 401
   (*"OAuth access token has expired"*). Exporting it to
   `CLAUDE_CODE_OAUTH_TOKEN` cleared the auth barrier.

The working invocation:

```powershell
$env:CLAUDE_CODE_OAUTH_TOKEN = (Get-Content -Raw "$HOME/.goal-probe-credentials/claude-oauth-token.txt").Trim()
claude -p "<goal text>" --output-format stream-json --print --verbose --model sonnet > leg-a-print.jsonl 2> leg-a-print.stderr.log
```

**Capture encoding note (`observed`)**: PowerShell's `>` redirect writes UTF-16LE
with a BOM on Windows. `Get-Content` auto-detects the BOM, so the instruments
parse these captures correctly — but any consumer using a byte-level or
UTF-8-assuming reader would see mojibake. Recorded because the harness will
capture headless output the same way.

**Credential-isolation caveat (`inferred`)**: the successful run used a token
generated by `claude setup-token` and exported explicitly, so the env-var channel
is `observed`. However, this probe did **not** independently prove the ambient
session could not also have supplied credentials — the isolation of the probe
token from ambient auth is not separately established.

## Leg (b) — terminal-outcome readability

**`observed`.** `Get-GoalProbeStreamJsonResult` (instrument I1) parsed genuine
emitted terminal events — not hand-written fixtures — across three real runs:

| Run | `Outcome` | `Subtype` | `IsError` | `TotalCostUsd` | `NumTurns` |
| --- | --- | --- | --- | --- | --- |
| successful goal | `satisfied` | `success` | `False` | 0.03742155 | 1 |
| expired-token 401 | `stopped` | `success` | `True` | 0 | 1 |
| budget breach | `stopped` | `error_max_budget_usd` | `True` | 0.0335877 | 1 |

Both `TotalCostUsd` and `NumTurns` were populated (non-`$null`) from a genuine
run's own emitted event, meeting leg (b)'s `observed` bar.

**Partial gap**: the `judged-impossible` discriminator path was **not** exercised
on live data — only `satisfied` and `stopped` were. That path remains
fixture-tested only.

**Note on the outcome discriminator (`observed`)**: I1's coarse `Outcome` value
collapses every error to `stopped`, but the `Subtype` field preserves the
specific vendor reason (`error_max_budget_usd` vs `success`), so a consumer can
distinguish a budget-breach stop from any other stop. The
`satisfied`/`judged-impossible` classification depends on a `<goal-status>` tag
convention this probe *instructed* the agent to emit; it is a probe-stage
assumption, **not** a vendor contract, and the harness must not treat it as one.

## Leg (c) — `--max-budget-usd` breach behavior

**`observed` — the report path.** Leg (c)'s question was *which* of two behaviours
occurs on breach; the answer is (i), the reporting path. The CLI emitted a
structured terminal event:

```
type: result
subtype: error_max_budget_usd
is_error: True
total_cost_usd: 0.0335877
num_turns: 1
stop_reason: end_turn
```

Exit code **0**, empty stderr. Artifact: `leg-c.jsonl` (27162 bytes).

This is a materially favourable result for the harness: the vendor's own budget
flag surfaces breaches as a parseable, uniquely-subtyped terminal event rather
than silently killing the process.

The event's `errors` field echoes the configured cap back:
`"Reached maximum budget ($0.01)"`.

**Overshoot (`observed`)**: the run spent **$0.0335877 against a $0.01 cap** —
roughly 3.4× the ceiling. Any harness delegating budget enforcement to this flag
must tolerate overshoot proportional to a single turn's cost. This bears directly
on the #848 D9 sub-ceiling question.

**Enforcement timing (`inferred`)**: the overshoot is consistent with enforcement
being evaluated at the **turn boundary**, after the turn that exceeded the cap,
rather than pre-emptively. Nothing in the artifact shows evaluation timing
directly — this is a mechanism conclusion drawn from a single data point (n=1,
one cap value, one model), not an observation.

### Silent-zero `usage` on the breach path (`observed`) — most consequential finding

The same terminal event reports **mutually contradictory** token accounting:

| Field | Value |
| --- | --- |
| `total_cost_usd` | `0.0335877` |
| `errors` | `"Reached maximum budget ($0.01)"` |
| `usage` | `input_tokens 0, output_tokens 0, cache_creation_input_tokens 0, cache_read_input_tokens 0`, `iterations: []` |
| `modelUsage["claude-sonnet-4-6"]` | `inputTokens 3, outputTokens 648, cacheReadInputTokens 18779, cacheCreationInputTokens 4860, costUSD 0.0335877` |

Real money was spent and **648 output tokens were genuinely consumed**, yet the
`usage` object reports **all four token counts as zero** with an empty
`iterations[]`. `modelUsage` and `total_cost_usd` carry the truth; `usage` does
not.

**Why this matters more than any other finding here**: 874-D5 designates the
platform `result` event as Arm H's end-of-run token accounting source. A harness
reading `result.usage` would record **zero tokens consumed on every budget
breach** — silently, with no error, on precisely the path the budget arm exists
to police. This is the **#873 silent-zero defect class reproduced in live vendor
output**, and it is not a hypothesis: it is in the retained `leg-c.jsonl`.

**Consequence for the harness**: token accounting MUST read `modelUsage` (or
`total_cost_usd`), **never** `result.usage` alone. Any reader that treats a
well-formed all-zero `usage` object as a truthful zero is wrong on this path.

**Correction this forces elsewhere in this document**: leg (f)'s reader
correctly *classified* an all-zero usage object as `usage-present-zero`. That
classification is the right answer to "is this object well-formed and zero?" —
but it must not be read as "zero tokens were truly consumed." The truthfulness
of a vendor zero is **not established by shape validation**, and this probe now
has a concrete counter-example.

## Leg (d) — goal registration in spawned sessions

**`observed`.** The `system/init` event of the successful leg-(a) capture carries
a `slash_commands` array of 96 entries which **includes `goal`**. Goal
registration in a headless-spawned session is therefore confirmed directly from
the session's own emitted init event.

As the run-book (`.github/scripts/README-goal-probe.md`) predicted, this leg was
not gated by the leg-(a) cascade — `system.init` is emitted before any auth-gated
turn resolves, and `goal` was visible in the 404 and 401 captures as well. (Not
the `--verbose`-rejection run, which produced a zero-byte capture containing no
events at all.)

## Leg (e) — supervisor-side force-halt

**Explicit gap — not run.** See [gaps](#explicit-gaps) for the reason and
consequence. `Test-GoalProbeForceHaltWin`'s win/loss logic remains Pester-tested
but has **never been exercised against a live Stop-hook-versus-evaluator race**,
and the `goal-probe-forcehalt-hook.ps1` stub's block-decision contract has never
been verified live.

**Containment correction (`documented`)**: during the review that preceded this
probe, the claim that the Stop-hook fragment is scoped via a `matcher` field was
found false. Claude Code's `Stop` event does not support matchers — the field is
silently ignored and the hook fires on every Stop within its registration scope.
The only real containment is worktree-local `.claude/settings.json` placement.
This is `documented` (from the vendor hooks reference), not `observed`.

## Leg (f) — transcript usage-reader

**`observed` for parsing; partial gap for the live read.**

`Get-GoalProbeLiveUsageReading` (instrument I2) was run against real captures:

| Input | `State` | `LastTurnUsage` | `ReadLatencyMs` |
| --- | --- | --- | --- |
| 401 run (all-zero usage, all four keys present; **truthfulness of the zeros not established**) | `usage-present-zero` | all zeros | — |
| successful run | `usage-present-nonzero` | input 3, output 1, cache_creation 8673, cache_read 14946 | ~2.3 (single sample) |

The first row matters, but read it precisely: the usage object was well-formed
with all four canonical token keys present and set to zero, and the reader
correctly reported `usage-present-zero` rather than routing to the wrong-shape
`usage-unavailable` branch. The **shape** discrimination (well-formed-zero versus
absent/wrong-shape — the #873 defect class) is validated against **real vendor
output**, not only fixtures.

**What that row does *not* establish**: that the zeros were *truthful*. Leg (c)
produced a direct counter-example — an all-zero `usage` object on a run that
genuinely consumed 648 output tokens. Shape validation cannot distinguish a
truthful zero from a vendor-emitted false zero, and no consumer should treat
`usage-present-zero` as proof that nothing was consumed.

**Latency caveat**: `~2.3 ms` is a **single unrepeated sample**; a re-run measured
4.24 ms (1.8×). Do not anchor a latency budget on it — and note these are
post-hoc file reads, not live-poll latencies (below).

**Partial gap**: these are **completed stream-json output captures**, not live,
mid-write session transcripts under `~/.claude/projects/`. Leg (f)'s actual
question — whether a hook can read cumulative usage from a *live, pre-termination*
transcript and at what latency — is **not answered**. The latency figures above
are post-hoc file reads and must not be read as live-poll latencies.

**Per-event versus aggregate discrepancy (`observed`)**: the last `assistant`
event reported `output: 1` while the terminal `result` event's aggregate reported
`output_tokens: 27` for the same run. A consumer reading mid-stream per-event
usage will not see the same totals the terminal event reports. This is why I2's
field is named `LastTurnUsage` and not `CumulativeUsage`.

## Leg (g) — clean release

**`observed`.** Run **interactively in the Claude Code desktop app** (Sonnet 5,
"Auto" mode) rather than the CLI, because that is the owner's normal use case —
so this observation covers the app surface specifically.

Against a genuinely satisfiable predicate (write `haiku.txt`, read it back,
confirm) — deliberately **not** the #871 spike's falsifier — the three required
records are:

1. **Condition flipped true**: turn 1. The agent wrote the file, read it back, and
   confirmed, all within a single assistant turn.
2. **Loop terminated**: turn 1. No further continuation occurred.
3. **What rendered at termination**: **no system-rendered completion status line.**
   The text "Goal complete." was the *agent's own prose*, not a harness render.
   After it, a single unlabeled glyph appeared, then the input placeholder simply
   reverted to its default. No completion banner, no summary, no turn count, no
   cost line.

**This resolves the #871 spike's explicit "clean release was never observed" open
item.** Release happens, and it happens silently.

**Design consequence**: the harness **cannot** key release detection on any
rendered UI signal, because there is none. This independently confirms 874-D11's
decision to detect release via a typed terminal run-log entry.

**Caveats, recorded rather than smoothed over:**

- The goal was satisfied on the **first** turn, so what was observed is clean
  release from a single-turn goal — **not** release after multiple continuations.
  A long-running loop's release path may differ and was not exercised.
- The unlabeled glyph rendered after the final turn was not identified. It is
  recorded as "a glyph with no accompanying text or status", not asserted to be
  meaningless.

**Containment (`observed`)**: the product checkout's `HEAD` (`5d96db9`) and
`git status --porcelain` fingerprint (`e3b0c44298fc`, 0 lines) were **identical
before and after** the run. The scratch directory contained only the goal's own
`haiku.txt` plus a `.gitignore` written by the plugin's own
`Ensure-ScratchGitignore` SessionStart hook. No scope expansion occurred.

**Account-level weekly ceiling (`observed`, both surfaces)**: the app surfaced
*"Approaching weekly usage limit — Resets Sat, Jul 25, 4:00 AM"*. Critically,
this ceiling is **not app-only** — the headless `leg-a-print.jsonl` capture
carries a structured, machine-readable event for the same limit:

```json
{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning",
"resetsAt":1784966400,"rateLimitType":"seven_day","utilization":0.76,
"isUsingOverage":false,"surpassedThreshold":0.75}}
```

`resetsAt: 1784966400` decodes to 2026-07-25T08:00Z — exactly the in-app string.

This is materially more useful to the harness than a rendered warning: the
ceiling is readable **headlessly and pre-emptively**, carrying current
`utilization` (0.76) against a `surpassedThreshold` (0.75), the limit type
(`seven_day`), an overage flag, and a reset epoch. A budget model can consume it
*during* a run rather than discovering the ceiling by hitting it.

This is a second, independent budget constraint — distinct from the per-run
`--max-budget-usd` cap — and `rate_limit_event` / `rate_limit_info{}` is an
undocumented platform surface now enumerated in the drift guard below.

---

## Explicit gaps

Per the #871 "probes not completed" discipline, these are recorded rather than
omitted or guessed at.

### Leg (e) — supervisor-side force-halt: not run

**Reason**: leg (c) established that the vendor's own `--max-budget-usd` reports
breaches structurally, which moved supervisor-side force-halt off the critical
path for the budget arm. The owner elected to bank the result rather than run the
highest-effort, most-uncertain leg. This is a scope decision, not a failure.

**Consequence**: the 874-D5 default applies unchanged — **token arm advisory,
wall-clock enforcing**. No evidence exists either way as to whether *any* Stop
hook can beat the goal evaluator's continuation decision.

### Leg (f) — live pre-termination read: not exercised

**Reason**: requires a session kept running concurrently while polling its live
transcript; not performed. The reader's parsing behaviour was validated against
completed captures instead, which answers a strictly weaker question.

**Consequence**: live-read feasibility and latency remain unknown, which is the
second controlling input to the token-arm decision.

### Leg (b) — `judged-impossible` path: not exercised live

**Reason**: no probe run produced a goal the agent judged impossible. Only
`satisfied` and `stopped` were emitted by real runs, so 2 of the 3 outcome
classifications were validated against live data.

**Consequence**: the `judged-impossible` classification remains **fixture-tested
only**. A harness relying on it to distinguish "the executor concluded the goal
cannot be met" from an ordinary error stop has no live evidence that the
discriminator fires correctly. This is why leg (b) is recorded as **partial**,
not fully observed, in the summary table.

---

## 874-D12 platform-internal-dependency enumeration

Drift-guard checklist. Each item is an undocumented or version-specific surface
the harness would depend on; re-verify each against a new build before trusting
harness behaviour.

1. **Terminal result event shape — success path** (`subtype: success`) —
   `type: result`; `is_error`; `api_error_status`; `num_turns`; `total_cost_usd`;
   `stop_reason`; `terminal_reason`; `result`; `session_id`; `uuid`;
   `duration_ms`; `duration_api_ms`; `ttft_ms`; `permission_denials[]`;
   `fast_mode_state`.
1a. **Terminal result event shape — error path** (`subtype:
   error_max_budget_usd` observed) — **the field set differs and the budget arm
   lives here**. `api_error_status` and `terminal_reason` are **absent**; an
   `errors` field is **present** and is the only place the configured cap is
   echoed back (`"Reached maximum budget ($0.01)"`). Do not assume the
   success-path field list holds.
2. **Usage object shape** — `usage.{input_tokens, output_tokens,
   cache_creation_input_tokens, cache_read_input_tokens}` plus nested
   `server_tool_use{}`, `cache_creation{ephemeral_1h_input_tokens,
   ephemeral_5m_input_tokens}`, `service_tier`, `iterations[]`, `speed`,
   `inference_geo`.
   **⚠ Most dangerous property in this enumeration**: `usage` is **not reliably
   truthful**. On the observed budget-breach run it reported all four token
   counts as `0` with `iterations: []` while `modelUsage` and `total_cost_usd`
   recorded 648 output tokens and real spend. Token accounting must read
   `modelUsage`/`total_cost_usd`; a well-formed all-zero `usage` object is not
   evidence that nothing was consumed.
3. **Per-model usage** — `modelUsage{<model-id>{inputTokens, outputTokens,
   cacheReadInputTokens, cacheCreationInputTokens, costUSD, contextWindow,
   maxOutputTokens}}`.
4. **CLI argument coupling** — `--print` + `--output-format stream-json`
   *requires* `--verbose`.
5. **Model resolution** — the unpinned default inherits an ambient model that may
   be inaccessible to the headless credential; `--model sonnet` resolved to
   `claude-sonnet-4-6`.
6. **Headless credential channel** — `CLAUDE_CODE_OAUTH_TOKEN` environment
   variable.
7. **Stop-hook matcher semantics** — `Stop` events ignore `matcher`; containment
   is registration-location-based only (`documented`).
8. **Goal registration surface** — `goal` in `system/init`'s `slash_commands`.
9. **Release rendering** — no system-rendered completion status at goal
   satisfaction (app surface).
10. **Budget enforcement timing** — `--max-budget-usd` evaluated at turn
    boundary, permitting single-turn overshoot.
11. **Account-level weekly usage ceiling** — exists and is independent of per-run
    caps; surfaced in-app *and* headlessly.
12. **`rate_limit_event` / `rate_limit_info{}`** — undocumented structured event
    in the headless stream carrying `status` (`allowed_warning` observed),
    `rateLimitType` (`seven_day` observed), `utilization` (float),
    `surpassedThreshold` (float), `isUsingOverage` (bool), and `resetsAt` (unix
    epoch seconds). This is the machine-readable, pre-emptive form of item 11 and
    the only observed surface that reports budget headroom *during* a run.

## Instrument dispositions

What the harness inherits versus what it should replace.

| Instrument | Disposition | Rationale |
| --- | --- | --- |
| `goal-probe-streamjson.ps1` (I1) | **promote-candidate** | Parsed real terminal events correctly across every shape encountered (success, 401 error, budget breach), covering 2 of 3 outcome *classifications* — `judged-impossible` was never produced live. Two caveats before promotion: its `<goal-status>` tag convention is a **probe-stage assumption, not a vendor contract**; and it does not surface `errors`/`modelUsage`, which the budget path needs. |
| `goal-probe-usage-reader.ps1` (I2) | **promote-candidate (conditional)** | Well-formed-zero versus absent/wrong-shape discrimination validated on real vendor output. Two blockers: its headline live-read purpose is unexercised, and leg (c) proved a well-formed zero can be **untruthful**, so its `usage-present-zero` state must not be consumed as "nothing was spent" without a `modelUsage`/`total_cost_usd` cross-check. |
| `goal-probe-forcehalt-rig.ps1` (I3) | **hold** | Logic Pester-tested, zero live validation. Leg (c) reduces the need for supervisor-side force-halt. Revisit only if the harness needs non-budget hard-halt. |
| `goal-probe-forcehalt-hook.ps1` (stub) | **hold** | Block-decision contract never verified live; same rationale as I3. |

## Open questions carried to the harness plan

Recorded, deliberately **not resolved** here — these are harness-plan and #848
decisions.

1. **Exit-3 release path risk** — 874-D3 counts validator exit 0 or 3 as
   satisfied, but the #871 spike observed the transcript-mediated evaluator
   withholding release on a non-zero exit. Not probed here; the seven legs are
   design-ratified and no leg was added.
2. **Wall-clock-arm enforceability** — derived from leg (e), which was not run, so
   this is **fully open**. A wall-clock enforcement hook must also beat the
   evaluator, and this probe produced no evidence that any Stop hook can.
   874-D5 makes wall-clock the *enforcing* fallback, so this gap sits directly
   under a load-bearing design assumption.
3. **D9 whole-run sub-ceiling amendment** — leg (c)'s observed post-turn overshoot
   (3.4× a small cap) and the newly-observed account-level weekly ceiling both
   bear on whether a sub-ceiling is needed. #848 owns the resolution.
4. **Budget-arm architecture** *(new, raised by leg (c))* — because
   `--max-budget-usd` reports breaches structurally, the harness may be able to
   delegate budget enforcement to the vendor flag rather than operating its own
   token arm at all. This is consistent with 874-D1's vendor-native-engine lock.
   Flagged for the harness plan to decide.
5. **874-D5's token-accounting source needs amending** *(new, raised by leg (c)'s
   silent-zero finding)* — 874-D5 designates the platform `result` event as Arm
   H's end-of-run token accounting source without naming a field. As written, the
   obvious reading (`result.usage`) is **wrong**: it reports zeros on the breach
   path. The harness plan must pin `modelUsage`/`total_cost_usd` explicitly, and
   #848 should consider whether D5's wording needs correcting at the umbrella
   level.
6. **Pre-emptive headroom via `rate_limit_event`** *(new)* — the weekly-ceiling
   event exposes live `utilization` against a `surpassedThreshold` mid-run. This
   is the only observed mechanism that could support *pre-emptive* budget action
   rather than post-hoc breach reporting, and no design decision currently
   contemplates it.
