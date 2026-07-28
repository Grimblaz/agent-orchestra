---
name: verification-before-completion
description: "Evidence-based verification checklist before marking work complete. Use before PRs, releases, marking tickets done, or any \"I'm finished\" declaration. DO NOT USE FOR: post-merge cleanup or archival (use post-pr-review) or processing GitHub review comments (use code-review-intake)."
---

# Verification Before Completion

Systematic verification process to ensure work is truly complete.

## When to Use

- Before creating a pull request
- Before marking a ticket/issue as done
- Before declaring a feature complete
- Before releases or deployments
- Anytime you think "I'm done"

## Core Principle

> **Iron Law**: Claims do not count as completion—only evidence does.

> "Done" means verified, not just implemented.

The gap between "I wrote the code" and "it works correctly" is where bugs hide.

If evidence is missing, the work is not complete yet.

**And evidence that could not have come out negative is missing evidence.** A proof that would read exactly the same against the unchanged tree tells you nothing about the change; it is a claim wearing evidence's clothes. The three properties every offered proof must carry — discriminating, attributed, per-criterion — are defined once under [Evidence Obligations](#evidence-obligations), and every checklist item and table row below **that prescribes or accepts proof** carries them in place. Sections that check something other than proof — code quality, integration, documentation, release and demo readiness — are unchanged and carry no such obligation. The *form* the proof takes is always your choice.

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

- [ ] All existing tests pass
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

- **Discriminating** — it could have come out negative. There is a state of the world, reachable by this codebase, in which this evidence would have shown failure. The sharpest form is a pairing: the same check red before the change and green after. Evidence that would read identically against the pre-change tree is not discriminating, no matter how detailed.
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
- ❌ A green suite that was equally green before the change (nothing here could have failed)
- ❌ A new test that passes against the pre-change code (it proves the code loads, not that the change did anything)
- ❌ A test whose expected value is computed by the function under test (it agrees with itself under every implementation)
- ❌ One aggregate green offered against several acceptance criteria at once (not per-criterion)
- ❌ Evidence that the change is *present* offered as evidence that it is *sufficient* — a diff, a field that was added, a term that now appears in a document
- ❌ A number with no population behind it — "most cases", "all the ones I checked" (not attributed)
- ❌ A consistency check that passes when nothing moved (agreement across locations is not the same as change)

## Verification Log Template

One block per acceptance criterion — the block structure is what makes the evidence *per-criterion*. Within each block, "Could have failed" carries *discriminating* and "Provenance" carries *attributed*; "Proof offered" is the evidence itself, not an obligation. A criterion whose "Could have failed" line is empty has no evidence yet.

The "Verified by" and "Date" fields at the end attribute the **log**, not the evidence — each criterion still carries its own provenance line.

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

## When NOT Done

Stop and address if:

- Any test is failing (even "unrelated" ones)
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
- You are deferring known validation to "after merge" or "later"

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
