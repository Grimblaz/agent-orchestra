# Goal-Loop Platform Spike

Issue #871 (child of #848, implementing that umbrella's AC0) verified the two
Claude Code `/goal` platform assumptions the #848 design challenge rated its only
unverified load-bearing dependencies. This is an exploratory artifact only: no
production scripts, skills, tests, or schemas are changed. Findings that require a
design response are proposed as amendments on #848, not applied here.

**Platform under test**: Claude Code `2.1.150` (Windows 11). All findings are
n=1 observations against that build. The version travels with the findings
because most surfaces described here are undocumented implementation details, not
a published contract.

## Evidence labelling

Every claim below carries one of four labels, and the distinction is
load-bearing:

- `observed` — behaviour seen in a live run, with an artifact backing it.
- `documented` — read from published CLI help. A vendor contract, but *not*
  evidence the behaviour was exercised.
- `static` — read out of the installed binary's strings by extracting printable
  text. Suggestive of internal shape; not proof of behaviour.
- `inferred` — a conclusion drawn from the above, flagged as reasoning.

The `documented` label was added during review: the original three-label scheme
had no slot for published CLI help, which forced help-text claims to masquerade as
`observed`.

## Method and instruments

Probes ran with their working directory in a disposable `git worktree` at
`C:/gs871wt` (detached HEAD), outside the product checkout. The instrument and
fixtures lived in `C:/gs871wt-scratch`, a **plain sibling directory containing no
`.git`** — not itself a worktree. The containment property that matters is that
both paths are outside the product checkout; the earlier description of the
scratch directory as a worktree was inaccurate and is corrected here.

The predicate was an **instrumented** validator: a script that appends
`timestamp, PID, parent PID` to a log at an absolute path on every invocation,
unconditionally, before gating its exit code on the presence of a sentinel file. A
second variant prints `validator: condition satisfied, exiting 0` to stdout while
unconditionally exiting `1`.

The invocation log is the instrument that makes this a measurement rather than a
claim: because the script logs on every call, the absence of a log line is
evidence that no execution reached the instrument. This replaced an earlier design
in which an actor would assert something false; the script's own output carries the
false claim instead, so no participant is asked to lie.

**Preconditions and limits of the absence argument.** The log path is absolute, so
a caller's working directory does not redirect it. The argument nonetheless detects
only executions that reach *that file*: an evaluator running a copy of the script,
executing in a sandboxed or virtualized filesystem, or reading the script rather
than executing it would all produce the same silence. Those channels were not ruled
out.

### Evidence record

The complete invocation log, verbatim, at end of session:

```text
2026-07-19T01:20:11Z,pid=1176,ppid=1172
2026-07-19T01:45:27Z,pid=1913,ppid=1911,variant=falsifier
```

Attribution method: the first line was produced by the operator invoking the
validator directly from a shell outside any goal session, at a moment recorded in
the session transcript; the second carries `variant=falsifier` and was produced
during the falsifier trial, in which the agent under goal reported running the
script and its tool-result output appeared in that session's transcript. The PIDs
are not independently resolvable after the fact — attribution rests on transcript
correlation, not on the log lines alone.

Containment record: the product checkout's `git status --porcelain` fingerprint
was `e3b0c44298fc` (clean tree) at both the pre-probe and post-probe checkpoints,
on branch `feature/issue-871-goal-loop-platform-spike` at HEAD `1a82aac`. It
changed to `03cb4e10456a` only when this document was authored, after all probes
concluded. Two limits: the checkpoints were per-session, not per-probe as the plan
specified, so a transient mutation reverted between them would be invisible; and
`git status --porcelain` does not report ignored paths, so writes under `.tmp/`
would not appear.

## Findings

### The completion condition is judged from the transcript, not by executing the validator

`observed`. Across three goal lifecycles and more than a dozen Stop-hook firings,
the validator was executed exactly twice — see the log above. Neither entry is
attributable to the evaluator.

`observed`. The hook's own feedback, as surfaced to the agent, was phrased in terms
of what the conversation contained — that the transcript showed no evidence the
script had exited 0 — rather than in terms of an independent check.

`static`. The condition is evaluated by a prompt-hook evaluator whose response is
schema-validated to an `{ok, impossible, reason}` shape, registered as a
session-scoped Stop hook.

`inferred`. The evaluator does not independently execute the validator; it reaches
its verdict from transcript content.

### Two mechanisms fit that evidence, and they differ for #883

