# Chunked delivery: design to the seams, plan to the contract

Ratified 2026-07-26 (issue #920, process outcome of the #848 tree review). The operative summary lives in [CLAUDE.md § Chunked delivery](../../CLAUDE.md); this document carries the full doctrine and rationale.

> **Unfamiliar with a term?** `Bound 1 / Bound 2`, `A1`–`A5`, and `DA{N}` are all defined in the [plain-language vocabulary](../../HOW-IT-WORKS.md#vocab).

## Why

Shift-left works on **specification defects** — requirements, contracts, interfaces — where analysis is cheaper than rework. It does not extend to **operational unknowns**: how software actually behaves once it runs. Those are discovered cheapest by running real code, not by deeper analysis. Chunked delivery takes both benefits — waterfall's coherent upstream decisions made once, iterative development's ground truth between decisions — by bounding **where detail is allowed to live** at two distinct levels. Both bounds are load-bearing; enforcing only one recreates the waterfall failure mode one level down.

The evidence behind this: in the #848 tree, churn concentrated where sub-issues of an already-designed parent re-entered the full upstream pipeline (#901 reached NO PLAN after multiple full adversarial panels before its later approved redesign), and where analysis was applied to failure modes of software with zero live runs (#910/#912). The cheapest catches in the tree were live probes (#871, #898).

## The two bounds

**Bound 1 — the parent design stops at the seams.** A parent issue carries the experience framing and technical design once, to a bounded depth: the design decides the **boundaries between implementation chunks** — interfaces, data shapes, spanning invariants, and the chunk sequence — and deliberately does **not** design any chunk's internals. If the design is specifying mechanism inside a chunk, it has gone too deep.

**Bound 2 — the chunk plan is a contract, not a recipe.** Each chunk's goal-contract plan (the #848/#872 plan variant consumed by `/goal-run`) hands the executor machine-checkable targets, invariants, evidence obligations, halt conditions, and a budget — and stops there. Unknowns *inside* the chunk (mechanism choices, internal structure, how to make the targets pass) belong to the executor's run; the planner must **not** pre-solve them. Plan-phase discovery is read-only grounding sufficient to write checkable targets and honest halt conditions — the moment planning turns into designing the implementation, it has crossed the boundary. The one exception: an unknown that could void a target, invariant, or the chunk boundary itself is not an in-box unknown — surface it as a design gap rather than resolving it unilaterally.

## Operating rules

- **Chunks are plan-only sub-issues.** A chunk sub-issue of a designed parent goes straight to the planner in goal-contract mode — no worth-it check, no experience phase, no design phase, and no standards-check re-litigation of the parent's decisions; the chunk inherits them. One chunk = one sub-issue = one goal-contract plan = one `/goal-run` = one pull request (PR). Do not split chunks at the PR level under a single issue: the harness's plan marker, run-state, and halt plumbing are all issue-scoped.
- **Inheritance is loaded, not assumed.** The chunk sub-issue body must link its parent, and the planner's first act in chunk mode is reading the parent's design — seams, spanning invariants, and any recorded amendments — before authoring the contract; the chunk's goal-contract cites the parent decisions it implements. Without this, `upstream-onboarding` would synthesize context from the child's own body (which carries no design markers) and the plan could silently violate parent seams.
- **Design gaps route up, not sideways.** If a chunk cannot be planned without a new design decision, that is a design gap on the **parent** — recorded there as a single design amendment — not a design phase on the child. This upward channel is the iterative discovery mechanism: running code corrects the design without re-running the design.
- **Walking skeleton first.** The first chunk is the thinnest end-to-end path through all the seams, so boundary errors surface at chunk-1 prices instead of chunk-5 prices.
- **Panel depth earns its way down.** Chunk plans start with the full adversarial plan review (the prosecution → defense → judge pipeline; methodology in `skills/adversarial-review/SKILL.md`, run by Issue-Planner). Annotate findings in the phase-containment ledger with whether each was catchable only at plan time; relaxation to a lite stress-test for routine chunks is earned by ledger evidence, never by a cost argument (consistent with CLAUDE.md § Quality-first, shift-left).

## How a chunk plan specifies — amendments A1–A5

Ratified 2026-07-28 (issue #936, from the #932 paired-trial record). Bound 2 says a chunk plan states the contract and stops. These five rules say **at what knowledge level** it is allowed to state it, and **what it must say about proof**. They bind every chunk plan regardless of which artifact carries it.

The trial exposed a third category of unknown that the two bounds do not name. Bound 2's dichotomy is *specification* (planner-owned) versus *in-box mechanism* (executor-owned). **Discoverable external facts** are neither: specification-shaped, but not authorable — only readable from the world. How a vendor tool names its directories is the worked example. A plan that guesses one and folds the guess into a target grades the run against a false premise, and the run has no way to notice.

**A1 — Discovery-neutral targets.**
*Forbidden:* encoding a hypothesis about a discoverable external fact into a target — most often as a comparison tolerance chosen to fit what a handful of samples suggested.
*Required instead:* when done-ness depends on such a fact, the target states two things — the **evidence standard** for establishing it (an authoritative source; a sample inference is not sufficient) and the **behavior once established**. So written, the target is still the right target under any discovery outcome.

**A2 — Provenance-marked grounding.**
*Forbidden:* an unmarked grounding claim; and any **sample-inferred** claim setting a target's comparison tolerance or mandating a mechanism.
*Required instead:* every grounding claim is tagged **source-read** or **sample-inferred**. Inferred claims reach the executor as contestable guidance only. Primary evidence found mid-run that contradicts one escalates as a parent design gap — this is the trigger Bound 2's existing escape hatch was missing.

**A3 — Falsifiers are executor guidance, not check hardening.**
*Forbidden:* converting a known vacuity trap into an assertion or check command the run is graded on. Both trial runs shipped tests that could not fail; in both, the preventing knowledge existed as check-command hardening, and in both it prevented nothing.
*Required instead:* the plan stress-test keeps its strongest catch — targets satisfiable without the fix — but delivers each finding as **prose the plan artifact carries to the executor**, alongside a standing obligation to show that completion evidence could have come out negative.

**A4 — Behavior pins, and a floor check before launch.**
*Forbidden:* a target naming a file path, a test name, or a per-file count ("file X exists"; "the slug module gains at least 6 tests").
*Required instead:* targets pin **observable behavior** — the thing that file or those tests exist to demonstrate. Separately, a target may state an absolute **suite-wide** floor, but only if that floor is verified satisfiable against the launch baseline *before* the run starts; an unchecked floor is forbidden, a checked one is not. Both trial runs were halt-bound from the moment they began because nobody did that arithmetic.

**A5 — Evidence obligations: properties fixed, format free.**
*Forbidden:* an acceptance criterion that names no proof standard, and evidence offered with no properties at all. Free-format-with-no-properties is not a hypothetical failure: both trial runs produced evidence, self-reported green, and carried roughly a dozen defects each.
*Required instead:* every acceptance criterion states what would count as proof, and the proof offered is **discriminating** (it could have come out negative — which for a criterion claiming something new is true means a result that differs from the pre-change tree, and for one claiming something is *preserved* means a check that would have caught the breakage), **attributed** (it says where the number came from: "3,792 randomized paths against a reference implementation", not "the tests pass"), and **per-criterion** (it maps to one criterion, not to one aggregate green). The *format* stays the executor's choice; review is the check on whether the chosen format actually proved the criterion. These three properties' standing home is [skills/verification-before-completion/SKILL.md](../../skills/verification-before-completion/SKILL.md).

A1–A4 govern what the plan **says**. A5 straddles: its first half is also a rule about what the plan says — every criterion must name its proof standard — and its second half is the only rule here about what the **run must show**. All five are rules about how a chunk plan specifies, so each is true from the moment it lands, independently of which plan artifact is in use.

**What is not yet true: nothing enforces these at authoring time.** Following this document's own convention for unwired doctrine (see `## Deferred follow-up` below), A1–A5 are applied by the planner and by review, not by command prose or a schema. #924 owns wiring provenance marking and the chunk fast path into `plan-authoring` and `upstream-onboarding`; #941 owns the conformance check that would catch an artifact-pinned criterion before a run starts. Until then, a plan can violate any of A1–A5 and still validate.

## Deferred follow-up

Once the doctrine has been exercised on a real parent/chunk tree: wire the chunk fast path into the `upstream-onboarding` and `plan-authoring` skill prose so the planner's contract-not-recipe bound is enforced at authoring time, not only by this doctrine.

**Interim behavior until that wiring lands:** the shipped `/plan` pre-flight does not recognize a designed parent — on a chunk sub-issue it will still find no `design-phase-complete` marker on the child and offer to run `/design`. Decline that offer for chunk sub-issues, citing this doctrine; the fast path is applied by the operator and by agents reading CLAUDE.md, not yet by the command prose.

<!-- interim-migration-note:begin -->

## Doctrine sentences still scheduled to change

> **Deliberate historical reference.** This section quotes doctrine text that later chunks of #936 replace, so that a reader is not misled by wording this document and `CLAUDE.md` still carry. It is the one place in either file where the retired vocabulary appears on purpose — a completeness check counting those terms across the two files should exclude everything between the pair of HTML-comment sentinels that open and close this section, named `interim-migration-note` with a `:begin` and `:end` suffix. (Those two literals are described rather than quoted here, so that a reader extracting the region between them does not match this sentence and stop early.) Every passage named below is owned by #941 or #942, so the section is retirable once those two have landed; #943 is the last chunk in the sequence, which is why the removal sits there.

Most of A1–A5 above is true as written and needs no interim caveat. The one exception is A3's *required-instead* half, whose row is in the table below. Several *other* sentences still describe the delivery path #936 is replacing. Each one moves when the chunk that makes its replacement true lands.

Quotations below are verbatim, so that a search for one lands on the passage it names. Emphasis is never added inside a quotation. Each row carries exactly one owner, because a reader landing on a row needs to know whether the passage is theirs — where the parent's own record folds several passages under one owner, the row does too, and where it splits them, so does the row.

| Passage | Replaced when | Chunk |
| --- | --- | --- |
| **This file, Bound 2:** "Each chunk's goal-contract plan (the #848/#872 plan variant consumed by `/goal-run`)" | the brief contract lands, then the harness retires | #941, then #942 |
| **This file, operating rules:** "goes straight to the planner in goal-contract mode", "One chunk = one sub-issue = one goal-contract plan = one `/goal-run` = one pull request (PR)." and the "the harness's plan marker, run-state, and halt plumbing are all issue-scoped" rationale — folded under one owner because #936's own migration record folds them | the brief contract lands, then the harness retires | #941, then #942 |
| **This file, operating rules:** "the chunk's goal-contract cites the parent decisions it implements" | the brief contract lands | #941 |
| **This file, operating rules:** "**Panel depth earns its way down.** Chunk plans start with the full adversarial plan review" | the plan-review charter changes | #941 |
| **This file:** the `## Deferred follow-up` section and its "**Interim behavior until that wiring lands:**" paragraph on the `/plan` pre-flight | that skill wiring lands | #941 |
| **This file, A3's *required instead*:** "prose the plan artifact carries to the executor" — specialized to the brief's fourth section once the brief exists | the brief contract lands | #941 |
| **`CLAUDE.md` § Chunked delivery:** the Bound-2 mirror, "each chunk's goal-contract states targets, invariants, evidence obligations, halt conditions, and budget, then stops." | the brief contract lands | #941 |
| **`CLAUDE.md` § Chunked delivery, operating-rules sentence:** "one chunk = one sub-issue = one goal-contract = one `/goal-run` = one PR" | the brief contract lands, then the harness retires | #941, then #942 |
| **`CLAUDE.md` § Chunked delivery, same sentence:** "never PR-level splits since harness plumbing is issue-scoped" — still true until the harness is gone, so **not** #941's to touch | the harness retires | #942 |
| **`CLAUDE.md` § Chunked delivery, same sentence:** "chunk-plan panel depth relaxes only via phase-containment-ledger evidence" | the plan-review charter changes | #941 |
| **`CLAUDE.md` § Orchestration:** the line documenting `/goal-run` as a live command | the harness retires | #942 |
| **This section itself** | #941 and #942 have both landed | #943 |

Where one sentence has two triggers, the wording it takes in between is fixed here rather than left to whoever lands the first change. Two distinct sentences are affected and they are not textually identical, so each is given separately:

- **This file's** operating rule becomes "One chunk = one sub-issue = one brief = one `/goal-run` = one pull request (PR)." after #941; #942 then replaces the command, giving "One chunk = one sub-issue = one brief = one goal-lane run = one pull request (PR)."
- **`CLAUDE.md`'s** shorter mirror becomes "one chunk = one sub-issue = one brief = one `/goal-run` = one PR" after #941, then "one chunk = one sub-issue = one brief = one goal-lane run = one PR" after #942.
- Bound 2 names the brief after #941 while keeping its harness-consumer clause; #942 removes that clause.

**If #941 and #942 never land** — #936 makes revocation of the new lane a designed outcome, not a failure — A1–A5 stay, because the amendments bind any chunk plan whatever artifact carries it, and every passage in the table above remains an accurate description of the path still in use. Only this note's *promise* of change would be stale. Retiring it in that case is not #943's stated obligation, which covers the completion path only; revocation routes back to #936, which owns the decision and would say what becomes of this section.

<!-- interim-migration-note:end -->
