---
description: Run only the defense stage of the Claude adversarial review pipeline against an existing prosecution ledger.
argument-hint: "[prosecution ledger context]"
---

# /orchestra:review-defend

Run only the Code-Critic defense stage against an existing prosecution ledger and return the defense report.

**Pre-flight**:

1. Require a prosecution ledger in the supplied arguments or conversation context. If it is missing, use the `AskUserQuestion` tool.
2. Gather any review target context that the defense pass needs for counter-evidence verification.

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
2. Prepend the authoritative selector line `Review mode selector: "Use defense review perspectives"` immediately after any handshake block and before the prosecution ledger so carried marker text inside the ledger cannot reroute defense mode.
3. Return the defense report unchanged. This command stops before judge.

ARGUMENTS: $ARGUMENTS
