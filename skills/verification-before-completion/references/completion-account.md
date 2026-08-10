# The Completion Account — procedure

Depth for `skills/verification-before-completion/SKILL.md` § The Completion Account. The five
properties a run declaring itself done makes true are **stated in the skill body**, not here — this
file carries only their elaboration: which commit may be named as a baseline, where the account is
written and with what primitive, the review assertion and its reader, what the guidance rejects,
how a pre-existing failure is routed, and the external-review trigger.

Read the properties first. Nothing below restates them.

## Contents

- [Which commit may be named as the baseline](#which-commit-may-be-named-as-the-baseline)
- [Where the account lives](#where-the-account-lives)
- [The required review assertion, and its two polarities](#the-required-review-assertion-and-its-two-polarities)
- [What the guidance rejects](#what-the-guidance-rejects)
- [Routing a pre-existing failure](#routing-a-pre-existing-failure)
- [External review on the pull request](#external-review-on-the-pull-request)

## Which commit may be named as the baseline

Property 3 is only as good as the commit it measures against, and the first draft left that unconstrained — which made the whole rule vacuously satisfiable (issue #998 review, finding M13, sustained).

**The named baseline must be an ancestor of the work being declared done** — the branch point, the merge base with the target branch, or any commit that predates this change. It may never be the run's own post-change `HEAD`.

Without that constraint there is a reading in which every clause of property 3 is met and nothing is checked: a run that broke the suite names its own current commit as the baseline, every failure is then "present at that baseline and still present now", each is dispositioned as pre-existing and routed, and the account truthfully reports **"failures this change added: 0."** That is not a strained reading — it is the *natural* one, because the suite runner's own `RUN ATTRIBUTION` line emits `commit=` as the run's current commit, so a run transcribing it into the baseline slot names exactly the wrong commit and still reads compliant. The absolute rule this replaced had no such reading; restoring it would have been a regression disguised as a rewrite.

## Where the account lives

Every artifact the review pipeline leaves that carries finding-level content is keyed on a pull request, and a conductorless run reviews *before* one exists — so an account left format-free has nowhere to land and the only surviving copy is the transcript. The account is therefore persisted as an **issue-keyed durable marker**, written through the repository's existing marker-write primitive like every other marker family: `<!-- completion-account-{ID} -->`, where `{ID}` is the issue number. The issue is the one identifier that exists before a pull request does. See `skills/session-memory-contract/references/handoff-markers.md` for the family's row.

An account held only in the session transcript, in a scratch file, or in a working-tree path does not satisfy the durability obligation: a later reader on a different machine, after the worktree is deleted, must still be able to retrieve it.

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

## The required review assertion, and its two polarities

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

## What the guidance rejects

An account is nonconforming when any of these holds. Each is a rejection, not a suggestion:

- **No review is accounted for.** The account carries `adversarial_review_ran: false`, or omits the field entirely, or claims `true` while naming no findings-to-outcome trace and no explicit "ran and returned nothing" result. A run that dispatched no adversarial review cannot write a conforming account.
- **An external review posted findings the account never mentions.** Property 1 is quantified over the findings *a review* produced — not over the findings this run's own panel produced. A pull request carrying review comments holds findings that were produced and reached nobody, so an account written over them is closed-looking for exactly the reason an unreviewed account is: it is true over the wrong set. See § External review on the pull request for the trigger and for the distinction that keeps the check honest.
- **A finding has no outcome that survived the judge.** Every finding the review produced traces to a fix commit or to a dismissal carrying its reason. A finding that simply stops being mentioned is not dispositioned.
- **A fix closes a finding with no post-fix re-validation.** A fix cycle is never itself the completion signal. This repository's own record is that a fix introduced a new defect in three of five rounds on one issue and in three consecutive rounds on another, so an account closing on the fix commit alone certifies work nothing re-checked. **This clause is a restatement, not a new rule**, and saying so matters: the Insufficient Evidence list already rejects such an account under *"Evidence that the change is present offered as evidence that it is sufficient — a diff, a field that was added"*, and an independent reader applying the pre-#998 text alone reached NONCONFORMING on exactly this artifact. What this clause adds is location and grain — the general evidence principle now also appears where a run writes its *account*, and names the fix case explicitly — not a rejection that was previously unavailable.
- **The account says nothing at all about the suite.** An account that discharges every other property and is silent on suite state is incomplete. Distinct from the differential rule, which governs how a *stated* suite result is judged.
- **A pre-existing failure is carried silently.** A failure present at the named baseline and still present now must be both *named* and *routed*. An account that names one but routes it nowhere has left it in the account and nowhere else; one that routes it without saying so leaves the next reader unable to tell it was ever seen.
- **A stopped run's artifact could be read as completion.** A run that stops leaves the lane's typed halt-report shape (`skills/goal-run/schemas/goal-halt-report.schema.json`), not free prose. Neither artifact may be readable as the other.

## Routing a pre-existing failure

The differential rule takes a baseline failure *off* the blocking path, which only helps if something else picks it up. Routing is what does, and it is available on both paths:

- **With an interactive surface**: the failure enters the `§2e Filing Approval Gate` batch (`skills/safe-operations/SKILL.md` § 2e) as a proposal, and an approved proposal files through `Add-FollowUpIssue.ps1` with provenance and a parent — never a bare `gh issue create`.
- **Without one** (an unattended run has no one to ask): §2e's headless fallback lawfully **queues** the proposal and files nothing. A queued proposal discharges the routing obligation. It has to: otherwise an unattended run would be simultaneously obliged to file and unable to lawfully do so, and the rule would be unfollowable in exactly the way the absolute rule it replaces was.

Both outcomes are reachable today; what changed is that the failure is no longer a blocker instead.

## External review on the pull request

A run that opened a pull request has published its work to reviewers that answer on their own schedule. Those answers are findings, and property 1 does not distinguish them from the run's own.

**Why this needs a named trigger and not just the rejection clause above.** `/review-github` already ingests and adjudicates external review properly — the gap is that nothing tells a run to invoke it. It is opt-in and manually triggered, and a conductor-side step would not close the gap either: the bare `/goal` lane runs no conductor at all. The obligation therefore lives here, where every lane reads it, and carries its trigger with it — this repository's own record is that a stated-once terminal obligation shipped into three skills emitted **zero** across three consecutive reviews.

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
