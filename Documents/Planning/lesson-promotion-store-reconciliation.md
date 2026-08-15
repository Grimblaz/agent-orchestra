# Lesson-promotion store reconciliation

Umbrella [#1045](https://github.com/Grimblaz/agent-orchestra/issues/1045), **AC6**: *each chunk's promoted lessons exit the store through its recorded-exit procedure, evidenced by the LEDGER exit rows cited in the chunk PR; the manifest is authoritative repo-side, the store LEDGER store-side, and chunk 3 reconciles the two — divergence is a finding, not a silent state.* As amended by **A2.3**: *each chunk's promoted lessons reach the store's landing-in-flight state naming that chunk's vehicle, with the executed exit row following after merge; chunk 3's reconciliation reads **both tracks**, and divergence on either is a finding.*

## Why this file exists rather than only a PR body

AC6 names the chunk PR as the evidence surface, and the reconciliation is carried there too. This file exists because **a PR body is not where a later reader looks.** The private store lives at `~/.claude/projects/{project-slug}/memory/`, is not under version control, and — as `lesson-promotion-manifest.json`'s own `roster_snapshot.note` records — is *absent from every CI runner*. No check in this repository can perform this comparison, now or after any amount of CI work: a runner gets a clone and the store is not in it. That makes the reconciliation an agent-session act with a dated result, and this file the thing a future session reads to know when it last happened and what it found.

Specifically, the memory store's own **2026-09-08 sweep** decides whether every rostered lesson is lawfully landing-initiated. This record is what that sweep should read first.

## Reconciliation of 2026-08-15

Performed against `Documents/Planning/lesson-promotion-manifest.json` at branch `claude/1051-a5-residue` (chunk 3, PR [#1065](https://github.com/Grimblaz/agent-orchestra/pull/1065)), baseline `6626102`, and the store's `LEDGER.md` / `SLATE.md` as of the same date.

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

A landing row names its **issue** while in flight and its **merged PR and commit** once landed; both are lawful references to the same vehicle.

### Result — all 46 rows, both tracks

| Chunk | Vehicle | Rows | Track A (landing) | Track B (exit) | Verdict |
| --- | --- | ---: | --- | --- | --- |
| 1 | #1049 → PR #1055 @ `d610bbe` | 19 | `landed` | `executed` | reconciles |
| 2 | #1050 → PR #1061 @ `3e39c91` | 25 | `landed` | `reconciled` | reconciles |
| 3 | #1051 → PR #1065 | 2 | `in-flight` | *(none — lawful pre-merge)* | reconciles |
| | | **46** | | | **0 divergences** |

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

1. After PR #1065 merges: flip `reference_quoted_text_needs_position_not_heuristic` and `reference_version_collision_invisible_until_merge` from `landing | in-flight` to `landed`, and write their `executed | promote` LEDGER rows citing the merge commit.
2. At the next sweep: promote chunk 1's 19 exit rows from `executed` to `reconciled` on the read-back evidence recorded above.
3. Umbrella #1045 closes when (1) is done, this record is current, and AC1's chunk-3 demonstrations exist — not when PR #1065 merges.

## Method

The comparison is scripted rather than eyeballed, and the script is reproducible from this description: parse the three registers, join on lesson name (identity is name-keyed per the manifest), apply the lawful-pairing table above, and report both directions. Two modelling errors were made and corrected before this record was written, both worth naming because either would have produced a confident and wrong reconciliation:

- **The exit vocabulary is not two-valued.** A first pass assumed `executed` was the only landed state and reported chunk 2's 25 `reconciled` rows as 25 divergences. `reconciled` is a stronger state, not a broken one.
- **A landed row names its PR, not its issue.** A first pass required the landing vehicle to name the chunk's issue and reported all 44 landed rows as divergent. Both references are lawful; which one appears tells you the phase.
