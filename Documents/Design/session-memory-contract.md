# Design: Session Memory Contract

**Domain**: Session-state survival and cross-tool handoffs  
**Status**: Current  
**Implemented in**: Issue #440

---

## Purpose

This document records the design rationale for the session-memory contract. It is
not the operational contract and intentionally does not duplicate the canonical
state-row table.

The operational source of truth is
[skills/session-memory-contract/SKILL.md](../../skills/session-memory-contract/SKILL.md).
That skill owns the survival vocabulary, read/write precedence, row IDs,
fungibility labels, and concrete mechanisms for plan, design, review, startup,
calibration, tracking, plugin, rate-limit deferral, and subagent state.

## Problem

Agent Orchestra had several valid state mechanisms but no single vocabulary for
describing what survives compaction, conversation end, worktree changes, or a
Copilot-to-Claude handoff. Plan and design caches used VS Code session memory,
Claude surfaces used GitHub issue markers, review and calibration data used a
mix of session memory, PR artifacts, and `.copilot-tracking/`, and startup and
release hygiene had hook-scoped local state.

The risk was not that every mechanism was wrong. The risk was that docs could
use the same phrase, usually "session memory", for state with different
survival boundaries and different handoff behavior.

## Options Considered

| Option | Summary | Decision |
| --- | --- | --- |
| A | Document a cross-tool contract over the mechanisms already in use. | Selected |
| B | Add a new Claude-local session store or sync layer that mirrors Copilot session memory. | Rejected |
| C | Make every handoff durable by writing GitHub artifacts for all state shapes immediately. | Rejected |

## Why Option A Won

Option A fixed the ambiguity without changing persistence behavior. It kept the
fast same-conversation path for Copilot, kept Claude on durable GitHub markers,
kept local worktree artifacts local, and made the limitations visible through
row-specific survival and fungibility labels.

Option B would have introduced a new mechanism with unclear lifecycle and
cross-tool semantics. It also would have made hook, inline command, and subagent
surfaces appear more uniform than they are.

Option C would have made all state durable, but at the cost of noisy GitHub
artifacts, premature handoff writes, and unnecessary API dependence for state
that is intentionally temporary or local. It also would have blurred the
difference between a cache and the source of truth.

## Design Decisions

### D1 - Operational Contract Lives In The Skill

The skill is the canonical implementation-facing source because agents and
commands load skills during workflow execution. Design docs, public docs, and
Claude guides should link to the skill when they describe state survival or
handoff behavior.

### D2 - This File Is Rationale Only

This document explains why the contract exists and why Option A was selected. It
must not grow a competing operational table. If a state shape changes, update
[skills/session-memory-contract/SKILL.md](../../skills/session-memory-contract/SKILL.md)
first, then adjust rationale docs only when the decision itself changed.

### D3 - No New Mechanism

Issue #440 deliberately added documentation, citations, and structural checks
over existing mechanisms. It did not add a Claude session-memory store, a new
sync path, or a replacement for GitHub issue and PR markers.

### D4 - Survival Vocabulary Names Failure Boundaries

The vocabulary distinguishes state that survives only a dispatch, the current
conversation, the current worktree, or a durable GitHub/committed surface. The
labels make the important user question inspectable: where will this state still
exist after compaction, after the conversation ends, after switching tools, or
after moving to a fresh checkout?

The surface-naming rule exists because the same logical feature can have
different survival behavior in a hook, inline command, or subagent prompt.
Without surface-qualified labels, docs would hide the exact gap the contract is
meant to expose.

### D5 - Row IDs Carry Discoverability Without Copying The Table

Stable IDs such as `SMC-01` let shell, command, skill, and public docs cite the
owning row without duplicating the 15-row table. This keeps the operational
contract centralized while still making a local paragraph understandable.

### D6 - Known Gaps Stay Visible

The contract names bounded or provisional paths instead of treating every shape
as fully fungible. The most important tradeoff is that same-session caches remain
fast but are not automatically cross-tool handoffs.

### D7 - Cache-Vs-Durable Conflict Rule

Durable GitHub or committed sources win over stale local caches, but a provably
fresher in-conversation cache is the source for the next durable write. This is
why D9 compares active plan and design state against the latest durable marker
before writing a pause/resume handoff, and why comparisons normalize
transport-only formatting drift before deciding whether a durable marker changed.

## Review Themes And Tradeoffs

- **Discoverability vs. duplication**: row citations make the contract findable
  from many surfaces without copying the full table into public docs.
- **Same-session speed vs. cross-tool resume**: Copilot session caches stay fast,
  while durable cross-tool resume remains marker-based.
- **Honest gaps vs. false symmetry**: Claude inline/headless surfaces and local
  worktree state are explicitly labeled when they lack durable or cross-tool
  guarantees.
- **Tests vs. prose**: structural tests lock the operational skill and citation
  surface; this rationale explains the decision but does not define runtime
  behavior.

## Issue #384 Pending Markers

Rows `SMC-01`, `SMC-02`, and `SMC-03` carry `pending-384` markers because the
plan/design cache and durable handoff rules may be refined by issue #384. Until
that resolves, the rows are intentionally provisional and include update
instructions in the operational contract.

When #384 resolves, update the affected rows in
[skills/session-memory-contract/SKILL.md](../../skills/session-memory-contract/SKILL.md)
before updating secondary docs. Do not remove or reinterpret the pending markers
only in this rationale document.

## Issue #379 Fungibility Implications

Issue #379 tracks follow-up work for partial or non-fungible paths. The contract
keeps those limitations explicit: a same-session Copilot cache is not a Claude
handoff, a branch-keyed pre-PR review-state file is not a durable artifact, and
raw calibration snapshots are not shared state until represented in durable PR
metadata.

The design accepts those limits because adding automatic mirroring would create
new synchronization behavior outside the selected Option A scope.

## Claude Handoff Implications

Claude does not gain a new session-memory mechanism from this design. Claude
handoffs continue to use parent dispatch context first, then latest-comment-wins
GitHub issue or PR markers where the operational contract defines them. This is
why `/plan`, `/orchestrate`, and Claude specialist shells cite `SMC-01`,
`SMC-03`, `SMC-06`, or `SMC-08` rather than referring to a Claude-local cache.

## Related Sources

- [skills/session-memory-contract/SKILL.md](../../skills/session-memory-contract/SKILL.md)
  - canonical operational contract
- [Documents/Design/plan-storage.md](plan-storage.md) - plan and design cache
  design history
- [CLAUDE.md](../../CLAUDE.md) - Claude Code guide and handoff surface
- [README.md](../../README.md) - public installation and workflow overview
