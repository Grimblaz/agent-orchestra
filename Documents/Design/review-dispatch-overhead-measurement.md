# Review-dispatch overhead: the #975 before/after measurement

Issue #975 cut fixed per-dispatch overhead in the standard adversarial review pipeline. This document is the measurement record its acceptance criteria call for — published as measured, with the confounds stated rather than smoothed over. Numbers here are from one before/after pair; they are evidence about this pair, not a benchmark.

## What was measured, and against what

Both runs reviewed the **same target at the same SHA**: merged PR #890 (issue #886), base `35125175f4af78650034896d2d9f23f024e9b749` → head `c7ce2904f2279589862f73f332d3b919939472b8`. Reviewing a target other than the change itself is deliberate — self-review lets a mid-run defect corrupt the measurement.

Contract version actually executed by the dispatched reviewers:

| Run | Plugin cache | Verified how |
| --- | --- | --- |
| Before | `3.8.0` (pre-change) | `installed_plugins.json` `gitCommitSha` = `18a28ba`; ten review-surface files hash-compared against the worktree |
| After | `3.9.0` (post-change, explicitly pinned) | registry repointed to a cache built from the worktree; every after-run pass independently reported booting `installPath` version `3.9.0` |

Dispatched reviewers resolve bodies and skills from the installed plugin cache first, so a run that boots the wrong version measures nothing. The pin was removed and the registry restored after the run.

## The mechanism being tested

A same-model panel can share a cached prompt prefix only up to the first byte where its prompts differ. Before the change, three things pushed that divergence early: each pass carried its own `handshake_issued_at` timestamp, each pass fetched its own copy of the diff/issue/plan, and every dispatch booted the whole six-mode methodology catalog.

## AC1 — how far the same-model prompts stay byte-identical

Measured over the three same-model (opus) specialist passes, comparing UTF-8 bytes from offset 0 to the first difference:

| Run | Shared prefix | Where it diverges |
| --- | --- | --- |
| Before | **314 bytes** | the per-pass `handshake_issued_at` digit, inside the handshake block |
| After | **64,740 bytes** | the pass-specific lens sentence, after the full evidence packet |

The after-run packet is 64,727 bytes, so the entire packet sits inside the identical span — which is the property that matters. A packet placed *after* the shared span would share the boilerplate and none of the payload.

Cache behavior followed: before, all three passes wrote their own prefix (cache-write 116,157 / 111,681 / 115,285 — uniform, no sharing). After, the batch tiered (124,361 / 88,313 / 87,777) — the first pass writes and the others read. The brief left "whether prefix sharing materializes in this harness" as a known-unknown; it does.

## AC2 — the evidence packet replaced per-pass fetching

All three after-run passes independently reported reading the packet exactly once and running **no** `gh` diff/issue/plan fetch. Tool calls per pass fell from 25/35/32 (before) to 15/13/10 (after) — the eliminated re-fetches, a count that does not depend on which model ran.

Every pass still investigated beyond the packet, reading and grepping the implementation in the live tree. That was the falsifier worth checking: fewer fetches because passes stopped investigating would be a quality regression wearing an efficiency costume.

## AC3 — what a dispatch boots

| | Before | After |
| --- | --- | --- |
| Methodology loaded | monolithic `SKILL.md`, 19,052 B, every dispatch | core 14,216 B + exactly one mode file |
| A code-prosecution dispatch | 19,052 B | 18,661 B (core + `code-prosecution.md` 4,445 B) |
| A defense dispatch | 19,052 B | 15,319 B |
| A design dispatch | 19,052 B | 15,173 B |
| A proxy dispatch | 19,052 B | 14,865 B |

All three after-run passes reported loading the core plus `modes/code-prosecution.md` and no other mode file, at the exact byte sizes above.

The sum of core plus all four mode files (21,370 B) is slightly larger than the old monolith, because each mode file repeats a short header. No single dispatch loads that sum, which is why the criterion is written about what a dispatch *boots* rather than about total file bytes.

## AC4 — per-dispatch token attribution

