---
name: verification-before-completion
description: "Evidence-based verification checklist before marking work complete. Use before PRs, releases, marking tickets done, or any \"I'm finished\" declaration; also when naming a baseline commit for a differential suite claim, when designing a mutation campaign or red-run evidence, when making an absence claim, a universal claim, or a one-time demonstration offered as a standing guarantee, when attributing a measurement or claiming a sweep or verification loop is complete, and when stating what a check or a CI suite will do about a change. DO NOT USE FOR: post-merge cleanup or archival (use post-pr-review) or processing GitHub review comments (use code-review-intake)."
---

# Verification Before Completion

Systematic verification process to ensure work is truly complete.

## When to Use

- Before creating a pull request
- Before marking a ticket/issue as done
- Before declaring a feature complete
- Before releases or deployments
- Anytime you think "I'm done"

## Composite References

- [references/completion-account.md](references/completion-account.md): the completion account's procedure — baseline-commit constraint, marker family and write primitive, the `adversarial_review_ran` assertion and its reader, the rejection list, pre-existing-failure routing, and the external-review trigger
- [references/verification-exhibits.md](references/verification-exhibits.md): the incident detail behind § Verification Lenses — measured numbers, named artifacts, and the failure sequences each lens was extracted from

## Core Principle

> **Iron Law**: Claims do not count as completion—only evidence does.
>
> "Done" means verified, not just implemented.

The gap between "I wrote the code" and "it works correctly" is where bugs hide.

If evidence is missing, the work is not complete yet.

**And evidence that could not have come out negative is missing evidence.** A proof that would read exactly the same against the unchanged tree tells you nothing about the change; it is a claim wearing evidence's clothes. The three properties every offered proof must carry — discriminating, attributed, per-criterion — are defined once under [Evidence Obligations](#evidence-obligations), and every checklist item and table row below **that prescribes or accepts proof** carries them in place. Sections that check something other than proof — code quality, integration, documentation, release and demo readiness — are unchanged and carry no such obligation. The *form* the proof takes is always your choice.

## The Completion Account

The checklists below govern whether each acceptance criterion has evidence behind it. They do not govern what sits *outside* the criteria — whether the mandatory adversarial review ran, what state the run left the suite in. A run can therefore report accurately on everything it was told to care about and still owe a review nobody records as outstanding. That gap is what this section closes.

Five properties hold of a run **declaring itself done** — the act, not a lane and not every run. They are restated in full here rather than pointed at, because this skill is served to consumer repositories that never receive this repository's root guidance file: for those runs, this section is the *only* place the properties exist.

1. **The review is accounted for.** Every finding the adversarial review produced traces to an outcome that survived the judge — a fix commit, or a dismissal with its reason.
2. **A review that ran and found nothing says so, in words that would be false if it had not run.** Silence is never readable as examined-and-clean. This is what stops property 1 being vacuously true over an empty finding set: a run that dispatched no review produces no findings, so it satisfies property 1 by doing nothing.
3. **The suite's state is stated differentially** — what this change added, against a named baseline commit **that predates the change** — **and, separately, pre-existing failures are named and routed** rather than blocking the work or vanishing from the account. Two obligations, not one, so a run that added a failure cannot read a single clause as broadly satisfied. The baseline may never be the run's own post-change commit; that reading satisfies every clause while checking nothing.
4. **A fix that closes a finding is itself re-validated before the account closes.** A fix cycle is never itself the completion signal.
5. **A stopped run reads as stopped** — in the lane's typed halt-report shape, never free prose that a reader could mistake for completion.

In this repository they are also stated in `CLAUDE.md` § What a finished run is true of, which is read live at session start. The two copies are one statement and must move together — a parity test pins them, because an unpinned "they move together" claim is the two-surfaces-disagreeing shape this file's own differential rule exists to prevent, and the first draft's copies had already diverged by the time they shipped.

**How** a run makes each property true is its own choice. Three things are not: the account exists, it outlives the session that wrote it, and it carries a review assertion that would read false had no review run.

The procedure behind those properties — **which commit may be named as the baseline**, where the account is written and with which primitive, the required `adversarial_review_ran` assertion and the reader that acts on it, what the guidance rejects, how a pre-existing failure is routed, and the external-review trigger — is [references/completion-account.md](references/completion-account.md). The properties above are the statement; that file is only their elaboration, and it restates none of them.

