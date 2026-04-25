---
description: Run only the prosecution stage of the Claude adversarial review pipeline and return the prosecution ledger.
argument-hint: "[PR number, PR URL, or short review context]"
---

# /orchestra:review-prosecute

Run only the Code-Critic prosecution stage and return the resulting prosecution ledger for later defense or judge reruns.

**Pre-flight**:

1. Resolve the review target from the arguments or the active PR context. If neither is available, use the `AskUserQuestion` tool.
2. Gather the diff, linked issue or plan context, and any prior review notes that should travel with the prosecution prompt.

**Review-state persistence**:

1. If the active branch matches `feature/issue-{N}-...`, target `/memories/session/review-state-{N}.md`; otherwise skip persistence silently.
2. Read any existing state through `skills/routing-tables/scripts/review-state-reader.ps1`. If the file is absent or malformed, fail closed and start from the default contract (`review_mode: full`, all stage booleans `false`).
3. After prosecution completes, write the same atomic front matter contract with only `prosecution_complete: true` forced in this command, preserve any readable stored values for the other fields, and update `last_updated`.
4. Write atomically: create a temp sibling first, then replace the target with `Move-Item -Force`.

**Handshake preamble** (required for this `code-critic` dispatch, per `skills/subagent-env-handshake/SKILL.md`):

1. Capture live parent-side working-tree state via the `Bash` tool. Run, in order:
   - `git rev-parse HEAD`
   - `git rev-parse --abbrev-ref HEAD`
   - `pwd`
   - `git status --porcelain | tr -d '\r' | (sha256sum 2>/dev/null || shasum -a 256) | cut -c1-12`
2. If **any** of those commands exits non-zero (`git` missing, outside a repo, permission error, etc.), **skip handshake construction entirely** and proceed without the block. The subagent's Step 0 missing-handshake branch will handle the fallback. Do not fabricate placeholder values.
3. Otherwise, construct the handshake block by copying the SKILL.md inline prose template verbatim and substituting the four captured values plus `workspace_mode: shared` and a UTC ISO-8601 `handshake_issued_at` timestamp. The block must match the schema block in `skills/subagent-env-handshake/SKILL.md` field-for-field and in canonical order. Do not rename, reorder, or omit fields.
4. Prepend the handshake block as the **first content** of the `prompt` parameter passed to the `Agent` dispatch below.

**Dispatch**:

1. Use the `Agent` tool with `subagent_type: code-critic`.
2. Prepend the authoritative selector line `Review mode selector: "Use code review perspectives"` immediately after any handshake block and before any carried review context so the prosecution stays in canonical code-review mode even if the supplied context also mentions other markers.
3. Return the prosecution ledger unchanged. This command stops before defense and judge.

ARGUMENTS: $ARGUMENTS
