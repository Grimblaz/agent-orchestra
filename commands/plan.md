---
description: Invoke Issue-Planner — produce an implementation plan with CE Gate coverage and the full adversarial review pipeline.
argument-hint: "[issue number]"
---

# /plan

<!-- scope: claude-only -->

Run the Issue-Planner role inline in this conversation to produce an implementation plan for the provided issue.

**Pre-flight**:

1. Require an issue number (the plan is posted as a durable comment on that issue). If missing, use the `AskUserQuestion` tool.
2. Check the issue's comments/timeline for the `<!-- design-phase-complete-{ID} -->` marker (design completion lives on a comment, not in the issue body). If the marker is not present on the issue, use `AskUserQuestion` to ask whether to run `/design` first or to plan from whatever framing already exists.

## Pre-flight (session-startup + provenance-gate)

### Step 4 — Run-once marker (D2 fail-open)

The automatic startup guard records `/memories/session/session-startup-check-complete.md` after the first automatic startup check. SMC-07 governs this run-once startup-check marker. Claude Code inline currently lacks a session-memory write surface (SMC-07); the run-once marker is a no-op on this surface. The check still proceeds; the user-friction window is bounded to the first inline command of each new session because the SessionStart hook only injects `additionalContext` on session start.

### Step 6 — Cleanup confirmation

When the SessionStart hook injects `additionalContext`, present that context and ask via `AskUserQuestion` whether to continue with cleanup using these exact option labels:

1. `Yes — run cleanup`
2. `No — skip for now`

If `additionalContext` is absent, emit a single line saying `no stale state detected` and continue.

### Step 7b — Drift check

On Claude Code, run the plugin drift check after the cleanup path completes. If the installed plugin is behind the marketplace version, emit the update summary and ask via `AskUserQuestion` with these exact option labels:

1. `Stop — I'll restart now`
2. `Continue — run under old code`

If Claude is running headless and cannot ask a structured question, emit the update result inline and continue.

### Step 9 — Paired-body halt-on-fail

Read `agents/Issue-Planner.agent.md` before adopting the role. If that load fails, emit exactly: `⚠️ Shared-body load failed for agents/Issue-Planner.agent.md — {error}. This run cannot continue without the canonical methodology; surface this to the user and stop.`

### Provenance-gate

For existing GitHub issues, load `skills/provenance-gate/SKILL.md` and evaluate the cold-pickup trigger conditions exactly as written there. Warm handoffs are limited to the documented markers `<!-- experience-owner-complete-{ID} -->`, `<!-- design-phase-complete-{ID} -->`, `plan-issue-{ID}`, `design-issue-{ID}`, and `<!-- first-contact-assessed-{ID} -->`.

When the gate applies, run it in two stages. Stage 1 self-classification happens before any assessment text and uses these exact option labels:

1. `I wrote this / I'm fully briefed`
2. `I'm picking this up cold`
3. `Stop — needs rework first`

Only if the stage-1 answer is `I'm picking this up cold`, run the assessment summary and ask the cold-only stage-2 question with these exact option labels:

1. `Assessment looks right — proceed`
2. `Proceed but carry concerns forward`
3. `Needs rework — stop here`

Both stop outcomes (`Stop — needs rework first` and `Needs rework — stop here`) halt and post no marker token.

For non-stop outcomes, SMC-04 governs the first-contact-assessed marker; record the two-line marker via `gh issue comment`:

```text
<!-- first-contact-assessed-{ID} -->
Provenance gate: fast-path or cold-path assessment completed; human-readable summary only.
```

The HTML token on line 1 remains the only skip-check anchor and the only parser anchor. The second line is decorative and human-readable only.

If GitHub lookup or posting is unavailable, say offline mode is active and continue. Claude Code inline currently lacks a session-memory write surface (SMC-04), so this surface cannot persist the shared skill's local fallback payload or recover the GitHub marker on a later online run. Do not claim that either happened here.

