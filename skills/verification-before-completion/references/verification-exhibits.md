# Verification Lens Exhibits

This file is the incident detail behind `skills/verification-before-completion/SKILL.md` § Verification Lenses. Each section below is cited by name from the lens named at the top of it, and carries only particulars — what happened, the measured figures, the named issues, pull requests, files, and commands, and the order events fell in. The actionable rule for each lives in its lens, not here; a reader who has already read the lens should find nothing restated below.

## Contents

- [A script that inverted on its own commit](#a-script-that-inverted-on-its-own-commit)
- [A criterion its own baseline already satisfied](#a-criterion-its-own-baseline-already-satisfied)
- [A campaign that was 22 of 22 red and nearly worthless](#a-campaign-that-was-22-of-22-red-and-nearly-worthless)
- [Four deliverables proved, 64 sub-property mutations green](#four-deliverables-proved-64-sub-property-mutations-green)
- [A control planted where the search was already strong](#a-control-planted-where-the-search-was-already-strong)
- [A window that became the evidence](#a-window-that-became-the-evidence)
- [Controls that passed while three inputs reached clean](#controls-that-passed-while-three-inputs-reached-clean)
- [A fix that never reached the population it existed for](#a-fix-that-never-reached-the-population-it-existed-for)
- [An attribution that did not reproduce](#an-attribution-that-did-not-reproduce)
- [A sweep that stayed incomplete for three rounds](#a-sweep-that-stayed-incomplete-for-three-rounds)
- [A loop that validated nothing](#a-loop-that-validated-nothing)
- [A migration that validated and counted while half-done](#a-migration-that-validated-and-counted-while-half-done)
- [A pin that was predicted backwards in both directions](#a-pin-that-was-predicted-backwards-in-both-directions)

## A script that inverted on its own commit

*Cited from § A differential script baselined on `HEAD` inverts the moment you commit.*

On #939 the differential verification script read the "before" side of every comparison with `git show HEAD:<file>`. That was correct for as long as the chunk sat uncommitted. The moment the work was committed, `HEAD` became the changed tree, so every assertion of the shape "this text was absent pre-change and is present now" was comparing the new tree against itself.

The result was 25 checks going red simultaneously. Not one of them was a real defect — the redness was entirely structural, produced by the baseline moving under the script. The loud direction is the one that fired here; the mirror case, a check written as "the defect is gone now" passing vacuously against a baseline that never carried the defect, produces no signal at all.

Repointing the script was not a one-line edit. Four separate `git show 'HEAD:` reads had to move. One of those four was the version-file loop for the plugin bump, which would otherwise have reported `pre 3.4.14 = 0 occurrences` — a number that reads as a clean result rather than as a broken comparison. The baseline was pinned to an explicit SHA, `e625d23`, with a comment on the assignment recording why `HEAD` must not be used there.

The same run surfaced the follow-on shape: a fix round needs a second baseline, the reviewed commit rather than the original base, so that each fix check asserts the defect existed at the commit the reviewer actually saw. Both were kept as named variables, `$BASE` and `$REVIEWED`.

## A criterion its own baseline already satisfied

*Cited from § Run the criterion's own discriminator against the untouched tree before you trust it.*

On #969 the acceptance criterion read: *"two corpora with identical total counts but different originating standards do not read identically… the discriminating property is that the two renders differ."* All three review lenses independently built exactly those corpora at the unmodified `HEAD` and ran the discriminator. All three got `RENDERS-DIFFER: True` with `VETO-LINES-DIFFER: False`.

The outcome was structurally guaranteed, not a near miss. Moving a row between adjudication standards changes the headline denominator (`0 of 5` becomes `0 of 6`), changes partition membership, and changes the exclusion note. All three of those sit inside "the render." So the comparison the criterion named could not have come out negative, and a run that shipped no code at all could have quoted two differing renders and closed the criterion on that.

The tell was visible in the criterion's own wording: the two "contrasting inputs" it described differed in more than the single variable under test. The correction made on #969 had two parts. First, hold the per-standard populations identical, varying only which standard holds the critical row. Second, name the compared span explicitly — the count-reporting text itself — and disqualify by name any difference in the denominator line, the partition line, or the rate lines, so that a difference arising for reasons unrelated to the work could not satisfy the criterion.

## A campaign that was 22 of 22 red and nearly worthless

*Cited from § A mutation campaign that only touches sites the suite already covers proves nothing.*

On #1018 (PR #1026) the reported evidence was a mutation campaign of 22 mutations in which each mutation turned exactly one test red — 22 of 22. That reads as strong coverage evidence.

A post-fix reviewer then ran six mutations of their own. Four of those six turned zero tests red.

The reason the first campaign came back perfect is that its mutation sites had been chosen from the code the tests were written against. It therefore measured coverage that was already known and said nothing about the rest of the deliverable.

The four sites the reviewer's mutations exposed were not obscure corners. They were: disconnecting a shipped entry point's gate call; inverting a prose table cell that the previous fix round had added; rewriting a disposition-count sentence; and flipping a tie-break comparison polarity (`-ge` against `-gt`) where neither direction had been pinned by anything.

One further particular from the first campaign is worth carrying: one of the 22 mutations did come back green, and that green was not a spare test. It was a fix masked by an unrelated fix, pinned by nothing at all. The all-red headline number had one green inside it, and that green was the only finding the campaign produced about its own evidence.

## Four deliverables proved, 64 sub-property mutations green

*Cited from § A red run at deliverable grain says nothing about the deliverable's sub-properties.*

On #973 the reported evidence was one scratch-copy red run per deliverable — among them property 5, the cold-read requirement, and the routing-call target — with all four deliverables reported as passing.

The review then mutated at sub-property grain instead and got 64 of 64 green, three separate times over. The three sub-properties that survived deletion untouched were the brief-target **scoping clause**, the **carrying-surface** sentence, and **reachability from the dispatch points**. Each was describable-but-deletable inside a deliverable that had been "proved" to hold, because each deliverable's pin asserted one salient literal — a verbatim question, a heading, an arm name — and deleting the whole deliverable removed that literal and fired the pin.

The two survivors were the most load-bearing clauses in the change. The scoping condition was precisely what #957 P1-F12 had explicitly declined to over-reach on. The carrying surface is what makes "silence is not clean" true. Both shipped unheld.

The same run produced a related trap in the reachability pin itself: the pin asserted a section's *name* against the file that *owns* that section, so the heading satisfied the `Contains` and the assertion could never fail. The correction was to assert a form only a pointer carries — the backticked `` `#### Heading` `` — and to require a count of at least 2, or else to bound the assertion outside the owning section.

## A control planted where the search was already strong

*Cited from § A witness can falsify a universal but never establish one.*

Caught live on #977 (PR #982). An audit ran three phrasings over the repository, planted a positive control of the form `$body = gh issue view ...`, watched all three phrasings flag the plant, and published "no second instance."

Review found five missed sites. Every one of them was of the form `$x = (& git ...)`. All three phrasings' regexes anchored the command immediately after the `=`, so a parenthesized capture was invisible to all three at once — and the plant had been written in the one shape every phrasing could already see. The corrected control was the thing that converted the claim into evidence: old regex returns 0 hits against it, new regex returns 1.

The same family showed up across #956's brief, where three independent prosecution lenses each found the same defect in *different* criteria. Four criteria stated universals — "no judge vocabulary anywhere", "every place that must recognise it does", "no surface other than its own", "cannot reach clean" — and each supplied a proof standard a single witness satisfies.

Two further particulars from #956. Its filter assertion needed three cases across the value domain, absent / `false` / `true`; the criterion said "did not execute" and the proof standard tested only *absent*, so an honest `convergence_filter_ran: false` routed straight to clean. And its rollup partition would, on total failure, have produced exactly the withheld sub-arm and unchanged pre-existing rates that two of three criterion clauses asked to see.

## A window that became the evidence

*Cited from § A bounded read window produces a false absence, and the window gets recorded as the evidence.*

During #968 planning, on 2026-08-01, a Pester context was read as lines 250–339 in order to inventory which refusal shapes a probe covered. One shape was listed as uncovered. The `It` block covering that shape, in both its forms, opens at line 340 — one block past where the read stopped.

A Verification Evidence row was then written citing the window `:257-338`, and the row was marked **verified**. Two of the three independent review lenses caught it. Neither was looking for that error specifically; both simply re-read the file without a window.

The artifact had recorded the window itself as the evidence. A later reader encountering a cited line range next to a `verified` tag has no reason to reopen the file, so the error was already laundered into a certification before anyone read it.

The same read produced a counting error of the same origin: the draft said ten refusal returns, there were thirteen, and all three of the missing ones sat past the window.

The directional pattern across that draft is the part that generalizes as a fact about the incident: every grounding error in it ran the same way. Each overstated the gap, and so overstated the case for the work being proposed. When a grounding claim in that draft turned out wrong, it was wrong in the direction that favored its author's conclusion.

## Controls that passed while three inputs reached clean

*Cited from § A demonstration at delivery is not a regression guard.*

#986's AC4 required a diagnostic predicate to be "demonstrably able to fail on every axis it reports," proved by three positive controls run against modified copies and recorded on the issue. The run did exactly that. The three controls passed.

The controls were a one-time manual artifact. Nothing in the tree re-ran them. The review then found three separate inputs — `- [see body](x.md)`, a `*` bullet, and an unparseable link — that already reached `RESULT: clean` against a defective index, on the very axes the recorded controls had certified as working. Each control had been planted at a point where the check was strong.

The phase-containment ledger row for that finding reads: introduced at *plan*, catchable at *plan*, caught at *code-review*. It was the only escape-distance-1 finding among that run's 29.

The corroborating detail is what happened after. The suite added in response to the finding caught three defects inside the fix round itself. One of those was a fix for an exclusive-branch bug that reintroduced the same bug in a new form and printed a false reason for it. Inspection had passed all three of those defects before the suite ran.

## A fix that never reached the population it existed for

*Cited from § Point the instrument at the real target, and build the negatives first.*

On #1018 (PR #1026), three adversarial rounds produced 52 findings across two fix cycles. Asked afterwards whether test-driven development would have prevented the rework, the honest split was roughly 15–20 of the 52 — the enumerate-the-input-space defects: unvalidated vocabularies, a pipe inside a field, no future-date guard, `ParseExact` crashes, gates failing open, exit-code contracts — and none of the criticals.

The worst finding of the second round was a fix that was correct and simply did not reach the population it existed for. Identity-keying and name-keying are the same operation when every identity is unbound, and that is true of 100% of the real store. Thirty seconds pointing the instrument at the live corpus would have shown it. That did not happen until a reviewer forced it. The fixtures in play had been shaped by the same understanding that shaped the code, so they agreed with it.

The brief's evidence obligations had already demanded a negative construction per criterion. Those were built last, so they were shaped to fit what had been written rather than to the criterion.

The expensive defects were not function-level: a design contradiction between prose and format (append-only inside a bounded region), an unconsumed producer, a cross-chunk interface with no producer at all, and a test population that never exercised the real shape. Round one's most embarrassing finding was a fully green library that no shipped entry point ever called.

Standing caveat recorded with the incident: this is n=1. Every finding annotated `introduced_phase: implementation`, `catchable_phase: implementation`, escape distance 0.

## An attribution that did not reproduce

*Cited from § An attribution that does not reproduce is a citation, not evidence.*

On #972 a verification-evidence row stated: *"repository-wide grep for `designed parent` returns ten hits across nine files; discounting two and one leaves the eight named."* Every clause in it was checkable, and the row was wrong three ways.

The grep returns 10 hits across **8** files, not nine. The arithmetic `10 − 2 − 1` is 7, not 8. And three of the eight named surfaces contain that phrase nowhere at all — they had come from a different search run earlier in the session and never recorded.

The enumeration itself was right. The derivation attached to it was reconstructed after the fact and had never been run as written. The tell is that the set could not have been produced by running what the row claimed: anyone re-running it gets a different number and either concludes the brief is wrong or silently re-derives their own set and calls that verification.

A companion failure ran in the same session. The enumeration was asserted complete twice and grew twice. It stood at 8 surfaces under two phrasings, then reached 10 when review tried `plan-variant: brief`. The test pins stood at 2, then reached 7 when review looked past the phrases originally searched. Both times the assertion of completeness was drawn from the phrases the author happened to choose.

Both errors ran in the same direction: each made the grounding look stronger and the work better-supported than it was.

## A sweep that stayed incomplete for three rounds

*Cited from § A phrasing sweep proves nothing about the population its regex cannot express.*

On #998, the AC11 completeness sweep — "no surviving rule contradicts the differential rule" — was run with five deliberately different phrasings across two path sets, diffed against the baseline tree so that neither half could be narrowed to suit the result. It still came out incomplete three separate times.

Round 1 shipped. Round 2, an internal review recorded as finding M12, found four hits: `implementation-plan.md:190`, `make-tests-pass.md:132`, and `refactor-safely.md:151` and `:153`. Round 3, CodeRabbit post-merge, found more, and a widened re-run found two beyond what CodeRabbit had named: `quality-gates.md:11`, `validate-coverage.md:13`, and `refactor-safely.md:38` and `:161`. Seven hits total, past five phrasings, over three rounds.

Both blind spots were mechanical. The first was table cells: the row `| 🥉 BASELINE | Tests Pass | JUnit | 100% | Basic correctness |` carries an absolute pass-rate gate, but a prose regex such as `all (existing )?tests (must )?pass` matches nothing in it, because the words are split across pipe-delimited columns and the threshold lives in a different cell from the noun. The second was an interposed word: `all tests **still** pass` defeats `all\s+tests\s+pass`, as do "tests continue to pass" and "all tests remain green".

One triage particular from round 3: CodeRabbit's finding pointed at `quality-gates.md:34`, which was already correct, while the real residual sat at `:11`. Dismissing on the cited line alone would have missed it.

## A loop that validated nothing

*Cited from § A verification loop that counts only failures reports green on zero checks run.*

This shape was hit twice in the same project: first in the `.psd1` load check, then in the phase-containment block validator. Both times the ad-hoc verification harness printed a confident green while checking nothing at all.

The recorded shape:

```powershell
$bad = 0
foreach ($x in $items) {
  $e = Some-Function -WrongParamName $x   # throws or returns nothing
  if (-not $e.IsValid) { $bad++ }         # throws under StrictMode
}
Write-Host "validated $($items.Count) items, invalid: $bad"   # prints "invalid: 0"
```

Under `Set-StrictMode`, referencing the unset `$e` throws. The increment never runs, so `$bad` stays at 0. The item count printed in the summary comes from `$items`, not from work actually done, so the line reads as full coverage of the full set. PowerShell's non-terminating-error default meant the loop kept going and the script still exited 0.

What made it survive both times is that the errors scrolled past *above* the summary line, and the summary line looked authoritative enough to read the red above it as noise.

This incident is recorded without an issue or PR number and without measured counts beyond the two occurrences; the memory entry carries the shape, the two sites, and the mechanism, but no figures.

## A migration that validated and counted while half-done

*Cited from § A coupled-field migration lands half-done and every count still agrees.*

A phase-containment row's `caught_stage` and its `finding_key` surface prefix have to move together. Rule 12 validates the `finding_key` pattern only and never cross-checks it against `caught_stage`, so either half-done state still validates and still counts.

The two halves fail differently. Stage moved and prefix not: the prefix gate discards every block and `BlockCount` collapses to 0. Prefix moved and stage not: the blocks count correctly and every row asserts the wrong adjudication standard, filing under the wrong rollup sub-arm.

The mechanism that split them was `[regex]::Replace($body, '(?m)^caught_stage[ \t]*:[ \t]*plan-stress-test[ \t]*$', …)`. In multiline mode `$` matches before the `\n` of a CRLF pair, and `\r` is not a member of `[ \t]`, so the anchored replace silently no-ops on a CRLF body. GitHub returns CRLF. The sibling `finding_key` replace carried no `$` anchor and applied fine.

The evidence ordering is the counterintuitive part: the Pester test caught it and the live-body probe did not. The probe normalised `\r\n` to `\n` when loading the fetched fixture, while the Pester fixture used `StringBuilder.AppendLine`, which emits CRLF on Windows. The more "realistic" evidence was the weaker one.

The count-grain check that passed over the broken state read "29 rows now say brief-review" — a corpus whose rows were all present, all parseable, all schema-valid, and invisible to every reader.

## A pin that was predicted backwards in both directions

*Cited from § A presence pin cannot resist a qualification, and its failure message ratchets against one.*

On #1032 a falsifier was written asserting that "qualifying a statement inside either suite's document set turns CI red," and that "green means only that you did not touch what the suite watches." Both were backwards, and all three `design-challenge` lenses caught it independently.

The assertions in question are `Should -Match 'ONLY documented write path'` — substring presence over whole files or extracted sections. So appending a qualification leaves them green; the pin cannot express "unqualified" and does not resist qualification at all. What turns them red is breaking the literal: bolding it, italicising a word inside it, rewording it. That is markup interposition operating one layer down from greps into assertions. The same run demonstrated the grep-level version: `git grep "only documented"` returns nothing against a file stating `the **only** documented write path`, because the bold markers close the word before the space.

The consequence worth recording is what the `-Because` message does. It reads "must preserve the X framing." A future editor who touches that prose is told by a red test to keep the absolute, and told by nothing at all to keep the qualification. That is not neutral undefendedness but active selection pressure against the remedy — which means the decision recorded as "ships undefended" had been made on a milder fact than the truth.

The procedural note attached to the incident: this error had by then been made twice, in different shapes, and reading the assertion line directly costs one command.
