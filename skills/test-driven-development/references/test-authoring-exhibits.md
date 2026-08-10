# Test-Authoring Lens Exhibits

This file is the incident detail behind the lenses in [`skills/test-driven-development/SKILL.md`](../SKILL.md) § Test-Authoring Lenses. Each section records one incident: what happened, the measured numbers, the named artifacts, and the sequence of events. The rules a reader applies live in the lens section named at the top of each entry — not here.

## Contents

- [A "safe" placement inside the pre-PR command](#a-safe-placement-inside-the-pre-pr-command)
- [A StrictMode leak that reddened 218 untouched tests](#a-strictmode-leak-that-reddened-218-untouched-tests)
- [Three CI round-trips against one dump](#three-ci-round-trips-against-one-dump)
- [A reverted rule that left 23 tests green](#a-reverted-rule-that-left-23-tests-green)
- [A docstring that named a check the body never ran](#a-docstring-that-named-a-check-the-body-never-ran)
- [A test that stamped six false records into its own run](#a-test-that-stamped-six-false-records-into-its-own-run)

## A "safe" placement inside the pre-PR command

*Cited from § Blast radius comes from what executes a path, not from what selects from it.*

Planning #1035 — measure the full test glob on Linux — needed a deliberately **non-returning** control suite, and the open question was where to put it on disk. The placement was reasoned out from `ci-suite-selection-core.ps1:149`, whose selection is `Get-ChildItem -Filter '*.Tests.ps1' -File` and therefore **non-recursive**. From that line the conclusion drawn was that a subdirectory of `.github/scripts/Tests/` was the *safest* home: the gate's glob never yields it, so it is never selected, and the quarantine registry stays untouched. Three prosecution lenses read that reasoning and did not object. A later cold read did, and it was right.

`Invoke-Pester .github/scripts/Tests/` is the documented pre-PR command, prescribed in `.github/copilot-instructions.md:106` and `.github/PULL_REQUEST_TEMPLATE.md:12`, and **Pester's directory discovery is recursive**. `pester6-baseline-core.ps1:69` hands the same directory to `$cfg.Run.Path` identically. Neither of those consumers reads `ci-quarantine.json`. So the "safe" placement would have put a suite that never returns directly into the loop every contributor runs before opening a PR, on a machine with no job ceiling to stop it. The quarantine could not have rescued an under-the-root placement either: the registry binds the gate's *selection*, not a raw directory run, so an entry would have protected CI and left every human exposed.

The set actually searched before placing was the set of *selectors* — the gate, the registration guard, and `Invoke-PesterSharded` — all non-recursive, all agreeing at 252 files that day. That agreement read as safety. The consumers that would have hung were never in the searched set. The convention that has kept this from biting so far: fixtures under that root do not carry the `.Tests.ps1` suffix. Only a location outside the tests root was actually safe.

## A StrictMode leak that reddened 218 untouched tests

*Cited from § CI selects suites by glob minus the quarantine registry, and a file-scope StrictMode in a dot-sourced library reddens the whole run.*

PR #988 replaced an allowlist with glob-minus-`.github/scripts/Tests/ci-quarantine.json` selection. Skipping a suite now means adding an entry carrying a `class` and a `reason`. The classes at ship: `unclassified` — never measured on Linux, a backlog rather than a decision, 189 entries at ship, all linked to #993; `linux-red` — measured failing on CI, an issue number required (#904, #909 are the live examples); and `never-ci` — structurally unable to run in CI (live `gh`, network, interactive terminal), permanent and legitimate. `ci-suite-registration.Tests.ps1` fails the job if any suite on disk is neither run nor listed, if an entry names a deleted file, if a reason is empty, or if the registry is missing or malformed. It is itself selected by the glob, so it cannot be dropped without dropping its own reporter.

What motivated the replacement: the old allowlist covered **52 of 243 files — 1,339 of 5,475 test blocks**. Roughly 75% of the corpus never ran in CI, including 26 properties written that same week.

The trap that nearly shipped alongside it: a file-scope `Set-StrictMode -Version Latest` in a library the workflow dot-sources. The workflow does `. lib.ps1` and then `Invoke-Pester` in the same session, so the strictness applied to every suite executed afterwards. **1432/1433 green became 1214/1433 — 218 failures**, every one of them in a subsystem the change never touched. `phase-containment-core.ps1` and `brief-review-migration-core.ps1` set StrictMode at file scope and were safe only because they are dot-sourced inside a Pester `BeforeAll`, where the blast radius is one file.

The leak was caught by extracting the workflow's own `run:` block out of `.github/workflows/pester.yml` and executing those exact bytes in a fresh process, with `Run.Exit = $true` swapped for `PassThru`. A hand-rolled local approximation had been run first and did not catch it, because it dot-sourced in a different order.

## Three CI round-trips against one dump

*Cited from § For a CI-only failure, dump the whole decision state in one run.*

On #922 a test passed on Windows and failed on the Linux runner. **Three CI round-trips** were burned adding one narrow assertion per hypothesis. Each came back clean, killing its hypothesis without pointing anywhere, and the next step under consideration was asking Micah to install WSL.

What then solved it in **one** run: a temporary block pushed to the branch that dumped everything the decision reads plus the product's own output, unconditionally, via `Write-Host` so the lines land in the log whether or not the assertion fails. The single most useful item was the product's own log line — the executor's `Skipped 'X' — <reason>` named the branch of the decision actually taken and ended the search immediately. Alongside it, every probe's exit code *and* stdout, the identity facts placed side by side, tool version and relevant config (`git --version`, `core.autocrlf`, `core.filemode`), and the mock call-log counts. Of those, `branchTip == mainTip == originMain` was the line that revealed the real cause.

Two traps surfaced in the same dump. First, a `gh.ps1` + `gh.cmd` shim pair is invisible to a bare-name `gh` invocation on Linux, so the code took its "tool unavailable" path — and every fixture *expecting a decline* still passed. Only the one fixture expecting a positive outcome failed. Second, `git cherry-pick` can reproduce the source commit's exact SHA when tree, parent, message, author and committer-second all match; the replayed commit is then the *same object*, the branch has zero unique commits, and the test silently exercises a different code path. That is a race rather than a platform difference, and a slower machine hides it. The fix forced a distinct SHA via `--no-commit` followed by a commit with a different message — patch-id is content-derived, so patch-equivalence survives.

## A reverted rule that left 23 tests green

*Cited from § A rule you cannot invoke cannot be defended, however many tests surround it.*

The exhibit is #1031, where three selectors were moved onto one shared predicate. Two of the three reddened when reverted in a scratch tree — 3 failures for the first, 1 failure for the second. The third, `cost-session-render.ps1`'s prior-degraded read, was reverted to the old unanchored match and came back **23 pass / 0 fail**, with 223 adjacent tests also green.

That third selector was the one the plan had singled out as load-bearing, precisely because it decides *whether a write happens at all*. Its retraction guard carried an additional conjunct: the cost walker must have found real events. The walker runs in a cloned runspace, so mocking it from the test's own scope never reached the code under test. No test in the repository could drive the rule, and reverting it therefore left the whole repository green — while the plan's prose describing the selectors as having "moved in lockstep" read as though the rule were defended.

The fix was not a larger or cleverer harness. The selection was **extracted into a named function, `Get-CSRPriorDegradedComment`**, which the real function then calls. Three CI-running cases now pin it, and the R4 case reddens when the rule is reverted.

## A docstring that named a check the body never ran

*Cited from § A test docstring can name a check the body never performs.*

On #975 a test was written whose docstring said it pinned that every selector in the routing table maps to exactly one mode file. The body never loaded `routing-config.json` at all — both of its assertions iterated a **hardcoded hashtable** typed out by hand in the test itself. The suite reported 14/14 green. That green proved the assertions as written, not the contract as claimed.

Four of five prosecution passes then independently found that `Use post-fix code review perspectives` was enumerated as first-class in the new loading table but had **no entry in routing-config at all**. That is exactly the defect the advertised-but-unwritten check would have caught. The overclaiming docstring and the missing entry were the same hole seen from two sides.

A second, related gap surfaced in the same run: the core-scoping test pinned that three moved sections were gone from the file but silently omitted the fourth, `## Design Review`. A re-addition of that section would have passed everything the test asserted.

The negative control that closed the run: after fixing, the pre-fix file was restored and the new tests re-run against it. All 5 new regression tests failed pre-fix and passed post-fix. One test passed in both states, and was correctly identified as covering behavior that already worked rather than as a regression guard.

## A test that stamped six false records into its own run

*Cited from § A test that fabricates hostile input can corrupt the aggregate artifact it protects.*

The instance is #958, AC3. The criterion under test was a property of the whole run's output: a full-suite run emits many attribution records, and *exactly one* of them must read `run=outer`, so that a reader can pick out the run they started.

A review-fix test set unrecognised run-depth values and then **started a run** for each of them, asserting that each reported `run=outer`. In isolation the test was correct. Inside a full suite, where that test file executes as one shard, each of those started runs stamped a *false* `run=outer` record into the enclosing run's output. The census of matching records went from 1 to **6**. The suite itself was **26/26 green** throughout.

A second, subtler defect landed in the same commit. Another test's fixture **directory was named** after the record prefix, in order to test forgery neutralisation. Pester echoes the path of every file it runs, so the fixture injected a record-shaped string into the log — the exact reading hazard the criterion exists to remove — from a line the product code never emitted.

Both defects were invisible at 26/26 green and both appeared instantly in a full-run census, `grep -c 'RUN ATTRIBUTION  run=outer'`. The remedies taken were to resolve the adversarial cases through the pure helper, which emits nothing, and to keep only end-to-end cases whose output is indistinguishable from a legitimate participant — in #958's case, a value resolving to `nested` and never to `outer`.
