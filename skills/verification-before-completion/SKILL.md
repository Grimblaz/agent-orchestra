---
name: verification-before-completion
description: "Evidence-based verification checklist before marking work complete. Use before PRs, releases, marking tickets done, or any \"I'm finished\" declaration; also when naming a baseline commit for a differential suite claim, when designing a mutation campaign or red-run evidence, and when making an absence claim, a universal claim, or a one-time demonstration offered as a standing guarantee. DO NOT USE FOR: post-merge cleanup or archival (use post-pr-review) or processing GitHub review comments (use code-review-intake)."
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

In this repository they are also stated in `CLAUDE.md` § What a finished run is true of, which is read live at session start; this section is their depth. The two copies are one statement and must move together — a parity test pins them, because an unpinned "they move together" claim is the two-surfaces-disagreeing shape this file's own differential rule exists to prevent, and the first draft's copies had already diverged by the time they shipped.

### Which commit may be named as the baseline

Property 3 is only as good as the commit it measures against, and the first draft left that unconstrained — which made the whole rule vacuously satisfiable (issue #998 review, finding M13, sustained).

**The named baseline must be an ancestor of the work being declared done** — the branch point, the merge base with the target branch, or any commit that predates this change. It may never be the run's own post-change `HEAD`.

Without that constraint there is a reading in which every clause of property 3 is met and nothing is checked: a run that broke the suite names its own current commit as the baseline, every failure is then "present at that baseline and still present now", each is dispositioned as pre-existing and routed, and the account truthfully reports **"failures this change added: 0."** That is not a strained reading — it is the *natural* one, because the suite runner's own `RUN ATTRIBUTION` line emits `commit=` as the run's current commit, so a run transcribing it into the baseline slot names exactly the wrong commit and still reads compliant. The absolute rule this replaced had no such reading; restoring it would have been a regression disguised as a rewrite.

**How** a run makes each property true is its own choice. Three things are not: the account exists, it outlives the session that wrote it, and it carries the review assertion below.

### Where the account lives

Every artifact the review pipeline leaves that carries finding-level content is keyed on a pull request, and a conductorless run reviews *before* one exists — so an account left format-free has nowhere to land and the only surviving copy is the transcript. The account is therefore persisted as an **issue-keyed durable marker**, written through the repository's existing marker-write primitive like every other marker family: `<!-- completion-account-{ID} -->`, where `{ID}` is the issue number. The issue is the one identifier that exists before a pull request does. See `skills/session-memory-contract/references/handoff-markers.md` for the family's row.

An account held only in the session transcript, in a scratch file, or in a working-tree path does not satisfy the durability obligation above: a later reader on a different machine, after the worktree is deleted, must still be able to retrieve it.

Write it with the shared primitive — never a hand-composed `gh issue comment`, for the same reason every other registered family is written this way. **What that rule buys is a single audited writer — not protection from `updated_at` advancement**; the primitive's own transport performs the identical whole-body PATCH. That is worth knowing here in particular, because this family is `upsert-in-place`: revising an account from `adversarial_review_ran: false` to `true` re-writes the whole comment and advances the timestamp of every family sitting beside it. See `skills/session-memory-contract/references/handoff-markers.md` § What the write-path rule buys. Invoke it like this:

```bash
pwsh skills/session-memory-contract/scripts/persist-marker.ps1 -Family completion-account -TargetSurface issue -Owner {owner} -Repo {repo} -Number {ID} -Marker '<!-- completion-account-{ID} -->' -BodyFile .tmp/completion-account-{ID}.md
```

Two things that refuse the write before any network call, both of them easy to hit:

- **`-Owner` and `-Repo` are mandatory.** Omitting either fails parameter binding, not the write.
- **`-BodyFile` must resolve inside the repository scratch root `.tmp/`.** A path outside it is refused.

And two things the payload itself must satisfy:

- **The marker is the body's first line.** Payload hygiene refuses a candidate whose own-family marker sits anywhere else.
- **The body must not carry another registered family's marker at the start of any line.** This one is easy to trip precisely because an account is *narrative about the run's own pipeline artifacts* — and a fenced block does not save you, because every marker reader is a raw-text scan rather than a semantic parse. The repository already has the remedy and it is not "indent it": render marker mentions **inertly**, stripping the HTML-comment delimiters so the pattern has nothing to anchor on. See `skills/session-memory-contract/references/handoff-markers.md` § Writing about markers safely, which states the hazard, names `Format-InertMarkerLabel`, and gives the worked form. Write `` `phase-containment-ledger-{ID}` ``, never the delimited literal at column zero.

The family declares **no validator adapter**, so nothing about the account's *own* shape is refused: an account with no review assertion, or a false one, still writes and is then flagged by the reader rather than blocked. That is deliberate — an account that cannot be written is worse than one that can be read and found wanting. But note the boundary carefully: the universal cross-family hygiene above runs regardless of that null adapter, so "no validator" does not mean "anything writes."

### The required review assertion, and its two polarities

The account MUST carry this field:

```yaml
adversarial_review_ran: true    # or false
```

Two polarities, both lexically present, and **absence is not a third**: an account omitting the field reads as *not run*, never as clean. Silence must not be readable as examined-and-clean.

This exists because property 1 is quantified over the findings a review produced. A run that dispatches no review produces no findings, so "every finding traces to an outcome" is vacuously true over the empty set and the run can write a closed-looking account without a review having happened. A single sentence forbidding that would be administered by the same run writing the claim — a hope, not a check. The assertion is what a reader other than the author can act on.

`Read-CompletionAccount` (`skills/verification-before-completion/scripts/completion-account-core.ps1`) is that reader. It is **warn-only**: it never blocks a write and never fails a run.

**Who runs it, and when.** A reader nobody invokes is not a check — it is the same hope one layer down, and this repository has already measured that shape: a stated-once terminal obligation shipped into three skills emitted **zero** across three consecutive reviews, and the recorded remedy was a warn-only reader-side *sweep*. So the trigger is named here rather than left to be inferred:

```bash
# Read the account for issue {ID}, with the comment author carried through.
pwsh -c ". skills/verification-before-completion/scripts/completion-account-core.ps1; \
  Get-CompletionAccountFromComments -Id {ID} \
    -Comments (gh issue view {ID} --json comments --jq '.comments' | ConvertFrom-Json)"
```

Run it **whenever you pick up an issue that has been worked before** — resuming a paused run, opening a follow-up, or reviewing someone else's finished work. `Get-CompletionAccountFromComments` selects the account by its family marker (never by concatenating every comment, which would let any unrelated comment supply the assertion), reports `Found: $false` when there is none, and surfaces the comment's author because a record recognised by shape alone does not authenticate itself. Everything it returns is advisory.

### What the guidance rejects

An account is nonconforming when any of these holds. Each is a rejection, not a suggestion:

- **No review is accounted for.** The account carries `adversarial_review_ran: false`, or omits the field entirely, or claims `true` while naming no findings-to-outcome trace and no explicit "ran and returned nothing" result. A run that dispatched no adversarial review cannot write a conforming account.
- **An external review posted findings the account never mentions.** Property 1 is quantified over the findings *a review* produced — not over the findings this run's own panel produced. A pull request carrying review comments holds findings that were produced and reached nobody, so an account written over them is closed-looking for exactly the reason an unreviewed account is: it is true over the wrong set. See § External review on the pull request for the trigger and for the distinction that keeps the check honest.
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

### External review on the pull request

A run that opened a pull request has published its work to reviewers that answer on their own schedule. Those answers are findings, and property 1 does not distinguish them from the run's own.

**Why this needs a named trigger and not just the rejection clause above.** `/review-github` already ingests and adjudicates external review properly — the gap is that nothing tells a run to invoke it. It is opt-in and manually triggered, and a conductor-side step would not close the gap either: the bare `/goal` lane runs no conductor at all. The obligation therefore lives here, where every lane reads it, and carries its trigger with it — this file's own record is that a stated-once terminal obligation shipped into three skills emitted **zero** across three consecutive reviews.

**Measured cost of not doing this** (PR #1023, 2026-08-08, all times UTC): the PR opened at 18:08; three findings posted at 18:11 and five more at 18:14 — all eight available **seven minutes** in. The run pushed its next commit at 19:46 without reading them, and closed them at 20:51, a full extra round later. That run had already completed a 5-pass prosecution panel, defense, judge, and **two** further post-fix adversarial passes: 27 internal findings, 23 sustained. The eight external findings were disjoint from every one of them and were sustained 8/8 through proxy prosecution → defense → judge, including a **high** — a duplicated policy region that made the checker report `clean` over a contradicting policy — whose defect class the internal panel had found and fixed at one call site while never sweeping for the other two.

**Before declaring done, when the run opened or pushed to a pull request:**

```bash
# THREE distinct collections. A reviewer may use any of them, and reading two of
# the three is how a review with findings reads as a review with none.
gh api "repos/{owner}/{repo}/pulls/{PR}/comments"  --paginate --jq '.[] | "\(.created_at) \(.user.login) inline \(.path):\(.line)"'
gh api "repos/{owner}/{repo}/pulls/{PR}/reviews"   --paginate --jq '.[] | select(.body != "") | "\(.submitted_at) \(.user.login) review-summary \(.state)"'
gh api "repos/{owner}/{repo}/issues/{PR}/comments" --paginate --jq '.[] | "\(.created_at) \(.user.login) top-level"'
```

**All three, and paginated — both corrections came from a reviewer on this very section, which is the argument for the rule in miniature.** The first revision listed only inline threads and top-level comments. `gh` keeps submitted-review bodies in a third collection entirely, so a reviewer who puts a finding *only* in its review summary is invisible to both — and `skills/code-review-intake/SKILL.md` already requires review summaries in the ingested ledger, so the trigger has to actually fetch them. `--paginate` is the same class of gap one level down: `skills/safe-operations/SKILL.md` records that an unpaginated read caps out and can shadow the record on a busy thread.

State the exposure honestly, because the check this section describes is the one that would have to catch it: on PR #1023 the two-command pair happened to reach **every** reviewer, since each had also commented inline or top-level — no reviewer was exclusive to `reviews`. So this is a **latent** gap, not a demonstrated miss, and it is recorded that way rather than dressed up with an exhibit that does not reproduce. What the pair genuinely does not return is the review-summary *body* — the object carrying, on that PR, one reviewer's "diff exceeds the review limit" verdict, which is a finding about coverage that a completion account needs and neither other collection holds.

Findings from this route are ingested through `skills/code-review-intake/SKILL.md` — as proxy prosecution over the ingested ledger, never as conductor-side merit judgments — and their dispositions then travel in the same account as everything else.

**The distinction that keeps this honest: an empty result is not a clean review.** Reviewers post asynchronously, so "no comments" minutes after opening a PR and "no comments after the reviewer finished" are different states, and only the second says anything. Check whether the review actually reported — `gh pr checks {PR}` names bots that are still `pending`, and several post a summary comment when they finish. Record which of the three the run is in, because collapsing them is how an unread review becomes an examined-and-clean claim:

- **findings present** → ingest and disposition them
- **reviewer finished, no findings** → an accounted-for review that returned nothing, in the words property 2 requires
- **reviewer not finished, or none configured** → say that, and say the account is closing without it

The last is a lawful close, not a failure. A reviewer that never answers cannot block a run; an account that quietly reads its silence as approval is what this clause forbids.

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

After the PR is open — and before declaring done — read what the reviewers actually posted (§ External review on the pull request). Findings arrive minutes after the PR opens, not at the moment you finish writing it.

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

Nine ways verification evidence passes while proving nothing. Every one is an escape from this repository's own review record, and every one survived the checklists above — a checklist asks whether you produced evidence, and these ask whether the evidence could ever have come out negative.

### When you are naming a baseline commit for a differential suite claim

#### A baseline that is not an ancestor makes the differential rule vacuous

Stated in full at § Which commit may be named as the baseline and in `CLAUDE.md` § What a finished run is true of, property 3 — read the rule there rather than re-deriving it here. What this lens adds is the generalisation those two do not make: **the same hole opens wherever an absolute threshold is replaced by a relative one**. Whenever you write a relative rule, ask who picks the reference point and what stops them picking one that makes the comparison trivial.

#### A differential script baselined on `HEAD` inverts the moment you commit

A verification script that reads the "before" side with `git show HEAD:<file>` is correct only until the work is committed. After that, `HEAD` *is* the changed tree, so every "this text was absent pre-change and is present now" assertion compares the new tree against itself. The loud direction is a false red — 25 checks went red at once on #939 that way. The dangerous direction is silent: a check written as "the defect is *gone* now" passes vacuously against a baseline that never had it. Pin the base to an explicit SHA in a named variable, say in a comment why it is pinned, and grep for **every** `git show HEAD:` when repointing — one missed read is enough. A fix round needs a second pinned baseline too: the reviewed commit, so each fix check asserts the defect existed at the commit the reviewer saw.

#### Run the criterion's own discriminator against the untouched tree before you trust it

A proof standard goes vacuous the same way a test does. Before shipping a criterion that says "X and Y differ", build X and Y at the **unmodified** baseline and confirm the comparison comes out negative. On #969 it did not: all three review lenses built the criterion's own two corpora at unmodified `HEAD` and got the difference the criterion demanded, because the two inputs differed in more than the one variable under test — the denominator, the partition membership, and the exclusion note all moved too. The tell is exactly that: **what else differs between X and Y for reasons unrelated to the work?** If anything does, the criterion is measuring that instead. Hold everything constant except the property being discriminated, and name the span being compared.

### When you are designing a mutation campaign or red-run evidence

#### A mutation campaign that only touches sites the suite already covers proves nothing

"22 mutations, each turns exactly one test red" reads as strong evidence and can be almost worthless. On #1018 that campaign came back 22 of 22 red, and a reviewer running **six** mutations found **four** that turned *zero* tests red — because the sites had been chosen, unconsciously, from the code the tests were written against. Pick sites from the **deliverable**, not from the test file: enumerate what ships, then ask which of it any test would notice changing. Mutate **both** polarities of every comparison you introduced, not just "remove the guard". Mutate the **prose** when the prose is the deliverable, and mutate rows a *later* fix added rather than only those present when the pins were written. An all-red campaign is the floor, not the verdict — state how the sites were chosen. And a mutation that comes back **green is a finding about the evidence**, never one that "did not apply": it reports that something ships which no assertion holds, which is the most informative result the campaign can produce. Record it against the check rather than dropping it as inapplicable.

#### A red run at deliverable grain says nothing about the deliverable's sub-properties

Deleting a whole deliverable in a scratch copy removes the one salient literal its pin asserts, so the pin fires and the red run looks conclusive. Its *other* claims — what it is conditioned on, where its output lands, who can reach it — were never separately asserted, so each stays independently deletable. On #973 four deliverables "proved" held, and mutation at sub-property grain came back 64 of 64 green three times over. **Enumerate the claims a criterion makes, not the features it adds, and mutate once per claim**: if only this clause vanished, which assertion goes red? Two shapes always worth mutating separately — a conditioning clause ("when the target is X"), whose deletion silently widens scope, and a named landing surface ("the answer lands in Y"), whose deletion sends the output nowhere while every other pin stays green.

### When you are making an absence claim, a universal claim, or a one-time demonstration offered as a standing guarantee

#### A witness can falsify a universal but never establish one

Proof standards get derived by asking what a convincing *demonstration* would look like. That instinct is right for existentials and wrong for universals, and an executor grades against the proof standard — so a criterion stating "no X anywhere" with a one-fixture proof standard is passable by a run that built one fixture. Partition criteria by logical form **before** writing any proof standard. Existential claims take demonstration-shaped proof. Universal claims take a **standing check that executes the quantifier on every run**, not the transcript of it holding once. Value-domain claims are exercised over the whole domain — absent, `false` and `true` are three cases, and a standard testing only *absent* rewards the scrupulous run and catches only the omitting one.

And every absence claim ships a **planted positive control, planted where the search is weakest**. "No X found" and "nothing looked for X" are the same evidence otherwise — but a plant in the shape the search was built around only proves the search can return *something*. On #977 an audit ran three phrasings, planted a positive of the form the phrasings were written for, saw all three flag it, and published "no second instance"; review then found five missed sites, all of a shape every phrasing's regex was structurally blind to. Before planting, ask: **what shape would my search miss, and is that what I am about to plant?**

#### A bounded read window produces a false absence, and the window gets recorded as the evidence

`Read` with `offset`/`limit` bounds the evidence, not the question; nothing in the output says "the window ended here." On #968 a context read as lines 250–339 produced an "uncovered" finding whose covering block opens at line **340**, and the resulting evidence row cited the window and was tagged verified — the error laundered into a certification before any reviewer saw it. For an **absence** claim, never bound the read: grep the whole file, or the whole tree. Counting claims need a mechanical count over the full span, not an eyeball over a window. And note the directional tell, which is the real lesson: grounding errors run in the direction that favours the conclusion you are arguing for, so audit absence claims for that bias specifically.

#### A demonstration at delivery is not a regression guard

*"Run controls at delivery and record the output"* buys one dated observation, satisfiable by a transcript — and the property it certifies starts decaying the moment the criterion is satisfied, with no signal. *"Ship a regression guard that exercises each axis against a modified copy"* buys the property over time and costs barely more to write. On #986 the delivery controls passed and review then found three inputs already reaching `clean` on a defective index, on the very axes those controls had certified — because each control had been planted where the check was strong. Ask at criterion-authoring time: **after this run ends, what re-checks this?** If the answer is "a person re-reading an issue comment", the criterion bought a demo, not a guard. This is a *plan*-phase fix, not a review-phase one: a criterion is what the executor builds to.

#### Point the instrument at the real target, and build the negatives first

Two checks that beat unit-level test-first at catching the expensive defects, because their unit is a population and a specification rather than a function. **Run it against the real target on day one**: fixtures are shaped by the same understanding that shaped the code, so they agree with it. On #1018 a fix was correct and never reached the population it existed for — identity-keying and name-keying are the same operation when every identity is unbound, which is true of 100% of the live corpus, and thirty seconds pointing the instrument at that corpus would have shown it. **Build each acceptance criterion's negative construction before the implementation**: built last, negatives get shaped to fit what you wrote rather than to the criterion. Standing caveat — this is one session's evidence; the phase-containment ledger is the instrument for whether it is systemic, and no lane changes on n=1.

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
