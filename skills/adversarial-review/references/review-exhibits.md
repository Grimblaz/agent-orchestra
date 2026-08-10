# Review Lens Exhibits

Incident detail for the lenses in `skills/adversarial-review/SKILL.md` § Review Lenses. Each section below records one occurrence — the change under review, the defect a pass found in it, the artifacts and identifiers involved, and the measurements taken at the time. The actionable rules live in the lens sections that cite these exhibits; the rules live in the lens, and where a sentence here necessarily carries one it is quoted as part of the incident rather than offered as the rule.

## Contents

- [A remedy that re-enacted its own silence](#a-remedy-that-re-enacted-its-own-silence)
- [A preflight that compared the input with itself](#a-preflight-that-compared-the-input-with-itself)
- [A guard whose motivating instance was outside its population](#a-guard-whose-motivating-instance-was-outside-its-population)
- [An amendment that orphaned its own criterion](#an-amendment-that-orphaned-its-own-criterion)
- [A gate pinned by five name matches](#a-gate-pinned-by-five-name-matches)
- [An exemption keyed on a bracket](#an-exemption-keyed-on-a-bracket)
- [A predicate hardened one layer above the create](#a-predicate-hardened-one-layer-above-the-create)
- [Six of eight highs were the mechanism breaking its own property](#six-of-eight-highs-were-the-mechanism-breaking-its-own-property)

## A remedy that re-enacted its own silence

*Cited from § A remedy for a silent defect reproduces that defect inside itself.*

PR #1006 fixed #944, a defect where a malformed ledger region was silently invisible. A 5-pass panel sustained **six** findings that were the remedy reproducing the very class it closes.

The six: the guard's advisory embedded a live marker head carrying a literal id, so posting the advisory made that thread's surface unreadable. The "prose survived" preflight compared the input to a partition of the input. The collision waiver's predicate tested a *count* (`beforeWellFormed -gt 0`) where the comment beside it said *membership*. A shared "something was skipped" counter drove a message naming one specific cause, false for the other skip kind — the exact misdirection the new reason existed to prevent. One skip path was handed the whole remaining document, counting a later region's entries twice while shadowing its own. And the entry floor sat on the advisory-only guard and was absent from the reader that flips `ParseStatus`.

Green tests proved nothing: all 914 pre-existing tests passed with every one of these defects live. What made the batch trustworthy was running the new pins against the pre-fix revision and requiring red — 18 of 20 went red.

Confirmed again on #1012 (2026-08-05). After a REQUEST-CHANGES round in which 20 of 23 findings were sustained, most of safe-operations §2e was rewritten and the acceptance evidence passed. A post-fix adapter run over `git diff <pre-fix>..HEAD` then returned 16 findings, 2 of them high, both fix-introduced. The fix added a mandatory `gate_ruling_counts` field whose prescribed value (`proposed: N, approved: K, …`) is a colon-space YAML mapping indicator, while the same fix's serialization remedy scoped itself to "every **free-text** field" — a machine-generated counts string is not free text, so a conforming writer leaves it bare, bare throws at parse, and the whole marker drops. The fix also made a surface anchor mandatory while leaving §2e's own three filing recipes (Approve, Modify, queue-consumed) showing `Add-FollowUpIssue` without it. A third effect rode along: an unresolvable anchor lands in `could-not-verify`, which the same text called "not about the ruling", so a filer could suppress its own defect signal by naming a nonexistent surface.

## A preflight that compared the input with itself

*Cited from § A "nothing was lost" check assembled from a partition of its own input cannot fail.*

This was item 2 of the six on PR #1006. The preflight claimed to prove that a transform consumed nothing outside the regions it replaced. It recorded the input as prose-segments interleaved with replaced-spans, then asserted that their concatenation equalled the original.

Both lists are slices of the input, recorded under `cursor := regionEnd`. Their concatenation is the input by construction. The check never touched the output string being PATCHed. It was mutation-proved: with the transform altered so that it dropped every prose segment from its *output*, the check still passed while the written body lost the prose.

Its own comment argued that it avoided circularity — "comparing the two OUTPUTS would be circular, since anything silently dropped would be absent from both". That reasoning is correct about the opposite direction, and it is what made the tautology feel rigorous to its author and to the readers who passed over it.

The replacement carries two halves, and they catch different things: input equals partition-of-input catches a **misjudged region extent**, which the output alone cannot show; and every prose segment appearing, in order, in the output that actually gets written catches consumed or dropped content.

## A guard whose motivating instance was outside its population

*Cited from § A proposed guard has two cheap falsifiers nobody runs.*

On #1000 the whole filing rested on a single recorded failure — and that failure occurred in a GitHub issue comment during authoring, not in a tracked file. A tree-scoped grep confirmed that **no tracked file made a claim of that shape at all**, so the proposed guard would have covered a population the motivating failure was never in. The filing half-spotted this and attributed the blind spot to only one of its three candidate mechanisms; it belonged to all three.

The second falsifier was one command. `git log -S "<the exact referenced string>"` returned two commits, both of which *added* references — **zero corrections, ever**.

Both checks required searching a different scope than the one that feels natural. The first meant grepping for the claim *shape* (`highest amendment|latest amendment|...`) rather than for the referenced token; the second meant searching history rather than HEAD. A HEAD-scoped grep for the token finds all the references and makes the exposure look large, because it counts the surface and never the events.

A further fact about the register the references pointed at: #957's register held 13 entries, none renumbered, and Amendment 13 *extends* 11 rather than replacing it. The filing was parked.

## An amendment that orphaned its own criterion

*Cited from § Demoting a signal orphans whatever it was the sole producer of.*

On #922, design Amendment A1 demoted `git cherry` from conclusive to inconclusive **in both directions**, and reasoned correctly about the false-`merged` direction it was fixing. It never asked what else that signal was the only source of.

The answer: `Test-BranchTreeEquivalentToDefault`'s two content signals can only ever `return $true`. The sole `return $false` — the whole `definitively-unmerged` verdict — was the cherry branch. After A1, no git-only signal could produce a conclusive negative at all. Decision D4's "definitively-unmerged renders silently" had no constructible input; AC13, the acceptance criterion A1 itself added, was unsatisfiable; and every in-flight branch would fall onto the budget-constrained network rung and be reported — the permanent-noise state the same design rejects by name in its rejected-alternatives table.

Three prosecution lenses missed it: tree-grounding, scope-fidelity, and failure-modes. Only the convergence filter's Part (a) cold read caught it, because a lens-based sweep reads the amendment against the design and the tree, and nobody had enumerated the return values of the function being changed.

A1 also asserted that "the three existing real-git fixtures were reconstructed and do not regress". That was false: it broke two green assertions that the executor detects unmerged branches *without* a network call, because the executor's merged check short-circuits on any non-null tri-state and `$null` now falls through to a `gh` lookup.

The repair was Amendment A2.1, which establishes the negative verdict from a clean `merge-tree` whose result still *differs* from the default — positive content evidence, satisfying I-6 without reinstating patch history.

## A gate pinned by five name matches

*Cited from § A test asserting that a name appears in a script pins nothing.*

On #1018 (PR #1026) the remediation for the finding "every gate is reachable only from the test suite" was pinned by reading the script as text: `Get-Content -Raw` plus five `Should -Match` assertions on function names.

The post-fix pass replaced the gate call with `$r = [pscustomobject]@{ Allowed = $true }` and left the function name in a trailing comment. The shipped gate then returned `RESULT: allowed`, exit 0, for a second deferral of a critical entry — and all 86 tests stayed green. That is the same defect the original finding named, reproduced one level down inside its own fix.

The pin that worked invokes the entry point and asserts on `$LASTEXITCODE`. In PowerShell, `& .\s.ps1 -Args` runs the script in a child *scope*, not a child process: its `exit N` sets `$LASTEXITCODE` and the caller continues. End-to-end coverage of parameter binding, the gate call and the exit code therefore cost nothing and stayed inside the repo's script-safety contract, which forbids tests spawning a child `pwsh`.

Three mutations were run against the reworked pin and all went red: disconnecting the deferral gate (1 test), disconnecting the exit gate (7 tests), and forcing the exit code to 0 (4 tests).

## An exemption keyed on a bracket

*Cited from § Narrowing a guard by syntax instead of by meaning widens the exemption past the intended class.*

On #948 (PR #955), a `-Skip` discipline guard was producing false positives on platform-conditional skips such as `-Skip:(-not $IsWindows)`, flagging them as if they were Copilot de-obligations. The narrowing applied was `-Skip(?!:\s*\()` — exempt anything with a parenthesised condition.

The intended class was platform gates. The class the discriminator actually cut was *every* parenthesised condition, including `-Skip:($true)`, `-Skip:(1 -eq 1)`, `-Skip:(-not $false)`, and `-Skip:($env:CI -eq 'true')` — all real de-obligations that the pre-change pattern caught. One extra character, `$true` becoming `($true)`, was enough for a maintainer to retire a test off the removal checklist.

The repair keyed on meaning instead: the condition must *be* a platform predicate — `$IsWindows`, `$IsLinux`, `$IsMacOS`, optionally negated — and everything else stays in scope.

The compounding failure was in the verification, not the regex. Four cases were checked and the write-up said "Lost: nothing that the guard was built to catch." Each of those four cases *was* discriminating; that was not the defect. The defect was that the case set had been drawn from the cases already in mind, never from the class the new discriminator exempts.

Four of five prosecution passes found this independently.

## A predicate hardened one layer above the create

*Cited from § When a finding hardens a selector, follow it to the caller's zero-match branch.*

On #1031 (PR #1040), `Test-CommentBodyMarkerLine1` was hardened to reject a whitespace-only marker. `Find-OrUpsertComment`'s zero-match branch POSTs a new comment. So a whitespace-only marker went from "matches nothing" to "accretes one comment per run", silently and forever.

The documentation written alongside the hardening made it worse: `.PARAMETER Marker` stated that such a marker "is rejected outright" — a doc asserting a guard that did not exist anywhere in the code.

An external reviewer (CodeRabbit) caught it. The in-house 5-pass panel had raised the predicate half of the issue as M16 and stopped there.

Two compounding traps came with it. First, `[Parameter(Mandatory)][string]` is not the guard: it rejects `''` at binding and passes `'   '` straight through, and reaching for "the binding already validates it" is how the gap survived review. Second, the bot's proposed patch was itself broken — it inserted the guard *above* `[CmdletBinding()]` and `param()`, where it cannot run. Right finding, non-compiling fix.

## Six of eight highs were the mechanism breaking its own property

*Cited from § A mechanism built to guarantee a property fails most often by violating that property.*

On #998 the mechanism was a false-polarity review assertion plus its reader, built so that "the review ran and found nothing" could not be confused with "no review ran". **Six of eight** high-severity findings were the mechanism violating that exact property.

The reader could not parse the assertion example its own documentation printed: the pattern admitted no trailing content, so an ordinary YAML inline comment made the field read as absent, and a run copying the documented form verbatim was reported as having run no review.

CRLF bodies read as `unasserted`. The documented write path produces CRLF end to end on Windows, so the only verdict meaning *examined* was unreachable by a conforming account. The cited precedent's regex ended `[ \t]*\r?$`; the `\r?` was dropped when it was copied.

A fenced example, a YAML block scalar, or an HTML comment containing the assertion all read as a live assertion — so the account's *author* controlled the verdict through incidental prose, which is precisely the property the mechanism removed.

The absence backstop declared "nothing was examined" about units that carried a recorded review — an ingested external-review record, and the judge's own sentinel — and it was switched off by a ruling head pasted from a different unit, because it never checked the id its sibling checks.

The reader had no caller anywhere in the tree, the same shape this repo had measured emitting zero across three consecutive reviews.

The suite was 27/27 green throughout, because it used only `` `n `` and hand-written strings, so it could not fail for any of the above.
