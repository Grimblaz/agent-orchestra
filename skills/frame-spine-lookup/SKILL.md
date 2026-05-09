---
name: frame-spine-lookup
description: "Frame spine lookup methodology for mid-turn slice retrieval by spine-aware specialists. Use when a dispatched specialist needs to fetch an addressable plan slice from the durable plan-issue comment. DO NOT USE FOR: authoring plan spines, emitting frame credits, frame-port adapter declarations, or custom transport implementation."
---

<!-- platform-assumptions: markdown skill guidance for Claude Code specialist shells with Read and Bash access in Agent Orchestra. -->
<!-- markdownlint-disable-file MD041 MD003 -->

# Frame Spine Lookup

Methodology for retrieving addressable frame-spine slices during a specialist
turn without loading the full implementation plan.

## When to Use

- When Code-Conductor dispatches a specialist with a frame spine, an active
  slice, and the durable plan comment id.
- When a specialist needs a depth-1 dependency slice or another explicitly
  addressable slice during the same turn.
- When the specialist must verify that the dispatched spine is still current
  before relying on a slice fetched from GitHub.

## Purpose

Keep specialist prompts focused while preserving plan traceability. The durable
plan-issue comment remains the source of truth; this skill defines how a
specialist fetches that comment, asks the production parser helpers for the
needed step, and handles stale-spine detection.

## Dispatch Inputs

Code-Conductor must provide the specialist with:

- Repository owner and name.
- The GitHub issue comment id for the `<!-- plan-issue-{ID} -->` comment.
- The target spine step id, such as `s4`.
- The spine `generated_at` value captured at dispatch time.

The specialist must carry the dispatched `generated_at` into lookup. The lookup
uses `generated_at` to compare the dispatch-time spine against the current
plan-issue comment body.

## Operational Contract

1. Fetch the durable plan payload with the GitHub issue comments API. See
   `platforms/claude.md` and `platforms/copilot.md` for tool-specific invocations.

   Read the response body field as the plan-issue comment body. Do not parse
   issue timelines or search results when the comment id is already known.

2. Invoke the production frame-spine parser helpers through the lookup
   operation. The command shape must match this contract:

   ```powershell
   pwsh -File .github/scripts/lib/frame-spine-core.ps1 -Op Lookup -CommentBodyPath {path} -GeneratedAt {generated_at} -StepId {id}
   ```

   The implementation may pass the fetched body by a supported path or stream,
   but the operation remains `-Op Lookup` against `frame-spine-core.ps1`, with
   the dispatched `generated_at` value and requested `-StepId {id}` present in
   the lookup invocation.

3. Use the returned slice content as the only additional plan context for the
   current turn. Do not manually parse `<!-- frame-spine -->` or
   `<!-- frame-slice -->` blocks in specialist prompt logic.

4. On generated_at mismatch, respect the F2.2 hash-elision filter before
   declaring staleness. If the lookup result is `stale-spine`, stop specialist
   work and return control to Conductor for re-dispatch with a fresh spine.

## Stale-Spine Handling

`generated_at` can change when the plan is amended or re-emitted. Lookup must
not treat timestamp-only churn as a semantic change until the F2.2
hash-elision filter has ignored transport-only `generated_at` differences. If
the filtered comparison still shows that the dispatched spine is no longer the
current plan spine, lookup returns `stale-spine`.

Specialist response on `stale-spine` is intentionally narrow:

- Do not continue implementation, tests, refactoring, or documentation from the
  stale slice.
- Report that the lookup returned `stale-spine`.
- Return control to Conductor so Conductor can re-dispatch the specialist with
  current spine context.

## Tool-Grant Verification

The specialist shells that can perform lookup already have the required tool grants.

Claude Code specialists (`Read` and `Bash`):

- `agents/code-smith.md`
- `agents/test-writer.md`
- `agents/doc-keeper.md`
- `agents/refactor-specialist.md`

Copilot specialists (`execute/runInTerminal` or `execute` wildcard):

- `agents/Code-Smith.agent.md`
- `agents/Test-Writer.agent.md`
- `agents/Doc-Keeper.agent.md`
- `agents/Refactor-Specialist.agent.md`
- `agents/Specification.agent.md`
- `agents/UI-Iterator.agent.md`
- `agents/Experience-Owner.agent.md`

`agents/Research-Agent.agent.md` is excluded: it has only `read`, `edit`, `search`, and
`web` grants — no `execute/*`. Copilot spine lookup for Research-Agent is deferred to a
follow-up issue (Step 12 of #514).

Do not edit specialist shells for this contract unless a future test proves the grants drifted.

## Non-Goals and Deferred Work

- Copilot parity shims for spine lookup shipped in #514. Research-Agent Copilot
  spine lookup is deferred to a follow-up issue (Step 12 of #514).
- A custom MCP server lookup path is deferred and is a non-goal for this skill.
- This skill is supporting methodology only. It declares no `provides:` field
  and does not fill a frame port.

## Platform-specific invocation

See `platforms/claude.md` for Claude Code tool bindings (`Bash` and `Read`) and
`platforms/copilot.md` for Copilot VS Code tool bindings (`execute/runInTerminal`).
Platform shims are the only location where tool names appear; the Operational
Contract above is tool-agnostic.

## Gotchas

| Trigger                       | Gotcha                                                               | Fix                                                               |
| ----------------------------- | -------------------------------------------------------------------- | ----------------------------------------------------------------- |
| Specialist sees a stale slice | Continuing from old context can apply the wrong requirement contract | Return control to Conductor for re-dispatch                       |
| Comment id is available       | Searching issue comments can select an older plan marker             | Fetch `gh api repos/{owner}/{repo}/issues/comments/{id}` directly |
