---
description: Invoke Issue-Planner — produce an implementation plan with CE Gate coverage and the full adversarial review pipeline.
argument-hint: "[issue number]"
---

# /plan

> Auto-mode boundary: see [CLAUDE.md § Auto-mode boundary](/CLAUDE.md#auto-mode-boundary). Auto-mode does not suppress `AskUserQuestion`.

<!-- scope: claude-only -->

Run the Issue-Planner role inline in this conversation to produce an implementation plan for the provided issue.

**Pre-flight**:

1. Require an issue number (the plan is posted as a durable comment on that issue). If missing, use the `AskUserQuestion` tool.
2. Check the issue's comments/timeline for the `<!-- design-phase-complete-{ID} -->` marker (design completion lives on a comment, not in the issue body). If the marker is not present on the issue, use `AskUserQuestion` to ask whether to run `/design` first or to plan from whatever framing already exists.

## Pre-flight (session-startup)

Load `skills/session-startup/SKILL.md` and follow Steps 4, 6, 7b, and 9 (paired body for Step 9: `agents/Issue-Planner.agent.md`).

### Step 9 — Paired-body halt-on-fail

Resolve and read `agents/Issue-Planner.agent.md` before adopting the role. Use the D1 plugin-cache-first body resolution sequence: first read `~/.claude/plugins/installed_plugins.json` and use the `installPath` for `agent-orchestra@agent-orchestra` to load `agents/Issue-Planner.agent.md`; if that registry entry is missing or unusable, fall back to the newest SemVer-sorted match for `~/.claude/plugins/cache/agent-orchestra/agent-orchestra/*/agents/Issue-Planner.agent.md`; only after those plugin-cache paths fail, allow a source-repo CWD read of `agents/Issue-Planner.agent.md` when `.claude-plugin/plugin.json` exists in the current repo and declares `name: agent-orchestra`. If every candidate load fails, emit exactly: `⚠️ Shared-body load failed for agents/Issue-Planner.agent.md — {error}. This run cannot continue without the canonical methodology; surface this to the user and stop.` The remediation command is `claude plugin install agent-orchestra@agent-orchestra`.

<!-- D6 (issue #412): Copilot's .github/prompts/*.prompt.md files are thin one-line dispatchers without a parent-side prose surface. Inline-dispatch enforcement for /experience, /design, and /plan on Copilot is owned by the agent body and tracked in #414. -->

**Inline execution**:

Use the resolved `agents/Issue-Planner.agent.md` shared body and adopt that role for the rest of this conversation. Follow all methodology sections, load the relevant skills, run plan approval inline, and persist the approved plan via the platform-appropriate plan path.

## Inline adversarial-pipeline dispatch

For every Code-Critic `Agent` dispatch in this pipeline, construct a fresh parent-side environment handshake immediately before that dispatch using the schema and inline prose template from `skills/subagent-env-handshake/SKILL.md`:

1. Immediately before each Code-Critic prosecution, defense, or retry dispatch, capture live parent-side working-tree state via the `Bash` tool. Run, in order:
   - `git rev-parse HEAD`
   - `git rev-parse --abbrev-ref HEAD`
   - `pwd`
   - `git status --porcelain | tr -d '\r' | (sha256sum 2>/dev/null || shasum -a 256) | cut -c1-12`
2. If any command exits non-zero (`git` missing, outside a repo, permission error, etc.), skip handshake construction for that dispatch and send the Code-Critic prompt without the block. The subagent's Step 0 missing-handshake branch handles the fallback. Do not fabricate placeholder values.
3. Otherwise, construct a fresh handshake block by copying the SKILL.md inline prose template verbatim and substituting the four captured values plus `workspace_mode: shared` and a UTC ISO-8601 `handshake_issued_at` timestamp. The block must match the schema field-for-field and in canonical order. Do not rename, reorder, or omit fields.
4. Prepend that fresh handshake block as the first content of the `prompt` parameter for the current `Agent` dispatch with `subagent_type: code-critic`. Do not reuse or carry forward a single, once-per-invocation, command-entry, entry-time, or earlier handshake across prosecution, defense, or judge dispatches.
5. Before the Code-Review-Response judge dispatch, live-recapture the same four parent-side values immediately before dispatch and pass them as contextual metadata only. Do not prepend a Step 0 verification handshake block, and do not claim Code-Review-Response verifies Step 0 unless that shell gains Step 0 environment handshake verification in a separate issue.

Before prosecution, emit this visible progress sentence: `Dispatching prosecution x3 in parallel...`

**Parallel-batch handshake policy** (per `skills/subagent-env-handshake/SKILL.md` "Parallel-batch dispatch" section): live-recapture HEAD, branch, CWD, and dirty fingerprint **once via a single `Bash` invocation in this same turn, immediately before emitting the parallel tool-use block**. Then construct three handshake blocks from those captured values, each with its own UTC ISO-8601 `handshake_issued_at` timestamp and otherwise field-identical content. This satisfies "fresh handshake per dispatch" because no tree mutation can occur between the parallel-block members — they fire as one batch with no interleaved tool calls. Do not reuse a capture from a prior turn or from a sequential earlier dispatch; the capture must be the most recent state before this parallel block.

Per `skills/subagent-env-handshake/SKILL.md` § Subagent working-tree discipline: under `workspace_mode: shared`, you MUST NOT write to the working tree of this repository during analysis. Reads are permitted; scratch space goes outside the repo root (`mktemp -d` on POSIX, `$env:TEMP/$(New-Guid)` on Windows; no `Bash` redirects into the repo).

Then dispatch three Code-Critic prosecution passes in one parallel tool-use block. Use lowercase `code-critic` as the dispatch identifier for every prosecution pass:

1. Pass 1: use the `Agent` tool with `subagent_type: code-critic`. Prepend the fresh handshake block constructed for this pass from the parallel-batch capture above, then prepend `Review mode selector: "Use design review perspectives"`. Include the issue number, issue body, Experience-Owner framing, Solution-Designer output, current draft plan, and project guidance.
2. Pass 2: use the `Agent` tool with `subagent_type: code-critic`. Prepend the fresh handshake block constructed for this pass from the parallel-batch capture above, then prepend `Review mode selector: "Use design review perspectives"`. Ask for an independent pass focused on missed implementation prerequisites, CE Gate coverage, persistence, and cross-tool handoff risks.
3. Pass 3: use the `Agent` tool with `subagent_type: code-critic`. Prepend the fresh handshake block constructed for this pass from the parallel-batch capture above, then prepend `Review mode selector: "Use product-alignment perspectives"`. Include the issue body, design comment, decision docs, ROADMAP/NEXT-STEPS absence or presence, and project guidance.

After all available prosecution passes return, merge and deduplicate findings by same perspective target plus same failure mode, preserving earliest-pass credit. Emit a visible progress signal naming the merged finding count: `Merged prosecution ledger: {count} finding(s).`

Defense: use one `Agent` dispatch with `subagent_type: code-critic`. Immediately before this dispatch, recapture live state and prepend the fresh handshake block when constructed, then prepend `Review mode selector: "Use defense review perspectives"` before the merged prosecution ledger and the current draft plan.

Judge: use one `Agent` dispatch with `subagent_type: code-review-response`, passing the merged prosecution ledger, defense report, current draft plan, and freshly captured handshake context as contextual metadata only. The judge shell owns ruling quality, but this command must not state or imply that Code-Review-Response verifies Step 0 unless that shell gains Step 0 environment handshake verification in a separate issue.

Partial-pass recovery: this recovery applies only to the redundant three Code-Critic prosecution passes. If one redundant Code-Critic prosecution pass has a body-load failure, cannot load the shared body, or returns malformed output, retry that pass once with the same substantive prompt and a newly recaptured fresh handshake block when constructed for the retry dispatch. If the retry also fails, persist a visible `pipeline-degraded` note naming the failed pass and continue only with the merged 2-of-3 prosecution ledger. Defense and judge are singleton paths: if the Code-Critic defense body-load fails, or if the Code-Review-Response judge body-load fails, halt-strict and stop; do not continue and do not use `pipeline-degraded` or 2-of-3 recovery for those singleton failures.

ARGUMENTS: $ARGUMENTS