`inferred`. "The executor's honesty envelope" is **one of two** mechanisms
consistent with everything observed, and the spike cannot discriminate between
them:

1. **Prose-mediated** — the evaluator reads the executor's natural-language report
   of the result. Exposure: an executor that misreports.
2. **Tool-result-mediated** — the evaluator reads the platform-authored tool-result
   block, which records the real exit code and which the executor cannot forge.
   Exposure: **omission** — never run the validator at all and assert completion in
   prose, or suppress the output.

In the falsifier trial the agent's prose report *and* the platform's tool-result
record were both present and both truthful, so "the hook cited the exit code"
does not distinguish them. This matters downstream: under mechanism 2 the integrity
risk is avoidance rather than misreporting, which changes what #883 must measure.

### The predicate withholds release correctly; clean release was never observed

`observed`. In the falsifier trial, the agent ran a script that printed a false
success line while exiting `1`, and reported both facts. The Stop hook **refused to
release** and continued blocking across seven further continuations.

**Correction under review**: an earlier draft of this document asserted
"predicate-driven exit works." That overstated the evidence. What is evidenced is
the **withholding** half: the predicate correctly refuses to release on a false
claim. The **release** half — a goal cleanly terminating because a truthful success
report satisfied the condition — was never recorded. The one run in which the
sentinel was created and the condition became genuinely true was the run whose
termination path is "not determined" below, and its mandated records (turn count,
sentinel-flip turn index, termination turn index) were not captured.

**Limitation — the decisive case was not tested.** The agent supplied truthful
disambiguation. This shows the evaluator handles truthful evidence correctly; it
does **not** show what happens when only a false claim is present. Per the two
mechanisms above, constructing that case may require suppressing tool-call output
from the evaluator's view, which is a materially harder experiment than simply
declining to disambiguate.

### The executor expands scope well beyond a terse condition

`observed`. Given the four-word condition "this script exits 0" and access to the
repository and GitHub, one run did not attempt the script. It read issue #871's
full comment history, read the parent umbrella #848 for design context, dumped
comments to a scratchpad for grep access, and concluded it had identified "the
exact steps I need to execute." It was interrupted before it mutated anything.

`static`. The goal prompt instructs the executor to treat the condition as its
directive and explicitly not to pause and ask the user what to do.

`inferred`. A terse predicate plus broad tool access invites scope expansion, and
the anti-pausing directive removes the natural correction.

**Caveats**: this is n=1, it is *intent* rather than action (the run never mutated
anything), and it occurred in the same trial whose fixture comments described the
experiment — see Limitations. The behaviour of the other lifecycles on this axis
was not systematically recorded, so no base rate is offered.

### Budget observables exist and are live mid-run

`observed`. A live counter renders elapsed time and cumulative tokens *during*
execution, updating across turns (successive readings of `1m 40s · 1.5k tokens`,
`6m 20s · 6.5k tokens`, `9m 39s · 11.2k tokens` were taken from a single run).
Granularity is per-turn, not continuous.

`documented`. Headless `stream-json` output is specified to carry per-message
`usage` and a terminal `result` event with `total_cost_usd`, `duration_ms`, and
`num_turns`. **Not observed**: no headless completion succeeded in this
environment, so no assistant message carrying `usage` was ever produced here. An
earlier draft labelled this `observed`; that was wrong.

`documented`. `--max-budget-usd` — "Maximum dollar amount to spend on API calls" —
constrained to `--print` mode. **Never exercised.**

`static`. Goal state carries a start timestamp, an iteration counter, and a token
baseline, with consumed tokens computed as a live cumulative read minus that
baseline.

**Probe B2 was not completed as specified.** The plan required a per-observable
tuple `{name, reader, mechanism, granularity, actionable-before-termination}`,
noting that without it "two operators can run this probe and disagree." That tuple
was not produced. What can be said: the live counter's reader is a terminal render
(not obviously reachable by an external process without scraping); the
`stream-json` fields would be external-process-readable but were never observed
working. The strict "mid-run" test — reader ≠ agent **and** actionable before
termination — is therefore **not** established for any single observable.

### No native ceiling observed within the tested envelope

`observed`. An interactive session ran seven forced continuations against a
deterministic failure with no automatic platform-side cutoff, to roughly
11.2k tokens and about ten minutes.

`inferred`. No platform ceiling exists *below that bound*. A ceiling at higher turn
counts, or keyed to account spend rather than turns, was not ruled out.

**Shared provenance**: this observation and the falsifier trial are the *same run*
examined along two axes, not two independent data points.

