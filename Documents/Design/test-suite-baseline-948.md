<!-- markdownlint-disable-file MD041 MD003 -->

# Full local test suite: launch baseline and failure dispositions (issue #948)

Durable record for the work that restored the full local Pester suite to green.

**How to use this file**: if a test is failing and you want to know whether it was
already known-red and what was done about it, search this file for the test name shown
in the runner's `[-]` line, or for its file name. Every test that was red at the launch
baseline, and every additional failure observed while the work was in progress, has a
row in [Dispositions](#dispositions). Each row names either the change that introduced
the failure or what attribution was attempted and why it did not resolve. Nothing here
requires reading issue #948 or any session transcript.

## Two commits, deliberately different

| Name | Commit | What it is |
| --- | --- | --- |
| Attribution anchor | `35125175f4af78650034896d2d9f23f024e9b749` (2026-07-19) | The last commit with a recorded green full-suite run, recorded in issue #566's closing comment on 2026-07-20. Attribution measures *back* to here. |
| Launch baseline | `a3cc8151a6261f15e86583cc37ccab79d1c235c7` | The default-branch commit this work launched from. The failing set below was measured *here*. |

These are never the same commit. Measured at the anchor the failing set is empty by
construction, so a baseline taken there would record nothing and prove nothing.

The window between them is 14 commits.

## Launch baseline

Measured with `.github/scripts/run-pester-sharded.ps1` — the full-suite runner named as
the standard validation gate in `skills/terminal-hygiene/SKILL.md` — in a **detached
worktree** created with `git worktree add <path> a3cc815 --detach`, working tree clean
(`worktree_dirty=False` recorded for both runs).

Baseline measurement must be built this way. A `git stash` cannot prove a failure is
pre-existing, and a `git archive` extract has no repository metadata or remote and fails
a large number of tests for that reason alone.

| Run | Commit | Exit | Reported totals | Wall |
| --- | --- | --- | --- | --- |
| 1 | `a3cc815` | 1 | `pass=5529 fail=13 files=238/238` | 494.8s |
| 2 | `a3cc815` | 1 | `pass=5529 fail=13 files=238/238` | 466.8s |

The two runs are identical at per-test granularity: the same seven assertions failed in
the same six files, with the same per-file pass/fail counts. The only textual difference
between the two failure listings is the random GUID in the runner's own temp fixture
path, which is not a test.

### Reading the runner's failure count

**The reported failure count is not a count of tests.** The runner sets the count from
the failing-test total and then increments it once per test container whose result is
`Failed` (`.github/scripts/lib/pester-sharded-core.ps1`, the `Result -eq 'Failed'`
branch). One test file is one container, so every failing file contributes one phantom.
`fail=13` here is **7 failing assertions across 6 files**, plus 6 per-file artifacts.

That reconciliation is not applied blind. A crashed worker and a file that discovers zero
tests both enter the count with no failing assertion behind them, so subtracting the file
count would report "zero real failures" for either. Both shapes are read off the per-file
status line (`[NO RESULT - WORKER CRASHED]`, `[ZERO TESTS DISCOVERED]`), never derived.
Neither occurred in these runs.

`crash-worker.Tests.ps1` and `zero-tests.Tests.ps1` appear in the output and are **not**
failures of this suite. They are temporary fixtures that `run-pester-sharded.Tests.ps1`
creates to exercise the runner's own no-false-green contract. They do not exist in
`.github/scripts/Tests/`, and they appear only inside nested `files=1/1` and `files=2/2`
totals — never in the `files=238/238` total, which is this suite's real result. Counting
the failed-file list naively yields 15 rather than 13 for exactly this reason.

### The measured failing set

| # | Test file and line | Test name |
| --- | --- | --- |
| 1 | `bootstrap-antigravity.Tests.ps1:38` | `Antigravity Compatibility Bootstrap Runner Contract.Get-AntigravitySubagents.resolves exactly 16 subagents` |
| 2 | `bootstrap-antigravity.Tests.ps1:84` | `Antigravity Compatibility Bootstrap Runner Contract.CLI Wrapper Execution.wrapper executes cleanly and outputs valid JSON` |
| 3 | `claude-body-resolution-contract.Tests.ps1:113` | `Claude shell body-resolution contract.discovers exactly the 16 Claude shells covered by the body-resolution contract` |
| 4 | `claude-shell-parity.Tests.ps1:227` | `Claude shell/shared-body parity contract.requires every shared-body H2 heading to map back to exactly one shell token with matching counts` |
| 5 | `composite-skill-structure.Tests.ps1:114` | `Composite skill structure contract.requires each composite skill to enumerate every file in its references folder` |
| 6 | `copilot-sunset-skip-discipline.Tests.ps1:23` | `Copilot sunset skip discipline (#651).every -Skip annotation added for the Copilot sunset carries the #651-option1-remove token` |
| 7 | `plugin-release-hygiene.Tests.ps1:383` | `plugin release hygiene hook contract.documents the full Claude plugin CLI surface in the three required files` |

Per-file reported counts at the baseline: `bootstrap-antigravity` 3, and
`claude-body-resolution-contract`, `claude-shell-parity`, `composite-skill-structure`,
`copilot-sunset-skip-discipline`, `plugin-release-hygiene` 2 each — one real assertion
each except `bootstrap-antigravity`, which has two.

### These are not seven independent regressions

Five of the seven trace to one event. `0c8beea` (issue #874, PR #903) added the goal-run
agent — a manifest entry, a shell, a shared body, and an extracted reference file — and
tripped four separate contract tests that assert over those exact surfaces. `847ac0e`
(issue #912, PR #926) later added one more heading to the same shared body, deepening one
of them. None of the six failing files is in CI's `pester.yml` allowlist, so nothing ran
these contracts at the time.

## Dispositions

Every row states what happened to the test, why, and which change introduced the failure,
measured back to the attribution anchor. All seven attributions resolved to a named
commit; none needed the "attribution attempted and did not resolve" route.

### `bootstrap-antigravity.Tests.ps1` — `resolves exactly 16 subagents`

Now named **`resolves every subagent declared in the plugin manifest`**.

**Introduced by** `0c8beea` (issue #874, PR #903), which added `./agents/goal-run.md` to
`.claude-plugin/plugin.json`, taking the declared roster from 16 to 17.

**What happened**: the expected value is now derived from the manifest rather than
hard-coded. **Why**: the literal was a stale encoding of the claim its own `-Because`
already made — "there are exactly N specialist roles declared in the plugin
configuration". The derived form checks that claim directly, and it is strictly stronger
here, not weaker: `Get-AntigravitySubagents` silently drops a declared agent whose file
does not resolve on disk, so with 17 declared and one dropped the literal `16` would have
**passed wrongly**. See the detection enumeration below for the evidence.

### `bootstrap-antigravity.Tests.ps1` — `wrapper executes cleanly and outputs valid JSON`

**Introduced by** `0c8beea`, same cause: the emitted JSON carries one object per declared
agent, so the literal `16` went stale with the manifest.

**What happened**: same derivation from the manifest. **Why**: as above.

### `claude-body-resolution-contract.Tests.ps1` — `discovers exactly the 16 Claude shells covered by the body-resolution contract`

Now named **`discovers exactly the Claude shells covered by the body-resolution contract`**.

**Introduced by** `0c8beea`, which created `agents/goal-run.md` without registering it in
this test's `$ExpectedShells` table.

**What happened**: `goal-run` → `Goal-Run.agent.md` was added to that table, and the count
assertion now derives from the table's length. **Why**: the table, not a number, is this
test's roster of record — it already asserts shell-by-shell name equality on the next
line, and registering `goal-run` there brings the shell under the D1 byte-alignment and
`CLAUDE_PLUGIN_ROOT` assertions it had been escaping entirely.

### `claude-shell-parity.Tests.ps1` — `requires every shared-body H2 heading to map back to exactly one shell token with matching counts`

**Introduced by** two commits: `0c8beea` added the `## Post-Loop Chain` heading to
`agents/Goal-Run.agent.md`, and `847ac0e` (issue #912, PR #926) added
`## Operator Restart (#912 D6)`. The shell's enumeration paragraph was never extended, so
it listed 6 sections against the body's 8.

**What happened**: `agents/goal-run.md` now enumerates all eight sections, in body order.
**Why**: the test was correct and the shell was wrong — a shell that under-enumerates its
body silently drops two sections of methodology from what the agent is told to follow.
No assertion was touched.

### `composite-skill-structure.Tests.ps1` — `requires each composite skill to enumerate every file in its references folder`

**Introduced by** `0c8beea`, which added
`skills/customer-experience/references/goal-run-surface-classes.md` without adding it to
the skill's `## Composite References` index.

**What happened**: the reference is now indexed. **Why**: the test was correct — an
unindexed reference file is undiscoverable from the entryway, which is the whole point of
the composite structure.

**Constraint worth recording**: the same test caps that `SKILL.md` at 80 lines and it was
sitting at exactly 80. The naive one-line index entry would have turned this failure into
a different one. It was fixed at **zero net lines** by merging the two `platforms/*.md`
bullets into a single line; both pointers survive and the cap was not touched.

### `copilot-sunset-skip-discipline.Tests.ps1` — `every -Skip annotation added for the Copilot sunset carries the #651-option1-remove token`

**Introduced by** `91d2e22` (issue #893, PR #917), which added two platform-conditional
skips in `persist-marker.Tests.ps1`, then `e625d23` (issue #908, PR #937), which added
three more in `cost-walker-slug.Tests.ps1`. The guard itself dates to `ec4f66a` (issue
#651, PR #658).

**What happened**: the guard's pattern was narrowed to exclude `-Skip:` followed by a
parenthesised condition. **Why**: this was a **guard defect, not a test defect**. All five
flagged lines are platform gating of the form `-Skip:(-not $IsWindows)` — the test still
runs, on the hosts where it applies. They are not Copilot de-obligations, and the
alternative fix of adding the `#651-option1-remove` token to them would have been actively
wrong: it would enrol platform-gated tests on the Option-1 *removal* checklist, so
completing #651 would delete tests that have nothing to do with Copilot.

### `plugin-release-hygiene.Tests.ps1` — `documents the full Claude plugin CLI surface in the three required files`

**Introduced by** `bd0aa8e` (issue #920, PR #921), whose CLAUDE.md rewrite replaced the
literal command catalog with a prose pointer. `README.md` and
`skills/plugin-release-hygiene/SKILL.md` still carried all eight literals; only CLAUDE.md
lost them.

**What happened**: CLAUDE.md names all eight commands again, inline on the existing line,
keeping both pointers. **Why**: the test was correct — an agent reading CLAUDE.md alone
could not learn the CLI surface. No assertion was touched.

**Constraint worth recording**: `claudemd-diet.Tests.ps1` requires CLAUDE.md under 200
lines and it was at 198. The fix rewrote the existing line in place rather than adding
one, so the file is **still at 198**.

### `phase-containment-report.Tests.ps1` — `does not orphan a real 0-byte GetTempFileName() file when a default run bypasses the value cache`

**Not in the launch baseline** — it passed in both baseline runs. It is recorded here
under the obligation to disposition every additional failure observed at any point during
the work: it failed under the concurrent runner at this same commit during planning.

**Attribution**: not attributed to a single introducing commit, and the reason is
substantive rather than a failed search. The test is a race, not a regression — it fails
whenever any of the seven sibling workers happens to create a matching temp file inside
its snapshot window, so the "introducing" change is the arrival of concurrent temp-file
creation anywhere in a 238-file suite, not an edit to this test or its subject. Across
three measured full-suite runs at `a3cc815` it failed once and passed twice.

**What happened**: the test now redirects `TMP`/`TEMP`/`TMPDIR` to a private directory for
the duration of the probe and snapshots through `[System.IO.Path]::GetTempPath()`.
**Why**: two reasons, and the second is the more important one. It removes the cross-worker
race; and it closes a latent gap where the test watched `$env:TEMP` while the code under
test resolves its path through `GetTempPath()` — if those ever diverged, the test could not
have seen the orphan it exists to catch.

**This one was fixed even though it was green in both baseline runs**, because leaving it
would mean AC2's two green runs could be luck rather than evidence.

## The previously reported network-touching failure class

A report predating this work described roughly twenty failures including a cluster of
live-network errors from the GitHub CLI, naming `Set-IssueParent.Tests.ps1`,
`create-improvement-issue.Tests.ps1`, `marker-transport-core.Tests.ps1`, and
`persist-marker-core.Tests.ps1`.

**That class did not appear.** Evidence standard for the negative: both baseline runs
executed the complete 238-file directory at `a3cc815`, which includes all four named
files, and all four passed in both runs. The runner launches every file in its own process
and records a per-file pass/fail line, so a network failure inside any of them would have
surfaced as a failing assertion attributed to that file — the same mechanism that surfaced
the seven failures that *were* present. No `gh`-network failure appeared in either run.

This is a negative from two runs on one workstation, and a class whose defining property
is intermittency is precisely the class two runs cannot exclude. It is recorded as **not
reproduced**, not as absent. If it reappears, four seams already exist rather than needing
invention: the runner's sequential shard (`Get-RealGitFiles` in `pester-sharded-core.ps1`),
the unenforced `requires-gh` / `no-gh` tag vocabulary, the `-GhCliPath` injection parameter
already used by `create-improvement-issue.Tests.ps1`, and the fixture-backed offline mode
applied to `aggregate-review-scores.Tests.ps1` (decision D8 in
`Documents/Design/terminal-test-hygiene.md`). Whichever is chosen must make the affected
suites pass under the *concurrent* runner across repeated runs, not merely in isolation.

## Detection-reduction enumeration

Enumerated over the whole change surface, not only the test tree. The surface is: four
test files, `agents/goal-run.md`, `skills/customer-experience/SKILL.md`, `CLAUDE.md`, this
document, and the version-bump files (`plugin.json`, `.claude-plugin/plugin.json`, both
`marketplace.json` catalogs, `README.md`, `CHANGELOG.md`).

Three changes touch an assertion. Each is examined for whether it reduces the suite's
ability to detect a real regression.

**1. `bootstrap-antigravity.Tests.ps1` — literal expected count replaced by a derived one.**
Lost: the "the agent roster changed at all" alarm. Retained and strengthened: detection of
a declared agent that fails to resolve. This is a net increase, and it is demonstrated
rather than asserted — against a fixture manifest declaring two agents where only one
exists on disk, the derived assertion fails (2 declared, 1 resolved) while a literal count
matching the resolved value passes. The lost alarm is not lost from the suite: the roster
is enumerated shell-by-shell in `claude-body-resolution-contract.Tests.ps1`'s
`$ExpectedShells` table, which fails by *name* on an unregistered addition or removal —
a strictly better signal than a moved number. The assertion is not tautological, because
the resolver drops non-resolving entries silently rather than erroring.

**2. `copilot-sunset-skip-discipline.Tests.ps1` — guard pattern narrowed.**
Lost: nothing that the guard was built to catch. What no longer matches is
`-Skip:(<condition>)`, which is platform gating rather than de-obligation. Verified
discriminating against four cases: bare `-Skip {` (the form every real Copilot
de-obligation in this repository uses) still matches; unconditional `-Skip:$true` still
matches, so the de-obligation escape hatch stays closed; both parenthesised platform-gate
forms correctly do not match. A `-Skip:$someVariable` written without parentheses would
still be flagged, which is the conservative direction.

**3. `phase-containment-report.Tests.ps1` — probe directory narrowed to a private path.**
Lost: nothing. The assertion, its subject, and its failure condition are unchanged; only
the directory being watched changed, and it changed to the directory the code under test
actually writes to. A real orphan still lands inside the probe path and still fails the
test. This *increases* detection in the case where `$env:TEMP` and
`[System.IO.Path]::GetTempPath()` resolve differently, which the old form could not see.

**No test was removed, disabled, or skipped.** Confirmed arithmetically rather than by
inspection: across the affected files the passing-test count rose by exactly the number of
previously-failing assertions in each file — `bootstrap-antigravity` 14→16,
`claude-body-resolution-contract` 8→9, `claude-shell-parity` 4→5,
`composite-skill-structure` 2→3, `copilot-sunset-skip-discipline` 0→1,
`plugin-release-hygiene` 12→13, `phase-containment-report` 61→61. A removed or skipped
test would have shown up as a shortfall.

**No expected value was re-pointed at current behaviour where that behaviour is the
defect.** The four non-assertion fixes go the other way: in each, the test was correct and
the artifact was wrong, so the artifact changed. `claude-shell-parity.Tests.ps1`,
`composite-skill-structure.Tests.ps1` and `plugin-release-hygiene.Tests.ps1` are not
modified at all.

**Changes with no detection surface**: `agents/goal-run.md` (prose enumeration),
`skills/customer-experience/SKILL.md` (index line), `CLAUDE.md` (command literals restored),
this document, and the version-bump files. None contains or governs an assertion. The two
line-count caps that constrain this diff were both verified after editing: the skill file
is at 80 against a `≤80` cap, CLAUDE.md at 198 against a `<200` cap.

## How the green was verified

Two consecutive complete runs of `.github/scripts/run-pester-sharded.ps1` on the merge
candidate, each recording its commit, exit status and own totals. The run evidence is
carried in the pull request rather than here, so that this document is final *before* the
verifying runs execute — appending results afterwards would mean the tree that was
verified is not the tree that ships.

Every complete run performed on the merge-candidate tree is disclosed there, not only the
two offered as evidence.

Three specifics matter when reading that evidence, all of them ways this exact suite can
report a false green:

- The **exit status** is reported alongside the failure count, never the count alone. Four
  distinct non-failure shapes — unresolvable test path, no files discovered, total below
  the minimum-count threshold, and a determinism-check flip — produce a zero failure count
  with a non-zero exit.
- No claim rests on matching a **distinctive string** in the runner's output. A plain
  full-suite run contains a determinism-check success line and a minimum-count warning
  emitted unconditionally by the runner's own nested fixtures, so grepping for either
  matches regardless of the real outcome.
- The exit status is **not masked**. A compound shell command reports its last command's
  status, so appending anything after the run hides a failing exit; the runs are invoked
  with nothing following them on the same line.

## What this record does and does not guarantee

The restored green is a **Windows** green from one workstation. None of the six failing
files is in CI's `pester.yml` allowlist, and the large majority of `.github/scripts/Tests/`
has never been measured on Linux — so nothing outside a local full-suite run will detect
the next regression of this kind. Promoting more files into CI is issue #672; the process
rule that stops the next regression is issue #949. Neither is funded by this work.

Treat this as a snapshot, not a guarantee.
