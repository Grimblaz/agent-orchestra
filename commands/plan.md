---
description: Invoke Issue-Planner — produce an implementation plan with CE Gate coverage and the full adversarial review pipeline.
argument-hint: "[issue number]"
---

# /plan

<!-- scope: claude-only -->

Dispatch the `issue-planner` subagent to produce an implementation plan for the provided issue.

**Pre-flight**:

1. Require an issue number (the plan is posted as a durable comment on that issue). If missing, use the `AskUserQuestion` tool.
2. Check the issue's comments/timeline for the `<!-- design-phase-complete-{ID} -->` marker (design completion lives on a comment, not in the issue body). If the marker is not present on the issue, use `AskUserQuestion` to ask whether to run `/design` first or to plan from whatever framing already exists.

**Handshake preamble** (per `skills/subagent-env-handshake/SKILL.md` — the `issue-planner` subagent is tree-dependent and may make tree-grounded claims):

1. Capture live parent-side working-tree state via the `Bash` tool. Run, in order:
   - `git rev-parse HEAD`
   - `git rev-parse --abbrev-ref HEAD`
   - `pwd`
   - `git status --porcelain | tr -d '\r' | (sha256sum 2>/dev/null || shasum -a 256) | cut -c1-12` (LF-normalized SHA-256:12)
2. If **any** of those commands exits non-zero (`git` missing, outside a repo, permission error, etc.), **skip handshake construction entirely** and proceed straight to dispatch without the block. The subagent's Step 0 missing-handshake branch will handle the fallback (tag tree-grounded findings `environment-unverified`). Do not fabricate placeholder values.
3. Otherwise, construct the handshake block by copying the SKILL.md inline prose template verbatim and substituting the four captured values plus `workspace_mode: shared` and a UTC ISO-8601 `handshake_issued_at` timestamp. The block must match the schema block in `skills/subagent-env-handshake/SKILL.md` field-for-field and in canonical order. Do not rename, reorder, or omit fields.
4. Prepend the handshake block as the **first content** of the `prompt` parameter passed to the `Agent` tool in the dispatch step below. Issue context / instructions follow the `<!-- /subagent-env-handshake -->` closing comment.

**Dispatch**:

Use the `Agent` tool with:

- `subagent_type: issue-planner`
- `description`: one short phrase describing the planning task
- `prompt`: the handshake block (when constructed) followed by the issue number plus any design/framing context

The subagent will read `agents/Issue-Planner.agent.md` for its full methodology, follow the Plan Style Guide and Plan Approval Prompt Format in `skills/plan-authoring/SKILL.md`, run the full adversarial pipeline (prosecution × 3 → defense → judge), and persist the approved plan as a GitHub issue comment with a `<!-- plan-issue-{ID} -->` marker.

Before doing any role work, the subagent's Claude shell at `agents/issue-planner.md` runs `## Step 0: Environment Handshake Verification` to parse the handshake block (if present), live-verify against its own observed state, and branch on match / mismatch / error / missing-handshake per the decision tree locked in `skills/subagent-env-handshake/SKILL.md`.

ARGUMENTS: $ARGUMENTS
