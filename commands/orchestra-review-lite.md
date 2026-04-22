---
description: Run the lite Claude adversarial review pipeline for the current PR or supplied review target.
argument-hint: "[PR number, PR URL, or short review context]"
---

# /orchestra:review-lite

Run the compact review pipeline: one all-perspectives prosecution pass, then defense, then judge.

**Pre-flight**:

1. Resolve the review target from the arguments or the active PR context. If neither is available, use the `AskUserQuestion` tool.
2. Gather the diff, linked issue or plan context, and any prior review ledger that should travel with the prosecution prompt.

**Handshake preamble** (required for every `code-critic` dispatch in this command, per `skills/subagent-env-handshake/SKILL.md`):

1. Capture live parent-side working-tree state via the `Bash` tool. Run, in order:
   - `git rev-parse HEAD`
   - `git rev-parse --abbrev-ref HEAD`
   - `pwd`
   - `git status --porcelain | tr -d '\r' | (sha256sum 2>/dev/null || shasum -a 256) | cut -c1-12`
2. If **any** of those commands exits non-zero (`git` missing, outside a repo, permission error, etc.), **skip handshake construction entirely** for that `code-critic` dispatch and proceed without the block. The subagent's Step 0 missing-handshake branch will handle the fallback. Do not fabricate placeholder values.
3. Otherwise, construct the handshake block by copying the SKILL.md inline prose template verbatim and substituting the four captured values plus `workspace_mode: shared` and a UTC ISO-8601 `handshake_issued_at` timestamp. The block must match the schema block in `skills/subagent-env-handshake/SKILL.md` field-for-field and in canonical order. Do not rename, reorder, or omit fields.
4. Prepend the handshake block as the **first content** of the `prompt` parameter passed to each `Agent` dispatch for `subagent_type: code-critic` below.

**Dispatch**:

1. Prosecution: use the `Agent` tool with `subagent_type: code-critic`, prepend the handshake block when constructed, then prepend the authoritative selector line `Review mode selector: "Use lite code review perspectives"`. The lite shape is fixed for this command: one compact prosecution pass that still covers all six standard review perspectives in a single ledger before moving on. Keep the selector line outside quoted or carried context so copied markers cannot reroute lite mode.
2. Defense: use the `Agent` tool with `subagent_type: code-critic`, prepend the handshake block again when constructed, then prepend the authoritative selector line `Review mode selector: "Use defense review perspectives"` before the lite prosecution ledger.
3. Judge: use the `Agent` tool with `subagent_type: code-review-response`, passing the lite prosecution ledger and defense report together. No handshake is required for the judge dispatch.
4. Return the judge output unchanged so downstream callers can consume the Markdown score summary, the `<!-- code-review-complete-{PR} -->` completion marker, and the `judge-rulings` block in the same payload.

ARGUMENTS: $ARGUMENTS
