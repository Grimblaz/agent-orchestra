# Design Lens Exhibits

This file is the incident detail behind the lenses in [`skills/design-exploration/SKILL.md`](../SKILL.md) § Design Lenses. Each section records one incident: what happened, the measured numbers, the named artifacts, and the sequence of events. The rules a reader applies live in the lens section named at the top of each entry — not here. The one exception is the creed section, which carries the six numbered points themselves because the lens can only carry their summary.

## Contents

- [Three doctrine records that already settled the shape](#three-doctrine-records-that-already-settled-the-shape)
- [Four grounding errors all pointing one way](#four-grounding-errors-all-pointing-one-way)
- [The six-point creed in full](#the-six-point-creed-in-full)
- [An append that landed outside the region it belonged to](#an-append-that-landed-outside-the-region-it-belonged-to)
- [Three rounds of quoting heuristics, all failed](#three-rounds-of-quoting-heuristics-all-failed)

## Three doctrine records that already settled the shape

*Cited from § Before proposing a mechanism for a missed step, ask which standing rule was absent.*

On #949 the problem was framed as "the process didn't happen," and the response drafted was a menu of mechanism options: an enforcer, a detector, a hook, a wired sequence. Micah rejected all three as heavy-handed, and gave the reason directly — that the repo should not be handing out a detailed, specific list of "have to" requirements, but instead making its doctrine clearer around what success looks like, specifically for the things nobody wants to have to add to each issue.

The repo had already *measured* that outcome, and recorded it in three places that should have been read before any option was authored:

- **A3** — both trial runs shipped tests that could not fail; in both, the preventing knowledge existed as check-command hardening, and in both it prevented nothing. The same knowledge delivered as guidance would have worked.
- **A5 plus the `evidence-obligation-home` decision (#936)** — "properties fixed, format free." What does not vary per chunk belongs in a standing surface; what varies belongs in the brief. That split is reusable at any altitude, not only for evidence.
- **#936 on the retired harness** — `Goal-Run.agent.md`'s 62 MUST/NEVERs did not prevent the loop bypass, and deletion beat revision. A long list of obligations is the recorded failure mode, not the fix.

A proper re-audit against that doctrine collapsed the run's own load-bearing classification gate to routine, because A3 and `evidence-obligation-home` had already settled the shape of the answer. A separate observation from the same session: `/goal` in practice works toward its objectives and communicates well, which points at an executor that is capable and under-informed rather than careless.

## Four grounding errors all pointing one way

*Cited from § Grounding errors that all point one way mean the pass was advocacy, not a test.*

On the design recorded under #951 (phase-containment provenance), four separate grounding errors survived into the adversarial challenge. Taken individually each was minor and each citation looked fine on its own. Taken together they shared one property: **every single one overstated the case FOR the mechanism already chosen**.

The four, as they were found:

1. An indistinguishability proof that was false for the very artifact it cited.
2. A claim that `Test-Json` appeared nowhere, which was too broad to be true.
3. An expected check verdict that was wrong, and wrong in the safe direction.
4. A stated failure mode in which "the arithmetic throws," where the real behavior is to fail silently.

The mechanism the errors favored had been chosen before the grounding pass ran, which is what made the direction invisible from inside: nothing in any one citation looked like advocacy.

The same pass showed the asymmetry in how alternatives were grounded. The preferred option was grounded properly; for the rejected alternatives, the collision sites were cited without the files being opened. The fatal head-collision in one of those alternatives sat **two lines from a citation that had already been made** in the same document — reachable at zero extra cost, and missed because the reading stopped where the argument was already satisfied.

## The six-point creed in full

*Cited from § Decide what an agent judges and what deterministic code checks, and type the boundary between them.*

This is the design creed for building agentic-development tooling (agents plus skills), agreed with Micah on 2026-08-08 as the lens for the Agent Orchestra architecture investigation. The six points are reproduced here in full because the lens can only carry their summary.

1. **Agents decide, code executes and validates; the boundary between them is a typed artifact.** Agents own decisions over open-ended input spaces; code owns transitions with closed semantics. Code doing judgment yields brittle syntactic proxies for semantic questions; agents doing mechanism yield nondeterministic bookkeeping. The narrower and better-typed the boundary artifact (schema, enum, marker grammar), the more both sides can be trusted.
2. **Spend determinism on verification of outcomes, not prescription of process.** Checks that pin properties of the artifact survive model upgrades, prompt rewrites, and flow restructuring; scripted step sequences encode assumptions on three drifting layers at once. Generalizes chunked-delivery amendment A4 (pin observable behavior, never path/test-name/count). When in doubt: replace a scripted step with (agent judgment + a check that can fail).
3. **Every check must have a reachable red state — falsifiability is the scarce resource, not determinism.** The dominant defect class in the ledger is checks that structurally cannot fail (input-partition tautologies, self-referential baselines, pre-satisfied proof standards). Ship every deterministic check with a kept negative exhibit (cf. #1011 as frozen negative exhibit); a check with no demonstrated red state is unproven scaffolding, and worse than a judgment call because it launders confidence.
4. **Match investment to half-life.** Slow layer (years — git semantics, GitHub API, own artifact contracts): code plus tests are safe. Medium (quarters — harness surfaces, hooks, plugin caching): thin replaceable adapters, test the consumed contract not vendor internals. Fast (weeks — model behavior, how much choreography a model needs): prose only, because prose degrades gracefully under a stronger model while stale code fails hard or silently does the wrong deterministic thing.
5. **Design for deletion; instrument every stage for retirement.** Model improvement absorbs scaffolding; the question for any stage is "how will I know when it stops catching anything, and how cheaply can I remove it?" The phase-containment ledger is the instrument that turns churn into scheduled subtraction instead of surprise demolition. Deletion is a success mode.
6. **Use code to compress context and pin invariants — never to save tokens on verification.** The best cost win is shrinking what an agent must read (distill raw output into typed summaries), not replacing judgment calls. Verification passes have the highest value density (own-fix defect rate roughly 1 in 3 until a reader re-runs the clause).

The audit lens derived from the creed at the same time: split existing skill and agent prose into *contract* (artifact shapes, evidence standards, falsifiability discipline — keep and harden) versus *choreography* (step sequences compensating for model weakness — candidates for evidence-based retirement via the ledger). Orchestra's deepest investment was assessed as sitting in the choreography layer, which is the layer most exposed to model improvement.

## An append that landed outside the region it belonged to

*Cited from § A record format cannot be append-only inside a begin/end marked region.*

Two design defects from #1018, both proved by a reviewer through execution, both of the shape "the document claims a property the format forbids."

The first: `LEDGER.md` records were documented as append-only, with an explicit concurrency rationale — an append survives a concurrent writer, whereas a read-modify-write silently discards whatever landed between the read and the write. The records were placed between an opening `memory-ledger-begin` marker and a closing `memory-ledger-end` marker. An `Add-Content` write lands *after* the end marker, outside the region, where the parser never looks. Executed, the reader saw **5 records where 6 had been written**. Every writer therefore had to read-modify-write — the very operation the rationale condemned — and two simulated concurrent sessions lost one record while reporting `malformed: 0`.

The tempting repair, "document `Add-Content`," was impossible under execution. The two real options were to change the format (opening marker only, records running to end of file) or to change the claim. The format was changed. The consequence accepted deliberately: everything after the marker is a record, so the file can carry no trailing prose. Whole-line HTML comments were exempted so a store can still annotate itself and so a leftover end marker from the old format is ignored rather than reported broken.

The second defect: the partition check keyed presence on a life key of the form `name@admitted-date`. That keying was correct, and it fixed the name-reuse defect on a *dated* corpus. But no surface writes `metadata.admitted` yet, so on the real store all **170 entries evaluate to `name@unknown`**, both sides of the comparison match on the bare name, and the check answered `still-hot` for a life that had left with no record. The resolution was a **third verdict — `unverifiable`, exit 2** — so the check declines to answer rather than returning the name-keyed answer wearing the life-keyed answer's name.

## Three rounds of quoting heuristics, all failed

*Cited from § Telling a declaration from text quoting it is decidable by position, never by a heuristic.*

Lived on #1017, the agent-memory-compaction split-store stanza. The check had to tell a store that *declared* the split-store stanza marker from a store that had *quoted* the shipped adoption recipe into itself. The shipped documentation prints the very marker the format is detected by, so a conforming index and a quoting index can contain byte-identical text.

Three fixes shipped, each caught by the next adversarial pass:

1. **Scope the search to the header region.** Failed: a "note to self" at the top of an index *is* the header region.
2. **Also require column 0.** Failed *worse* than the defect it replaced — the same commit moved the shipped snippet to column 0 so it would be copy-pasteable, so a verbatim paste now landed at column 0 by construction. The remedy widened its own defect's reach.
3. **Also track fenced-code state.** Failed in **both** directions at once. Quoting a fenced block requires a longer outer fence, whose inner triple-backtick run toggles a naive state machine back off, so a legacy store read as split; and an *unclosed* fence above the first heading hid a **real** stanza, so a fully conforming split store read as legacy and its size axis went silently dark.

What worked: the declaration must be the file's **first non-blank line**. A file cannot quote something at its own first line without that line *being* its first line. No spoofing surface, no fence parser to get wrong, one sentence to document.

Two riders from the same run. A guard's **threshold** is part of the guard: the residue check ("has this store still got policy text in it?") fired on **one** matching line, which failed four *lawful* stores — including one carrying the shipped check-command line, a line the live store carries today. Raised to a run of three and documented as a proxy. A store quoting its policy is not a store that still contains it.

And from the owner ruling that closed the run: before tightening a guard so a subject cannot opt out of being measured, ask **what the guard would force the subject to fabricate**. Making the size axis mandatory for any store adopting the split would have pushed downstream consumers to copy the harness's own observed limit into their store — manufacturing the hand-picked-absolute-dressed-as-a-formula defect the rule exists to prevent. Where a value must be measured locally, optional-and-honest beats mandatory-and-copied.