Extracted with `.github/scripts/extract-dispatch-attribution.ps1` over the session's subagent transcripts. This is a grain the existing cost machinery cannot produce: `cost-attribution.ps1` maps every review dispatch into a single `review` port.

Before-run, full pipeline (five panel passes, defense, judge):

| dispatch | model | selector | api calls | cache_write | cache_read | output | total |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| pass 1 | sonnet | code | 50 | 157,768 | 5,437,317 | 24,051 | 5,619,236 |
| pass 2 | fable | code | 15 | 135,671 | 1,210,585 | 24,879 | 1,371,165 |
| pass 3 | opus-5 | code | 15 | 116,157 | 1,175,312 | 35,567 | 1,327,066 |
| pass 4 | opus-5 | code | 36 | 111,681 | 3,132,850 | 38,322 | 3,282,925 |
| pass 5 | opus-5 | code | 27 | 115,285 | 2,642,799 | 33,618 | 2,791,756 |
| defense | opus | defense | 14 | 120,745 | 947,288 | 13,471 | 1,081,532 |
| judge | fable | — | 13 | 132,747 | 944,150 | 50,739 | 1,127,662 |
| **total** | | | **170** | **890,054** | **15,490,301** | **220,647** | **16,601,342** |

After-run, the three same-model specialist passes (the batch AC1 targets):

| dispatch | model | selector | api calls | cache_write | cache_read | output | total |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| pass 3 | opus-4-8 | code | 16 | 124,361 | 1,226,515 | 21,610 | 1,372,518 |
| pass 4 | opus-4-8 | code | 14 | 88,313 | 977,754 | 15,936 | 1,082,031 |
| pass 5 | opus-4-8 | code | 9 | 87,777 | 518,890 | 15,249 | 621,934 |
| **total** | | | **39** | **300,451** | **2,723,159** | **52,795** | **3,076,483** |

Same three passes, before vs after: **7,401,747 → 3,076,483 tokens**, a 58% reduction, with cache-read (6.94M → 2.72M) as the dominant term, tracking the drop in re-fetching.

**Two confounds that keep this from being a clean same-model delta**, both of which the reader needs in order to size the number honestly:

1. **Model version differed.** The `opus` alias resolved to `claude-opus-5` in the before-run and `claude-opus-4-8` in the after-run. Absolute token counts are therefore not attributable to the change alone. The model-independent signals — shared prefix bytes (314 → 64,740), tool calls (92 → 38), and booted methodology bytes — are the ones that isolate the mechanism.
2. **Scope differed.** The before-run is the full seven-dispatch pipeline; the after-run measured the three-pass same-model batch plus live confirmation of each mechanism. Generalist, defense, and judge dispatches inherit the same parent-side construction by contract, but were not separately re-measured.

No floor is claimed anywhere. If a later run measures less, that is the measurement.

## AC5 — behavior and rigor

Behavior is unchanged: same stages, pass counts, tier map, quorum rules, selectors, and atomic discipline. The full local suite went from 5,685 passing at the launch pin to 5,713 after, the difference being 28 new tests; no test was lost. Parity tests that pin the review surfaces — `atomic-adversarial-pipeline`, `coverage-first-prosecution`, `adversarial-review-panel`, `orchestra-review-handshake`, `orchestra-review-mode-trigger`, `orchestra-review-shell-parity`, `claude-body-resolution-contract`, `specialist-shell-parity`, `bdd-scenario-contract`, `review-credit-emission`, `inline-dispatch-contract` — all pass.

Rigor is comparable rather than merely asserted. The load-bearing findings reproduced across both runs: the judge-mirror-narrowing defect, the untested `Replacement` discriminator, the dropped applicability trigger, and the in-diff disposition contradiction all surfaced on both sides. The after-run's raw finding count is lower because it ran three specialist passes rather than a five-pass panel with a merge stage — a difference in what was run, not a drop in what was caught.

## What this does not establish

One pair, one target, one harness. The 58% figure carries both confounds above. The byte-level and boot-level results are deterministic properties of prompt construction and file loading, so those hold independently of the run; the token totals are a single observation.
