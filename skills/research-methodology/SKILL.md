---

name: research-methodology
description: "Evidence-driven research methodology for technical analysis and recommendation building. Use when gathering verified findings, cross-referencing internal and external sources, or converging multiple options into one recommended approach. DO NOT USE FOR: implementation work (use implementation-discipline) or debugging a live failure path (use systematic-debugging)"
---

<!-- platform-assumptions: platform-neutral research methodology, plus a Claude Code-specific Two-Layer Research Delegation section (see below) for fan-out reads via the Explore subagent; assumes evidence is gathered from workspace and approved external sources. -->
<!-- markdownlint-disable-file MD041 MD003 -->

# Research Methodology

Reusable methodology for deep technical research that produces verified findings, clear trade-offs, and one recommended approach.

## When to Use

- When a task needs evidence-backed research before planning or implementation
- When findings must be cross-checked across multiple files, tools, or authoritative external sources
- When multiple viable approaches need a concise recommendation with explicit trade-offs
- When research notes need maintenance so stale or duplicate findings do not accumulate

## Purpose

Research should narrow uncertainty, not create more of it. Gather evidence, verify patterns across sources, document only what is supported by tools, and end with one recommended path that is ready for planning or implementation.

## Core Principles

- Treat unverified statements as hypotheses until tool output confirms them
- Prefer repeated evidence across independent sources over one-off matches
- Converge on one recommended approach instead of leaving unresolved option lists behind
- Delete superseded or duplicate findings as soon as better evidence appears
- Keep findings concise enough that a planner or implementer can act on them immediately

## Research Workflow

1. Define the research question and the specific decisions the research must support.
2. Gather internal evidence from the codebase, instructions, design docs, and neighboring implementations.
3. Add external evidence only when the workspace does not fully answer the question.
4. Compare viable approaches against project constraints, conventions, and maintenance cost.
5. Reduce alternatives to one recommended approach and remove discarded paths from the final notes.

## Evidence Collection

### Internal Research

- Read the closest owning files before broad exploration
- Search for repeated patterns, not isolated snippets
- Check usage sites to understand how a pattern is actually applied
- Verify repository conventions from architecture and instruction surfaces before recommending structural changes

### External Research

- Prefer official documentation, standards, or authoritative repositories
- Record why the source is relevant, not just what it says
- Cross-check external guidance against the repository's current constraints before treating it as applicable
- Stop external exploration once the remaining uncertainty no longer changes the recommendation

## Documentation Discipline

For each substantive finding:

1. Record the source or tool evidence that established it.
2. Explain the implementation or planning impact in one or two sentences.
3. Merge duplicate observations into one stronger entry.
4. Remove obsolete statements instead of stacking corrections under them.

## Alternative Analysis

When multiple approaches are viable, compare them on:

- Fit with current architecture and conventions
- Complexity to implement and validate
- Risk of drift or future maintenance cost
- Quality of supporting evidence in the codebase or authoritative sources

The final output should recommend one approach explicitly. Keep rejected alternatives out of the final research document unless they remain relevant as active risks or constraints.

<!-- pointer-stability: this heading is referenced verbatim by seven inbound pointer sites — design-exploration §1 (Gather the Current Context), design-exploration §2 (Load Adjacent Guidance), plan-authoring §3 (Keep the Research Subagent Bounded), customer-experience (Upstream Framing At A Glance), multi-issue-bundling.md (Agent Selection dispatch notes), subagent-env-handshake (tree-claim rubric + adoption guidance), Documents/Design/session-cost-discipline.md (§ Related Mechanism + § Related Sources). Renaming this heading breaks all seven; update every listed site before renaming. -->

## Two-Layer Research Delegation

Claude Code sessions can split a fan-out repo read into two layers: a Layer-1 (locate/enumerate) `Explore` subagent dispatch for locating or enumerating things, and the expensive parent session — Layer 2 — for any read that requires judgment while reading. This section is the canonical definition; other skills point here rather than restating it.

### Split rule

Delegate a fan-out repo read to a fresh-context `Explore` subagent when the read *locates* where a known thing lives or *enumerates* a fixed shape ("where is X", "what is Y's signature", "which files match Z"). Keep the read inline in the expensive session when it requires *synthesizing* a judgment from what is found ("what is the right convention here", "how do these pieces fit together"), regardless of file count.

**Worked borderline example**: "list every adapter file matching the glob and report each file's `adapter-type` frontmatter value" delegates (multi-file enumeration). "Infer the adapter convention from reading those files" stays inline (synthesis, judgment-during-reading).

### Citation contract

Every claim a Layer-1 (`Explore`) dispatch returns must carry an exact `path:line` (or `path:line-line`) citation. If the dispatch cannot find something, it must say so explicitly ("not found") — never infer or guess a citation.

### Lower boundary