Two rules from it are load-bearing often enough to name here rather than behind the citation, because a run that never opens the reference still has to get them right:

- **The named baseline must be an ancestor of the work being declared done** — never the run's own post-change `HEAD`, which makes every failure "pre-existing" and property 3 vacuous.
- **The account MUST carry the review assertion**, in this form:

```yaml
adversarial_review_ran: true    # or false
```

- **Absence of that field is not a third polarity.** An account omitting `adversarial_review_ran` reads as *not run*, never as examined-and-clean. The example above stays in this entryway rather than moving behind the citation: `completion-finish-line.Tests.ps1` reads it from **this live file** on purpose, so that the reader and the documentation cannot drift apart — a fixture holding its own copy of the example is exactly the defect that assertion was written for.

## Universal Verification Checklist

### 1. Requirements Verification

- [ ] Re-read the original requirements/ticket
- [ ] All acceptance criteria explicitly met
- [ ] **Each** acceptance criterion has its own evidence — one aggregate green does not cover several criteria at once
- [ ] For each criterion, you can name the result that would have shown it *unmet* — and that result did not occur
- [ ] Edge cases identified and handled
- [ ] No scope creep (didn't add unrequested features)
- [ ] No scope miss (didn't forget requested features)

### 2. Code Quality Verification

- [ ] Code compiles/runs without errors
- [ ] No new warnings introduced
- [ ] Linter passes with no new issues
- [ ] Follows project code style
- [ ] No debug code left (console.log, TODO hacks)

### 3. Testing Verification

- [ ] Suite state stated **differentially** — what this change *added*, measured against a named baseline commit **that is an ancestor of this work** (branch point or merge base, never your own post-change commit) — not whether the suite is absolutely green
- [ ] Every failure present at that baseline and still present now is **named and routed** (filed, or queued as a proposal where the run has no interactive surface), never silently carried and never treated as this change's blocker
- [ ] New tests written for new code
- [ ] **Every test offered as evidence for a criterion proven able to fail** — run against the pre-change code (stash, prior commit, reverted patch) and observed red, or otherwise shown to go red without the fix
- [ ] Any test that would pass identically against the pre-change tree is identified as such — a characterization test, a regression guard, a test added alongside a refactor. Those are legitimate and worth keeping; they are simply not evidence that this change did anything, and are not offered as proof of a criterion
- [ ] No test computes its expected value using the thing under test
- [ ] Tests cover happy path
- [ ] Tests cover error/edge cases
- [ ] Manual testing performed in realistic environment — and you can say what the same steps produced *before* the change

### 4. Integration Verification

- [ ] Works with rest of system (not just in isolation)
- [ ] Database migrations work (up AND down)
- [ ] API contracts honored
- [ ] No breaking changes to dependents
- [ ] Feature flags configured if needed

### 5. Documentation Verification

- [ ] Code comments for complex logic
- [ ] README updated if needed
- [ ] API documentation updated
- [ ] Changelog entry added
- [ ] Migration/upgrade notes if needed

## Quick Verification Commands

```bash
[CUSTOMIZE] Add your project's verification commands:

# Run all checks
[your-verify-command]

# Individual checks
[your-lint-command]   # Static analysis
[your-test-command]   # Unit tests
[your-integration-command] # Integration tests
[your-build-command]  # Ensure it builds
```

These commands establish that the tree is healthy. They are **not** per-criterion evidence: a whole-suite green is one aggregate result, and if the suite was already green before the change it is also the same green you would have got by changing nothing. To turn a run into evidence for a criterion, scope it to the tests that exercise that criterion and pair it with the run where they failed. A suite that was genuinely red before and is green now already is that pairing — say which tests moved and at which commit, and it becomes per-criterion evidence.

## Context-Specific Checklists

### Before Pull Request

- [ ] Branch is up to date with target
- [ ] Commit messages are clear
- [ ] PR description explains the change
- [ ] Screenshots/videos if UI change — before **and** after, so the difference is visible
- [ ] Per-criterion evidence in the PR description, each item saying what could have failed and where it came from
- [ ] Reviewers assigned
- [ ] Labels/tags applied

After the PR is open — and before declaring done — read what the reviewers actually posted ([references/completion-account.md](references/completion-account.md) § External review on the pull request). Findings arrive minutes after the PR opens, not at the moment you finish writing it.

### Before Release

- [ ] All PRs merged and verified
- [ ] Release notes complete
- [ ] Version numbers updated
- [ ] Rollback plan documented
- [ ] Stakeholders notified
- [ ] Monitoring alerts configured

### Before Demo

- [ ] Feature works end-to-end
- [ ] Test data is realistic
- [ ] Environment is stable
- [ ] Backup demo path ready
- [ ] Talking points prepared

## Evidence Collection

Don't just check boxes—collect evidence:

### Evidence Obligations

Three properties, fixed. The **format is yours to choose** — offer whatever best demonstrates the criterion — but whatever you choose must carry all three:

- **Discriminating** — it could have come out negative. There is a state of the world, reachable by this codebase, in which this evidence would have shown failure. Note what this does *not* say: it is about whether the check could have failed, not about whether its result changed.
  - For a **change criterion** — the work makes something new true — the sharpest form is a pairing: the same check red before and green after. Here a result identical to the pre-change tree is not discriminating, no matter how detailed.
  - For a **preservation criterion** — the work must leave something true: a refactor, a backward-compatibility guarantee, "no breaking changes to dependents" — invariance *is* the result you want, and the check is discriminating as long as it would have caught the breakage. Say what it would have caught, or show it going red once against a deliberately broken version. A parity run is real evidence; a parity run nobody has ever seen fail is not.
- **Attributed** — it says where it came from. What ran, against what, how many, at which commit. "28 of 30 enumerable project directories" and "3,792 randomized paths compared against a reference implementation" are attributed; "the tests pass" and "verified locally" are not.
- **Per-criterion** — it maps to one acceptance criterion. A single suite-wide green offered against every criterion at once tells you the suite is green, and nothing about which criteria are met.

A note on the second and third: attribution and scoping are what make discrimination *checkable by someone else*. A reviewer who cannot tell what ran cannot tell whether it could have failed.

### Acceptable Evidence

Each form below is acceptable **only when it carries all three obligations above**. That gate governs every entry: a form that satisfies its own qualifier but fails *discriminating*, *attributed*, or *per-criterion* is not acceptable. The qualifiers below supply whichever property the bare form most often omits — usually the discriminating half, but for the counted-measurement entry it is attribution, and that entry still has to be discriminating on its own account.

- ✅ Screenshot of passing tests — paired with the same tests failing before the change, and naming the commit or working state each was taken at
- ✅ Link to successful CI/CD run — paired with the run, commit, or job where the same checks failed without the fix; a green run on its own shows the suite is green, not that the change did anything
- ✅ Screen recording of feature working — showing the behavior that was broken or absent beforehand, not a working feature that also worked yesterday
- ✅ Query results showing correct data — with the before-state alongside, naming the query and the dataset it ran against
- ✅ Logs showing expected behavior — including the line that was absent or wrong before, and naming the run they came from
- ✅ A differential: the same input through the old and new paths, with the outputs that differ
- ✅ A counted measurement over a named population — how many, out of what, and how the population was enumerated, **plus the count the same measurement returned before the change**; a count that was already at its target proves nothing
- ✅ For a guidance or documentation change: a concrete artifact the old text accepted, shown being rejected by the new text — never the mere presence of the new wording

### Insufficient Evidence

The first four object to vagueness, staleness, and unverified assumption. Of the rest, most object to **non-discrimination** — proof that could not have come out negative — and two do not: the aggregate-green entry is a *per-criterion* objection, and the no-population entry is an *attribution* objection. Each entry names which property it fails.

- ❌ "I tested it locally" (no proof)
- ❌ "It worked yesterday" (not now)
- ❌ "The tests pass" (which tests?)
- ❌ "I didn't change that" (verify anyway)
- ❌ A green suite that was equally green before the change, offered for a criterion claiming something *new* is true (nothing there could have failed). Not this: the same run offered for a **preservation** criterion, where invariance is the point — that is acceptable once you say what the check would have caught
- ❌ A new test that passes against the pre-change code (it proves the code loads, not that the change did anything)
- ❌ A test whose expected value is computed by the function under test (it agrees with itself under every implementation)
- ❌ One aggregate green offered against several acceptance criteria at once (not per-criterion)
- ❌ Evidence that the change is *present* offered as evidence that it is *sufficient* — a diff, a field that was added, a term that now appears in a document
- ❌ A number with no population behind it — "most cases", "all the ones I checked" (not attributed)
- ❌ A consistency check that passes when nothing moved (agreement across locations is not the same as change)

## Verification Lenses

> **Authoritative source**: which lessons are promoted here, what anchor each one lives at, and the trigger text that has to reach a reader are recorded in `Documents/Planning/lesson-promotion-manifest.json`. `.github/scripts/Tests/lesson-promotion-manifest.Tests.ps1` is what stops this section and that manifest drifting apart, and it is the suite a red comes from. **Renaming a heading below is a migration, not a regression** — update that lesson's `anchor` in the manifest in the same commit as the rename. A red naming an anchor you just renamed is reporting a manifest row left behind, not a lost lens.

Fourteen ways verification evidence passes while proving nothing. Every one is an escape from this repository's own review record, and every one survived the checklists above — a checklist asks whether you produced evidence, and these ask whether the evidence could ever have come out negative.

**How this section grows, corrected — the note that stood here pointed the wrong way.** It said a tenth lens does not fit and that the remedy was to move this section to a `references/` file. That remedy is the one extraction the standing check forbids: `lesson-promotion-core.ps1` reds a `kind: lens` whose home is a `references/` path, because a lens that stops loading has been archived rather than promoted. The extraction that creates room is the **inverse** — reference-shaped procedure moves out and the lenses stay, which is what § The Completion Account did to reach [references/completion-account.md](references/completion-account.md). Room for a lens comes from moving its *incident detail* into an exhibit and citing it, never from moving the lens.

### When you are naming a baseline commit for a differential suite claim

#### A baseline that is not an ancestor makes the differential rule vacuous

Stated in full at [references/completion-account.md](references/completion-account.md) § Which commit may be named as the baseline and in `CLAUDE.md` § What a finished run is true of, property 3 — read the rule there rather than re-deriving it here. **This lens is rule-only** — the one entry in the promotion roster with no exhibit of its own, and the reason is recorded here rather than left implicit: its incident detail is already shipped doctrine at the two surfaces above, so a second copy would be the restatement the cite-don't-restate rule forbids. What this lens adds is the generalisation those two do not make: **the same hole opens wherever an absolute threshold is replaced by a relative one**. Whenever you write a relative rule, ask who picks the reference point and what stops them picking one that makes the comparison trivial.

#### A differential script baselined on `HEAD` inverts the moment you commit

A verification script that reads the "before" side with `git show HEAD:<file>` is correct only until the work is committed. After that, `HEAD` *is* the changed tree, so every "this text was absent pre-change and is present now" assertion compares the new tree against itself. The loud direction is a false red — 25 checks went red at once on #939 that way. The dangerous direction is silent: a check written as "the defect is *gone* now" passes vacuously against a baseline that never had it. Pin the base to an explicit SHA in a named variable, say in a comment why it is pinned, and grep for **every** `git show HEAD:` when repointing — one missed read is enough. A fix round needs a second pinned baseline too: the reviewed commit, so each fix check asserts the defect existed at the commit the reviewer saw. Exhibit: [references/verification-exhibits.md](references/verification-exhibits.md) § A script that inverted on its own commit.

#### Run the criterion's own discriminator against the untouched tree before you trust it

A proof standard goes vacuous the same way a test does. Before shipping a criterion that says "X and Y differ", build X and Y at the **unmodified** baseline and confirm the comparison comes out negative. On #969 it did not: all three review lenses built the criterion's own two corpora at unmodified `HEAD` and got the difference the criterion demanded, because the two inputs differed in more than the one variable under test — the denominator, the partition membership, and the exclusion note all moved too. The tell is exactly that: **what else differs between X and Y for reasons unrelated to the work?** If anything does, the criterion is measuring that instead. Hold everything constant except the property being discriminated, and name the span being compared. Exhibit: [references/verification-exhibits.md](references/verification-exhibits.md) § A criterion its own baseline already satisfied.

### When you are designing a mutation campaign or red-run evidence

#### A mutation campaign that only touches sites the suite already covers proves nothing

"22 mutations, each turns exactly one test red" reads as strong evidence and can be almost worthless. On #1018 that campaign came back 22 of 22 red, and a reviewer running **six** mutations found **four** that turned *zero* tests red — because the sites had been chosen, unconsciously, from the code the tests were written against. Pick sites from the **deliverable**, not from the test file: enumerate what ships, then ask which of it any test would notice changing. Mutate **both** polarities of every comparison you introduced, not just "remove the guard". Mutate the **prose** when the prose is the deliverable, and mutate rows a *later* fix added rather than only those present when the pins were written. An all-red campaign is the floor, not the verdict — state how the sites were chosen. And a mutation that comes back **green is a finding about the evidence**, never one that "did not apply": it reports that something ships which no assertion holds, which is the most informative result the campaign can produce. Record it against the check rather than dropping it as inapplicable. Exhibit: [references/verification-exhibits.md](references/verification-exhibits.md) § A campaign that was 22 of 22 red and nearly worthless.

#### A red run at deliverable grain says nothing about the deliverable's sub-properties

Deleting a whole deliverable in a scratch copy removes the one salient literal its pin asserts, so the pin fires and the red run looks conclusive. Its *other* claims — what it is conditioned on, where its output lands, who can reach it — were never separately asserted, so each stays independently deletable. On #973 four deliverables "proved" held, and mutation at sub-property grain came back 64 of 64 green three times over. **Enumerate the claims a criterion makes, not the features it adds, and mutate once per claim**: if only this clause vanished, which assertion goes red? Two shapes always worth mutating separately — a conditioning clause ("when the target is X"), whose deletion silently widens scope, and a named landing surface ("the answer lands in Y"), whose deletion sends the output nowhere while every other pin stays green. Exhibit: [references/verification-exhibits.md](references/verification-exhibits.md) § Four deliverables proved, 64 sub-property mutations green.

### When you are making an absence claim, a universal claim, or a one-time demonstration offered as a standing guarantee

#### A witness can falsify a universal but never establish one

Proof standards get derived by asking what a convincing *demonstration* would look like. That instinct is right for existentials and wrong for universals, and an executor grades against the proof standard — so a criterion stating "no X anywhere" with a one-fixture proof standard is passable by a run that built one fixture. Partition criteria by logical form **before** writing any proof standard. Existential claims take demonstration-shaped proof. Universal claims take a **standing check that executes the quantifier on every run**, not the transcript of it holding once. Value-domain claims are exercised over the whole domain — absent, `false` and `true` are three cases, and a standard testing only *absent* rewards the scrupulous run and catches only the omitting one.

And every absence claim ships a **planted positive control, planted where the search is weakest**. "No X found" and "nothing looked for X" are the same evidence otherwise — but a plant in the shape the search was built around only proves the search can return *something*. On #977 an audit ran three phrasings, planted a positive of the form the phrasings were written for, saw all three flag it, and published "no second instance"; review then found five missed sites, all of a shape every phrasing's regex was structurally blind to. Before planting, ask: **what shape would my search miss, and is that what I am about to plant?** Exhibit: [references/verification-exhibits.md](references/verification-exhibits.md) § A control planted where the search was already strong.

#### A bounded read window produces a false absence, and the window gets recorded as the evidence

`Read` with `offset`/`limit` bounds the evidence, not the question; nothing in the output says "the window ended here." On #968 a context read as lines 250–339 produced an "uncovered" finding whose covering block opens at line **340**, and the resulting evidence row cited the window and was tagged verified — the error laundered into a certification before any reviewer saw it. For an **absence** claim, never bound the read: grep the whole file, or the whole tree. Counting claims need a mechanical count over the full span, not an eyeball over a window. And note the directional tell, which is the real lesson: grounding errors run in the direction that favours the conclusion you are arguing for, so audit absence claims for that bias specifically. Exhibit: [references/verification-exhibits.md](references/verification-exhibits.md) § A window that became the evidence.

#### A demonstration at delivery is not a regression guard

*"Run controls at delivery and record the output"* buys one dated observation, satisfiable by a transcript — and the property it certifies starts decaying the moment the criterion is satisfied, with no signal. *"Ship a regression guard that exercises each axis against a modified copy"* buys the property over time and costs barely more to write. On #986 the delivery controls passed and review then found three inputs already reaching `clean` on a defective index, on the very axes those controls had certified — because each control had been planted where the check was strong. Ask at criterion-authoring time: **after this run ends, what re-checks this?** If the answer is "a person re-reading an issue comment", the criterion bought a demo, not a guard. This is a *plan*-phase fix, not a review-phase one: a criterion is what the executor builds to. Exhibit: [references/verification-exhibits.md](references/verification-exhibits.md) § Controls that passed while three inputs reached clean.

#### Point the instrument at the real target, and build the negatives first

Two checks that beat unit-level test-first at catching the expensive defects, because their unit is a population and a specification rather than a function. **Run it against the real target on day one**: fixtures are shaped by the same understanding that shaped the code, so they agree with it. On #1018 a fix was correct and never reached the population it existed for — identity-keying and name-keying are the same operation when every identity is unbound, which is true of 100% of the live corpus, and thirty seconds pointing the instrument at that corpus would have shown it. **Build each acceptance criterion's negative construction before the implementation**: built last, negatives get shaped to fit what you wrote rather than to the criterion. Standing caveat — this is one session's evidence; the phase-containment ledger is the instrument for whether it is systemic, and no lane changes on n=1. Exhibit: [references/verification-exhibits.md](references/verification-exhibits.md) § A fix that never reached the population it existed for.

### When you are attributing a measurement, or claiming a sweep or verification loop is complete

#### An attribution that does not reproduce is a citation, not evidence

The *attributed* obligation is not "name a method" — it is **name a method that reproduces**. Before writing a provenance line, run the exact command you are about to claim and check the numbers come out; the failure mode is a derivation reconstructed after the fact, whose clauses are each individually checkable and collectively never executed, so anyone re-running it gets a different set and either calls the brief wrong or silently substitutes their own. The companion half is the completeness claim riding on it: an enumeration is only ever complete with respect to **the phrasings you happened to choose**, so state such a count as a **floor**, write the criterion over the claim rather than over the list, and require the next reader to try a phrasing you did not. Worked numbers in [references/verification-exhibits.md](references/verification-exhibits.md) § An attribution that did not reproduce.

#### A phrasing sweep proves nothing about the population its regex cannot express

A completeness sweep run with several deliberately different phrasings, diffed against a baseline tree so neither half can be narrowed to suit the result, is still bounded by what its patterns can *reach*. Ask what shapes the regex is structurally blind to, not what synonyms you forgot. Three recur: **table cells**, where the noun and its threshold sit in different pipe-delimited columns and no prose pattern spans them; **an interposed word**, where `all tests **still** pass` defeats `all\s+tests\s+pass`, so allow a bounded gap; and any construction separating subject from predicate. And when a reviewer cites a line that is already correct, check the **file**, not the line — the real residual usually sits elsewhere in it. Detail in [references/verification-exhibits.md](references/verification-exhibits.md) § A sweep that stayed incomplete for three rounds.

#### A verification loop that counts only failures reports green on zero checks run

Absence of failures and absence of checks are indistinguishable when the only assertion is a zero count. A loop that increments `$bad` on the failure path and prints `"validated N items, invalid: 0"` prints exactly that when every iteration threw — the `N` comes from the input list, not from work done, and under `Set-StrictMode` a wrong parameter name makes the increment unreachable while the script still exits 0. Every verification loop asserts a **positive** count (`ok -eq total -and ok -gt 0`), increments on the success path, and sets `$ErrorActionPreference = 'Stop'` so a binding error aborts rather than silently skipping. When a harness prints green immediately after a wall of red, treat the green as the suspect. See [references/verification-exhibits.md](references/verification-exhibits.md) § A loop that validated nothing.

#### A coupled-field migration lands half-done and every count still agrees

When a migration must rewrite two fields that only mean anything together, a count-grain post-check passes on either half-done state: the corpus is all present, all parseable, all schema-valid, and asserting the wrong thing. Assert **each half separately** and **re-parse** rather than recount — a recount ("29 rows now say X") is satisfied by a corpus no reader can use. The mechanism that splits the halves is usually smaller than the migration: an anchored `(?m)…[ \t]*$` replace silently no-ops on a CRLF body because `$` matches before the `\n` and `\r` is not in `[ \t]`, while its unanchored sibling applies fine. Write `[ \t]*\r?$`. And note which evidence was weaker: the "more realistic" live-body probe normalised the line endings away, so only the fixture reproduced it. Exhibit: [references/verification-exhibits.md](references/verification-exhibits.md) § A migration that validated and counted while half-done.

### When you are stating what a check or a CI suite will do

#### A presence pin cannot resist a qualification, and its failure message ratchets against one

Never write what a check will do without opening it — `sed -n` the assertion line first. A `Should -Match 'some phrase'` is a **presence** pin over a file or an extracted section, so **appending a qualification leaves it green**: the assertion cannot express "unqualified", only that the phrase is somewhere in the text. What turns it red is breaking the literal — bolding it, italicising a word inside it, rewording — which is markup interposition one layer down from the grep problem above. The consequence worth carrying: a presence pin whose `-Because` message says *"must preserve the X framing"* is a **one-way ratchet**, telling a future editor by a red test to keep the absolute and telling them nothing at all to keep the qualification. So when a plan records that a qualification "ships undefended", ask whether the guard is *absent* or *adversarial* — those are different records and only one is what a design usually means. Worked case in [references/verification-exhibits.md](references/verification-exhibits.md) § A pin that was predicted backwards in both directions.

## Verification Log Template

One block per acceptance criterion — the block structure is what makes the evidence *per-criterion*. Within each block, "Could have failed" carries *discriminating* and "Provenance" carries *attributed*; "Proof offered" is the evidence itself, not an obligation. A criterion whose "Could have failed" line is empty has no evidence yet.

The "Verified by" and "Date" fields at the end attribute the **log**, not the evidence — each criterion still carries its own provenance line.

The suite-health block's first three lines are where the differential rule becomes readable to a run filling this artifact out. A block reporting only an absolute result — a CI link, a green run, a pass count — is **incomplete**: it leaves the baseline commit unnamed, so nothing in it distinguishes a failure this change caused from one it inherited.

```markdown
## Verification: [Ticket/Feature ID]

### Criterion 1: [restate the criterion]

- Proof offered: [whatever form you chose]
- Could have failed: [the negative result that was reachable, and what was
  observed instead — e.g. "red at abc123 before the fix, green at def456 after"]
- Provenance: [what ran, against what, how many, at which commit]

### Criterion 2: [restate the criterion]

- Proof offered:
- Could have failed:
- Provenance:

### Suite health (not per-criterion evidence)

- Baseline commit: [an ANCESTOR of this work — the branch point or merge base.
  Never this run's own post-change commit: that makes every failure
  "pre-existing" and the differential vacuous]
- Failures at baseline: [count, and where each is named/routed — "none" is a
  result, an empty line is not]
- Failures this change added: [count; the differential, not the absolute]
- Unit tests: [Link to CI run]
- Integration: [Link or screenshot]
- Manual: [Description of what tested]

### Notes

- [Any caveats or known limitations]
- [Any criterion whose evidence is weaker than the three obligations require,
  named here rather than left for the reviewer to notice]

Verified by: [Name]
Date: [Date]
```

## Common "Almost Done" Traps

| Trap                        | Reality Check                                                       |
| --------------------------- | ------------------------------------------------------------------- |
| "Works on my machine"       | Did you test in CI/staging?                                          |
| "Just needs review"         | Did YOU review it first?                                             |
| "Tests pass"                | Do tests cover the change — and were they ever red without it?       |
| "Same as before"            | Did you verify it still works?                                       |
| "Simple change"             | Simple changes cause outages                                         |
| "Just a refactor"           | Refactors can change behavior                                        |
| "I added a test"            | Would it have failed before the fix? Run it against the old code.    |
| "The green run proves it"   | Was it green before the change too?                                  |
| "The doc now says it"       | Text presence is not behavior — what does the guidance reject now that it accepted before? |
| "The numbers look right"    | Out of what population, enumerated how?                              |
| "The suite is red anyway"   | Red against *what*? Name the baseline commit and say which failures are yours |
| "The review found nothing"  | Did a review run? An account that omits the assertion reads as *not run* |
| "The fix is committed"      | A fix cycle is never itself the completion signal — what re-validated it? |

## Rationalization Prevention

Use this table when you catch yourself justifying instead of verifying.

| Rationalization                        | Replace With                                                              |
| -------------------------------------- | ------------------------------------------------------------------------- |
| "It probably works"                    | "Show the exact test run or result, and the paired run where it failed"    |
| "I already checked that"               | "Re-run, capture current evidence, and state what result would have contradicted it" |
| "This part is unrelated"               | "Verify integration impact explicitly"                                    |
| "No one will hit this edge case"       | "Add or run an edge-case test — and confirm it fails without the change"   |
| "Review will catch it"                 | "Self-verify before requesting review"                                    |
| "The evidence is right there in the diff" | "A diff shows the change exists; show what it now rejects that it previously accepted" |
| "The test is obviously correct"        | "Run it against the pre-change code and watch it go red"                   |
| "Everything's green"                   | "Name the criterion this green proves, and what it would have looked like unmet" |
| "Those failures were already there"    | "Name them and route them — filed, or queued where there is no interactive surface. Already-there is a reason not to block, never a reason not to say" |
| "The review is the next step"          | "Then the account says `adversarial_review_ran: false`. Write that, or run the review" |

## When NOT Done

Stop and address if:

- Any test **this change made fail** — measured against a named baseline commit that predates the change, not against green. A failure already present at that baseline is not this change's stop condition; it is property 3's routing obligation, below.
- Any baseline you named that is not an ancestor of this work. Naming your own post-change commit makes every failure "pre-existing" and the rule vacuous.
- Any baseline failure you have neither named nor routed. Carrying it silently is the stop, not the failure itself.
- Any warning you don't understand
- Any TODO/FIXME you added
- Any hardcoded value that should be config
- Any "I'll fix it later" thought

## Red Flags — STOP

Do not mark complete while any of these are true:

- You cannot point to evidence for each acceptance criterion — evidence that could have come out negative, and that names where it came from
- The evidence you are about to offer would read the same if you had changed nothing
- You cannot say what result would have told you the criterion was **not** met
- You are covering several criteria with one aggregate green
- You are relying on memory instead of a current verification run
- You are skipping a check because "it's probably fine"
- You are deferring **your own change's** known validation to "after merge" or "later". This does not reach a pre-existing baseline failure: naming and routing one rather than fixing it now is what property 3 requires, not a deferral this flag catches. The flag fires when the validation you are deferring is of the work you are declaring done.

## Project-Specific Requirements

[CUSTOMIZE] Add your project's completion criteria:

```markdown
## Definition of Done

### Code

- [ ] [Project-specific coding standard]
- [ ] [Required review process]

### Testing

- [ ] [Minimum coverage requirement]
- [ ] [Required test types]

### Documentation

- [ ] [Required documentation updates]

### Process

- [ ] [Required approvals]
- [ ] [Required notifications]
```

Whatever you fill the Testing section with, coverage counts what *ran*, not what *could have failed* — a coverage threshold is not a substitute for showing that the tests offered as evidence were able to go red. This obligation is stated here rather than inside the block above, because a project customizing that block would otherwise overwrite it.

## Gotchas

| Trigger                                                    | Gotcha                                                                                                     | Fix                                                                                 |
| ---------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| "I tested it locally" as the completion claim              | No evidence = claims-based completion; untestable by reviewer                                              | Provide a screenshot, CI link, terminal output, or screen recording — **paired with the same check failing without the change**, since any of those four is otherwise satisfiable by the unchanged tree |
| "It worked yesterday"                                      | Stale evidence; code and state have changed since then                                                     | Re-validate in current state against current code immediately before declaring done |
| "The tests pass" without specifying which                  | Ambiguous scope — which tests? Unit only? Integration?                                                     | Specify exact test command and scope run — and the run where that same scope was red |
| "I didn't change that area" as reason to skip verifying it | Indirect breakage happens through shared state, CSS side effects, shared utilities                         | Verify anyway; run the full suite regardless of which files were touched            |
| Declaring done without re-reading original requirements    | PR may add unrequested features or omit required ones                                                      | Re-read every AC item explicitly; check off each before opening the PR              |
| Verifying components in isolation only                     | Component works standalone but breaks at integration surface (API contracts, DB migrations, feature flags) | Complete the integration checklist items, not just unit tests                       |
| A new test written after the fix, never run against the old code | It may assert something that was already true; it passes, and proves nothing about the change         | Stash or revert the change, run the test, watch it go red, then restore             |
| A test whose expected value is derived from the function under test | It agrees with itself under every implementation, including a broken one                          | Compute the expectation independently — a literal, a reference implementation, a hand-worked case |
| A whole-suite green offered against every acceptance criterion | One aggregate result cannot say which criteria are met                                                 | Scope evidence per criterion; keep suite health as a separate, clearly-labelled line |
| A documentation or guidance change evidenced by quoting the new text | Presence of wording is not a change in what is accepted or rejected                                 | Name a concrete artifact the old text accepted, and show the new text rejecting it  |
| A consistency or agreement check offered as proof something changed | It passes when all locations agree, including when none of them moved                               | Show the before and after values, not just their agreement                          |
