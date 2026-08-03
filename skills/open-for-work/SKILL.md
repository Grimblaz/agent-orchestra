---
name: open-for-work
description: The operating methodology for opening a filed standalone issue for work — the trivial floor, the worth-it doors, beat 1 alignment with its affirmation gate and durable affirmation record, beat 2 routing, and the two outputs (a brief on the routine arm, a continuation into design on the novel arm). Use when a person asks to open an issue for work, when `/open` is invoked, or when resuming an issue that already carries an affirmation record. DO NOT USE FOR: chunk sub-issues of a designed parent (they inherit authority source (a) — author the brief directly per plan-authoring § Brief plan variant), post-merge close-out mechanics (use post-pr-review), or the adversarial review of the artifact this flow produces (use adversarial-review with the `design-challenge` adapter).
---

# Open for work

This skill is the **operating methodology** for the open-for-work flow. The doctrine — why the flow exists, what each beat is for, and the contracts it must not break — lives in [`Documents/Design/open-for-work.md`](../../Documents/Design/open-for-work.md). That document is the rationale home; this file is what the conversation actually follows, and it is self-contained: a run does not need the doctrine document handed to it.

> Auto-mode boundary: see [CLAUDE.md § Auto-mode boundary](/CLAUDE.md#auto-mode-boundary). Auto-mode does not suppress `AskUserQuestion`.

<!-- vocab-pointer -->
> **Unfamiliar with a code or term?** Shortcodes like `SMC-NN`, `D1/D2/D3`, and `CE Gate` are defined in the [plain-language vocabulary](../../HOW-IT-WORKS.md#vocab).

## When to Use

- A person asks to open a filed issue for work, in any phrasing, or invokes `/open {issue}`.
- A run resumes an issue that already carries an affirmation record (see [Resuming](#resuming-an-issue-already-opened-for-work)).

**Not this flow**: a chunk sub-issue of a designed parent inherits authority source (a) and is planned directly as a brief — no worth-it check, no beat 1, no affirmation record. A person who explicitly asks for `/experience` or `/design` gets the phase pipeline, which remains fully lawful.

## The shape of a run

Six steps, in order. Steps 0 and 1 can end the run; steps 2 through 4 always run together.

| Step | What happens | Can end the run? |
| --- | --- | --- |
| 0 | Trivial floor, read from the filed issue alone | Yes — below the floor, fix it directly |
| 1 | Worth-it check, three doors | Yes — Park or Decline |
| 2 | Beat 1: ground, amend, state what is being built; **affirmation gate**; record | No |
| 3 | Beat 2: classify the still-open list — routine or novel | No |
| 4 | The arm's output: a brief, or a continuation into design | Yes — this is the exit |

Two things run alongside every step: a **gate-decision token** at each checkpoint ([below](#gate-decision-tokens)), and the escape hatch, which is available from step 4 onward for the whole life of the run.

## Step 0 — the trivial floor

Decide this **first, from the filed issue alone**, before any conversation happens. No affirmation, routing artifact, or pull request is a precondition.

Read the six structural criteria and their pickup-time reading from `skills/safe-operations/SKILL.md` § 2a — **read the floor there, not from a summary**. That section is the canonical statement; it is not restated here, deliberately, so a second floor cannot drift into existence.

Two things about §2a's pickup-time reading are load-bearing enough to name here so a run cannot miss them:

- **The risk guard**: a change touching **permission, authentication, or data-integrity behavior is never below the floor, regardless of size**. Below the floor there is no brief and no adversarial review, so pull-request review is the only review the change will ever get.
- **The guard fails closed**: filing requires no proposed solution (§2f), so a filed issue routinely does not establish whether the eventual change avoids those three behaviors. When it does not establish that, treat the change as touching them. That is the expected pickup state, not an edge case.

**Verdict below the floor**: say so plainly, fix it directly, and stop. No brief, no run ceremony, no issue theatre. Record the disposition on the issue in one sentence so a later reader knows the floor was read and how it came out.

**Verdict above the floor**: continue to step 1.

## Step 1 — the worth-it check and its three doors

Ask the three prompts from `skills/customer-experience/SKILL.md` § Value Reflex, unchanged:

1. **Bet** — what specific bet is this change making?
2. **Falsifier** — what would have to be true for this to be a waste?
3. **Alternative** — what is the simplest cheaper move that also addresses the need?

It is **advisory and skippable**: `frame it` skips it, exactly as it does in that skill.

Present **three doors** — *proceed*, *shrink the bet*, or *don't* — and map the person's answer onto the unchanged five-value enum before recording anything:

| Door | Enum outcome | What follows |
| --- | --- | --- |
| proceed | `Proceed-full` or `Proceed-lite` | Continue to step 2 |
| shrink the bet | `Shrink` | Amend the filing's scope, then continue to step 2 |
| don't | `Park` or `Decline` | Record and stop |

The `Proceed-full` / `Proceed-lite` distinction collapses **in presentation only**. The enum, the labels, and same-decision-resume are untouched.

**Recording**: only `Park` and `Decline` record, as a `worth-it-{ISSUE_NUMBER}` entry inside the issue's `engagement-record-experience-{ISSUE_NUMBER}` marker, with `status: parked` / `status: declined`, per `skills/customer-experience/references/value-reflex.md`. That entry is what suppresses re-prompting on a later pickup and distinguishes a declined issue from a fresh one. A proceed outcome records nothing here.

## Step 2 — beat 1: align on what is being built

Beat 1's job is **understanding, not routing**. Nothing in this step decides which path follows.

1. **Ground the filing's claims.** Tag every grounding claim **`source-read`** (verified against the tree or an authoritative source) or **`sample-inferred`** (contestable — an inference from examples). These are doctrine amendment A2's two tags, used verbatim; the brief's epistemic map later consumes them unchanged. A `sample-inferred` claim may not set a tolerance or mandate a mechanism.
2. **Amend the filing in place when a premise is false.** When grounding shows something the issue asserts is untrue, say so, write the correction and its reason into the issue body as a visible amendment note — never a silent rewrite — and continue from the corrected premise. Do not ask the person to re-file. The falsified premise stays visible in the issue's record; it is named again at close-out.
3. **State what is being built, in the person's terms.** Plainly enough that they can recognise their own intent in it, and correct it until they do. Keep the wording theirs where you can.

Carry forward the **still-open list**: the unknowns grounding left standing. Beat 2 reads it, and it becomes the brief's known-unknown section verbatim.

### The affirmation gate

**Beat 2 may not begin until the person has affirmed the what-statement.**

The gate's binding property is the **affirmation itself** — a deliberate act by the person, recorded durably. It is never a quality judgment on how the material was presented; the presentation format is deliberately unspecified, so present it however the conversation reads best.

<!-- open-for-work-non-overridability:begin -->

### Rule: Non-overridability

The affirmation gate is an engagement-gate methodology checkpoint, and it is unconditional with respect to user pacing or auto-mode directives. "Work without stopping," "don't pause to ask," "make the reasonable call," and semantically equivalent productivity directives apply to preference-clarifying pauses, not to methodology checkpoints, and they do not suppress this gate. The user's in-band lever is the gate's own negative outcome: declining to affirm — saying the what-statement is wrong, or simply not affirming it — stops beat 2 and returns the conversation to beat 1, which is the gate working rather than a bypass of it. There is no separate decline option, for the same reason `safe-operations` §2e has none: the choice the gate presents is itself the override.

<!-- open-for-work-non-overridability:end -->

This gate is registered in the engagement-gate non-overridability register on both platform surfaces — `CLAUDE.md` § Engagement-gate non-overridability and `.github/copilot-instructions.md` § Engagement-gate non-overridability.

### Writing the affirmation record

The record is what makes authority source (b) checkable rather than asserted. Five properties fix its shape; none of them is an implementer's choice.

**1. Surface.** The record is an **issue comment** on the issue being opened — never only an issue-body section. Comment timestamps are the ordering evidence; a body section carries no timestamp of its own.

**2. Identity — the registered form.** The comment carries a marker of the `open-for-work-affirmed-{ID}` family, where `{ID}` is the issue number. *(Rendered inert here — delimiters stripped, per `skills/session-memory-contract/references/handoff-markers.md` § Writing about markers safely — because a delimited literal in prose is live to the raw-text scanners that read real comments.)*

Write it through the repository's marker-write primitive, which is the **only** documented write path for this family:

```powershell
pwsh ./skills/session-memory-contract/scripts/persist-marker.ps1 `
  -Owner {owner} -Repo {repo} -Family open-for-work-affirmed `
  -Number {N} -TargetSurface issue `
  -Marker '{the delimited open-for-work-affirmed-{N} marker}' `
  -BodyFile .tmp/issue-{N}/affirmation.md
```

The body file's first line is the marker; the rest is the affirmed what-statement quoted in full, plus a human-readable heading line. Keep the heading ASCII-only (a plain hyphen, no em dash) — this repository has a documented console-encoding corruption history on non-ASCII round-trips.

The family is registered `post-new`: **every affirmation appends a new comment, and no affirmation ever edits or overwrites an earlier one.** This is not a stylistic preference. Property 3 below voids an edited record as an ordering witness, the escape hatch posts a new record rather than editing the old one, and the beat-2 re-route count is derived by counting records. An in-place write shape would silently destroy all three.

**3. Identity — the interim practiced form, still recognised.** Before the family was registered, the record was written as a plain issue comment whose **first line is exactly**:

```text
**Open-for-work affirmation (interim form, issue 957 Amendment 8) - issue {N}**
```

Records in that form already exist on real issues. **They remain valid source-(b) authority for their issue, permanently.** Supersession changed the form of *new* records; it did not retroactively invalidate old ones. A resume must recognise both forms — see [Resuming](#resuming-an-issue-already-opened-for-work). Do not write new records in the interim form: new affirmations use the registered form above.

**4. Ordering — a constraint, not a description.** The affirmation record **must exist before the routing decision's artifact is written**: before the brief's plan comment on the routine arm, before the design-completion marker on the novel arm. A routing artifact whose timestamp precedes the issue's affirmation record is **not lawful** under source (b).

An affirmation comment **edited after creation** (its `updated_at` later than its `created_at`) is **void as an ordering witness** — a back-dated retro-fit must not be able to pass as an original. Post a new record instead of editing an old one, on either arm.

**5. Durable record versus human-readable mirror.** The comment is the authoritative record. Additionally mirror the affirmed what-statement into the **issue body** so a human reading the issue sees what was agreed without opening the comment thread. If the two ever diverge, **the comment governs**; the mirror is never the lawfulness source. Say so at the mirror site.

**Trust model.** The record is **self-attested** by the conversation that posts it — it does not evidence *who* typed the affirmation, consistently with every other engagement record in this system. The gate's protection is its non-overridability at question time, not authorship proof in the artifact.

## Step 3 — beat 2: which path follows

After affirmation, read the **still-open list** against the affirmed what-statement and classify each entry by one question:

> *Could this unknown change **what** we affirmed we are building, or change **how we would know it is done**?*

- **Any yes → novel.** At least one open question could void a target or a boundary; writing a brief now would mean guessing at it.
- **All no → routine.** Everything still open is something the run itself can settle.

This is the same knowledge-shaped test as the brief's escalation rule, restated for the pre-brief moment. The classification is expressed **against the list**, entry by entry, not as a free judgment call — that is what lets a reviewer check the call later.

Record the verdict and the per-entry reasoning where the arm's output artifact carries it (below). The still-open list, so classified, becomes the brief's `## 2. Epistemic map` known-unknown section verbatim: the routing evidence and the plan's epistemic honesty are the same artifact.

## Step 4 — the two outputs

Both arms exit this conversation. Neither invents a new artifact class.

### Routine arm — a brief

Author a brief meeting the **unchanged** six-section contract in `skills/plan-authoring/SKILL.md` § Brief plan variant, and persist it as the issue's plan comment with `plan-variant: brief` frontmatter.

- The brief is lawful under **authority source (b)** — the issue's affirmed open-for-work framing record. **No deviation note.**
- The plan-approval prompt — an existing registered non-overridable gate — fires at brief persistence exactly as it does today.
- The routing decision and its falsifier ride the brief itself.

### Novel arm — the same conversation continues into design

The novel verdict is a **routing target, not a construction**. Continue **inline, in this same conversation**, into the existing design methodology: adopt the Solution-Designer role from `agents/Solution-Designer.agent.md`, run the 3-pass design challenge, and exit at the standard design-completion marker. Sub-issue creation goes through `skills/safe-operations/SKILL.md` §2's gates; the chunk sub-issues are each planned as a brief under **authority source (a)**, exactly as chunked delivery already provides.

No seams artifact. No new review shape. No third authority source. The entrance's promise stays honest: one conversation, which *continues* rather than ends when the work turns out to be novel.

On this arm the routing decision and its falsifier ride the design-completion marker — the arm's output artifact — exactly as the routine arm's ride the brief. The novel arm's routing verdict deliberately has no separate reviewer; the reasoning is recorded in the doctrine document's § Review.

## The standalone escape hatch

When a **routine**-arm run later hits a target-voiding unknown mid-run — the situation that, for a chunk, escalates to the designed parent — the standalone destination is the issue's **affirmed framing record**, which is the standalone arm's parent-design-equivalent.

1. Amend the framing record **in place** — meaning: post an **updated affirmed what-statement as a new record** (same form rules, new timestamp). Never edit the old comment.
2. The person re-affirms. The gate fires again, unconditionally.
3. Re-run beat 2 against the updated still-open list.
4. **Record the re-route.** The count is a named close-out datum; zero is the common and reportable case.

The count is derivable by counting the issue's affirmation records and subtracting one, which is exactly why the family appends rather than overwrites.

## Resuming an issue already opened for work

A resume reads the issue's comments and answers two questions: *is there a lawful affirmation record*, and *what state is this issue in*.

**Read the comments through `gh api`, not `gh issue view`.** This is not interchangeable: `gh issue view --json comments` returns `includesCreatedEdit` and carries **no `updated_at` field at all**, so property 4's void-if-edited rule cannot be evaluated from it — and a null comparison fails silently in the permissive direction, accepting an edited record as an ordering witness.

```bash
gh api repos/{owner}/{repo}/issues/{N}/comments --paginate
```

**Finding the record** — accept either form:

- **Registered form**: the body's first line is the delimited `open-for-work-affirmed-{N}` marker.
- **Interim practiced form**: the body's first line is exactly `**Open-for-work affirmation (interim form, issue 957 Amendment 8) - issue {N}**`. Scan for that literal first line, not for a marker — interim records carry none.

**Edit state**: for each candidate, compare `updated_at` against `created_at`. Later means the record is **void as an ordering witness** — skip it and use an unedited one. If no unedited record survives, the issue has no lawful source-(b) authority; say so rather than proceeding.

**The three states**, decided from the record plus the issue's routing artifacts:

| State | Evidence | What the resume does |
| --- | --- | --- |
| **affirmed-not-routed** | A lawful affirmation record; no brief plan comment and no design-completion marker | Resume at **beat 2**. Do not re-run the worth-it check or beat 1, and do not ask to run `/design` first — the record plus a routine verdict are the lawful authority. |
| **routed** | A lawful affirmation record **and** a routing artifact (a `plan-variant: brief` plan comment, or the design-completion marker), issue open | The routing decision is made. Continue the run under that artifact; do not re-affirm unless the escape hatch fires. |
| **complete** | The issue is closed | Nothing to resume. The outstanding obligation is the close-out record — see `skills/post-pr-review/SKILL.md` § Close-out record. |

**A record alone, with beat 2 unrun, does not authorize a brief.** That is the affirmed-not-routed state, and its answer is to run beat 2 — not to author.

## Gate-decision tokens

Every checkpoint this conversation runs emits a **gate-decision token** — the agent's own self-report that a gate fired and how it resolved, written to the session event log (the "L0" layer, the agent-written one, as opposed to the hook-written L1 and the reconciler L2) — per `skills/solution-authoring/SKILL.md` § L0 Gate Token. Instructing emission is not enough to make the tokens readable, so each checkpoint's four fields are fixed here.

**All tokens from this conversation carry `phase: experience`.** The conversation is the experience-replacement, and the token schema's closed five-value phase enum is **deliberately not extended** — a token carrying a new enum value fails validation before it reaches the reconciler, and every consumer filters on the five existing values. Do not "fix" this mapping by adding an open-for-work phase; the rationale is recorded here and in `skills/solution-authoring/SKILL.md` § L0 Gate Token so a later reader finds it before editing the schema.

| Checkpoint | `decision_id` | `window_position` | `classification` | `outcome` |
| --- | --- | --- | --- | --- |
| Worth-it doors | `worth-it-{N}` | `pre-ask` | `load-bearing` on Park/Decline; `routine` otherwise | `asked`, or `same-decision-resume` when a prior `worth-it-{N}` entry suppresses the prompt, or `declined` on `frame it` |
| Affirmation gate | `open-for-work-affirmation` | `pre-ask` | `load-bearing` | `asked` |
| Brief approval (routine arm) | `open-for-work-brief-approval` | `pre-ask` | `load-bearing` | `asked` |

`window_position` is `pre-ask` for all three: that value is the classification gate's pre-dispatch firing position, which is where each of these fires. `unknown` would validate and reconcile against nothing — do not use it.

**Every load-bearing `asked` token must have a correspondingly recorded decision**, or the reconciler warns on every subsequent run. Record each one as a `load_bearing_decisions` entry with the **same `decision_id`** in the issue's `engagement-record-experience-{ISSUE_NUMBER}` marker (`skills/engagement-record-emission/SKILL.md`; `capture_session: "normal-experience-v2"`). That marker is this conversation's single engagement record; the `worth-it-{N}` entry lives in it too.

Check the result rather than assuming it:

```powershell
pwsh -NoProfile -Command ". .github/scripts/lib/gate-reconciliation-core.ps1 -Phase experience -IssueNumber {N}"
```

A `status: clean` result discharges this. A `findings` result must be explained, not ignored.

## Review

A brief produced by this flow takes the **same review a chunk brief takes** — the brief charter:

1. The `#### Brief conformance check` (author before dispatch, reviewer as first act).
2. The prosecution-only `design-challenge` adapter — three lenses, no defense, no judge — plus the **convergence filter** over the merged ledger.

The review runs **once**, after beat 2's artifact exists and before the worktree opens.

**The routing call is a named review target on the routine arm.** The reviewer locates the recorded verdict, re-asks beat 2's question over the brief's own known-unknown entries, and rules one of four ways: routine and consistent with the map; routine but inconsistent (a finding); **novel**, which authorizes no brief at all; or **absent**, which is a review failure rather than a gap. **On this flow the outcome is never not-applicable** — a brief produced here is source (b), so it must carry a routine verdict consistent with its map. The not-applicable arm is reserved for source-(a) chunk briefs, and even there it must state its basis.

**The alignment beat itself gets no adversarial pass.** The person is ground truth for what they want built; an agent prosecuting that would be prosecuting them.

## Close-out

When the issue closes, the conversation's owner writes the close-out record on the issue: one line per sustained finding, a dead-premises note, and the beat-2 re-route count. The obligation and its exact shape live at the close-time surface that already runs at that moment — `skills/post-pr-review/SKILL.md` § Close-out record. This flow adds no ledger-emission machinery of its own.

## Related Guidance

- [`Documents/Design/open-for-work.md`](../../Documents/Design/open-for-work.md) — the doctrine: rationale, the whole flow, and the decisions behind each contract here.
- [`skills/safe-operations/SKILL.md`](../safe-operations/SKILL.md) — §2a the trivial floor (canonical), §2f the filing content standard.
- [`skills/plan-authoring/SKILL.md`](../plan-authoring/SKILL.md) — § Brief plan variant: the six-section contract, the conformance check, and the routing call as a review target.
- [`skills/customer-experience/SKILL.md`](../customer-experience/SKILL.md) — § Value Reflex: the worth-it prompts and the five-value enum.
- [`skills/solution-authoring/SKILL.md`](../solution-authoring/SKILL.md) — § L0 Gate Token: the token contract these checkpoints emit against.
- [`skills/engagement-record-emission/SKILL.md`](../engagement-record-emission/SKILL.md) — the engagement-record marker this flow's decisions are recorded in.
- [`skills/session-memory-contract/references/handoff-markers.md`](../session-memory-contract/references/handoff-markers.md) — the marker catalog, including this flow's affirmation-record family.
- [`skills/post-pr-review/SKILL.md`](../post-pr-review/SKILL.md) — § Close-out record.
