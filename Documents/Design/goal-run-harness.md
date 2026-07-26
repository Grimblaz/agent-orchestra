# Goal-run harness: runtime architecture

The goal-run harness (#874, with its resume-path defects closed by #912) is the
runtime that walks a single approved goal-contract issue through to a reviewed,
classed pull request without a human answering questions mid-run. This document
is the architectural record of *why* the harness is shaped the way it is —
the stage machine, the mutex lifecycle, the operator-recovery levers, and the
limits the design accepts on purpose. It is not a restatement of the #912 diff
and should stay accurate after that PR merges and its branch is gone.

Complementary reading, each with a different job:

- [agents/Goal-Run.agent.md](../../agents/Goal-Run.agent.md) — the runnable
  stage-machine prose an invocation actually follows.
- [skills/goal-run/SKILL.md](../../skills/goal-run/SKILL.md) — the contract
  reference: the written stage vocabulary, the halt-reason enum and its
  precedence, the marker schemas, the worktree lifecycle, and the
  label-to-ledger join key. This document assumes that contract and explains
  the design reasoning behind it instead of re-describing its shape.
- [HOW-IT-WORKS.md § Goal-run: the unattended pipeline](../../HOW-IT-WORKS.md#3-goal-run-the-unattended-pipeline) —
  the newcomer-facing orientation (which pipeline to choose, how to read a
  halt report, honest budget expectations).

## What the harness is, and the guarantee it exists to provide

`/goal-run {issue}` hands one GitHub issue — carrying an approved
`goal-contract` plan variant (872-D2) — to the vendor's own `/goal` loop, and
walks the result through re-validation, CE Gate (Customer Experience Gate),
adversarial review, capped fix cycles, and PR creation, all without a live
human answering questions mid-run. It is the second of two pipelines Agent Orchestra ships alongside
`/orchestrate` (see HOW-IT-WORKS.md's comparison table): where the conducted
pipeline pauses at engagement gates and waits for an answer, goal-run has no
mechanism to ask one, so every point that would otherwise raise
`AskUserQuestion` produces a typed halt instead.

The one command, `/goal-run {issue}`, is deliberately **both launcher and
resumer**. Every invocation inspects only durable GitHub-and-worktree
artifacts — issue comments, the goal-contract block, `goal-run-active.json`,
the typed run log — and never the current conversation's memory of what
happened earlier. This is the harness's entire reason to exist: a maintainer
launches it and walks away, and the value of walking away is entirely
contingent on coming back being safe. #912 exists because that guarantee was
violated for the single most common return path — an ordinary interruption
(a closed window, a sleeping machine, an ended session) left the issue
permanently unusable through `/goal-run`, with no lever to recover it short
of hand-editing a GitHub comment. Everything described below is in service of
one property: **an interruption should cost the maintainer time, never the
issue.**

## The stage machine and resume precedence

The stage machine has a small **written** vocabulary — the value actually
persisted to the `goal-run-stage-{issue}` marker comment:

```text
pre-loop -> loop-launched -> loop-released -> chain-dispatched
```

`pre-loop` is implicit; no marker is ever posted for it on its own. A
resuming invocation does not read this marker directly to decide what to do —
it calls `Resolve-GoalRunResumeStage`, which reads a fixed precedence of
durable signals (contract-hash verification, terminal-emissions state, the
explicit stage marker, the run log, `goal-run-active.json`, the mutex marker)
and returns a `.ResumeStage` that is a **superset** of the written vocabulary:
it adds `blocked`, `complete`, and — since #912 — `loop-interrupted`.
`blocked` and `complete` are terminal reports, not stages a resumer executes.
`loop-interrupted` is different: it is a stage the resumer actually runs.

### Why `loop-interrupted` exists, and why it re-derives from committed state

Before #912, an explicit `loop-launched` marker with no later `loop-released`
follow-up resolved straight to `loop-released` — the resume machinery treated
"the loop ran" and "the loop reported back to me" as the same fact. They are
not: the session that launched the loop may be gone, and `Resolve-GoalRunControlReturn`
(the function that reads the loop's `goal_status` verdict) is scoped to a
session reading back its *own* control-return — it has nothing to read when
the transcript that would carry that verdict no longer exists or belongs to a
dead session.

The load-bearing decision is that `loop-interrupted` never tries to answer
"what did the interrupted loop's outcome verdict say" — because that
question cannot be answered honestly once the transcript is gone. It asks a
different, always-answerable question instead: **"does the committed
worktree state already satisfy the contract, right now?"** It calls
`Invoke-GoalRunChainRevalidate` directly against the worktree — the same
disposition check chain Stage 1 uses — and branches on the answer:

- `satisfied` — the interrupted loop's committed work already met the target.
  Record `loop-released` (discovered after the fact) and proceed straight
  into the chain.
- `not-satisfied` — re-check liveness against a fresh heartbeat read. If the
  run is genuinely stale, relaunch the loop **in the same worktree** (never
  re-provision; the committed history already exists). If it is not stale,
  the run may still be live under a *different* session — report that and
  stop rather than risk a second loop running concurrently.
- A transient tree-state refusal (`uncommitted-changes`, `no-run-diff`) is
  treated as "the loop has more to do," not a terminal failure, and follows
  the same relaunch path as a stale, not-satisfied run.
- A genuine `invariant-conflict` (the contract actually changed since launch)
  or an unresolvable read halts, exactly as it would from any other stage.

Re-validating from committed state before consulting anything wall-clock- or
budget-related is itself load-bearing ordering: the chain-stage-boundary
housekeeping call can already read `budget-exhausted` by the time a stale run
is finally resumed, and running that check first would halt a run whose work
was actually already done before the resume ever discovered that fact. A
resuming session also is not the session that originally launched the loop,
so it registers itself in the wall-clock budget-session registry as part of
this stage, before branching — not after — so no branch can transfer control
out of the stage ahead of that registration landing.

The practical upshot for a future maintainer: `loop-interrupted` is what
makes the harness's "come back safely" promise honest for the flagship case
(an ordinary interruption after the loop was making progress). Anything that
touches the resume path should ask whether it preserves this: resume decides
truth from what is on disk and in the issue, never from a transcript that may
already be gone.

## The mutex/marker lifecycle

The `goal-run-inflight-{issue}` marker is the harness's mutex, and it is
enforced by ordering, not by an external lock: **the marker is always posted
before any worktree is provisioned**, so a running worktree with no matching
live marker must never exist. `Invoke-GoalRunMutexLaunch` performs this as
one sequence — post, re-fetch every live marker, tiebreak by lowest comment
id, re-confirm once after a short delay to absorb GitHub's comment-list
eventual consistency, and only then provision.

### Adopt-not-resolve for a stale or interrupted marker

Before #912, the only two marker states were "unresolved" (a run claims to be
live) and "resolved" (withdrawn or completed). A resume that found a
stale-looking marker had no state to land in that meant "I am now the one
executing this run" without destroying the mutex a live loop might still
depend on — resolving a marker under a loop that is still iterating removes
the only artifact protecting it from a second concurrent launch, and
in-loop halts post their own report while the loop keeps iterating, so a
terminal-looking artifact does not even prove the loop stopped.

The fix adds a third marker state, `adopted`, reached only through
`Set-GoalRunInflightMarkerAdopted`. Adoption is a verified mutation, not a
fire-and-forget PATCH: after writing `status: adopted` plus the adopting
session's id, the function re-reads the comment to confirm the mutation is
actually observable (not byte-identical to the pre-adoption body, and
parses back to the expected status and session id), then re-reads a second
time after a short delay to catch a same-window concurrent adopter that
raced past the first check — the same TOCTOU class `Invoke-GoalRunMutexLaunch`
already guards against for fresh launches. An adopted marker is a run still
in progress under a session, not a resolved one, and every triage read in
the harness (`Get-GoalRunInflightMarkers`, `Test-GoalRunInflightAppearsDead`)
treats `adopted` as live for exactly that reason.

### The session-identity-aware admission gate (the subtle fix)

This is the most subtle correction #912 makes, and the one most likely to be
silently reintroduced by a well-intentioned future edit.

Once `adopted` exists as a live state, a new failure mode opens: a session
adopts a marker, then crashes before provisioning the worktree ever
completes. On the next invocation, the admission gate (`Get-GoalRunInflightMarkers`
→ `Resolve-GoalRunInvocationAction`) sees exactly one live marker — its own,
already `adopted`, not `unresolved` — and nothing else. If the gate treated
"no unresolved marker" as "nothing to resume," it would fall through to
launching fresh, which would post a **brand-new** marker. Comment ids are
monotonic, so that new marker's id is always higher than the one already
held, and the mutex tiebreak (lowest id wins) means the new marker always
yields — to itself, forever. That is a deterministic self-yield livelock:
the session cannot win a mutex race against a marker it already owns,
because it just created a second one that can only lose.

The fix is that `Resolve-GoalRunInvocationAction` accepts three additional
parameters — `-MarkerStatus`, `-AdoptedBySessionId`, `-CurrentSessionId` —
and checks, ahead of every other rung including the explicit `adopt` lever,
whether the live marker is `adopted` **by this same session's own id**. When
it is, the action is `resume-own-adopted`: the invocation reuses its
already-held marker's comment id for the rest of the run and calls
`New-GoalRunWorktree` directly, skipping `Invoke-GoalRunMutexLaunch`
entirely — it must never post a second marker for a run it already holds.

The invariant a future maintainer must preserve: **any code path that can
reach an `adopted` marker state must be able to recognize "this session
already holds this marker" before it ever considers posting a new one.**
Passing `-CurrentSessionId` (or its equivalent) through to the admission
check is not optional plumbing — omitting it silently makes this rung
unreachable and reopens the livelock for exactly the crash-before-provisioning
window this fix targets.

## The two operator levers: `adopt` and `restart`

Both levers are typed as the command's explicit second argument
(`/goal-run {issue} adopt` / `/goal-run {issue} restart`) and are **never**
inferred from a halt report, harness state, or a prior conversation turn —
an operator must type the word.

**`adopt`** force-adopts a live marker ahead of both the liveness gate
(`refuse-resume-existing`) and the completion gate (`resolve-and-report-complete`).
This is deliberately the highest-precedence rung in `Resolve-GoalRunInvocationAction`
(behind only the same-session `resume-own-adopted` case above), and its blast
radius is documented rather than narrowed: invoking `adopt` against an issue
whose run already reached a terminal outcome (a halt report or PR exists, but
its marker was never resolved) relaunches the chain instead of reporting
completion. Reordering precedence to guard against this misuse was rejected
as riskier than an honest, well-documented override — check for an existing
PR or halt report before typing `adopt`.

**`restart`** is the recovery path for a run whose time budget is exhausted
or that is otherwise stuck with no other lever available. `Invoke-GoalRunRestart`
enforces three safety invariants, in this order:

1. **Never resolve or clear anything under a live run.** It re-reads the
   heartbeat first and refuses outright (`refused-live-run`) if it still
   looks fresh — clearing markers under a genuinely running loop would leave
   an unprotected worktree.
2. **Capture before clear.** Before touching any artifact, it resolves the
   worktree's branch name live from the still-intact worktree and posts a
   durable `goal-run-restart-report-{issue}` comment naming the worktree path
   and branch. Only after that report lands does it clear the
   `goal-run-stage-{issue}` marker and `goal-run-active.json` — so a
   maintainer can always recover committed work by hand even after the
   markers that would otherwise describe where to look are gone. If the
   report fails to post, nothing is cleared.
3. **Resolve the mutex only after restart has actually decided to proceed.**
   The mutex marker (`goal-run-inflight-{issue}`) is resolved in a step run
   strictly *after* `Invoke-GoalRunRestart`'s own outcome is known, and only
   on outcomes where something genuinely was cleared. An earlier ordering
   resolved the mutex *before* calling restart, which meant a restart against
   a still-live run destroyed the mutex and then refused to clear anything —
   a false all-clear with the run still live and now unprotected. The
   corrected order never lets "nothing was cleared" coexist with "the mutex
   is gone."

The worktree directory itself is never deleted by `restart` — only its
markers. The next plain `/goal-run {issue}` (no lever) resumes fresh from
`pre-loop`.

## Known residual and accepted limitations

- **Unparseable inflight-marker fields have no clearing lever (#925).** Both
  `adopt` and `restart` correctly *detect* an inflight marker whose
  `contract_hash`/`launched_at` fields cannot be parsed and return a typed
  refusal rather than throwing — but neither can *clear* that state.
  `restart` clears the stage marker and active-state file but reports
  `Found: $false` when it tries to resolve the mutex marker itself, so the
  next invocation refuses again, identically. This state is reachable only
  through a hand-edited or truncated marker comment, never through any path
  the harness itself writes — narrower than what #912 covers (recoverability
  of a corrupted artifact, not honesty about one).
- **No hard ceiling when a contract's `wall_clock` value is unparseable.**
  The goal-contract schema types `budget.wall_clock` as a free-form string
  (e.g. `"4h"`) with no enforced pattern, and the validator treats an
  unparseable value as advisory-only. `ConvertTo-GoalRunCeilingMinutes`
  returns `$null` for an absent, unparseable, or non-time value, and a
  `$null` ceiling means the wall-clock arm never fires — `budget-exhausted`
  can never trip for that run. This is an accepted, documented trade rather
  than an oversight: the alternative (silently coercing an unparseable value
  to a 0-minute ceiling) would halt every such run immediately at the first
  chain-stage boundary, which is worse than no ceiling.
- **A narrow post-launch race in the loop predicate remains unclosed by
  design (M21).** The per-iteration predicate wrapper checks the
  launch-pinned contract hash before invoking the validator, but the
  validator subprocess it invokes independently re-fetches the live contract
  a second time after that pin check passes. A contract edit landing inside
  that narrow window is a known residual risk, not eliminated.
- **One `Resolve-GoalRunResumeStage` rung is confirmed unreachable by any
  live call path today.** The rung that would resolve from a run-log
  checkpoint alone with no explicit stage marker has no durable
  worktree-path source in the current tree, because evaluating that signal
  itself already requires a resolved worktree path. If it is ever reached,
  the `loop-interrupted` stage-machine section emits an honest
  `chain-stage-failure` halt naming the gap rather than inventing an
  undefined filesystem search.
- **No budget enforcement of any kind while the vendor loop is actually
  running.** The wall-clock arm only checks at chain-stage boundaries — the
  post-loop checkpoints the Post-Loop Chain already treats as stage
  transitions — never inside the loop itself. In-loop enforcement (a Stop
  hook, a settable iteration ceiling) is explicitly out of scope; see
  HOW-IT-WORKS.md's "Budget expectations, stated honestly" for the
  reader-facing framing.
- **Arm H (headless) and Arm M (manual hand-off) are not built.** This
  harness implements only Arm I (in-session, control-return). The
  loop-to-chain seam (`New-GoalRunExecutorSessionHandle`,
  `Invoke-GoalRunLaunchChain`) is deliberately shaped from durable artifacts
  only so a future arm can populate the same shapes without rewriting the
  transition, but no further design decisions for either arm have been made.
