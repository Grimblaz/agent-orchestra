# Opening an issue for work

Ratified 2026-08-02 (issue #957, design decisions D1–D10; chunk 1 = #972). This document is the doctrinal home for the **open-for-work flow**: the single conversation that takes a filed standalone issue to something an executor can run. It exists so that the whole flow can be read in one place rather than reconstructed from amendments scattered across other guidance.

<!-- vocab-pointer -->
> **Unfamiliar with a code or term?** Shortcodes like `SMC-NN`, `D1/D2/D3`, and `CE Gate` are defined in the [plain-language vocabulary](../../HOW-IT-WORKS.md#vocab).

## Availability — what is live and what is pending

This flow was designed in #957 and lands in three chunks. **After chunk 1 (this document), the flow is lawful and fully specified, and it runs manually** — see [Running the flow today](#running-the-flow-today). The pieces that are not yet available, each named with the chunk that delivers it:

- **The explicit `/open {issue}` command and `skills/open-for-work/SKILL.md`** — pending, #957 chunk 3. No `/open` command exists in the repository today; do not offer it as an invocable surface.
- **The registered `open-for-work-affirmed-{N}` marker family** — pending, #957 chunk 3. Until it registers, the affirmation record uses the [interim practiced form](#the-affirmation-record) defined below (#957 Amendment 8).
- **The strengthened brief-review teeth** — the vacuity property in the brief conformance check and the required vacuity question in the convergence cold read — pending, #957 chunk 2. Until then a brief from this flow takes today's brief charter unchanged.
- **The affirmation gate's entries in the engagement-gate non-overridability register** (both platform surfaces) — pending, #957 chunk 3. The gate is binding as doctrine from this document; the register entries make it machine-audited.

The central pending-machinery record for #957, with its retirement owner, lives in [chunked-delivery.md § Pending machinery owned by #957](chunked-delivery.md#pending-machinery-owned-by-957-open-for-work).

## The problem this flow solves

Before #957, a standalone issue had two routes to an executable artifact: the full three-phase pipeline (`/experience` → `/design` → `/plan`, one conversation each), or a **brief** (the six-section chunk-plan shape, `plan-variant: brief`) authored against doctrine that only permitted it for a chunk sub-issue of a designed parent — which meant writing a self-annotated deviation note that no downstream reader ever sees. Two issues in one week (#948, #922) paid full phase ceremony and *still* needed the deviation note, because the gate was on the artifact, not on the phase-skipping. That is the signature of a missing law, not of operators cutting corners.

## The flow, whole

One entrance, one fork. The fork is about **knowledge, not size**; it lives inside the conversation; and both of its arms belong to this flow.

```text
filed issue   (problem · evidence · known vs unknown — and nothing else; §2f)
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

The process is called **opening an issue for work**. Its invocation surface is the explicit command `/open {issue}` — one short command, no natural-language routing intent, no confirmation mechanics (#957 D9, Amendment 5). `/experience` and `/design` stay reserved as the explicit way to request the old phase pipeline, which remains lawful — this flow inverts the default for standalone work; it deletes nothing.

> **Pending (chunk 3):** `/open` does not exist yet. Today the entrance is manual — see [Running the flow today](#running-the-flow-today).

### The worth-it check and its three doors

The conversation opens with the worth-it check — the same three prompts the Value Reflex asks today (`skills/customer-experience/SKILL.md` § Value Reflex): **bet** (what specific bet is this change making?), **falsifier** (what would have to be true for this to be a waste?), and **alternative** (what is the simplest cheaper move that also addresses the need?). It is advisory and skippable, exactly as it is there.

The conversation presents **three doors**: *proceed*, *shrink the bet*, or *don't*. Behind the doors, the agent maps the outcome onto the existing five-value enum (`Proceed-full`, `Proceed-lite`, `Shrink`, `Park`, `Decline`) so that the recording contract survives unchanged (#957 D10): "don't" records as `Park` or `Decline` with the existing `worth-it-{N}` engagement-record entry, which is what suppresses re-prompting and distinguishes a declined issue from a fresh one. The `Proceed-full`/`Proceed-lite` distinction collapses in presentation only — the enum, the labels, and same-decision-resume are untouched.

### Beat 1 — align on what is being built

Beat 1's job is understanding, not routing. Concretely, the conversation:

1. **Grounds the filing's claims**, tagging each grounding claim **source-read** (verified against the tree or an authoritative source) or **sample-inferred** (contestable — an inference from examples), the same two provenance tags doctrine amendment A2 defines. Grounding provenance is promoted into this conversation from the phase pipeline it replaces (#957 d-phase-inheritance).
2. **Amends the filing in place when a premise is false.** When grounding finds that something the issue asserts is untrue, the conversation says so, writes the correction and its reason into the issue (an amendment note in the body, not a silent rewrite), and continues from the corrected premise. The person is not asked to re-file. The falsified premise stays visible as part of the issue's record — dead premises are named again at close-out.
3. **States what is being built, in the person's terms** — plainly enough that the person can recognise their own intent in it, and correct it until they do.

**The affirmation gate**: beat 2 may not begin until the person has affirmed the what-statement (#957 d-alignment-gate). The gate's binding property is the affirmation itself — a deliberate act by the person, recorded durably (see [The affirmation record](#the-affirmation-record)) — never a quality judgment on how the material was presented; the presentation format is deliberately unspecified. The gate is an engagement-gate methodology checkpoint: a pacing directive ("work without stopping", "don't pause to ask") does not suppress it.

> **Pending (chunk 3):** the gate's entries in the non-overridability register on the two platform surfaces land with the surface chunk. The gate binds as doctrine from this document regardless.

### Beat 2 — evaluate which path follows

After affirmation, the conversation reads the **still-open list** — the unknowns beat 1's grounding left standing — against the affirmed what-statement, and classifies each entry by one question (#957 D3):

> *Could this unknown change **what** we affirmed we are building, or change **how we would know it is done**?*

- **Any yes → novel.** At least one open question could void a target or a boundary; writing a brief now would mean guessing at it.
- **All no → routine.** Everything still open is something the run itself can settle.

This is the same knowledge-shaped test as the brief's escalation rule (`skills/plan-authoring/SKILL.md` § Brief plan variant: an unknown that could void a criterion routes up rather than being resolved in the brief), restated for the pre-brief moment. The still-open list, so classified, becomes the brief's `## 2. Epistemic map` known-unknown section verbatim — the routing evidence and the plan's epistemic honesty are the same artifact.

### The two outputs

**Routine arm — a brief.** The conversation authors a brief meeting the unchanged six-section contract (`skills/plan-authoring/SKILL.md` § Brief plan variant) and persists it as the issue's plan comment (`plan-variant: brief` frontmatter). The brief is lawful under **authority source (b)** — the issue's affirmed open-for-work framing record — with no deviation note (#957 D4). The plan-approval prompt, an existing registered non-overridable gate, fires at brief persistence exactly as it does today. The routing decision and its falsifier ride the brief itself.

**Novel arm — the same conversation continues into design.** Beat 2's novel verdict is a routing target, not a construction (#957 D8): the conversation continues inline into the existing `/design` methodology — Solution-Designer role, the 3-pass design challenge, the standard `design-phase-complete` marker, sub-issue creation through `skills/safe-operations/SKILL.md` §2's gates — and its chunk sub-issues are each planned as a brief under **authority source (a)**, a designed parent, exactly as chunked delivery already provides. No seams artifact, no new review shape, no third authority source. The entrance's promise stays honest: one conversation, which *continues* rather than ends when the work turns out to be novel. The novel arm's chunk output is bound by the acceptable-resting-state rule ([chunked-delivery.md § Operating rules](chunked-delivery.md)).

### The rule that decides the path — and the standalone escape hatch

The routing rule is beat 2's classification question above; it is expressed against the conversation's own still-open list rather than as a free judgment call, so a review can check the call against the list (the routing call is a named review target — see [Review](#review)).

**The escape hatch** (#957 D3): when a **routine**-arm run later hits a target-voiding unknown mid-run — the situation that, for a chunk, escalates to the designed parent — the standalone destination is the issue's **affirmed framing record**, which is the standalone arm's parent-design-equivalent. Amend the framing record in place (post an updated affirmed what-statement; the person re-affirms), re-run beat 2 against the updated still-open list, and record the re-route. The re-route count is a named close-out datum.

### The trivial floor

Whether an issue is below the trivial floor is decided **at pickup, from the filed issue alone**, by the same six structural criteria that decide mid-run follow-up disposition and review deferral — one criteria set, three moments (#957 D6). The canonical statement of the criteria and the risk guard lives in `skills/safe-operations/SKILL.md` §2a; this document does not restate them, so the floor cannot drift into divergent copies. In short form: below the floor iff the fix would trip none of the six structural criteria — **and** a change touching permission, authentication, or data-integrity behavior is never below the floor regardless of size, because below the floor pull-request review is the only review that will ever see the change.

**Verdict below the floor**: fix it directly. No brief, no run ceremony, no issue theatre. The conversation says so and ends.

### Review

A brief produced by this flow takes the same review a chunk brief takes — the **brief charter**: the `#### Brief conformance check` (author before dispatch, reviewer as first act), then the prosecution-only `design-challenge` shape (three lenses, no defense, no judge) plus the convergence filter over the merged ledger. The review runs once, after beat 2's artifact exists and before the worktree opens. The **routing call** — beat 2's routine-versus-novel classification against the still-open list — is a named review target. The alignment beat itself gets no adversarial pass: the person is ground truth for what they want built, and an agent prosecuting that would be prosecuting them (#957 d-review-shape).

> **Pending (chunk 2):** the vacuity property in the conformance check ("is there a reading of the criteria under which every one passes and no work happens?") and the required vacuity question in the convergence cold read land with #957 chunk 2. Until then, the charter runs as it stands today.

### The close-out habit

When the issue closes, the conversation's owner writes the close-out record on the issue:

- **One line per sustained finding** — where it was introduced, where it was catchable, where it was caught (the phase-containment ledger's grain; emission mechanics ride #951/#940/#944, this flow adds none).
- **A dead-premises note** — which filed premises were falsified during the flow and amended in place, so the next reader does not resurrect them.
- **The beat-2 re-route count** — how many times the escape hatch re-ran the routing (zero is the common, and reportable, case).

## The affirmation record

The affirmation record is what makes authority source (b) checkable rather than asserted. Its contract is fixed here, completely, so that no implementer has discretion about its shape (#957 D5, Amendment 8). Five properties:

1. **Surface.** The record is an **issue comment** on the issue being opened — never only an issue-body section. Every resume reader in this system reads comments, comment timestamps are the ordering evidence, and a body section is destructively editable, which disqualifies it as a lawfulness source. The registered form is written via `persist-marker.ps1`; the interim form (below) is written with a plain `gh issue comment`.
2. **Identity.**
   - *Registered form (pending, #957 chunk 3):* the comment carries a marker of the `open-for-work-affirmed-{N}` family, where `{N}` is the issue number. (That family name is rendered here inert — delimiters stripped, per the handoff-marker registry's § Writing about markers safely — because a delimited literal in prose is live to the raw-text scanners that read real comments. The family's registry row is chunk 3's; **do not register it, or write delimited instances of it, before chunk 3 lands** — the marker-write preflight refuses unregistered families.)
   - *Interim practiced form (usable now, #957 Amendment 8):* an issue comment whose **first line is exactly** `**Open-for-work affirmation (interim form, #957 A8) — issue #{N}**` (bold text, no HTML-comment delimiters, `{N}` the issue number), followed by the affirmed what-statement quoted in full. Nothing else is required in the comment, and nothing less identifies it.
3. **Ordering — stated as a constraint, not a description.** The affirmation record **must exist before the routing decision's artifact is written**: on the routine arm, before the brief's plan comment; on the novel arm, before the `design-phase-complete` marker. A routing artifact whose timestamp precedes the issue's affirmation record is not lawful under source (b). Comment timestamps are the evidence; no other ordering proof is required or accepted.
4. **Gate-decision token phasing.** Gate-decision tokens emitted by this conversation's checkpoints (the worth-it doors, the affirmation gate, plan approval on the routine arm) map to `phase: experience` — the conversation is the experience-replacement, and the token schema's closed five-value phase enum is deliberately not extended (#957 D5).
5. **Durable record versus human-readable mirror.** The comment is the authoritative record. The affirmed what-statement **may** additionally be mirrored into the issue body for human reading; if the two ever diverge, the comment governs, and the mirror is never the lawfulness source.

**Supersession.** When chunk 3 registers the marker family, new affirmations use the registered form. An interim-form record already on an issue remains a valid source-(b) authority for that issue — supersession changes the form of new records, it does not retroactively invalidate old ones. The escape hatch's "amend the framing record in place" posts a **new** record (same form rules, new timestamp) rather than editing the old comment, so the ordering evidence stays honest.

## The filing contract

Filing an issue carries three things and nothing more (#957 d-filing-shape): the **problem**, the **evidence it is real**, and **what is known versus unknown**. No proposed solution, no design, no scope decision, and no scenarios are required to file — those are this conversation's job, later, if the issue is ever opened for work. The operative rule lives in `skills/safe-operations/SKILL.md` §2f, and the repository's issue templates ask for exactly these three things.

## Default posture

The open-for-work entrance is the **expected route for standalone work**; the three-phase pipeline is the thing you reach by explicitly asking for it (`/experience` or `/design`), and it remains lawful (#957 § Default posture, owner decision 2026-07-28). Deletion of any phase machinery is a separate, evidence-gated decision that belongs to #953 — this flow inverts the default and deletes nothing.

## Running the flow today

Until #957 chunk 3 ships the `/open` command and its skill, the flow runs **manually**, and that is a lawful, complete way to run it — #957's own framing conversation is the existence proof. Concretely, in any conversation:

1. Say you want to open issue `{N}` for work, and walk the beats in this document top to bottom: worth-it check, beat 1 grounding with provenance tags, amendments-in-place, the affirmed what-statement.
2. Post the affirmation record in its interim practiced form (§ The affirmation record, property 2) **before** any routing artifact.
3. Run beat 2's classification, then produce the arm's output: author the brief per `skills/plan-authoring/SKILL.md` § Brief plan variant (routine), or continue into `/design` (novel), or fix directly (below the floor).

A `/plan` invocation that finds an affirmed framing record on the issue authors the plan as a brief under source (b) — see the pre-flight in `commands/plan.md`.

## Relationship to neighbouring doctrine

- **Chunked delivery** (`chunked-delivery.md`): authority source (a), the seams/contract bounds, and the chunk operating rules are unchanged. This flow adds source (b) for standalone issues; the A1–A5 amendments bind a brief under either source (see that document's § How a chunk plan specifies).
- **#924** owns `/plan`-side recognition of an already-filed **chunk** sub-issue; this flow owns the **standalone** entrance. The two do not overlap.
- **#949** owns the run's terminal sequence (review-run, suite-state accounting); **#951/#940/#944** own ledger emission mechanics. This flow adds no emission machinery.