Point lookups — a single grep or a single file read — stay inline. Dispatch overhead exceeds the saving for a single lookup. This cost gate takes precedence over the split rule's kind-classification: a locate/enumerate read that resolves in a single grep, glob, or file read stays inline even though it is locate/enumerate work in kind.

### Upper boundary

Open-ended architectural reading where judgment happens *during* the reading stays inline, regardless of how many files it touches. This is the flip side of the split rule's worked example above.

### Verification duty with visible trace

The dispatching session must verify any Layer-1 claim that a design or plan decision actually rests on, and must leave a visible one-line trace in the session in the form `verified {claim} at {path:line}` (so the duty is observable; issue #691's CE Gate exercises this trace). **Residual-risk boundary**: Layer-1 citations that do not underlie a decision are, by design, NOT re-verified — that skipped re-verification is the cost saving this convention exists to capture, and the accepted trade-off is that a wrong non-decision citation could in principle steer authoring without a mechanical backstop.

### Never delegate the verifier

Verification of Layer-1 claims — including the plan-authoring Grounding Pass work described elsewhere in this skill set — is in-parent work and must never be routed back to a Layer-1 dispatch.

### Canonical dispatch-prompt template

The template below is fenced with an outer `~~~~` (four tildes) block, not a plain triple-backtick fence, because the template's own citation examples can contain triple-backtick sequences that would otherwise prematurely close a triple-backtick block. This fencing choice is deliberate; keep the outer fence at four characters (tildes or backticks) if this template is ever edited.

~~~~markdown
Locate/enumerate task: {precise question — "where is X defined", "which files match glob Y", "what is Z's signature"}.

Scope: {directory or glob to search}.

Return every claim with an exact `path:line` (or `path:line-line`) citation. If you cannot find something, state "not found" explicitly — do not infer or guess a citation.

Do not synthesize a judgment, recommendation, or convention from what you find; report locations and enumerations only.
~~~~

### Tier note

As of Claude Code v2.1.198, `Explore` inherits the main conversation's model (capped at Opus on the Claude API) — it does not run on a fixed cheap tier by default. The dispatch's context-window saving (the parent never carries the fan-out read; `Explore` runs a short-lived fresh context) is real and model-independent regardless of tier. The per-invocation `model:` parameter remains the override lever, per the inheritance order in `Documents/Design/agent-body-architecture.md`.

### Handshake note

Layer-1 `Explore` dispatches under `workspace_mode: shared` skip the `subagent-env-handshake` protocol. This is grounded on `Explore` reading the live shared tree in the parent's own working directory (not a stale or isolated copy), plus the verification-duty compensating control described above. This justification is independent of, and does not rely on, the handshake skill's research-subagent exemption (ND-3), which covers a different, non-tree-verifying class of dispatch. Layer-1 dispatches run under `isolation: worktree` are **NOT** covered by this waiver — a worktree-isolated dispatch reads a potentially divergent tree and remains subject to the handshake protocol — which in v1 treats `workspace_mode: worktree` as an error path: the subagent may proceed but must tag every tree-grounded finding `environment-unverified` (see `subagent-env-handshake` § Error path).

### Platform qualifier

Copilot (frozen, retiring per the repo's deprecation notice) has no native `Explore`-equivalent agent, so on that platform fan-out reads stay inline; this convention's Layer-1 delegation applies to Claude Code sessions.

## Completion Criteria

Research is complete when it can answer:

- What needs to change
- How it should be approached
- Where the work belongs in the repository
- Why the recommendation is preferable
- Which risks or unknowns still need explicit handling

If those questions are answered with verified evidence, stop researching and hand off.

## Handoff Expectations

- Provide the key discoveries that materially affect planning or implementation
- State one recommended approach, not an unranked list
- Call out unresolved risks or unavailable evidence explicitly
- Ensure the final notes are current, deduplicated, and ready for the next agent

## Related Guidance

- Load `implementation-discipline` when the work shifts from analysis to code changes
- Load `software-architecture` when the recommendation depends on dependency direction or layer boundaries
- Load `systematic-debugging` when the problem is a failing behavior with unclear root cause rather than an open-ended research question

## Gotchas

| Trigger                                               | Gotcha                                           | Fix                                                           |
| ----------------------------------------------------- | ------------------------------------------------ | ------------------------------------------------------------- |
| Treating one matching file as proof of a repo pattern | A local exception is misreported as a convention | Verify the pattern across multiple owning files or call sites |

| Trigger                                               | Gotcha                                                                | Fix                                                          |
| ----------------------------------------------------- | --------------------------------------------------------------------- | ------------------------------------------------------------ |
| Leaving multiple viable approaches in the final notes | Planning stays ambiguous and downstream agents must redo the judgment | Choose one recommendation and delete superseded alternatives |