### Programmatic launch is structurally supported but was not verified end to end

`documented`. `/goal` is not a CLI flag; there is no `--goal` option.

`documented`. `claude agents` is a documented subcommand for managing background
agents, whose `--json` mode is specified as "does not require a TTY" and whose
options govern "sessions dispatched from agent view." **Whether it can carry a goal
condition was not tested.** An earlier draft of this document claimed no subcommand
dispatches a background session; that was factually wrong, and the correction
matters because this is a candidate launch surface for #874.

`observed`. A headless `claude -p --input-format stream-json` session registers
`goal` in the `slash_commands` array of its `system.init` event, and session hooks
fire identically to an interactive session.

`observed`. Every headless completion in this environment failed
`401 authentication_error`, while `claude auth status` in the same shell reported an
active authenticated session. `claude setup-token` requires an interactive terminal
and produced no output under a non-interactive timeout.

`inferred`. The 401 is an environment-scoping artifact — this sandbox's ambient
OAuth does not propagate to spawned subprocesses — not evidence that headless goal
runs are impossible. **This remains unproven and is the highest-value item for #874
to confirm first.** A harness pursuing it would need durable credentials; see the
handling constraint in the downstream table.

**Probe A1's branch was never formally recorded.** The plan made A1 the router —
scripted execution if programmatic launch worked, owner-executed handoff if not.
A1 returned a third outcome the plan's binary did not anticipate (structurally
supported, environmentally unverifiable), and the remaining probes were in fact
owner-executed at a keyboard.

### Termination outcome is only partly observable

`observed`. An explicit `/goal clear` renders a visible confirmation naming the
cleared condition.

`observed`. A different run's goal terminated with **no visible status line** and no
completion render; the input placeholder simply reverted to its default state.

`static`. The binary contains a goal-status attachment carrying a `sentinel` flag
whose renderer returns nothing, alongside a distinct path for a condition judged
impossible.

**Not determined.** Which path ended that run, and whether a machine-readable
terminal outcome distinguishing *satisfied* from *judged impossible* from
*externally stopped* is exposed to a harness. Headless verification was blocked by
the auth issue above.

