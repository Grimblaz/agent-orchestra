# Design: Goal-Contract Validator

**Domain**: Run-time verification for autonomous `/goal` runs against a
goal-contract plan
**Status**: Current
**Implemented in**: Issue #873 (child 3 of 5 under umbrella #848, branch
`feature/issue-873-goal-contract-validator`), implementing #848's AC3

---

## Purpose

This document records why the goal-contract validator has the shape it does,
what actually shipped, and which trade-offs were accepted rather than solved.
It is a reference for maintainers touching
`.github/scripts/lib/goal-contract-validate-core.ps1`, its thin CLI wrapper,
or the #874 harness that will consume this validator's verdict — not a
session transcript of issue #873's history. For the operational function
contract itself, read the `.NOTES` block in
`.github/scripts/lib/goal-contract-validate-core.ps1`; for the contract
artifact this validator consumes, read
[goal-contract-artifact.md](goal-contract-artifact.md). This document is the
rationale layer above both.

## What This Is

When an autonomous, budget-capped `/goal` run claims it satisfied its
goal-contract, the only evidence available today is the run's own transcript
— issue #871's platform spike ([goal-loop-platform-spike.md](goal-loop-platform-spike.md))
confirmed that the platform's built-in completion checker reads the
transcript and never independently re-executes anything. The **goal-contract
validator** closes that gap: it re-derives a run's completion claim from
committed code, independent of what the run says about itself. It is the
chain's only non-transcript verification.

The validator is a CLI entry point,
`.github/scripts/goal-contract-validate.ps1 -Issue <N> -RepoRoot <path>`,
that reads the pinned goal-contract from a GitHub issue comment, re-verifies
its approval hash, executes the contract's `targets[].check` commands and
the full Pester suite in a disposable detached worktree, and emits a JSON
verdict with an exit code. It does not launch or supervise a goal run, does
not post anything back to GitHub, and does not judge intent — only whether
the claimed outcome is reproducible from what was actually committed.

## Design Decisions

The following decisions (873-D1 through 873-D7) came out of a plan-phase
technical design section, a 5-pass adversarial plan stress test (22 of 25
findings sustained, including a CRITICAL false-GREEN gap in the plan's own
draft gate), and the implementation's own code-review and CE Gate cycles.
Citations use the `873-Dn` numbering from the issue body's Technical Design
section.

**873-D1 — Script Library Convention.**
A thin CLI wrapper (`goal-contract-validate.ps1`, entry-guard + param
declaration only) dot-sources a `-core` library
(`goal-contract-validate-core.ps1`) that holds all logic, with a paired
`.Tests.ps1` suite — the repo's standard three-file split. The wrapper's
public surface deliberately omits a `-MinTestCount` override that the core
library's `Invoke-GoalContractValidate` accepts internally only for the
fixture/test harness; a real invocation through the shipped CLI can never
weaken the D4 green-floor gate.

**873-D2 — Detached disposable worktree execution.**
Every check and the full suite run inside a `git worktree add --detach
<path> <sha>` checkout at a GUID-suffixed unique temp path outside the repo,
never in the invoking tree. A dirty invoking tree is a hard pre-worktree
refusal (`refused: uncommitted-changes`). Detached is mandatory — a branch
checkout would hard-fail if that branch is checked out elsewhere. Execution
order is fixed (suite, then checks), with a cleanliness assertion after each
phase, and teardown (`git worktree remove --force` + `git worktree prune`,
one bounded retry) runs in a `finally` regardless of outcome; on persistent
removal failure the function never throws — it returns the orphaned path so
the eventual verdict can surface it instead of losing it as a warning.

**873-D3 — Marker-pinned contract intake, no re-derivation.**
The contract-hosting comment is selected by literal marker-substring
containment against a specific `<!-- plan-issue-{ID} -->`-family marker,
never by "latest comment wins," and reads the GitHub API's JSON `body` field
directly — paginated via `gh api ... --paginate` (never `gh issue view`,
which caps at 100 comments), never console-rendered output (this repo has
documented OEM-mangling history, issue #862). Zero matches and two-or-more
matches both fail closed to refusal rather than guessing. The validator
reuses #872's parser (`Get-GCContractBlock` → `ConvertFrom-GCContractBlock`
→ `Test-GCContractHash`) with no re-derivation (872-D6). The 64-zero
placeholder digest is refused as `contract-not-approved` *before*
`Test-GCContractHash` ever runs — a draft contract's real digest is never
checked, so its refusal reason is always the placeholder reason, never a
manufactured hash-mismatch. Every `$null`-returning cause from the #872
parser (absent block, ambiguous arity, truncated block, schema violation)
fails closed to the same refusal disposition.

