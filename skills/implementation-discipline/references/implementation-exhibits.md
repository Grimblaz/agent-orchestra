# Implementation Lens Exhibits

Incident detail for the lenses in `skills/implementation-discipline/SKILL.md` § Implementation Lenses. Each section below records only what happened on one run — the artifacts, the counts, and the order of events. The rules a reader applies live in the lens section named at the top of each entry; nothing here restates them.

## Contents

- [A clause that was false at 11 of 15 sites](#a-clause-that-was-false-at-11-of-15-sites)
- [A migrated sentence that was false on landing](#a-migrated-sentence-that-was-false-on-landing)

## A clause that was false at 11 of 15 sites

*Cited from § When one qualifying claim is propagated to many sites, the boilerplate copies are where it turns false.*

Issue #1032, landed as PR #1044. The chunk existed because an unqualified sentence — `persist-marker.ps1` is the ONLY documented write path — let readers conclude something false. The remedy propagated a qualifying clause into 15 files. The clause read that the primitive's own transport performs the identical whole-body PATCH.

That property belongs to the `upsert` write shape, not to the primitive. Of the 10 registered marker families, 3 are `upsert`; the remaining 7 are `post-new` and never reach `Set-CommentBodyDirect` on their primary write. The clause was therefore false at roughly 11 of the sites it had just been copied to — the remedy reproducing its own defect class one level down, inside the very change filed to close it.

The discriminator across those 15 sites was sharp and one-dimensional. Every variant that had been hand-written for its own site — and so named the family and its write shape — came out correct. Every boilerplate copy came out wrong. Uniform phrasing was exactly what erased the one fact that decided whether the sentence held.

The worst instance was directionally harmful rather than merely inert. At the family the census itself had flagged as "the sharp one," the copied clause told a writer standing on a creation path that a timestamp "advances either way" — at precisely the family whose records a timestamp advance voids.

## A migrated sentence that was false on landing

*Cited from § Swapping the subject noun leaves the old predicate, and the sentence lands false.*

Issue #941. A migration table assigned a set of doctrine sentences to the chunk, each as a term replacement. The Bound-2 mirror was rewritten to say that each chunk's **brief** states targets, invariants, evidence obligations, halt conditions, and budget, then stops.

The noun was correct. The predicate was not: that five-part field list belonged to the goal contract. The brief contract authored in the same PR requires six sections, and neither halt conditions nor budget is among them. The sentence was false the moment it landed — and it landed in the exact file whose acceptance criterion read that every doctrine sentence the migration table assigns to this chunk reads true after it lands.

Five prosecution passes, a defense pass, and a judge all cleared it. What they checked was that the noun had changed and that the migration completion check returned zero. An external bot, Codex, caught it afterwards. The migration table quoted verbatim, which made the *subject* auditable by grep and left the *predicate* auditable only by reading; every completion check built on token counting was structurally blind to the class.

The same PR carried a second instance of the family. `agents/Issue-Planner.agent.md` held a fourth unconditional `standard`-adapter dispatch that three successive enumerations had missed — D5 recorded two sites, DA4 corrected that to three, and the real answer was four.
