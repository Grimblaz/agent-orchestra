---
description: "Invoke Code-Conductor — run the full orchestration pipeline for one or more GitHub issues: scope classification, smart resume, D9 checkpoint, implementation, review, PR."
argument-hint: "Single issue (e.g. issue #177) or multiple issues (e.g. issues #177 #178 #179)"
---

# /orchestrate

<!-- scope: claude-only -->

Dispatch the `code-conductor` subagent to orchestrate one issue or a coordinated issue bundle.

In Claude Code, `/orchestrate` is also the resume entry point for paused Code-Conductor work. When the shared workflow text mentions resuming with `/implement`, use `/orchestrate` here instead.

**Pre-flight**:

1. Resolve the issue context from the arguments. Accept a single issue number, an issue URL, or a multi-issue bundle. If the arguments do not identify at least one issue, use the `AskUserQuestion` tool.
2. For each resolved issue, check the issue's comments/timeline for the smart-resume markers `<!-- plan-issue-{ID} -->`, `<!-- design-issue-{ID} -->`, `<!-- design-phase-complete-{ID} -->`, and `<!-- experience-owner-complete-{ID} -->`; SMC-08 governs these durable phase-completion markers.
3. If any resolved issue is missing its `<!-- plan-issue-{ID} -->` marker, do not block dispatch. Carry the resolved issue list and marker status into the dispatch prompt so Code-Conductor can either resume from the most advanced durable artifact available or continue fresh hub-mode execution and call Issue-Planner itself. SMC-01 governs the plan-marker resume path, and SMC-03 governs the design fallback chain: parent dispatch context when available, latest durable `<!-- design-issue-{ID} -->` issue comment, then issue body. Include whether a durable `<!-- design-issue-{ID} -->` handoff already exists for D9 suppression and full-pipeline resume.

**Handshake preamble** (per `skills/subagent-env-handshake/SKILL.md` — the `code-conductor` subagent is tree-dependent and may make tree-grounded claims):

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

- `subagent_type: code-conductor`
- `description`: one short phrase describing the orchestration task
- `prompt`: the handshake block (when constructed) followed by the resolved issue or bundle context plus the smart-resume marker status

The subagent will read `agents/code-conductor.md` for its Claude shell, follow the shared Code-Conductor methodology, and own the orchestration flow for the provided issue set.

ARGUMENTS: $ARGUMENTS
