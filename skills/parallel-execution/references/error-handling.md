# Parallel Execution Error Handling Reference

This reference owns the reusable error-handling and terminal guardrails extracted from Code-Conductor for the parallel-execution composite.

See [../SKILL.md](../SKILL.md) for the execution-mode contract, Requirement Contract, convergence gate, and triage-routing flow this reference supports.

## Subagent Call Resilience (R5)

When a subagent call fails or returns no output, classify the failure before routing:

**Rate-limit detection (heuristic)**: A call is presumed rate-limited when: the subagent returns no output or an empty response, the error message contains terms such as `rate limit`, `throttle`, `capacity`, `quota`, or `too many requests`, or when the same subagent call fails twice in succession without a clear tool-error cause.

**Non-rate-limit errors** (parse failures, tool-specific errors, environment issues) route to `## Error Handling`, not backoff.

**Backoff protocol (R5)** (rate-limit failures only):

1. Wait `2^attempt × 30s` before retrying (attempt 1 = 60s, attempt 2 = 120s).
2. On Sonnet-class model failure: before entering backoff, consider switching to an Opus-class model - Sonnet and Opus have separate per-model TPM limits, so Opus may still be available when Sonnet is throttled.
3. After **2 consecutive retry failures** for the same call (3 total attempts in the timeout-failure path; the rate-limit-heuristic detection path described above may trigger a prompt after 2 attempts when the initial call + 1 retry both return empty output): prompt via the platform's structured-question tool with:
   - Option A: "Defer remaining work - {N} findings pending (resume next session from current phase)" _(recommended)_
   - Option B: "Skip remaining low-severity findings and continue" - only available when all pending findings are `low` severity; Critical/High/Medium findings cannot be skipped.

   If the user selects Option A (or only Option A is presented because Option B's condition is not met):
   - Save pending work state to session memory - record the deferred findings, the interrupted step, and the resume point.
   - Emit: `⚠️ Rate limit: deferring remaining work - {N} findings pending. Resume from the current phase using session memory as ground truth for deferred state.`
   - Do NOT silently drop deferred findings. They must be re-processed in the next session.

   If the user selects Option B:
   - Skip remaining low-severity findings, log them to session memory as intentionally skipped, and continue.

**Applies to**: ALL subagent calls (Code-Smith, Test-Writer, Code-Critic, Code-Review-Response, Refactor-Specialist, Doc-Keeper, Experience-Owner, and any other specialist).

## Error Handling

**Common Issues**:

0. **No plan exists** -> Escalate via the platform's structured-question tool to request a plan path/options (with a recommended option)
1. **Specialist returns incomplete work** -> Diagnose what was unclear in your instructions. Retry with more specific guidance that addresses the gap - don't just re-submit the same prompt.
2. **Tests fail after implementation** -> Investigate the failure pattern before delegating. Call Test-Writer with your diagnosis, not just "fix it."
3. **Architecture violations detected** -> Call Refactor-Specialist with the specific violation and the project architecture rule being broken (see `.github/architecture-rules.md`).
4. **Plan doesn't match reality** -> Adapt the plan. If the deviation is minor (renamed file, moved interface), adjust and proceed. If fundamental (design assumption invalid), escalate to user with analysis and a recommendation.

**When to Escalate** - always via the platform's structured-question tool with structured options:

- **Design decision required** -> Present options with pros/cons in conversation, then use the platform's structured-question tool with the options and your recommended choice
- **Persistent failures** (max 2 retries per phase) -> Explain what you tried and your diagnosis, then ask: "Retry with [approach]", "Skip this step", "Abort and investigate manually"
- **Blocking dependencies** -> Identify what's blocking, then ask: "Proceed with [workaround]", "Wait for [dependency]", "Restructure approach to [alternative]"
- **Quality gates not met** -> Show which gate failed and the delta, then ask: "Accept and proceed (if marginal)", "Fix [specific issue]", "Defer to separate PR"
- **Parallel loop thrashing** (more than 3 cycles) -> Present failure taxonomy + recommended next move: "Re-scope contract", "Fix tests first", "Fix implementation first", "Pause and investigate"

### Terminal Non-Interactive Guardrails (Mandatory)

All terminal execution must be non-interactive and automation-safe:

- Prefer explicit non-interactive flags (for example: `--yes`, `--ci`, `--no-watch`) when available.
- Avoid commands that open prompts, pagers, editors, watch loops, or interactive REPL sessions unless the step explicitly requires long-running background execution.
- For long-running/background tasks, state startup criteria and verification checks, and avoid blocking orchestration flow.
- On command failure, capture stderr/stdout evidence and route via failure triage instead of re-running blindly.
- If a command is known to be interactive-only, escalate with the platform's structured-question tool and provide non-interactive alternatives when possible.

### Terminal Lifecycle Protocol

Background terminals spawned through the platform's async/background terminal surface persist indefinitely. In long sessions, dozens of idle shells accumulate and - at scale (~30+) - enter CPU-spin states that degrade the developer's workstation. This protocol prevents accumulation.

**Tracking**: Track terminal IDs returned by your own async/background terminal calls in conversation context. No persistent file needed. On context compaction, tracked IDs are lost; per-step cleanup prevents dangerous buildup, and new terminals after compaction are re-tracked.

**Cleanup triggers** (3-tier):

1. **Post-step**: After each plan step's validation passes and before marking `✅ DONE`, sweep tracked terminal IDs.
2. **Phase-boundary**: After all implementation steps complete, before entering the review cycle.
3. **Post-PR**: After PR creation, before user handoff.

**Completion check before kill**:

1. Call the platform's terminal-output inspection tool for the tracked terminal ID.
2. Output ends with a PowerShell prompt (`PS ...>`) -> **confirmed completed** -> safe to `kill_terminal`.
3. Output shows ongoing activity (no PS prompt at end) -> **active** -> preserve.
4. Output is empty, unclear, or terminal-output inspection fails -> **unknown** -> preserve.

> **Note**: if terminal termination is a deferred or optional platform capability, load or enable it before first use in a session. When the termination tool is unavailable (version regression or restricted tool surface), the protocol degrades gracefully to **preserve-all** - all terminals are preserved regardless of completion status. The completion-check logic above is retained so the protocol can be re-activated when terminal termination becomes available.

Only kill terminals with **confirmed completion**. All other states -> preserve. When terminal termination is unavailable, log the preserve-all degradation and continue.

**Error tolerance**: All terminal-termination calls are non-fatal. If a kill fails (terminal already gone, invalid ID, API error), log the failure and continue. Cleanup must never block orchestration flow.

**Logging**: After each sweep, log: `"Terminal cleanup: killed N completed, preserved M active, K unknown/already-gone"`.

**Scope boundaries**:

- Only terminals CC created via the platform's async/background execution path are tracked and eligible for cleanup.
- Cross-window safety is inherent - VS Code terminal IDs are window-scoped.
- Subagent terminals are not tracked (subagents follow `isBackground: false` preference).