**Halt-enum mapping (probe A5's mandated fallback).** Of #874's five halt-reason
members, only two depend on a platform-observable terminal outcome:

| Halt reason | Source | Status |
| --- | --- | --- |
| `unachievable-target` | platform-observable (impossible verdict) | **not determined** |
| `budget-exhausted` | platform-observable on the headless path | **not determined** |
| `invariant-conflict` | validator-generated (D5) | no platform dependency |
| `gate-input-needed` | harness-generated (D4 chain) | no platform dependency |
| `chain-stage-failure` | harness-generated (D4 fix-cycle cap) | no platform dependency |

An earlier draft claimed the enum "cannot be populated" until terminal-outcome
readability is resolved. That was over-broad: three of five members are buildable
today.

### Probes not completed

Recorded explicitly rather than left as silent absences:

- **B4 (external halt)** — **not run.** The in-session arm is covered (`/goal clear`
  cleanly removes the hook), but supervisor-side termination of a running loop —
  the case #874 actually needs — was never attempted. Reason: the session reached
  its findings without a non-converging run that warranted a forced kill. Note the
  B5 branch "if no external halt exists, both budget arms are advisory" does **not**
  fire, because an in-session halt path demonstrably exists.
- **B2 tuple** — not produced; see the budget section.
- **A4 evaluator verdict field** — **not recorded.** The plan required either the
  verdict field (`ok` vs `impossible`) or an explicit finding that it is not exposed
  to the operator. Neither was captured. Because the loop never released, the
  distinction was not decision-relevant for this trial, but the record is missing.
- **A2 records** — turn count, sentinel-flip turn index, and termination turn index
  were not captured; see the release-half correction above.
- **B1** — not delivered as a per-field enumeration. The no-status-line observation
  materially tensions the planner's static grounding but does not confirm or refute
  it field by field.

## Assumption versus observed

The identifiers below are #848's numbered design decisions: **D4** is the terminal
chain (how a goal run is launched, validated, reviewed, and turned into a pull
request), **D5** is the post-run validation contract, **D7** is the halt model, and
**D9** is the budget model. Stage 1 is that umbrella's first pilot run.

| # | Assumption | What was found | Evidence grade | Consequence |
| --- | --- | --- | --- | --- |
| D4 | Goal loop launched with validator-as-predicate | Predicate withholds correctly; evaluator never executes the validator | `observed` + `inferred` | Narrow D4: the in-loop predicate is transcript-mediated, not independent |
| D4 | Harness launches the loop programmatically | `goal` registered in headless sessions; no completion succeeded | `observed` (registration), unproven (launch) | #874 must confirm first; `claude agents` is an untested candidate |
| — | Contract = targets, invariants, evidence, halt conditions, budget (#848's contract statement, not D4) | Executor expanded a terse condition into "execute the whole issue" | `observed`, n=1, intent not action | Add **scope boundaries**; owner is the contract statement and #872's schema |
| D5 | Post-run validator provides environmental independence | Unaffected — and now the chain's only independent verification | `inferred` | No amendment; record the reinforced rationale |
| D7 | Five-value halt enum | Two members platform-dependent and undetermined; three harness/validator-generated | `static` + `inferred` | Only `unachievable-target` and `budget-exhausted` are blocked |
| D9 | Token observable may not exist; token arm may be advisory | Live per-turn counter observed; harness-reachable path documented but never exercised | `observed` + `documented` | Token arm can be harness-enforced; native `--max-budget-usd` unverified |
| D9 | Ceilings convert non-convergence into a halt | No cutoff within 7 turns / ~11.2k tokens | `observed`, bounded | Harness owns bounding for interactive runs |

## Limitations

- **n=1 per probe**, against a single platform build, on one operating system.
- **Two probes were contaminated.** (1) The first constrained the agent from
  touching the script, which manufactured a deadlock and **prevented the normal
  case — clean release on success — from being observed**. (2) In the second, the
  agent read #871's plan comment, including the falsifier's design and intended
  interpretation, before acting; the fixture's own comments also described the
  experiment. A clean re-run needs an innocuous fixture in a session with no access
  to the plan.
- The **prose-only case** was never tested, and per the two-mechanism finding may
  require suppressing tool-call output to construct.
- **Termination-outcome machine-readability** is unresolved.
- Several plan-mandated records were not captured — see Probes not completed.

## Downstream impact

| Issue | Disposition | Detail |
| --- | --- | --- |
| #872 | constrains as follows | Contract schema should carry **scope boundaries** — what the executor may read and mutate — alongside targets and invariants. This lands in the umbrella's contract statement and #872's schema, not D4 |
| #873 | no change | Unblocked and reinforced: D5's independent re-validation is untouched by the finding and is now the chain's only non-transcript verification |
| #874 | blocks pending | Two items only: (1) end-to-end headless launch — `claude agents` non-TTY `--json` is an untested candidate; (2) terminal-outcome readability, which blocks **only** `unachievable-target` and `budget-exhausted`. Three enum members are buildable now. Budget: the live counter is per-turn, so a harness ceiling overshoots by up to one turn; `--max-budget-usd` is unexercised and, as a process kill, may produce no halt report at all — verify before relying on it, since D7 requires `budget-exhausted` to be *reported*. Durable credentials must be scoped, stored outside the repo, excluded from captured transcripts and hook logs, and revocable |
| #875 | blocks pending | Blocked by #874. Interactive pilot runs need an operator-side abort procedure and a pre-registered cap; no platform cutoff was observed within the tested envelope, and supervisor-side termination (B4) was never verified |
| #883 | constrains as follows | Beyond the plan's four-child scope; addresses #883's AC1 only, and #883 remains gated on #875 by its own terms. Probe **A3** — the identifier #883 keys on — found the evaluator never executes the validator. Two mechanisms fit: prose-mediated (exposure: misreporting) and tool-result-mediated (exposure: omission). Executor tier is therefore partly an integrity question, but **which** integrity question is unresolved, and the decisive credulity case is untested |

## Retrospective

The instrumented-log design changed the conclusion. A positive-only probe would
have observed the loop terminating after the sentinel appeared and concluded that
script-predicate exit works as designed. The log is what revealed the script had
never run. The negative-control discipline the plan's adversarial review insisted
on is what produced the finding, and it is recorded here as an input to #875's A/B
protocol.

Defects in the plan itself surfaced during execution and were not caught by its
five-pass review: the verdict truth table had no row for the outcome that actually
occurred; the evidence-label taxonomy had no slot for published CLI help; and the
fixture leaked the experiment's design into a file the subject could read. The
review of *these* artifacts sustained 37 findings, most of them reporting-surface
defects rather than evidence defects — which is itself a data point about where
this pipeline's residual risk sits.
