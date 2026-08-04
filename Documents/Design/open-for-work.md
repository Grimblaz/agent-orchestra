# Opening an issue for work

Ratified 2026-08-02 (issue #957, design decisions D1–D10; chunk 1 = #972). This document is the doctrinal home for the **open-for-work flow**: the single conversation that takes a filed standalone issue to something an executor can run. It exists so that the whole flow can be read in one place rather than reconstructed from amendments scattered across other guidance.

<!-- vocab-pointer -->
> **Unfamiliar with a code or term?** Shortcodes like `SMC-NN`, `D1/D2/D3`, and `CE Gate` are defined in the [plain-language vocabulary](../../HOW-IT-WORKS.md#vocab).

## Availability

This flow was designed in #957 and landed in three chunks, all of which have shipped. **Every piece of the flow's machinery is in the tree**: `/open {issue}` is the entrance, [`skills/open-for-work/SKILL.md`](../../skills/open-for-work/SKILL.md) is the methodology it runs, the `open-for-work-affirmed-{ID}` marker family is registered in the marker-write primitive, and the affirmation gate is enumerated in the engagement-gate non-overridability register on both platform surfaces.

**This document is doctrine, not the operating procedure.** It records why the flow is shaped the way it is and which contracts a change must not break. A run follows the skill; the skill is self-contained and does not need this document handed to it. Where the two describe the same contract, this document holds the rationale and the skill holds the instruction — and any drift between them is a defect in the skill, since the contracts here are what #957 ratified.

Two things stated here have no live machinery behind them and say so at their own sites: the interim practiced form of the affirmation record (superseded for new records, permanently valid for records already made — § [The affirmation record](#the-affirmation-record)), and Copilot, which is frozen and ships neither `/open` nor the `/plan`-side resume.

## The problem this flow solves

Before #957, a standalone issue had two routes to an executable artifact: the full three-phase pipeline (`/experience` → `/design` → `/plan`, one conversation each), or a **brief** (the six-section chunk-plan shape, `plan-variant: brief`) authored against doctrine that only permitted it for a chunk sub-issue of a designed parent — which meant writing a self-annotated deviation note that no downstream reader ever sees. Two issues in one week (#948, #922) paid full phase ceremony and *still* needed the deviation note, because the gate was on the artifact, not on the phase-skipping. That is the signature of a missing law, not of operators cutting corners.

## The flow, whole

One entrance, one fork. The fork is about **knowledge, not size**; it lives inside the conversation; and both of its arms belong to this flow.

```text
filed issue   (required: problem · evidence · known vs unknown; §2f)
      │
      ▼
  open it for work — ONE conversation
      │
      ├─ worth-it check: bet / falsifier / cheaper alternative
      │        └─ three doors: proceed · shrink the bet · don't
      │
      ├─ BEAT 1 — align on WHAT
      │     ground the claims (source-read / sample-inferred)
      │     amend the filing in place where a premise is false
      │     state what is being built, in the person's terms
      │     ── gate: the person affirms it; the affirmation is recorded ──
      │
      └─ BEAT 2 — evaluate WHICH PATH
            read the still-open list against the affirmed what-statement
                    │
         ┌──────────┴──────────┐
         │ no unknown could    │ some unknown could
         │ void it → routine   │ void it → novel
         ▼                     ▼
   brief, persisted as    the SAME conversation
   the issue's plan       continues into /design
   comment                (existing methodology,
   (plan-variant: brief,   design-phase-complete
   authority source (b))   marker) → chunk sub-issues,
         │                 each planned as a brief
         │                 under authority source (a)
         └──────────┬──────────┘
                    ▼
        review: the brief charter, per brief
                    ▼
        worktree + run → merge → close-out record
```

Beneath the whole flow sits the **trivial floor**: work below it exits the conversation with a direct-fix disposition — no brief, no run ceremony. See [The trivial floor](#the-trivial-floor).

### The entrance

The process is called **opening an issue for work**. Its invocation surface is the explicit command `/open {issue}` ([`commands/open.md`](../../commands/open.md)) — one short command, no natural-language routing intent, no confirmation mechanics (#957 D9, Amendment 5). `/experience` and `/design` stay reserved as the explicit way to request the old phase pipeline, which remains lawful — this flow inverts the default for standalone work; it deletes nothing.

The absence of a natural-language routing intent is deliberate and is a **standing property**, not an omission awaiting wiring: a bare pickup ("let's work on #123") must not silently enter a flow whose first act is an engagement gate.

### The worth-it check and its three doors

The conversation opens with the worth-it check — the same three prompts the Value Reflex asks today (`skills/customer-experience/SKILL.md` § Value Reflex): **bet** (what specific bet is this change making?), **falsifier** (what would have to be true for this to be a waste?), and **alternative** (what is the simplest cheaper move that also addresses the need?). It is advisory and skippable, exactly as it is there.

The conversation presents **three doors**: *proceed*, *shrink the bet*, or *don't*. Behind the doors, the agent maps the outcome onto the existing five-value enum (`Proceed-full`, `Proceed-lite`, `Shrink`, `Park`, `Decline`) so that the recording contract survives unchanged (#957 D10): "don't" records as `Park` or `Decline` with the existing `worth-it-{ISSUE_NUMBER}` engagement-record entry, which is what suppresses re-prompting and distinguishes a declined issue from a fresh one. The `Proceed-full`/`Proceed-lite` distinction collapses in presentation only — the enum, the labels, and same-decision-resume are untouched.

### Beat 1 — align on what is being built

Beat 1's job is understanding, not routing. Concretely, the conversation:

1. **Grounds the filing's claims**, tagging each grounding claim **source-read** (verified against the tree or an authoritative source) or **sample-inferred** (contestable — an inference from examples), the same two provenance tags doctrine amendment A2 defines. Grounding provenance is promoted into this conversation from the phase pipeline it replaces (#957 d-phase-inheritance).
2. **Amends the filing in place when a premise is false.** When grounding finds that something the issue asserts is untrue, the conversation says so, writes the correction and its reason into the issue (an amendment note in the body, not a silent rewrite), and continues from the corrected premise. The person is not asked to re-file. The falsified premise stays visible as part of the issue's record — dead premises are named again at close-out.
3. **States what is being built, in the person's terms** — plainly enough that the person can recognise their own intent in it, and correct it until they do.

**The affirmation gate**: beat 2 may not begin until the person has affirmed the what-statement (#957 d-alignment-gate). The gate's binding property is the affirmation itself — a deliberate act by the person, recorded durably (see [The affirmation record](#the-affirmation-record)) — never a quality judgment on how the material was presented; the presentation format is deliberately unspecified. The gate is an engagement-gate methodology checkpoint: a pacing directive ("work without stopping", "don't pause to ask") does not suppress it. It is enumerated in the engagement-gate non-overridability register on both platform surfaces, and `skills/open-for-work/SKILL.md` carries the matching skill-side `### Rule: Non-overridability`.

### Beat 2 — evaluate which path follows

After affirmation, the conversation reads the **still-open list** — the unknowns beat 1's grounding left standing — against the affirmed what-statement, and classifies each entry by one question (#957 D3):

> *Could this unknown change **what** we affirmed we are building, or change **how we would know it is done**?*

- **Any yes → novel.** At least one open question could void a target or a boundary; writing a brief now would mean guessing at it.
- **All no → routine.** Everything still open is something the run itself can settle.

This is the same knowledge-shaped test as the brief's escalation rule (`skills/plan-authoring/SKILL.md` § Brief plan variant: an unknown that could void a criterion routes up rather than being resolved in the brief), restated for the pre-brief moment. The still-open list, so classified, becomes the brief's `## 2. Epistemic map` known-unknown section verbatim — the routing evidence and the plan's epistemic honesty are the same artifact.

### The two outputs

**Routine arm — a brief.** The conversation authors a brief meeting the unchanged six-section contract (`skills/plan-authoring/SKILL.md` § Brief plan variant) and persists it as the issue's plan comment (`plan-variant: brief` frontmatter). The brief is lawful under **authority source (b)** — the issue's affirmed open-for-work framing record — with no deviation note (#957 D4). The plan-approval prompt, an existing registered non-overridable gate, fires at brief persistence exactly as it does today. The routing decision and its falsifier ride the brief itself.

**Novel arm — the same conversation continues into design.** Beat 2's novel verdict is a routing target, not a construction (#957 D8): the conversation continues inline into the existing `/design` methodology — Solution-Designer role, the 3-pass design challenge, the standard `design-phase-complete` marker, sub-issue creation through `skills/safe-operations/SKILL.md` §2's gates — and its chunk sub-issues are each planned as a brief under **authority source (a)**, a designed parent, exactly as chunked delivery already provides. No seams artifact, no new review shape, no third authority source. The entrance's promise stays honest: one conversation, which *continues* rather than ends when the work turns out to be novel. The novel arm's chunk output is bound by the acceptable-resting-state rule ([chunked-delivery.md § Operating rules](chunked-delivery.md)). On this arm the routing decision and its falsifier ride the `design-phase-complete` marker — the arm's output artifact — exactly as the routine arm's ride the brief (#957 D5).

### The rule that decides the path — and the standalone escape hatch

The routing rule is beat 2's classification question above; it is expressed against the conversation's own still-open list rather than as a free judgment call, so a review can check the call against the list (on the routine arm the routing call is a named review target — see [Review](#review), which also records why the novel arm's verdict deliberately has no separate reviewer).

**The escape hatch** (#957 D3): when a **routine**-arm run later hits a target-voiding unknown mid-run — the situation that, for a chunk, escalates to the designed parent — the standalone destination is the issue's **affirmed framing record**, which is the standalone arm's parent-design-equivalent. Amend the framing record in place (post an updated affirmed what-statement; the person re-affirms), re-run beat 2 against the updated still-open list, and record the re-route. The re-route count is a named close-out datum.

### The trivial floor

Whether an issue is below the trivial floor is decided **at pickup, from the filed issue alone**, by the same structural-criteria set that decides mid-run follow-up disposition and review deferral — one criteria set, three moments (#957 D6). The canonical statement of the criteria, their pickup-time reading, and the risk guard all live in `skills/safe-operations/SKILL.md` §2a — read the floor there rather than from any summary here.

**Verdict below the floor**: fix it directly. No brief, no run ceremony, no issue theatre. The conversation says so and ends.

### Review

A brief produced by this flow takes the same review a chunk brief takes — the **brief charter**: the `#### Brief conformance check` (author before dispatch, reviewer as first act), then the prosecution-only `design-challenge` shape (three lenses, no defense, no judge) plus the convergence filter over the merged ledger. The review runs once, after beat 2's artifact exists and before the worktree opens. The **routing call** — beat 2's routine-versus-novel classification against the still-open list — is a named review target **on the routine arm**, and the charter aims at it: `skills/plan-authoring/SKILL.md` § The routing call as a review target has the reviewer locate the recorded verdict, re-ask beat 2's question over the brief's own known-unknown entries, and rule one of four ways — routine and consistent with the map; routine but inconsistent (a finding); **novel**, which authorizes no brief at all; or **absent**, which under Amendment 10 is a review failure rather than a gap, since a framing record with beat 2 unrun does not authorize a brief at all. The vacuity question lands twice in the same charter (#957 D2): as conformance-check property 5, and as a required question in the convergence cold read whose answer is emitted whichever way it comes out. On that second landing the shell performing the cold read is the instructed producer, and its answer — a surviving reading, or the stated sentence that none survived — is persisted into the review's `**Plan Stress-Test**` summary, so silence about vacuity is a nonconforming record rather than a clean one. The routing-call outcome lands on that same surface. **On this flow the outcome is never not-applicable**: a brief produced here is source (b), so it must carry a routine verdict consistent with its map — the not-applicable arm is reserved for source-(a) chunk briefs, which carry no verdict of their own, and even there it must state its basis. The alignment beat itself gets no adversarial pass: the person is ground truth for what they want built, and an agent prosecuting that would be prosecuting them (#957 d-review-shape).

**The novel arm's routing verdict has no separate reviewer, and that is a decision rather than an omission** (owner disposition 2026-08-03, from the #973 chunk-2 escalation). D5 has that verdict ride the `design-phase-complete` marker, and no review surface names it a target. The asymmetry follows from what each misclassification actually costs. A wrongly-**routine** call produces a brief whose criteria rest on an unknown capable of voiding them — an *unsoundness* failure, and precisely what the brief charter above exists to catch. A wrongly-**novel** call produces a design phase that was not needed: the work still becomes a designed parent whose chunk sub-issues are each planned as briefs and each take the full brief charter, so what is lost is ceremony, not correctness. **The unreviewed direction is the safe one.** Buying a reviewer for it would mean adding an obligation to every design review — the path #957 P1-F12 deliberately left behaviourally unchanged — in order to catch a waste failure. Revisit if the phase-containment ledger ever shows novel-arm misclassification producing defects rather than overhead; that evidence, not a symmetry argument, is what would reopen this.

### The close-out habit

When the issue closes, the conversation's owner writes the close-out record on the issue. The instruction lives on the surface that already runs at that moment — `skills/post-pr-review/SKILL.md` § 9. Close-Out Record (Issues Opened For Work) — so an agent walking the close-time checklist reaches it without being pointed here first; it applies only to issues that carry an affirmation record. Three things:

- **One line per sustained finding** — where it was introduced, where it was catchable, where it was caught (the phase-containment ledger's grain; emission mechanics ride #951/#940/#944, this flow adds none).
- **A dead-premises note** — which filed premises were falsified during the flow and amended in place, so the next reader does not resurrect them.
- **The beat-2 re-route count** — how many times the escape hatch re-ran the routing (zero is the common, and reportable, case).

## The affirmation record

The affirmation record is what makes authority source (b) checkable rather than asserted. Its contract is fixed here, completely, so that no implementer has discretion about its shape (#957 D5, Amendment 8). Five properties:

1. **Surface.** The record is an **issue comment** on the issue being opened — never only an issue-body section: comment timestamps are the ordering evidence, and a body section carries no timestamp of its own, which disqualifies it as a lawfulness source. (A comment body is also editable in place — that is why property 3 voids edited records rather than pretending edits cannot happen.) The registered form is written via `persist-marker.ps1` and is visible to marker-keyed resume readers; the interim form (below) is never written through that family and **carries no marker**, so a reader checking for an interim-form record scans the issue's comments for its exact first line rather than for a marker.
2. **Identity.**
   - *Registered form (live; family registered by #974):* the comment carries a marker of the `open-for-work-affirmed-{ID}` family, where `{ID}` is the issue number. (That family name is rendered here inert — delimiters stripped, per the handoff-marker registry's § Writing about markers safely — because a delimited literal in prose is live to the raw-text scanners that read real comments.) The placeholder is written `{ID}` rather than the `{N}` this document used before the row existed: the catalog/registry drift guard recognizes only `-{ID}` and `-{PR}` and silently skips any other token, so `{N}` would have opted this family out of the guard that exists to catch exactly the kind of write-shape drift property 3 depends on. Runtime behavior is identical either way. **Write shape is `post-new`** — see property 3 for why that is load-bearing rather than incidental.
   - *Interim practiced form (superseded for new records, #957 Amendment 8):* an issue comment whose **first line is exactly** `**Open-for-work affirmation (interim form, issue 957 Amendment 8) - issue {ID}**` (bold text, ASCII only — a plain hyphen, deliberately no em dash given this repository's documented console-encoding corruption history, no `#`-prefixed cross-reference, no HTML-comment delimiters; `{ID}` is the issue number), followed by the affirmed what-statement quoted in full. Records in this form exist on real issues and **remain valid authority for their issue permanently** (§ Supersession); a resume must still recognise them. New records use the registered form above. (The spelled-out "Amendment 8" is deliberate: the short form "A8" belongs to the chunked-delivery doctrine-amendment namespace `A1`–`A5`, which `DA{N}` was minted to avoid colliding with.)
3. **Ordering — stated as a constraint, not a description.** The affirmation record **must exist before the routing decision's artifact is written**: on the routine arm, before the brief's plan comment; on the novel arm, before the `design-phase-complete` marker. A routing artifact whose timestamp precedes the issue's affirmation record is not lawful under source (b). Comment timestamps are the evidence — and an affirmation comment that has been **edited after creation** (its `updated_at` later than its `created_at`) is **void as an ordering witness**: post a new record instead of editing an old one, on either arm, so a back-dated retro-fit cannot pass as an original.

   This is why the registered family's write shape is `post-new` and never `upsert`: an in-place write would edit the existing record on every re-affirmation, voiding it under this very rule, erasing the escape hatch's new-record requirement below, and destroying the per-re-affirmation ordering witnesses the record sequence provides (the re-route count itself is what the conversation observed; record counts only cross-check it). **A reader must fetch comments through `gh api repos/{owner}/{repo}/issues/{ID}/comments` to evaluate this property at all** — `gh issue view --json comments` returns `includesCreatedEdit` and no `updated_at`, and a null comparison fails silently in the permissive direction.
4. **Gate-decision token phasing.** Gate-decision tokens emitted by this conversation's checkpoints (the worth-it doors, the affirmation gate, plan approval on the routine arm) map to `phase: experience` — the conversation is the experience-replacement, and the token schema's closed five-value phase enum is deliberately not extended (#957 D5).
5. **Durable record versus human-readable mirror.** The comment is the authoritative record. The affirmed what-statement **is** additionally mirrored into the issue body for human reading (#957 D5); if the two ever diverge, the comment governs, and the mirror is never the lawfulness source.

**Trust model — self-attested, by decision (#957 Amendment 11), with the planted-record gap disclosed and accepted (#957 Amendment 13).** The record does not evidence *who* typed the affirmation: it is self-attested by the conversation that posts it, consistent with every other engagement record in this system. A sixth attestation degree of freedom was considered and declined; the gate's protection is its non-overridability at question time (register entries on both platform surfaces), not authorship proof in the artifact.

That decision leaves a gap, and it is stated here rather than left to be discovered. Recognition is by comment **shape alone** — no surface tests authorship — and this repository is public with both recognised forms published verbatim, so **anyone with a GitHub account who can comment on the issue can post a record every recognition surface accepts**, owner or not, collaborator or not. **Nothing gates it**: no author check, no permission check, and no approval between the comment landing and a resume acting on it. Nor is the effect confined to which review shape a brief receives — the `affirmed-not-routed` resume state instructs a run to skip the worth-it check and beat 1, so a planted record supplies the very what-statement the work is then built against.

**This is a known and accepted failure mode, not an oversight.** Amendment 11's protection is the gate's non-overridability *at question time*; a planted record means no run, no question, and no gate, so that protection never covered this case. #957 Amendment 13 re-examined the decision, **reaffirmed self-attestation unamended**, and accepted the exposure — measured at zero occurrences, against a contributor population of one — with **disclosure** as the mitigation instead of a check: every surface that resumes or routes on a record states who posted it, so an unexpected author is visible rather than something a reader must think to look up. Disclosure adds no attestation, so the degree of freedom Amendment 11 declined stays declined. The acceptance is revisited if the contributor population grows or a planted record is ever observed.

**On noticing a record posted by someone you did not expect to be affirming work on this issue** — the trigger is an *unexpected* author, not merely one who is not you; resuming under a lawful record someone else wrote is the ordinary case these records exist for — stop, and do not resume under it. Say on the issue which comment you are declining and why — nothing records that for you. Leave the comment in place rather than editing it: an edit voids a record as an ordering witness under property 3 and destroys the evidence. If the work should still proceed, run beat 1 yourself and post a **new** record, as the escape hatch does. Escalate to the repository's owner when you cannot tell whether the author is legitimate — that judgment is a person's, deliberately, because a rule for it would be the check this trust model declined. The operational form of these steps lives in [`skills/open-for-work/SKILL.md`](../../skills/open-for-work/SKILL.md) § Writing the affirmation record.

**Supersession.** The marker family is registered, so new affirmations use the registered form. An interim-form record already on an issue remains a valid source-(b) authority for that issue — supersession changes the form of new records, it does not retroactively invalidate old ones. The escape hatch's "amend the framing record in place" posts a **new** record (same form rules, new timestamp) rather than editing the old comment, so the ordering evidence stays honest.

## The filing contract

Filing an issue's **required** content is three things (#957 d-filing-shape): the **problem**, the **evidence it is real**, and **what is known versus unknown**. No proposed solution, no design, no scope decision, and no scenarios are required to file — those are this conversation's job, later, if the issue is ever opened for work; a filer who already has a proposed solution in mind may include it, but its absence never blocks or discounts a filing. The operative rule lives in `skills/safe-operations/SKILL.md` §2f, and the repository's issue templates ask for exactly these three required things.

## Default posture

The open-for-work entrance is the **expected route for standalone work**; the three-phase pipeline is the thing you reach by explicitly asking for it (`/experience` or `/design`), and it remains lawful (#957 § Default posture, owner decision 2026-07-28). Deletion of any phase machinery is a separate, evidence-gated decision that belongs to #953 — this flow inverts the default and deletes nothing.

## Running the flow

Type `/open {issue}`. The command loads [`skills/open-for-work/SKILL.md`](../../skills/open-for-work/SKILL.md) and runs the flow inline in that conversation; if the methodology cannot be loaded the command halts rather than improvising the flow from this document. The skill owns the operating detail — the trivial-floor read, the worth-it doors, the beats, the affirmation record's write path, beat 2's classification, both output arms, resume-state detection, and gate-token emission.

Two entry points other than `/open` reach the same flow, and neither is a second methodology:

- **A `/plan` invocation on an issue that already carries an affirmed framing record** resumes the conversation at beat 2 and, on a routine verdict, authors the plan as a brief under source (b) (#957 Amendment 10) — see the pre-flight in `commands/plan.md`, a **Claude-only surface** (`<!-- scope: claude-only -->`). The record alone, with beat 2 unrun, does not authorize a brief.
- **A conversation that walks the beats by hand**, following this document, remains lawful — the flow was designed to be exercisable that way and #957's own framing conversation is the existence proof. It is no longer the expected route, and a run that takes it should still write the affirmation record through the registered family rather than the superseded interim form.

**On Copilot the flow has no command.** Copilot ships neither `/open` nor the `/plan` pre-flight, and that will not change: support is frozen and retires after 2026-08-31 (`Documents/Design/copilot-deprecation.md`).

## Relationship to neighbouring doctrine

- **Chunked delivery** (`chunked-delivery.md`): authority source (a), the seams/contract bounds, and the chunk operating rules are unchanged. This flow adds source (b) for standalone issues; the A1–A5 amendments bind a brief under either source (see that document's § How a chunk plan specifies).
- **#924** owns `/plan`-side recognition of an already-filed **chunk** sub-issue; this flow owns the **standalone** entrance. The two do not overlap.
- **#949** owns the run's terminal sequence (review-run, suite-state accounting); **#951/#940/#944** own ledger emission mechanics. This flow adds no emission machinery.
