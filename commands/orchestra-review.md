---
description: Run the standard Claude adversarial review pipeline for the current PR or supplied review target.
argument-hint: "[PR number, PR URL, or short review context]"
---

# /orchestra:review

Run the standard review pipeline: Code-Critic prosecution -> Code-Critic defense -> Code-Review-Response judge.

**Pre-flight**:

1. Resolve the review target from the arguments or the active PR context. If neither is available, use the `AskUserQuestion` tool.
2. Gather the diff, linked issue or plan context, and any prior review ledger that should travel with the prosecution prompt.

**Review-state persistence**:

1. If the active branch matches `feature/issue-{N}-...`, target `/memories/session/review-state-{N}.md`; otherwise skip persistence silently.
2. After the judge stage completes, write the exact front matter contract from `skills/validation-methodology/references/review-state-persistence.md` with `review_mode: full`, all three `*_complete` fields set to `true`, and `last_updated` as a UTC ISO-8601 timestamp.
3. Write atomically: create a temp sibling first, then replace the target with `Move-Item -Force`.

**Handshake preamble** (required for every `code-critic` dispatch in this command, per `skills/subagent-env-handshake/SKILL.md`):

1. Immediately before each Code-Critic prosecution, defense, or retry dispatch, recapture HEAD, branch, CWD, and dirty fingerprint live via the `Bash` tool. Run, in order:
   - `git rev-parse HEAD`
   - `git rev-parse --abbrev-ref HEAD`
   - `pwd`
   - `git status --porcelain | tr -d '\r' | (sha256sum 2>/dev/null || shasum -a 256) | cut -c1-12`
2. If **any** of those commands exits non-zero (`git` missing, outside a repo, permission error, etc.), **skip handshake construction entirely** for that `code-critic` dispatch and proceed without the block. The subagent's Step 0 missing-handshake branch will handle the fallback. Do not fabricate placeholder values.
3. Otherwise, construct the handshake block by copying the SKILL.md inline prose template verbatim and substituting the four captured values plus `workspace_mode: shared` and a UTC ISO-8601 `handshake_issued_at` timestamp. The block must match the schema block in `skills/subagent-env-handshake/SKILL.md` field-for-field and in canonical order. Do not rename, reorder, or omit fields.
4. Prepend the handshake block as the **first content** of the `prompt` parameter passed to the current `Agent` dispatch for `subagent_type: code-critic` below. The block is fresh for the current dispatch; do not reuse an earlier handshake block across Code-Critic dispatches.

**Dispatch**:

Per `skills/subagent-env-handshake/SKILL.md` § Subagent working-tree discipline: under `workspace_mode: shared`, you MUST NOT write to the working tree of this repository during analysis. Reads are permitted; scratch space goes outside the repo root (`mktemp -d` on POSIX, `$env:TEMP/$(New-Guid)` on Windows; no `Bash` redirects into the repo).

1. Prosecution: emit the visible progress sentence `Dispatching prosecution x3 in parallel...`, then dispatch three redundant Code-Critic prosecution passes with the `Agent` tool and `subagent_type: code-critic` **in one parallel tool-use block**. Apply the parallel-batch handshake policy from `skills/subagent-env-handshake/SKILL.md` "Parallel-batch dispatch" section: live-recapture HEAD, branch, CWD, and dirty fingerprint **once via a single `Bash` invocation in this same turn, immediately before emitting the parallel block**, then construct three handshake blocks from those captured values, each with its own UTC ISO-8601 `handshake_issued_at` timestamp. For each pass, do **not** add a review-mode marker inside carried review context. No marker selects the canonical default `code_prosecution` route when it appears only inside quoted or carried material. Instead, prepend the authoritative selector line `Review mode selector: "Use code review perspectives"` immediately after the handshake block, then include a short review description and the resolved review target context. Keep that selector line outside quoted or carried context so the standard command cannot be rerouted by marker text inside pasted ledgers or comments.
2. Merge and deduplicate: after all available prosecution passes return, merge findings by same perspective target plus same failure mode, preserving earliest-pass credit. Emit a visible progress signal naming the merged finding count: `Merged prosecution ledger: {count} finding(s).`
3. Defense: use the `Agent` tool with `subagent_type: code-critic`. Immediately before the Code-Critic defense dispatch, recapture and prepend a fresh handshake block when constructed, then prepend the authoritative selector line `Review mode selector: "Use defense review perspectives"` before the merged prosecution ledger.
4. Judge: use the `Agent` tool with `subagent_type: code-review-response`, passing the merged prosecution ledger and defense report together. No handshake is required for the judge dispatch.
5. Return the judge output unchanged so downstream callers can consume the Markdown score summary and the `judge-rulings` block in the same payload.

**Body-load failure policy**:

The full-review prosecution route uses three redundant Code-Critic prosecution passes. If one redundant Code-Critic prosecution pass has a body-load failure, cannot load the shared body, returns malformed output, or encounters an ND-2 environment-divergence, retry that pass once with the same substantive prompt and a newly recaptured fresh handshake block when constructed for the retry dispatch. ND-2 halts arising from sibling-subagent tree mutation under `workspace_mode: shared` are a documented recovery path declared in `skills/subagent-env-handshake/SKILL.md` § Subagent working-tree discipline, not a contract violation. If the retry is exhausted, represent that pass as `pipeline-degraded`, name the failed pass visibly, and continue only when enough valid passes remain to form a 2-of-3 merged prosecution ledger. Do not silently proceed as if all three passes succeeded.

This degraded recovery applies only to redundant full-review prosecution body-load or malformed-pass failures. Defense and judge are singleton stages: if the Code-Critic defense body-load fails, or if the Code-Review-Response judge body-load fails, halt-strict and stop; do not continue, and do not use `pipeline-degraded` or 2-of-3 recovery for defense or judge.

ARGUMENTS: $ARGUMENTS