<!-- D6 (issue #412): Copilot's .github/prompts/*.prompt.md files are thin one-line dispatchers without a parent-side prose surface. Inline-dispatch enforcement for /experience, /design, and /plan on Copilot is owned by the agent body and tracked in #414. -->

**Inline execution**:

Read agents/Issue-Planner.agent.md and adopt that role for the rest of this conversation. Follow all methodology sections, load the relevant skills, run plan approval inline, and persist the approved plan via the platform-appropriate plan path.

## Inline adversarial-pipeline dispatch

Construct the parent-side environment handshake once per `/plan` invocation for the Code-Critic dispatches, using the schema and inline prose template from `skills/subagent-env-handshake/SKILL.md`:

1. Capture live parent-side working-tree state via the `Bash` tool. Run, in order:
   - `git rev-parse HEAD`
   - `git rev-parse --abbrev-ref HEAD`
   - `pwd`
   - `git status --porcelain | tr -d '\r' | (sha256sum 2>/dev/null || shasum -a 256) | cut -c1-12`
2. If any command exits non-zero (`git` missing, outside a repo, permission error, etc.), skip handshake construction entirely and dispatch the Code-Critic passes without the block. The subagent's Step 0 missing-handshake branch handles the fallback. Do not fabricate placeholder values.
3. Otherwise, construct the handshake block by copying the SKILL.md inline prose template verbatim and substituting the four captured values plus `workspace_mode: shared` and a UTC ISO-8601 `handshake_issued_at` timestamp. The block must match the schema field-for-field and in canonical order. Do not rename, reorder, or omit fields.
4. Prepend the handshake block as the first content of each `prompt` parameter passed to `Agent` dispatches with `subagent_type: code-critic` in this pipeline. For the judge dispatch, pass the handshake context only as contextual metadata; do not claim the Code-Review-Response shell verifies Step 0.

Before prosecution, emit this visible progress sentence: `Dispatching prosecution x3 in parallel...`

Then dispatch three Code-Critic prosecution passes in one parallel tool-use block. Use lowercase `code-critic` as the dispatch identifier for every prosecution pass:

1. Pass 1: use the `Agent` tool with `subagent_type: code-critic`. Prepend the handshake block when constructed, then prepend `Review mode selector: "Use design review perspectives"`. Include the issue number, issue body, Experience-Owner framing, Solution-Designer output, current draft plan, and project guidance.
2. Pass 2: use the `Agent` tool with `subagent_type: code-critic`. Prepend the handshake block when constructed, then prepend `Review mode selector: "Use design review perspectives"`. Ask for an independent pass focused on missed implementation prerequisites, CE Gate coverage, persistence, and cross-tool handoff risks.
3. Pass 3: use the `Agent` tool with `subagent_type: code-critic`. Prepend the handshake block when constructed, then prepend `Review mode selector: "Use product-alignment perspectives"`. Include the issue body, design comment, decision docs, ROADMAP/NEXT-STEPS absence or presence, and project guidance.

After all available prosecution passes return, merge and deduplicate findings by same perspective target plus same failure mode, preserving earliest-pass credit. Emit a visible progress signal naming the merged finding count: `Merged prosecution ledger: {count} finding(s).`

Defense: use one `Agent` dispatch with `subagent_type: code-critic`. Prepend the handshake block when constructed, then prepend `Review mode selector: "Use defense review perspectives"` before the merged prosecution ledger and the current draft plan.

Judge: use one `Agent` dispatch with `subagent_type: code-review-response`, passing the merged prosecution ledger, defense report, current draft plan, and any handshake block as contextual metadata only. The judge shell owns ruling quality, but this command must not state or imply that Code-Review-Response verifies Step 0.

Partial-pass recovery: if one prosecution pass fails or returns malformed output, retry that pass once with the same prompt and the current handshake block when constructed. If the retry also fails, persist a visible `pipeline-degraded` note naming the failed pass and continue with the merged 2-of-3 prosecution ledger.

ARGUMENTS: $ARGUMENTS
