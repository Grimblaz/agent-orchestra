# Design: Control Tower v2 — Ranked-Umbrella Portfolio Board

> **Status**: Shipped (#753). Supersedes the v1 "lanes/rounds" portfolio model from [#692](https://github.com/Grimblaz/agent-orchestra/issues/692). Renders into control-tower issue [#704](https://github.com/Grimblaz/agent-orchestra/issues/704).

---

## Summary

Control Tower v2 is the derived portfolio board for Agent Orchestra. It answers one question at a morning glance: **"what is being worked on next, and what is loose?"** A merge-triggered renderer reads a flat priority spec (`Documents/Planning/sequence.yaml`) and the live GitHub issue graph, then idempotently splices a three-zone board plus a recently-closed footer into the body of issue #704.

v2 replaces the v1 five-bucket "Now / Next / Blocked / Recently closed / Triage" lane model. The organizing primitive is no longer a flat sequence of leaf issues distributed into lanes; it is an **ordered list of umbrella (epic) issues**, ranked by priority, with the first open umbrella expanded to show its open children. Triage is no longer a label scan — it is **derived** from parent-edge data.

The renderer is `.github/scripts/render-portfolio.ps1`. The merge-triggered workflow is `.github/workflows/render-portfolio.yml`. The Pester suite is `.github/scripts/Tests/render-portfolio.Tests.ps1`.

---

## Table of Contents

- [What changed from v1](#what-changed-from-v1)
- [The spec format (schema_version 2)](#the-spec-format-schema_version-2)
- [The three zones plus footer](#the-three-zones-plus-footer)
- [Derivation rules](#derivation-rules)
- [Warning tiers](#warning-tiers)
- [Idempotent splice](#idempotent-splice)
- [Known dependency: connection caps (#746)](#known-dependency-connection-caps-746)
- [Touchpoints](#touchpoints)

---

## What changed from v1

| Aspect | v1 (#692, superseded) | v2 (#753) |
|---|---|---|
| Organizing primitive | Flat sequence of leaf issues | Ordered list of umbrella (epic) issues |
| Zones | Now / Next / Blocked / Recently closed / Triage | 🎯 Active / Umbrellas (ranked) / 🔥 Triage / Recently closed |
| Spec | `schema_version: 1`, sequenced leaves + `rounds:` | `schema_version: 2`, inline `umbrellas: [N, …]` priority list |
| Triage source | `--label triage` query (label scan) | Derived from parent-edge data (no label scan) |
| "Active" selection | Now/Next lanes from sequence + blocker graph | First **open** umbrella in spec order, expanded |

The most consequential change is the **Triage model**: v2 removed the triage-label scan entirely. Any prose claiming an issue needs a `triage` label to appear on the board is stale. See [safe-operations §2b-bis](../../skills/safe-operations/SKILL.md#2b-bis-umbrella-or-triage-at-creation-additive-to-2b).

---

## The spec format (schema_version 2)

`Documents/Planning/sequence.yaml` is parsed by `ConvertFrom-SequenceSpec` with **regex only** (no `ConvertFrom-Yaml` dependency). The contract is intentionally strict so that a malformed spec fails loud rather than rendering a wrong board.

```yaml
schema_version: 2
control_tower: 704
recently_closed_days: 14
umbrellas: [476, 571, 674, 662, 343, 693, 732]
```

| Field | Meaning |
|---|---|
| `schema_version` | Must be the integer `2`. `1` is rejected with a migration diagnostic. |
| `control_tower` | Issue number that receives the rendered board. Unquoted integer. |
| `recently_closed_days` | Look-back window (days) for the recently-closed footer. |
| `umbrellas` | Inline list of umbrella issue numbers in **priority order** (rank 1 first). |

**Rejected (returns `$null` with a loud diagnostic):**

- `schema_version: 1` (migration message).
- Quoted `control_tower` or quoted numbers inside `umbrellas`.
- Block-style `umbrellas:` (items on separate `- N` lines); the inline `[…]` form is required.
- A stray `rounds:` key (a v1 artifact).
- Duplicate entries in `umbrellas:`.
- An empty `umbrellas:` list.
- Non-integer entries in `umbrellas:`.

By design the parse failure is **non-terminating** (`Write-Error -ErrorAction Continue` then `return $null`), so the contract "returns `$null` on validation failure" holds even when the caller runs under `$ErrorActionPreference = 'Stop'` (e.g. the GitHub Actions `pwsh` shell). The caller (`Invoke-PortfolioRender`) then hard-exits rather than writing a partial board.

---

## The three zones plus footer

The renderer writes the following between `<!-- portfolio-tracker:begin -->` and `<!-- portfolio-tracker:end -->` in the #704 body, in this order:

1. **🎯 Active** — the first **open** umbrella in spec order, expanded. Heading is `## 🎯 Active — #N {title}`. Lists that umbrella's **open** direct sub-issues; a blocked child is annotated `⛔ blocked by #N`. Closes with a progress footer line `── done/total done ──` (or `── no children linked ──` when the umbrella has no children). When no umbrella is open, renders `## 🎯 Active` / `*(no active umbrella)*`.
2. **Umbrellas (ranked)** — every umbrella in spec order, one line each: `- #N {title} done/total ◀ active`. The `◀ active` marker flags the active umbrella. `done/total` counts **direct** children only; an umbrella with no linked children renders `0/0 (no children linked)`.
3. **🔥 Triage** — derived loose issues (see [Derivation rules](#derivation-rules)), ranked and capped at 5 with a `(+N more)` residual line. Renders `*(none)*` when empty.
4. **Recently closed** — issues closed within `recently_closed_days`. Renders `*(none)*` when empty.

[Warning lines](#warning-tiers) (if any) follow the zones, before the footer. The footer line `portfolio content unchanged since {timestamp} — rendered by render-portfolio.ps1` is load-bearing for idempotency and must remain last.

---

## Derivation rules

All classification happens in `Get-PortfolioBuckets` against the live issue graph.

**Active umbrella** — the first umbrella in `umbrellas:` order whose state is `OPEN`. Earlier umbrellas that are `CLOSED` are skipped (and emit a drift warning, below).

**Active children** — the active umbrella's **open** direct sub-issues, ordered deterministically by: priority-label key (`high` → `medium` → `low` → unlabeled) → `createdAt` descending → issue-number ascending. The number-ascending leg is a mandatory final tiebreak so the order is fully deterministic. The Markdown formatter consumes this order verbatim and does not re-sort.

**Ranked umbrellas** — every entry in `umbrellas:`, in spec order. `done/total` is computed over **direct** children only: a closed direct child counts as done regardless of its grandchildren. Zero linked children renders `0/0 (no children linked)`.

**Triage** — derived, **not** label-based. An issue is Triage when **all** of:

- state is `OPEN`, **and**
- GraphQL `parent` is null (no umbrella parent), **and**
- `subIssues.totalCount == 0` (not itself an umbrella), **and**
- the issue number is **not** listed in `umbrellas:`.

Triage is ranked priority → recency → number-ascending and capped at 5; the remainder is summarized as `(+N more)`. There is **no inversion fallback** — if nothing qualifies, Triage renders `*(none)*`.

**Recently closed** — issues whose `closedAt` is within `recently_closed_days` of the render time.

---

## Warning tiers

Warnings are **additive** `⚠️` lines appended after the zones. They never fail the render — a board with warnings still renders fully.

**Drift warnings** flag spec/graph inconsistencies:

- An **open** issue with `subIssues.totalCount > 0` that is **not** listed in `umbrellas:` — it looks like an unlisted umbrella (`⚠️ open umbrella #N not in ranked list`).
- A **closed** issue that is still listed in `umbrellas:` (`⚠️ listed umbrella #N is closed`).

**Integrity warnings** flag possible fetch truncation: when an umbrella's `subIssues.totalCount` does not equal the number of `nodes` actually returned (`⚠️ umbrella #N: subIssues.totalCount=X but only Y nodes returned (possible truncation)`). This is the safety net for the connection-cap dependency below — it is a warn tier, so the board still renders.

A separate **unresolved** warning fires when a listed umbrella could not be fully resolved (issue not found, or incomplete blocker data).

---

## Idempotent splice

`Get-SplicedBody` replaces the content between the `portfolio-tracker` markers. Before writing, it strips the timestamped footer line from both the existing and the freshly-rendered block and compares the remainder. If the timestamp-stripped content is identical, the splice returns `$null` and **no write occurs** — so a no-op render does not churn the issue body or its edit history. Prose outside the marker block is always preserved; if the markers are absent, the block is appended once.

A malformed region (exactly one of the two markers present) throws rather than guessing — the board is never written into a half-marked body.

---

## Known dependency: connection caps (#746)

The per-umbrella GraphQL query fetches connections at `first: 50` — `labels`, `blockedBy`, and `subIssues`. Issue [#746](https://github.com/Grimblaz/agent-orchestra/issues/746) (raise and guard those caps, or paginate) is the prerequisite for **guaranteed** completeness at scale and is **still open**.

This is a **known dependency, not a defect**:

- Live umbrella child counts are ≪ 50, so no data is dropped in practice today.
- The **integrity warn tier** is the current safety net: if `subIssues.totalCount` exceeds the returned node count, the board renders a truncation warning rather than silently dropping children.
- Separately, the bulk open/closed issue scans use a two-tier truncation contract that **hard-exits** (refuses to render) if a scan returns at its ceiling, so a truncated leaf scan can never produce a misleading board.

When live counts approach the cap, #746 must land before the board can be trusted for completeness at that scale.

---

## Touchpoints

- **Renderer**: `.github/scripts/render-portfolio.ps1` (`ConvertFrom-SequenceSpec`, `Get-PortfolioBuckets`, `Format-PortfolioMarkdown`, `Get-SplicedBody`, `Invoke-PortfolioRender`).
- **Spec**: `Documents/Planning/sequence.yaml` (`schema_version: 2`).
- **Workflow**: `.github/workflows/render-portfolio.yml` (push to `main` / `workflow_dispatch`).
- **Tests**: `.github/scripts/Tests/render-portfolio.Tests.ps1`.
- **Intake rule**: [`skills/safe-operations/SKILL.md` §2b-bis](../../skills/safe-operations/SKILL.md#2b-bis-umbrella-or-triage-at-creation-additive-to-2b) — umbrella insert-at-rank and auto-derived Triage.
- **Auto-render note**: `skills/post-pr-review/SKILL.md` §7 — the board re-renders after every merge to `main`.
- **Session snapshot**: `skills/session-startup/SKILL.md` Step 7c — reads the rendered board from #704 at session start.
