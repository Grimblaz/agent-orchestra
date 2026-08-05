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

## The Completion Account

The checklists below govern whether each acceptance criterion has evidence behind it. They do not govern what sits *outside* the criteria — whether the mandatory adversarial review ran, what state the run left the suite in. A run can therefore report accurately on everything it was told to care about and still owe a review nobody records as outstanding. That gap is what this section closes.

Five properties hold of a run **declaring itself done** — the act, not a lane and not every run. They are restated in full here rather than pointed at, because this skill is served to consumer repositories that never receive this repository's root guidance file: for those runs, this section is the *only* place the properties exist.

1. **The review is accounted for.** Every finding the adversarial review produced traces to an outcome that survived the judge — a fix commit, or a dismissal with its reason.
2. **A review that ran and found nothing says so, in words that would be false if it had not run.** Silence is never readable as examined-and-clean.
3. **The suite's state is stated differentially** — what this change added, against a named baseline commit — **and, separately, pre-existing failures are named and routed.** Two obligations, not one.
4. **A fix that closes a finding is itself re-validated before the account closes.** A fix cycle is never itself the completion signal.
5. **A stopped run reads as stopped** — in the lane's typed halt-report shape, never free prose.

In this repository they are also stated in `CLAUDE.md` § What a finished run is true of, which is read live at session start; this section is their depth. The two are one statement, and they move together.

**How** a run makes each property true is its own choice. Three things are not: the account exists, it outlives the session that wrote it, and it carries the review assertion below.

### Where the account lives

Every artifact the review pipeline leaves that carries finding-level content is keyed on a pull request, and a conductorless run reviews *before* one exists — so an account left format-free has nowhere to land and the only surviving copy is the transcript. The account is therefore persisted as an **issue-keyed durable marker**, written through the repository's existing marker-write primitive like every other marker family: `<!-- completion-account-{ID} -->`, where `{ID}` is the issue number. The issue is the one identifier that exists before a pull request does. See `skills/session-memory-contract/references/handoff-markers.md` for the family's row.

An account held only in the session transcript, in a scratch file, or in a working-tree path does not satisfy property 3's durability: a later reader on a different machine, after the worktree is deleted, must still be able to retrieve it.

Write it with the shared primitive — never a hand-composed `gh issue comment`, for the same reason every other registered family is written this way:

```bash
pwsh skills/session-memory-contract/scripts/persist-marker.ps1 -Family completion-account -TargetSurface issue -Number {ID} -Marker '<!-- completion-account-{ID} -->' -BodyFile <path>
```

The marker must be the body's **first line**: the primitive's payload hygiene refuses a candidate whose own-family marker sits anywhere else, before any network call. The family declares no validator adapter, so nothing else about the payload is refused — a nonconforming account still writes, and is then flagged by the reader rather than blocked. That is deliberate: an account that cannot be written is worse than one that can be read and found wanting.

### The required review assertion, and its two polarities

The account MUST carry this field:

```yaml
adversarial_review_ran: true    # or false
```

Two polarities, both lexically present, and **absence is not a third**: an account omitting the field reads as *not run*, never as clean. Silence must not be readable as examined-and-clean.

This exists because property 1 is quantified over the findings a review produced. A run that dispatches no review produces no findings, so "every finding traces to an outcome" is vacuously true over the empty set and the run can write a closed-looking account without a review having happened. A single sentence forbidding that would be administered by the same run writing the claim — a hope, not a check. The assertion is what a reader other than the author can act on.

`Read-CompletionAccount` (`skills/verification-before-completion/scripts/completion-account-core.ps1`) is that reader. It is **warn-only**: it never blocks a write and never fails a run.

### What the guidance rejects

An account is nonconforming when any of these holds. Each is a rejection, not a suggestion:

- **No review is accounted for.** The account carries `adversarial_review_ran: false`, or omits the field entirely, or claims `true` while naming no findings-to-outcome trace and no explicit "ran and returned nothing" result. A run that dispatched no adversarial review cannot write a conforming account.
- **A finding has no outcome that survived the judge.** Every finding the review produced traces to a fix commit or to a dismissal carrying its reason. A finding that simply stops being mentioned is not dispositioned.
- **A fix closes a finding with no post-fix re-validation.** A fix cycle is never itself the completion signal. This repository's own record is that a fix introduced a new defect in three of five rounds on one issue and in three consecutive rounds on another, so an account closing on the fix commit alone certifies work nothing re-checked. **This clause is a restatement, not a new rule**, and saying so matters: the Insufficient Evidence list already rejects such an account under *"Evidence that the change is present offered as evidence that it is sufficient — a diff, a field that was added"*, and an independent reader applying the pre-#998 text alone reached NONCONFORMING on exactly this artifact. What this clause adds is location and grain — the general evidence principle now also appears where a run writes its *account*, and names the fix case explicitly — not a rejection that was previously unavailable.
- **The account says nothing at all about the suite.** An account that discharges every other property and is silent on suite state is incomplete. Distinct from the differential rule below, which governs how a *stated* suite result is judged.
- **A pre-existing failure is carried silently.** A failure present at the named baseline and still present now must be both *named* and *routed*. An account that names one but routes it nowhere has left it in the account and nowhere else; one that routes it without saying so leaves the next reader unable to tell it was ever seen.
- **A stopped run's artifact could be read as completion.** A run that stops leaves the lane's typed halt-report shape (`skills/goal-run/schemas/goal-halt-report.schema.json`), not free prose. Neither artifact may be readable as the other.

### Routing a pre-existing failure

The differential rule takes a baseline failure *off* the blocking path, which only helps if something else picks it up. Routing is what does, and it is available on both paths:

- **With an interactive surface**: the failure enters the `§2e Filing Approval Gate` batch (`skills/safe-operations/SKILL.md` § 2e) as a proposal, and an approved proposal files through `Add-FollowUpIssue.ps1` with provenance and a parent — never a bare `gh issue create`.
- **Without one** (an unattended run has no one to ask): §2e's headless fallback lawfully **queues** the proposal and files nothing. A queued proposal discharges the routing obligation. It has to: otherwise an unattended run would be simultaneously obliged to file and unable to lawfully do so, and the rule would be unfollowable in exactly the way the absolute rule it replaces was.

Both outcomes are reachable today; what changed is that the failure is no longer a blocker instead.

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

- [ ] Suite state stated **differentially** — what this change *added*, measured against a named baseline commit — not whether the suite is absolutely green
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

- Baseline commit: [the commit this run's suite state is measured against]
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

- Any test **this change made fail** — measured against a named baseline commit, not against green. A failure already present at that baseline is not this change's stop condition; it is property 3's routing obligation, below.
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
