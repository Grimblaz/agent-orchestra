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
- The GitHub issue comment id for the `<!-- frame-slices-{ID} -->` sibling
  comment, required when the dispatched spine's `slice_comment_id` field is
  present. Code-Conductor already has the `<!-- frame-spine ... -->` block in
  its own dispatch context (see `agents/Code-Conductor.agent.md`) and reads
  `slice_comment_id` from it directly to populate this input — the specialist
  never reads `slice_comment_id` itself. Absent when the spine has no
  `slice_comment_id` (legacy/unsplit plan); see Operational Contract step 1
  for the resulting single-fetch behavior.
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

   When a sibling comment id was dispatched (the spine's `slice_comment_id` was
   present at dispatch time), also fetch the `<!-- frame-slices-{ID} -->`
   sibling comment body, keyed on the dispatched sibling id, with the same
   GitHub issue comments API. Before concatenating, verify the fetched sibling
   body carries a `<!-- frame-slices-{ID} -->` marker whose `{ID}` matches the
   dispatched issue number. If the marker is absent or names a different
   issue, stop before invoking `-Op Lookup` and report
   `sibling-identity-mismatch` to Conductor rather than proceeding with a body
   that may belong to the wrong issue — a copy-pasted or stale sibling id is a
   zero-adversary path to executing a foreign requirement contract. This check
   runs at the shim, before `frame-spine-core.ps1` is invoked: the core script
   has no issue-number parameter to perform it, and adding one would widen the
   signature the shim concatenation approach was chosen to avoid.

   When the identity check passes, concatenate the plan-issue comment body and
   the sibling body with a single blank line (`\n\n`) between them — plan body
   first, sibling body second — and pass the concatenated text to `-Op Lookup`
   as a single comment body. When no sibling id was dispatched (legacy plan,
   no `slice_comment_id` on the spine), fetch only the plan comment and pass
   it unchanged; this is the current single-fetch behavior and its shape does
   not change.

2. Invoke the production frame-spine parser helpers through the lookup
   operation. The command shape must match this contract:

   ```powershell
   pwsh -File .github/scripts/lib/frame-spine-core.ps1 -Op Lookup -CommentBodyPath {path} -GeneratedAt {generated_at} -StepId {id} -Format Json
   ```

   The implementation may pass the fetched body by a supported path or stream
   (`-CommentBodyPath` for file-based, `-CommentBodyStdin` for piped stdin), but
   the operation remains `-Op Lookup` against `frame-spine-core.ps1`, with the
   dispatched `generated_at` value and requested `-StepId {id}` present in the
   lookup invocation. When a sibling was fetched, the body passed here is the
   step-1 concatenation of the plan comment and the sibling comment — the
   command shape and `-Op Lookup`/`-StepId {id}` invocation are unchanged
   either way; only the content behind `-CommentBodyPath`/`-CommentBodyStdin`
   differs. Always pass `-Format Json` so the response is machine-
   parseable JSON regardless of platform; parse the returned `status` field to
   determine the lookup outcome (do not rely on exit code alone — see Exit Codes
   below).

3. Use the returned slice content as the only additional plan context for the
   current turn. Do not manually parse `<!-- frame-spine -->` or
   `<!-- frame-slice -->` blocks in specialist prompt logic — this includes the
   spine's `slice_comment_id` field. The specialist obtains the sibling
   comment id exclusively from the Dispatch Inputs Conductor supplies, never
   by reading the spine block itself: the Lookup CLI's JSON payload is closed
   (`frame-spine-core.ps1`'s `-Op` parameter is `[ValidateSet('Lookup')]`) and
   exposes no "parsed spine field" operation, so there is no lawful shim-side
   path to derive `slice_comment_id`.

4. On generated_at mismatch, respect the F2.2 hash-elision filter before
   declaring staleness. If the lookup result is `stale-spine`, stop specialist
   work and return control to Conductor for re-dispatch with a fresh spine.

## Exit Codes and Status Values

Always parse the JSON `status` field to determine the lookup outcome. Do not
branch on exit code alone — `stale-spine` exits 0, not 1.

| Status          | Exit code | Meaning                                                       |
| --------------- | --------- | ------------------------------------------------------------- |
| `ok`            | 0         | Slice retrieved successfully; `slice` field contains content. |
| `stale-spine`   | 0         | Dispatched spine is no longer current; return to Conductor.   |
| `missing-spine` | 1         | Comment body contains no `<!-- frame-spine -->` block.        |
| `invalid-spine` | 1         | Spine block is present but malformed (parse error).           |
| `missing-slice` | 1         | Spine is valid but the requested step id was not found.       |
| `error`         | 1         | Unexpected error; `message` field contains the reason.        |

Wrapper-level error codes (when the outer process fails before the script
can run) are surfaced by the platform shim — see `platforms/copilot.md` and
`platforms/claude.md` for `gh-not-installed`, `gh-auth-expired`,
`pwsh-not-found`, and `sibling-identity-mismatch` error handling. The last is
a shim-level check (see Operational Contract step 1) — it never reaches
`frame-spine-core.ps1`, so it is not one of the core `status` values above.

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
`web` grants — no `execute/*`. Copilot spine lookup for Research-Agent is deferred to
[#544](https://github.com/Grimblaz/agent-orchestra/issues/544).

Do not edit specialist shells for this contract unless a future test proves the grants drifted.

## Non-Goals and Deferred Work

- Copilot parity shims for spine lookup shipped in #514. Research-Agent Copilot
  spine lookup is deferred to [#544](https://github.com/Grimblaz/agent-orchestra/issues/544).
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
