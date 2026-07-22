# Goal-loop capability probe (#874 AC5)

Empirical probe of the seven capability unknowns (legs a–g) that gate the #874
goal-run harness's headless and budget arms, per 874-D9. Sibling to — and
deliberately modelled on — [goal-loop-platform-spike.md](goal-loop-platform-spike.md)
(#871), whose evidence-label taxonomy and "probes not completed" discipline this
document reuses.

## Platform build and limits

**The legs did not all run on one build.** An earlier draft of this document
attributed every finding to `2.1.150`; that was wrong and is corrected here.
Build and surface are recorded per leg:

| Legs | Surface | Build |
| --- | --- | --- |
| (a)–(d), (f) | headless `claude -p` from `C:\Users\Micah` | **2.1.150** (CLI, captured at run time) |
| (g) | **Claude Code desktop app** (the owner's normal use case) | **2.1.215** (recorded in the session transcript) |
| (h) | headless `claude -p` from a scratch directory | **2.1.216** (CLI, captured at run time) |

`observed` claims are **n=1** live observations against the stated build unless a
repeat count is given. The build travels with each finding because most surfaces
described here are undocumented implementation detail that can change without
notice — and this probe **directly observed such drift** between 2.1.150 and
2.1.216 (see the [drift-guard enumeration](#874-d12-platform-internal-dependency-enumeration)).
Do not generalise a single-build observation across builds; two of this
document's own findings had to be narrowed for exactly that reason.

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
| (g) | clean release | `observed` | Releases **silently** to the eye, but emits a **typed `goal_status` event** to the transcript |
| (h) | headless goal-loop start | `observed` | **`/goal` does NOT start a goal loop under `claude -p`** — and headless default permissions deny every write |

**Five legs fully observed (a, c, d, g, h), two partial (b, f), one explicit gap (e).**

> **The two findings that most change the harness design:**
>
> 1. **The goal loop is only startable interactively.** `/goal` is consumed as
>    literal prompt text under `claude -p` — no loop, no evaluator, no
>    `goal_status` (leg h). Any headless arm must be re-scoped around this.
> 2. **The interactive surface emits a typed release signal.** `goal_status`
>    carries `met`, the evaluator's own `reason`, `iterations`, `durationMs`, and
>    `tokens` straight into the session transcript (leg g). Release is invisible
>    on screen but fully machine-readable on disk — the harness should
>    **consume this event rather than invent a parallel run-log**.
>
> Together these invert the surface story: the surface that can actually *run* a
> goal loop is also the one that reports it best.

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

**Overshoot (`observed`, n=2) — express it in dollars, not as a ratio**: an
earlier draft of this document reported "roughly 3.4× the ceiling". That framing
was misleading, and leg (h) supplied the second data point that corrects it:

| Run | Build | Cap | Spent | Over (absolute) | Ratio |
| --- | --- | --- | --- | --- | --- |
| (c) | 2.1.150 | $0.01 | $0.0335877 | **$0.024** | 3.36× |
| (h) | 2.1.216 | $0.50 | $0.5159808 | **$0.016** | 1.03× |

The **absolute** overshoot is roughly one turn's cost in both runs; the *ratio*
only looked alarming in leg (c) because that cap was pathologically small — of
the same order as a single turn. The actionable rule for the harness is
**"budget one additional turn beyond the cap"**, not "expect 3.4× your cap". A
cap set meaningfully above per-turn cost overshoots by a few percent.

**Enforcement timing (`inferred`)**: the overshoot pattern is consistent with
enforcement being evaluated at the **turn boundary**, after the turn that
exceeded the cap, rather than pre-emptively — and the n=2 result strengthens that
reading, since a fixed one-turn overshoot at two very different cap sizes is what
turn-boundary evaluation predicts. Still `inferred`: nothing in either artifact
shows evaluation timing directly.

### Silent-zero `usage` on the breach path — `observed` on 2.1.150, **NOT reproduced** on 2.1.216

> **Scope correction.** An earlier draft of this document presented this as a
> general property of the platform ("`result.usage` lies"). It is not. The
> defect was observed **once, on build 2.1.150**, and leg (h) — a
> same-subtype `error_max_budget_usd` run on **2.1.216** — reported a fully
> populated, correct `usage` object. The finding below is real and retained,
> but it is **build-specific evidence, not a standing platform property**.

On build **2.1.150**, the terminal event reported **mutually contradictory**
token accounting:

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

**Why it still matters**: 874-D5 designates the platform `result` event as Arm
H's end-of-run token accounting source without naming a field. On a build
exhibiting this defect, a harness reading `result.usage` would record **zero
tokens consumed on every budget breach** — silently, with no error, on precisely
the path the budget arm exists to police. This is the **#873 silent-zero defect
class appearing in live vendor output**, and it is not a hypothesis: it is in the
retained `leg-c.jsonl`.

**The contrasting evidence (`observed`, 2.1.216)**: leg (h)'s
`error_max_budget_usd` event reported `usage` = `input 34 / output 4342 /
cache_read 840600 / cache_creation 26718` alongside `modelUsage`, both populated
and mutually consistent.

**Consequence for the harness** — unchanged by the narrowing, because the safe
practice is the same either way: token accounting should read `modelUsage` /
`total_cost_usd` and **cross-check** rather than trust `usage` alone. A
well-formed all-zero `usage` object cannot be assumed truthful on every build, and
a reader that silently accepts one has no way to tell a real zero from this
defect. Whether 2.1.150 was buggy or 2.1.216 fixed it is **not established** —
n=1 per build, and no changelog was consulted.

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
produced a direct counter-example on build 2.1.150 — an all-zero `usage` object
on a run that genuinely consumed 648 output tokens. Shape validation cannot
distinguish a truthful zero from a vendor-emitted false zero, and no consumer
should treat `usage-present-zero` as proof that nothing was consumed. (That
counter-example did not reproduce on 2.1.216; see leg (c) for the scope
correction. The caution stands regardless, because a reader cannot tell which
build it is talking to from the payload alone.)

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

### The `goal_status` transcript channel (`observed`) — release is silent on screen, typed on disk

The rendered surface says nothing, but the **session transcript** at
`~/.claude/projects/{project-slug}/{session-id}.jsonl` carries the full goal
lifecycle as structured events. The same app session that rendered nothing wrote:

```json
{"type":"attachment","attachment":{"type":"goal_status","met":false,"sentinel":true,
 "condition":"<goal text>"},"entrypoint":"claude-desktop","cwd":"...","sessionId":"...","version":"2.1.215"}

{"type":"attachment","attachment":{"type":"goal_status","met":true,"condition":"<goal text>",
 "reason":"<the evaluator's own written judgment>","iterations":1,"durationMs":12033,"tokens":379}}
```

A `queue-operation`/`enqueue` event also records the literal `/goal …` text the
owner submitted, and every `assistant` event carries `message.usage`.

So the interactive surface exposes, machine-readably and without any harness
instrumentation:

| Signal | Field |
| --- | --- |
| goal started | `goal_status.sentinel: true`, `met: false` |
| goal text | `goal_status.condition` |
| **release** | `goal_status.met: true` |
| evaluator's reasoning | `goal_status.reason` |
| iterations / duration | `iterations`, `durationMs` |
| goal-scoped token spend | `tokens` |
| launch surface | `entrypoint` (`claude-desktop` observed) |

**This revises the design consequence recorded in the previous draft.** That
draft concluded: *"the harness cannot key release detection on any rendered UI
signal, so it must emit its own typed run-log entry."* The first half is correct;
the second does not follow. **The platform already emits a typed release event.**
874-D11's instinct — do not depend on a render — is confirmed, but the harness
should **consume `goal_status`** rather than build a parallel run-log beside it.
That is both simpler and better aligned with 874-D1's vendor-native lock: the
release verdict, and the evaluator's stated reason for it, come from the engine
rather than from a harness re-derivation.

**Comparison with the headless terminal event**: `result` reports that the
*process* ended (`terminal_reason`, `subtype`); `goal_status` reports that the
*goal was judged met*, with the evaluator's reasoning. For release detection these
are not interchangeable — `goal_status` is the goal-semantic signal, and it exists
only on the surface that can actually run a goal loop (see leg (h)).

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

## Leg (h) — headless goal-loop start

Added after the original seven legs, because reviewing legs (a)–(g) exposed an
unexamined assumption: every headless leg had used a **plain prompt**, so
"arm-H enabling" had never actually been tested against a *goal loop*. Run on
**2.1.216** from a scratch directory, reusing leg (g)'s **exact goal text** so the
two surfaces are directly comparable.

```powershell
claude -p "/goal <same text as leg (g)>" --output-format stream-json --print `
  --verbose --model sonnet --max-budget-usd 0.50 > leg-h.jsonl 2> leg-h.stderr.log
```

### Result 1 — `/goal` does not start a goal loop headlessly (`observed`)

**Zero `goal_status` events** in the 152 KB capture, versus two in leg (g)'s
interactive run of the identical goal. `/goal` was consumed as **literal prompt
text**: no loop, no evaluator, no release verdict.

**Consequence**: arm-H's "enabling" verdict covers headless **invocation and
prompting** only. Headless **goal-looping is not supported** through `claude -p`
on this build. Any harness arm that assumed a background headless goal loop must
be re-scoped; the goal loop is, on current evidence, an **interactive-only**
capability.

### Result 2 — headless default permissions deny all writes, and the agent burns the budget discovering it (`observed`)

`system/init` reported `permissionMode: default` with the `Write` tool present in
the tool list. Every write was nonetheless **denied**: 14 recorded
`permission_denials` across `Write` (×5), Bash heredoc / `printf` / `tee` /
`python`, `PowerShell`, and one attempt carrying `dangerouslyDisableSandbox: true`
— which was denied as well. Read-only Bash succeeded throughout.

Because headless has **no interactive approver**, no approval prompt could ever
reach a human. The agent iterated **18 turns** and spent **$0.5159808** producing
no file at all, terminating only when the budget cap fired
(`terminal_reason: budget_exhausted`). Its closing message was accurate and
self-aware — *"still blocked on write permissions after 9 attempts … I cannot
complete this goal right now"* — but the entire cap had already been spent
reaching that conclusion.

**Consequence**: this is a **budget-burn failure mode**, not a mere
configuration nit. A headless arm without an explicit permission posture
(`--permission-mode`, `--allowedTools`, or equivalent) will reliably consume its
whole budget and produce nothing. The `--max-budget-usd` belt was the only thing
that bounded the loss — which is itself a point in favour of always setting it.

**Also observed on this run**: `usage` fully populated (contrast leg (c)); a
second model (`claude-haiku-4-5-20251001`) appeared in `modelUsage` despite
`--model sonnet`; and `--model sonnet` resolved to `claude-sonnet-5`, where on
2.1.150 it resolved to `claude-sonnet-4-6`.

**Containment (`observed`)**: product checkout `HEAD` (`8428e06`) and porcelain
fingerprint (`e3b0c44298fc`, 0 lines) identical before and after.

---

## What the evidence forces the user-facing flow to look like (874-D13 / AC6 input)

This section is **design input, not user documentation** — the harness does not
exist yet, so nothing here is a usable instruction today. It records the flow the
probe's constraints permit, so 874-D13's eventual user guide is built on evidence
rather than assumption.

### The mechanism that decides everything

**`/goal` takes over the session it is typed in.** It spawns nothing; it drives
*that* conversation's turns until its evaluator judges the goal met (leg g: the
turns and both `goal_status` events landed in the typing session's own
transcript). Two consequences follow directly:

- Every iteration re-sends that session's accumulated context, so a goal loop
  started in a long orchestration conversation pays for that conversation on
  every turn.
- The harness is defined as **bookends around** the executor (874-D1). Running the
  loop in the session doing the orchestration collapses bookends and executor into
  one context, dissolving the separation the design depends on.

### Option 1 — two sessions, short typed goal (evidence-preferred)

```text
Session A (orchestration):   /experience 900  →  /design 900  →  /plan 900
Session B (fresh, in repo):  /goal implement issue #900 per the approved plan comment
                             …loop runs autonomously; releases silently…
Session B (same session):    {finish command}   ← reconcile, review, CE Gate, PR
```

Why this shape is the one the evidence supports:

- **The goal text can be short** because #872 already persists the
  machine-checkable contract *inside* the plan comment. The executor reads its
  requirements from the durable artifact, not from what the owner types — which
  is the stated intent ("point towards the thing we've created for requirements").
- **Session B starts empty**, so the loop pays no orchestration-context tax.
- **Finishing happens in Session B**, because release simply hands the prompt back
  (leg g) — the session stays usable. Cross-session resumption is safe regardless,
  since phase state lives in durable issue markers, not in a conversation.
- **Cost: one extra session, one short typed line, one finish step.**

### Option 2 — everything in one session

Type `/goal …` directly in the orchestration session. Mechanically works. Costs
the context tax on every iteration and forfeits the bookend separation.
Defensible for a small slice; wasteful and muddy for a real issue.

### Option 3 — headless background worker: **ruled out by leg (h)**

Not "untested" — actively unsuitable on current evidence. `/goal` does not start a
loop under `claude -p` at all, and default headless permissions deny every write
while the agent spends its full budget discovering that. Any future headless arm
needs both a way to start a loop (none known) and an explicit permission posture.

### Open flow question for the harness plan

Whether the finish step can be **automatic**. A hook watching for
`goal_status.met: true` could trigger reconciliation with no command from the
owner — and per the decomposition in the open questions below, *observing* does
not require winning the Stop-hook race that leg (e) never tested. If that holds,
Option 1 reduces to: type one goal line, walk away. The harness plan should
settle this rather than assume it.

### What exists today versus what Option 1 needs

| Exists now | Does not exist |
| --- | --- |
| `/goal` (vendor-native, interactive) | the finish command (name TBD) |
| `/experience`, `/design`, `/plan`, `/orchestrate` | contract hand-off, inflight marker, reconciliation, budget advisory |
| `goal_status` transcript signal (platform-emitted) | any consumer of it |

Typing `/goal` at a plan today yields a vendor goal loop with **no bookends**: no
markers, no review pipeline, no CE Gate, no PR.

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
   lives here**. `api_error_status` is absent; an `errors` field is **present**
   and is the only place the configured cap is echoed back (`"Reached maximum
   budget ($0.01)"`). `terminal_reason` was **empty on 2.1.150 but populated
   (`budget_exhausted`) on 2.1.216** — do not assume the success-path field list
   holds, and do not assume this path's own shape is stable across builds.
2. **Usage object shape** — `usage.{input_tokens, output_tokens,
   cache_creation_input_tokens, cache_read_input_tokens}` plus nested
   `server_tool_use{}`, `cache_creation{ephemeral_1h_input_tokens,
   ephemeral_5m_input_tokens}`, `service_tier`, `iterations[]`, `speed`,
   `inference_geo`.
   **⚠ Treat `usage` as untrusted without a cross-check.** On the 2.1.150
   budget-breach run it reported all four token counts as `0` with
   `iterations: []` while `modelUsage` and `total_cost_usd` recorded 648 output
   tokens and real spend. The same shape on 2.1.216 was populated and correct, so
   this is **build-specific evidence, not a standing property** — but a payload
   carries no indication of which behaviour it exhibits, so token accounting
   should read `modelUsage`/`total_cost_usd` and cross-check rather than trust a
   well-formed all-zero `usage` object.
3. **Per-model usage** — `modelUsage{<model-id>{inputTokens, outputTokens,
   cacheReadInputTokens, cacheCreationInputTokens, costUSD, contextWindow,
   maxOutputTokens}}`. **Keyed by more models than you asked for**: leg (h) pinned
   `--model sonnet` yet `modelUsage` carried both `claude-sonnet-5` and
   `claude-haiku-4-5-20251001`. A consumer summing per-model cost must iterate all
   keys, not read the pinned model's entry.
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
13. **`goal_status` attachment event** *(interactive surface only)* —
    `{type: goal_status, met, sentinel, condition, reason, iterations,
    durationMs, tokens}`. The goal loop's own lifecycle and release verdict. Not
    emitted headlessly, because no goal loop starts there (leg h).
14. **`queue-operation`** — `{operation: enqueue|dequeue, content}`; the
    `enqueue` payload carries the literal submitted command text, including
    `/goal …`.
15. **Slash-command handling under `-p`** — `/goal` is **not** interpreted as a
    command; it is passed through as prompt text.
16. **Headless permission posture** — `permissionMode: default` denies all writes
    with no reachable approver; tool presence in `system/init.tools` does **not**
    imply the tool is usable.
17. **`system/thinking_tokens`** — event type present on 2.1.216, absent from the
    2.1.150 captures.

### Drift actually observed between 2.1.150 and 2.1.216

This is not a hypothetical guard — the probe caught four changes across its own
run window, which is the strongest argument for re-verifying the list above:

| Surface | 2.1.150 | 2.1.216 |
| --- | --- | --- |
| `terminal_reason` on a budget breach | empty | `budget_exhausted` |
| `--model sonnet` resolves to | `claude-sonnet-4-6` | `claude-sonnet-5` |
| `usage` on a budget breach | all zeros (defect) | populated |
| `system/thinking_tokens` events | absent | present |

## Instrument dispositions

What the harness inherits versus what it should replace.

| Instrument | Disposition | Rationale |
| --- | --- | --- |
| `goal-probe-streamjson.ps1` (I1) | **promote-candidate** | Parsed real terminal events correctly across every shape encountered (success, 401 error, budget breach), covering 2 of 3 outcome *classifications* — `judged-impossible` was never produced live. Two caveats before promotion: its `<goal-status>` tag convention is a **probe-stage assumption, not a vendor contract**; and it does not surface `errors`/`modelUsage`, which the budget path needs. |
| `goal-probe-usage-reader.ps1` (I2) | **promote-candidate (conditional)** | Well-formed-zero versus absent/wrong-shape discrimination validated on real vendor output. Two blockers: its headline live-read purpose is unexercised, and leg (c) proved a well-formed zero can be **untruthful**, so its `usage-present-zero` state must not be consumed as "nothing was spent" without a `modelUsage`/`total_cost_usd` cross-check. |
| `goal-probe-forcehalt-rig.ps1` (I3) | **hold — but re-prioritise** | Logic Pester-tested, zero live validation. An earlier draft justified the hold on "leg (c) reduces the need for supervisor-side force-halt"; **that reasoning was CLI-scoped and does not survive leg (h)** — `--max-budget-usd` is a command-line flag with no interactive equivalent, and the goal loop only runs interactively. Budget *enforcement* on the surface that can actually run a loop therefore still depends on the untested Stop-hook race. |
| `goal-probe-forcehalt-hook.ps1` (stub) | **hold** | Block-decision contract never verified live; same rationale as I3. |
| *(none — new need)* | **gap** | Nothing here reads `goal_status`. That is the interactive surface's release signal and the harness's primary detection channel; a reader for it is net-new work for the harness plan. |

## Open questions carried to the harness plan

Recorded, deliberately **not resolved** here — these are harness-plan and #848
decisions.

1. **Exit-3 release path risk** — 874-D3 counts validator exit 0 or 3 as
   satisfied, but the #871 spike observed the transcript-mediated evaluator
   withholding release on a non-zero exit. Not probed here; the seven legs are
   design-ratified and no leg was added.
2. **Wall-clock-arm enforceability — now higher priority, not lower** — derived
   from leg (e), which was not run, so this is **fully open**. Leg (h) raises its
   stakes: since the goal loop runs only interactively, and `--max-budget-usd` is
   CLI-only, **no vendor-native budget enforcement exists on the surface that can
   run a loop**. Enforcement there depends entirely on whether a hook can halt the
   loop — precisely the untested question. 874-D5 makes wall-clock the *enforcing*
   fallback, so this gap sits directly under a load-bearing assumption.
   *(Mitigating decomposition: **observation** does not require winning that race.
   A hook that watches `goal_status` and writes reports never has to beat the
   evaluator — only halting does. So reconciliation is buildable today; only
   enforcement is blocked.)*
3. **D9 whole-run sub-ceiling amendment** — the corrected overshoot
   characterisation (≈ one turn's cost absolute, n=2) plus the account-level
   weekly ceiling both bear on whether a sub-ceiling is needed. #848 owns the
   resolution.
4. **Budget-arm architecture** *(revised by leg (h))* — `--max-budget-usd` reports
   breaches structurally, so a *headless* arm could delegate enforcement to it.
   But headless cannot run a goal loop at all, so that delegation is unavailable
   to the interactive arm, which is the one that matters. The harness plan must
   decide what the interactive arm does about budget given that its only proven
   capability is *reading* spend (`goal_status.tokens`, per-turn `message.usage`),
   not bounding it.
5. **874-D5's token-accounting source needs pinning** *(raised by leg (c))* —
   874-D5 designates the platform `result` event as Arm H's end-of-run token
   accounting source without naming a field. The obvious reading (`result.usage`)
   returned zeros on the 2.1.150 breach run. The harness plan should pin
   `modelUsage`/`total_cost_usd` with a cross-check, and #848 should consider
   whether D5's wording needs correcting at the umbrella level. Note D5 is also
   framed around Arm H, which leg (h) shows cannot host a goal loop — so the
   decision may need re-siting onto the interactive arm entirely.
5a. **Release detection should consume `goal_status`, not a parallel run-log**
   *(new, raised by leg (g)'s transcript finding)* — 874-D11's premise (no
   rendered signal) is confirmed, but the platform already emits a typed release
   event carrying the evaluator's own verdict and reasoning. The harness plan
   should decide whether D11's run-log becomes a consumer of `goal_status` rather
   than an independent re-derivation.
5b. **Headless permission posture is mandatory if any headless arm survives**
   *(new, raised by leg (h))* — default headless permissions deny all writes with
   no reachable approver, and the agent burns its entire budget discovering this.
   Any retained headless arm must specify an explicit permission posture, and the
   harness should treat "many consecutive permission denials" as a halt condition
   in its own right.
6. **Pre-emptive headroom via `rate_limit_event`** *(new)* — the weekly-ceiling
   event exposes live `utilization` against a `surpassedThreshold` mid-run. This
   is the only observed mechanism that could support *pre-emptive* budget action
   rather than post-hoc breach reporting, and no design decision currently
   contemplates it.
