# Lesson-promotion store reconciliation

Umbrella [#1045](https://github.com/Grimblaz/agent-orchestra/issues/1045), **AC6**: *each chunk's promoted lessons exit the store through its recorded-exit procedure, evidenced by the LEDGER exit rows cited in the chunk PR; the manifest is authoritative repo-side, the store LEDGER store-side, and chunk 3 reconciles the two — divergence is a finding, not a silent state.* As amended by **A2.3**: *each chunk's promoted lessons reach the store's landing-in-flight state naming that chunk's vehicle, with the executed exit row following after merge; chunk 3's reconciliation reads **both tracks**, and divergence on either is a finding.*

## Why this file exists rather than only a PR body

AC6 names the chunk PR as the evidence surface, and the reconciliation is carried there too. This file exists because **a PR body is not where a later reader looks.** The private store lives at `~/.claude/projects/{project-slug}/memory/`, is not under version control, and — as `lesson-promotion-manifest.json`'s own `roster_snapshot.note` records — is *absent from every CI runner*.

Be precise about which part is unavailable to CI, because the first draft of this paragraph over-claimed. **The manifest↔store join** is what needs the store: a GitHub-hosted runner gets a clone, and the store is not in it. That leg is unavailable to any check keyed to this repository's contents alone. The **repo-side leg is not** — that every promoted entry's `home` file exists and carries its manifest `anchor` is checked today by `lesson-promotion-manifest.Tests.ps1`, on every run, with no store present. And the store-side leg is not unavailable *in principle*: a self-hosted runner on the store's host, or the store supplied as a job artifact, would reach it. Neither is proposed here — the store is private and putting it on a runner changes what it is — but the claim is "not available to CI as this repository is configured", not "impossible". *(The earlier form read "now or after any amount of CI work", an unbounded universal over the future — the same unfalsifiable-absolute shape amendment A5.1 exists to remove, in the document that records A5.1. Corrected on review of PR #1065.)*

That makes the store-side reconciliation an agent-session act with a dated result, and this file the thing a future session reads to know when it last happened and what it found.

Specifically, the memory store's own **2026-09-08 sweep** decides whether every rostered lesson is lawfully landing-initiated. This record is what that sweep should read first.

## Reconciliation of 2026-08-15

Performed against `Documents/Planning/lesson-promotion-manifest.json` on the branch that became PR [#1065](https://github.com/Grimblaz/agent-orchestra/pull/1065) (chunk 3), and the store's `LEDGER.md` / `SLATE.md` as of the same date.

**Anchoring, for the reader arriving after the merge.** The comparison was run at branch commit `6626102`. That commit is **not reachable from `main`** — this repository squash-merges, so a fresh clone weeks later cannot resolve it, which matters because a fresh clone is exactly this record's intended reader. Cite **PR #1065 as merged** instead; its merge commit is the durable anchor, and the § Result table below already uses that convention for chunks 1 and 2 (`d610bbe`, `3e39c91`). The manifest did change between `6626102` and the shipped state, so the baseline is not the shipped tree: **the delta touched no `state`, `home`, `anchor`, `chunk` or `issue` field** — only `resolution` prose, two `roster_snapshot` keys, a `cited_by` row and an `in_file_pins` row — so all 46 rows are identical and the roster conclusion below survives it. Verified rather than assumed.

**Store-side snapshot.** `LEDGER.md` carried **271** rows and `SLATE.md` **399** at the time of this run. Those totals are the fingerprint: a later sweep that re-runs the method and gets different counts knows the store moved, and can tell that from a genuine divergence.

### What was compared

Three registers, not two — A2.3 splits the store side into two tracks that can diverge independently:

| Register | Location | Row shape |
| --- | --- | --- |
| **Repo-side roster** | `Documents/Planning/lesson-promotion-manifest.json` → `entries[]` | `lesson`, `state`, `chunk`, `issue`, `home`, `anchor` |
| **Track A — landing** | store `SLATE.md` | `date \| name@date \| landing \| in-flight\|landed \| vehicle` |
| **Track B — exit** | store `LEDGER.md` | `date \| status \| promote \| name@date \| reason \| destination` |

Lawful pairings, from A2.3's own sequencing — in flight before the merge, exit row after it:

- `landing = in-flight` with **no** exit row — correct for a chunk whose PR has not merged.
- `landing = landed` with exit `executed` — the exit was written.
- `landing = landed` with exit `reconciled` — the exit was written **and later read back** at a sweep, with the destination confirmed to carry the lesson and the landing confirmed an ancestor of `origin/main`. `reconciled` is strictly stronger than `executed`.

**The exit vocabulary has three values, not two.** `LEDGER.md` carries `executed` (239), `reconciled` (25) and **`proposed` (7)**. `proposed` is declared by the store's own `POLICY.md` rule 3 — an unattended session may *record a proposal* but may not execute a removal — so it is a lawful state, not a malformed one. It did not arise on this roster: all 69 on-roster promote rows are `executed` or `reconciled`, zero `proposed`. It is named here because the table above would otherwise be silent about a value the **next** reconciliation will certainly meet: the seven live `proposed` rows are dated 2026-08-10 and destined for a successor umbrella. A roster row sitting at `landed` with a `proposed` exit is **not** covered by the pairings above and should be treated as a finding requiring a ruling, not as lawful by omission.

**Provenance, per amendment A2 (tag every grounding claim).** The three pairings above are **inferred** from the observed store, not read from a declaration: no store-side document enumerates the exit vocabulary or states that `reconciled` is stronger than `executed`. `POLICY.md` rule 3 is *source-read* and grounds the `proposed`/`executed` distinction and the destination read-back; the `executed`→`reconciled` ordering is the inferred part. Two of this record's own corrections moved the verdict toward zero divergence and none moved it away, so an inferred rule fitted to the data it then judges is exactly the risk — recorded here rather than left for a reader to notice.

**One pairing is now source-read rather than inferred**: `landed` + `executed`, written at merge without a sweep, is lawful for a promotion exit under an approved vehicle — ruled by the store's owner on 2026-08-15, recorded under § Still owed item 1. That closes the question the first draft of this record left silently instructed.

A landing row names its **issue** while in flight and its **merged PR and commit** once landed; both are lawful references to the same vehicle.

### Result — all 46 rows, both tracks

| Chunk | Vehicle | Rows | Track A (landing) | Track B (exit) | Verdict |
| --- | --- | ---: | --- | --- | --- |
| 1 | #1049 → PR #1055 @ `d610bbe` | 19 | `landed` | `executed` | reconciles |
| 2 | #1050 → PR #1061 @ `3e39c91` | 25 | `landed` | `reconciled` | reconciles |
| 3 | #1051 → PR #1065 | 2 | `in-flight` | *(none — lawful pre-merge)* | **provisional — see § Still owed** |
| | | **46** | | | **0 divergences, as of the date above** |

> **Read the chunk-3 row with its date.** Its two assertions — `in-flight`, no exit row — are correct *before* PR #1065 merges and **false after**, and this table will not change on its own. A reader arriving later cannot tell "correctly in flight" from "merged weeks ago and the exit rows were never written" from the table alone; § Still owed is what distinguishes them. That is why the cell says provisional rather than inheriting the green footer.

**Divergence verdict, stated in the polarity AC6 requires: none.** Every one of the 46 manifest rows carries a Track A landing row naming its own chunk's vehicle, and a Track B exit row in a state lawful for that landing phase. No manifest row lacks a store counterpart, and no rostered lesson sits in a pairing the sequence does not allow.

### Reverse direction

- **39** `promote` subjects in `LEDGER.md` fall outside this roster. These belong to the first promotion tranche and other vehicles; this manifest is not their registry and does not claim to be. Not divergence.
- **1** `landing` subject in `SLATE.md` falls outside the roster: `project_1045_second_promotion_tranche`, `in-flight`, naming the umbrella itself. Correct — the umbrella's own project entry lands when the umbrella closes, not with any one chunk.

### The one asymmetry, and its discharge

Not a divergence, but the substantive thing this reconciliation surfaced and the reason "read both tracks" was worth requiring:

**Chunk 1's 19 exits sit at `executed`; chunk 2's 25 sit at `reconciled`.** The 2026-08-10 sweep read chunk 2's rows back and left chunk 1's alone — its record reads *"25 exits completed from records already in force."* So 19 of the 46 had been **written** but never **verified**: nothing had confirmed their destinations actually carried the lessons. A count of terminal rows cannot see that difference, which is exactly why AC6 asks for the rows rather than the count.

**Discharged here rather than reported and left.** Every `promote` row on this roster — **69** rows across the 44 landed lessons, chunk 2's carrying both an `executed` and a later `reconciled` row — was parsed for its destination, and each destination checked against the live tree for both the section text the row names and the manifest's own anchor for that lesson.

**Result: 69 of 69 destinations confirmed to carry their lesson. 0 problems.** Chunk 1's 19 are now read back; their store rows may be promoted to `reconciled` at the next sweep on this evidence.

### What this does not establish

- It does not prove the lessons *fire*. It proves the destinations carry them and the two registers agree. Firing is AC1's demonstration leg, evidenced separately.
- It is a **dated observation, not a regression guard**. Nothing re-runs it. The comparison is unavailable to CI by construction, so a divergence introduced after 2026-08-15 will be found by the next session that performs this reconciliation and by nothing else.
- Chunk 3's two lessons are `in-flight`. Their exit rows are owed **after** PR #1065 merges, and until they execute this reconciliation's chunk-3 line is provisional.

## Still owed

1. After PR #1065 merges: flip `reference_quoted_text_needs_position_not_heuristic` and `reference_version_collision_invisible_until_merge` from `landing | in-flight` to `landed`, and write their promote exit rows citing the merge commit.

   Those rows carry **`executed`**, not `proposed`.

   **Ruled by the store's owner on 2026-08-15**, resolving an apparent conflict between two authorities:

   - The store's **`POLICY.md` rule 3**: exits are *proposed* by any session and *executed* only in an interactive sweep with the owner present.
   - Parent **#1045 amendment A2.3**, which this record cites as its own authority: promoted lessons reach landing-in-flight "with the **executed** exit row following after merge."

   **A2.3 governs for this class.** The owner's ruling: *approving the change is the approval* — once a promotion has been approved and merged, executing its recorded exit needs no second consent. Rule 3's owner-present requirement guards against an unattended session removing something nobody agreed to lose; a landing-initiated promotion under an approved umbrella is not that case, because the removal was authorized when the promotion was.

   Scope, so this is not read wider than it was ruled: it covers **promotion exits whose landing row was already in flight against an approved, merged vehicle**. Demotions, dedupes, structural rewrites and body deletions are untouched — rule 3 still governs those, and the seven live `proposed | promote` rows remain lawful as proposals awaiting a sweep.

   *(Recorded because the evidence could not have settled it: both prior chunks merged on 2026-08-10 and all 44 of their `executed` rows are stamped 2026-08-10, so a merge-time write and a same-day sweep are indistinguishable in the ledger. The reading was never observable — it had to be ruled.)*
2. At the next sweep: promote chunk 1's 19 exit rows from `executed` to `reconciled` on the read-back evidence recorded above.
3. Umbrella #1045 closes when (1) is done, this record is current, and AC1's chunk-3 demonstrations exist — not when PR #1065 merges.

## Method

The comparison is scripted rather than eyeballed, and the script is reproducible from this description: parse the three registers, join on lesson name (identity is name-keyed per the manifest), apply the lawful-pairing table above, and report both directions. Two modelling errors were made and corrected before this record was written, both worth naming because either would have produced a confident and wrong reconciliation:

- **The exit vocabulary is not two-valued.** A first pass assumed `executed` was the only landed state and reported chunk 2's 25 `reconciled` rows as 25 divergences. `reconciled` is a stronger state, not a broken one.
- **A landed row names its PR, not its issue.** A first pass required the landing vehicle to name the chunk's issue and reported all 44 landed rows as divergent. Both references are lawful; which one appears tells you the phase.