**873-D4 — Absolute green-floor suite gate, no flake-quench.**
An owner decision that replaced the originally-designed baseline-delta
model: any suite failure fails validation outright, there is no baseline
artifact, and there is deliberately **no retry-on-failure logic of any
kind** — any failure, flaky or not, is `fail`. The gate predicate
(`Test-GCSuiteGatePass`) requires all three of `ExitCode -eq 0`,
`TotalFailed -eq 0`, and `(TotalPassed + TotalFailed) -gt 0` — not
`TotalFailed` alone. `Invoke-PesterSharded` returns `ExitCode=1,
TotalFailed=0` on three distinct no-run shapes (tests-path-not-found,
zero-tests-discovered, and the runner's own `MinTestCount` floor), so gating
on `TotalFailed` alone would green-light a suite that never actually ran.
This was caught as a CRITICAL finding in the plan stress test and is the
single most important invariant in the file — the gate predicate is
isolated as its own pure function specifically so every false-GREEN shape is
directly unit-testable against a hand-constructed result object, without a
real Pester sub-run per case.

**873-D5 — Advisory-only test-diff-integrity signals.**
A set of heuristic flags — never gates — computed over the diff between a
pinned merge-base and the run's own commit, entirely inside the disposable
worktree: the merge-base is pinned with explicit SHAs and **no `git
fetch`** (a worktree shares the operator's own object store and
remote-tracking refs, so fetching here would mutate the operator's real repo
as a side effect — an absent ref refuses rather than fetching);
`merge-base == run-sha` refuses `no-run-diff` rather than guessing a cause;
deleted-test-file detection is rename-aware (`--diff-filter=DR
--no-renames`, so a renamed-and-gutted test file cannot evade a plain
`--diff-filter=D` check); assertion-weakening detection counts `Should`
commands via AST parsing
(`[System.Management.Automation.Language.Parser]::ParseInput`), never a
substring/regex match, which would mis-hit comments, string literals, and
unrelated `ShouldProcess`/`$PSCmdlet.ShouldProcess` calls; and the
helper-lib allowlist for the fixture/helper-modification flag is computed
live at the diff's own **merge-base** (grepping every `*.Tests.ps1` file for
dot-source references), never from the run's own — tamperable — tree state.

**873-D6 — Emit-only verdict; #874 predicate interface.**
The validator never posts anything back to GitHub — it emits a JSON verdict
and a human-readable report to stdout and exits. Exit codes are the
contract #874's harness loop will consume: `0` pass (no review needed), `1`
fail (contract not satisfied; a harness loop may iterate/retry), `2`
refused (the validator could not render a judgment at all — bad contract,
dirty tree, unauditable diff; a harness loop must hard-stop, distinct from
both pass and fail), `3` pass-review-required (environmentally accepted, but
human review is mandatory before merge — a harness loop must stop-for-review
and a PR carrying this disposition must not merge unflagged). This interface
is pinned by a field-lock test on the verdict-constructing function rather
than a committed `verdict.schema.json` — the verdict is *produced* output,
not untrusted input, so a producer test is the proportionate contract
(#872's schema guards untrusted contract input; this object doesn't need the
same treatment). Exit code `1` carries no semantic meaning beyond "not a
pass" beyond that specific mapping, because `pwsh` itself returns `1` on any
uncaught crash — every otherwise-uncaught exception in
`Invoke-GoalContractValidate`'s sequence is caught and mapped to the
infra-error pass-review-required disposition instead, so an environment
defect is never misreported as the run having actually failed.

