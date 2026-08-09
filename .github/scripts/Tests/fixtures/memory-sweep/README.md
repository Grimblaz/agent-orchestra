# Fixture memory store — sweep procedure demonstrations

Committed inputs for `.github/scripts/Tests/memory-sweep-procedure.Tests.ps1`, which executes the
sweep procedure (`skills/agent-memory-compaction/references/sweep-procedure.md`) and its record
shapes (`references/store-records.md`) against them. They are committed so a later reader can re-run
every demonstration — including every negative construction — rather than take a transcript's word
for it.

The suite assembles a working store in a temp directory from these files plus the two canonical texts
read out of the shipped `SKILL.md`, the same way `memory-index-policy.Tests.ps1` builds its split
stores. Assembling rather than committing a copy of the policy text is deliberate: a committed copy
would drift from the text it is checked against the first time either changes.

Assembled layout:

| Assembled file | Built from |
| --- | --- |
| `MEMORY.md` | the canonical stanza + `index-body.md` |
| `POLICY.md` | `store-values.txt` + the sweep-machinery section + the canonical policy region |
| `LEDGER.md`, `SLATE.md` | copied verbatim |
| entry bodies | `entries/*.md`, copied to the store root |
| `ARCHIVE.md` | absent — a store that has never demoted anything has none |

## What is planted, and why

Nothing here is arbitrary. Each entry exists to make one clause of one acceptance criterion able to
come out negative.

| Entry | Planted so that |
| --- | --- |
| `reference_critical_delta` | a critical entry sits **sixth** in file order, so an ordering taken from file position fails |
| `reference_critical_orphan` | a critical lesson lives in an **orphan body** with no pointer, so a walk of the index alone misses it |
| `reference_tail_zeta` | the **last** pointer, past a simulated truncation cut, so a loss planted there is invisible to an enumeration made from a session's loaded view |
| `reference_reused_name` | the ledger carries an executed exit for this name's **first life** (`@2026-01-05`) while the live body is admitted `@2026-08-08`, so a name-keyed reconciliation calls a live entry handled |
| `reference_legacy_unknown` | no `metadata.admitted` at all, so the reconciliation must answer **undecidable** rather than pick a side |
| `reference_interrupted_eta` | an `executed` promotion record with the pointer **still in the index** — a disposition interrupted between the record and the act |
| `feedback_prerule_epsilon` | admitted `2026-05-02`, before this store's admission rule landed on `2026-06-01`, so an unscoped `remove-fails-admission` would condemn it |
| `reference_dupe_source` / `reference_dupe_survivor` | the deduplication pair, whose lesson survives *inside* the store and so is neither a promotion nor a demotion |
| `project_settled_beta` | a settled `project_` entry, for the settled-section move that is **not** an exit |
| `reference_obsolete_gamma` | an entry whose subject no longer exists, for `remove-obsolete` and the first demotion that creates `ARCHIVE.md` |
| `reference_ordinary_alpha` | carries a **proposed** removal in the ledger while staying in the index, so a reader that took a proposal for an exit would call it gone |

`SLATE.md` deliberately carries **no** `critical` row for `reference_reused_name` or
`reference_legacy_unknown`: absent is *unassessed*, not *ordinary*.

The store's admission rule is treated as having landed on **2026-06-01**; the suite passes that date
explicitly. The two pinned sweep dates are **2026-08-08** (sweep 1) and **2026-09-15** (sweep 2,
after the expiry sweep 1 writes), so no expiry or staleness assertion can start passing or failing
because time moved.

## Re-running

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path .github/scripts/Tests/memory-sweep-procedure.Tests.ps1 -Output Detailed"
```

Nothing here touches any real store. The suite asserts that it depends on no path outside the
repository, and that none of the three instruments writes to the store it reads.
