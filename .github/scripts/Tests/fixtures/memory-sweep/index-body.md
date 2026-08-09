<!-- markdownlint-disable-file MD041 -->
<!-- Fixture data: a memory-store entry body opens with its frontmatter and carries no H1,
     which is the shape a real store has. The lint rule is disabled rather than the fixture
     bent into a shape no real entry has. -->

## Method — how to be right

- [alpha's ordinary lesson](reference_ordinary_alpha.md) — a stale read wins the race and the retry cap silently drops the write
- [beta, a settled project](project_settled_beta.md) — the migration landed; the durable lesson is that the coupled fields must move together
- [the duplicated lesson](reference_dupe_source.md) — a bounded read window produces a false absence that then gets tagged verified
- [the surviving copy of it](reference_dupe_survivor.md) — for an absence claim, grep the whole file rather than a bounded window
- [gamma, about a surface that is gone](reference_obsolete_gamma.md) — the sunset flow re-ran the frozen adapter on every push
- [delta, the expensive one](reference_critical_delta.md) — a marker head that is not self-closed is dropped in silence, and no reader ever reports it
- [epsilon, admitted before the rule](feedback_prerule_epsilon.md) — explain the state and the conflict before offering options
- [the re-earned name](reference_reused_name.md) — a guard narrowed by syntax rather than semantics widens the exemption it meant to close
- [an entry from before this convention](reference_legacy_unknown.md) — two branches can bump to the same version, each internally consistent

## Tooling gotchas

- [eta, whose promotion was interrupted](reference_interrupted_eta.md) — a PATCH built from a local file clobbers appends the server already accepted
- [zeta, at the tail](reference_tail_zeta.md) — a merge conflict makes pull_request CI absent rather than red, so the checks page shows only the bots