**873-D7 — Untrusted `check` execution: process-tree kill, edit-coherence
trust.**
Each `targets[].check` string is untrusted comment-sourced data (inherited
trust framing from #872's `.NOTES`), executed inside the worktree via `pwsh
-NoProfile -NoLogo -NonInteractive -Command <check>` without sanitizing or
interpreting its content beyond that — the trust model is **edit-coherence,
not tamper-evidence** (already settled by 872-D3): execution is authorized
by deliberate operator invocation of the validator, not by any property of
the check string itself. `expected` is never parsed as a pass/fail
predicate; only the process exit code decides. Timeouts (default 300s) are
enforced with a **preemptive process-tree kill**
(`System.Diagnostics.Process` + `Kill($true)`, with a `taskkill /PID <pid>
/T /F` fallback on Windows) — never `Stop-Job`/`Wait-Job`, which does not
kill descendant OS processes and orphans grandchildren that hold worktree
file handles, breaking teardown. A blank/whitespace-only `check` refuses at
a per-target floor without spawning a process. A missing/blank `falsifier`
field adds a purely informational `falsifier-absent` advisory flag — it
never changes the target's outcome, since genuine vacuity detection is
undecidable. Executor-vs-owner identity binding for who is authorized to
trigger this execution surface is explicitly deferred to #830/#883, not
solved here.

## What Actually Shipped

**Three files** (thin-wrapper convention, 873-D1):

- `.github/scripts/goal-contract-validate.ps1` — CLI entry guard, ~85 lines.
- `.github/scripts/lib/goal-contract-validate-core.ps1` — all logic, public
  entry point `Invoke-GoalContractValidate`.
- `.github/scripts/Tests/goal-contract-validate-core.Tests.ps1` — the test
  suite.

**The public entry point's sequence** (`Invoke-GoalContractValidate`):

1. `Get-GCPinnedCommentBody` (marker-pinned, paginated, byte-safe read) —
   `$null` → refused: `contract-comment-unresolvable`.
2. `Get-GCContractBlock` (#872 parser) — `$null` → refused (873-D3).
3. `ConvertFrom-GCContractBlock` (#872 parser), wrapped in try/catch — the
   one loud throw that function raises (a missing `powershell-yaml` module)
   is caught here and mapped to the infra-error pass-review-required
   disposition, never to a plain fail.
4. Non-empty `Violations` (schema failure) → refused.
5. The 64-zero placeholder hash → refused: `contract-not-approved`, checked
   before hash comparison.
6. `Test-GCContractHash` false → refused: `contract-hash-mismatch`.
7. With every intake gate passed: `Invoke-GCWorktreeSession` creates the
   disposable worktree, then runs `Invoke-GCSuitePhase` (the D4 green
   floor), `Invoke-GCTargetChecks` (D7, every `targets[]` entry), and
   `Invoke-GCDiffIntegrityPhase` (D5) — in that fixed order, inside the same
   disposable worktree, torn down in a `finally` regardless of outcome.
8. The worktree session's and diff-integrity phase's results fold into
   `Resolve-GCVerdictDisposition` (precedence lattice: refused > fail >
   pass-review-required > pass) and assemble into the final verdict via
   `New-GCVerdictReport` — the single exit point for every return path,
   including every intake refusal above.

**Inert-render on every echoed field** (`New-GCVerdictReport`,
`Format-GCInertRender`): every piece of untrusted echoed content — target
ids, `expected`, `falsifier` prose, check stdout/stderr excerpts,
diff-derived filenames, refusal-reason prose — is stripped of `<!--`/`-->`
to a fixed point (a single-pass strip is reconstructable: `<!<!---- x
---->>` reassembles into a live marker after one pass) and wrapped in a
Markdown fenced code block one backtick longer than the longest backtick run
already present in the content, so no embedded content can close the fence
early. Stripping to a fixed point has a documented side effect: benign prose
using `-->` as a plain ASCII arrow is silently altered too; a content-free
`inert-render-altered` advisory flag on the affected target signals when
that happened, without echoing what was stripped (which would itself be a
reconstruction channel).

**Test suite**: 155 tests in
`.github/scripts/Tests/goal-contract-validate-core.Tests.ps1`, covering
intake refusal shapes, the D4 gate predicate's false-GREEN cases, D5's diff
detectors, D7's timeout/tree-kill and blank-check paths, and the D6 verdict
field-lock.

## Known Limitations

These are documented, accepted trade-offs — not omissions.

**Environmental independence only.** The validator re-verifies that the
claimed outcome reproduces from committed code in a clean environment. It
says nothing about whether the goal-contract's targets were the *right*
targets, or whether the run's stated intent matches what was actually built
— that remains the CE Gate's and the letter-vs-intent review lens's job.

**Soundness boundary.** A production regression covered by neither an
existing test nor any contract `targets[].check` is structurally invisible
to this gate — the validator has no independent production-behavior signal
beyond the existing Pester suite and the contract's own checks. The green
floor is only satisfiable where the target suite is genuinely green at the
runner version in use; the validator does not itself verify
pwsh/Pester-version compatibility between the invoking environment and the
worktree under audit.

**Diff-integrity signals are advisory heuristics, not gates.**
Count-preserving assertion weakening (e.g. `Should -Be $x` rewritten to
`Should -Not -BeNullOrEmpty`) is undetectable by AST-based `Should`-count
comparison alone, and the detector says so in its own output rather than
overclaiming coverage.

**`MinTestCount` override is unreachable from the shipped CLI.** The
override exists in the core library only so fixture suites can be exercised
in tests; the public `goal-contract-validate.ps1` surface does not declare
the parameter, so a production run cannot use it to weaken the D4 floor.

## What Review Caught

The implementation went through a 5-pass adversarial code review (18 of 21
findings sustained), a mandatory post-fix cycle, and a CE Gate pass — each
catching real defects, not just re-confirming earlier ones:

- The post-fix cycle caught a HIGH regression *introduced by one of the
  fixes*: a `RunSha` resolved after the untrusted checks phase let a check
  `git commit` inside the worktree and poison the audited commit, since a
  commit leaves `git status --porcelain` clean while moving `HEAD`.
- The CE Gate caught a HIGH defect all three prior review cycles missed: a
  falsifier presence-check used `.PSObject.Properties.Match()` against a
  `[Hashtable]`, which only enumerates the CLR type's own members (`Keys`,
  `Values`, `Count`, …) and never the hashtable's actual keys.
  `ConvertFrom-GCContractBlock`'s real parse path returns a `Hashtable`, so
  the design-mandated falsifier echo was 100% dead in production while
  `[pscustomobject]`-shaped unit fixtures kept the tests green. The fix
  (`Test-GCPropertyPresent`) is the single shared presence-check used at
  every call site that needs it.

## What's Deliberately Deferred

- **#874+** owns the goal-run harness itself: invoking this validator as
  part of a harness loop, interpreting its exit codes to decide
  iterate/retry vs. hard-stop vs. stop-for-review, and building the goal-run
  harness that launches, budgets, and halts a run in the first place.
- **#830/#883** own executor-vs-owner identity binding for who is authorized
  to trigger a validator run that executes untrusted `targets[].check`
  content — this validator's trust model (edit-coherence) assumes
  deliberate, authorized invocation and does not itself bind or verify who
  invoked it.

## Related Sources

- [goal-contract-artifact.md](goal-contract-artifact.md) — the plan-seat
  artifact (schema, parser, `frame-validate` variant branch) this validator
  consumes without re-deriving
- [goal-loop-platform-spike.md](goal-loop-platform-spike.md) — issue #871's
  platform-capability spike; the finding that the platform's own completion
  checker never independently executes anything is this validator's reason
  to exist
- [.github/scripts/lib/goal-contract-validate-core.ps1](../../.github/scripts/lib/goal-contract-validate-core.ps1)
  — the validator library, with the full function-by-function contract in
  its `.NOTES` block
- [.github/scripts/lib/goal-contract-core.ps1](../../.github/scripts/lib/goal-contract-core.ps1)
  — the #872 parser this validator reuses for contract intake
- [session-memory-contract.md](session-memory-contract.md) — the
  marker-survival vocabulary the `plan-issue-{ID}` pinning in 873-D3
  is registered against

<!-- vocab-pointer -->
> **Unfamiliar with a code or term?** Shortcodes like `SMC-NN`, `D1/D2/D3`, and `CE Gate` are defined in the [plain-language vocabulary](../../HOW-IT-WORKS.md#vocab).
