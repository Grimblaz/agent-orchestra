# Design: Step Commits

**Domain**: Validated step-level commit automation during Code-Conductor implementation
**Status**: Current
**Implemented in**: Issue #336

---

## Purpose

Step commits capture the validated state of each plan step as a discrete git commit during Code-Conductor's implementation loop. This provides:

- **Resume resilience**: Step commit history bridges session-memory / git-state gaps after compaction or session recovery (D13 reconciliation)
- **Review boundary visibility**: Each commit maps to a plan step, giving reviewers logical boundaries in the PR diff
- **Proven-good state capture**: Commits occur only after Tier 1 validation and RC conformance pass — no untested code is committed

---

## Architecture

The feature is a 3-piece design that keeps Code-Conductor's directive count stable:

| Piece | Location | Role |
|-------|----------|------|
| Opt-out detection (D12) | CC Step 1 (plan load) | Reads consumer `copilot-instructions.md` once; sets `auto_commit_enabled` flag for the session |
| Step commit gate | CC Step 3 (step loop) | Checks `auto_commit_enabled` before loading the instruction file |
| Protocol | `.github/instructions/step-commit.instructions.md` | Self-contained 7-step protocol loaded by reference (FG-D4 pattern) |

**Relationship to formatting gate**: Independent mechanisms. Step commits capture pre-formatting validated state per step; the formatting gate runs at PR creation time (CC Step 4). Step commits use `--no-verify` to bypass hooks — formatting is the hook's concern, not the step commit's.

**Relationship to diff-scoping**: Post-fix review's diff-scoping prerequisite checks that the original implementation is committed. When `auto_commit_enabled` is `true` and all step commits succeeded, this prerequisite is automatically satisfied.

**Relationship to plan storage**: Step commits preserve the plan step boundaries that session-memory plan annotations track. D13 reconciliation uses `git log --grep` to re-derive step completion state when session memory is lost.

---

## Design Decisions

| ID | Decision | Rationale |
|----|----------|-----------|
| D1 | Step commits are implementation-only (no spec/test separation) | Single commit per step keeps the model simple; per-step refactor is already folded into the step |
| D2 | Default-on with opt-out via `## Commit Policy` / `auto-commit: disabled` | Most workflows benefit; opt-out for squash-only or manual-commit teams |
| D3 | Commits happen after validation ladder + RC conformance | No untested code is committed |
| D4 | Self-contained instruction file (FG-D4 pattern) | Avoids CC directive bloat; protocol loaded by reference only when enabled |
| D5 | Detection at plan-load time; flag persists for session | Single read of consumer config; no per-step re-parsing |
| D6 | Explicit file list staging (never `git add -A`) | Prevents sweeping unrelated working-tree changes into a step commit |
| D7 | `step(N): {title}` message format with `Plan:`, `Agents:`, `Validation:` trailers | Machine-parseable for D13 reconciliation; human-readable for reviewers |
| D8 | Non-blocking failure — warn and continue | Step work is validated regardless of commit success |
| D9 | `--no-verify` bypasses hooks | Formatting gate handles formatting separately; hooks are unnecessary overhead on validated state |
| D10 | SHA recorded after commit for informational purposes | HEAD advances with each step commit; post-fix diff recipe `git diff HEAD -- {files}` remains correct |
| D11 | Resume reconciliation — git-ahead case | If `step(N)` exists in git log but session memory lacks `✅ DONE`, mark done and advance |
| D12 | Case-insensitive opt-out detection with malformed-section warnings | `^## Commit Policy` heading + `auto-commit:` line; warns if heading exists but line is absent/malformed |
| D13 | Resume reconciliation — uncommitted case | `✅ DONE (uncommitted)` steps get a retry commit on resume; if files already captured by a later commit, suffix is cleared |
| D14 | Consecutive-failure escalation at ≥2 | Single flake is silent; repeated failures prompt user to disable or investigate |

---

## Consumer Opt-Out

Add to the project's `.github/copilot-instructions.md`:

```markdown
## Commit Policy

auto-commit: disabled
```

When opted out: validation ladder, RC conformance, and progress checkpoints still run unchanged. The formatting gate at PR creation is independent and runs unconditionally.

---

## Related Files

- [.github/instructions/step-commit.instructions.md](../../.github/instructions/step-commit.instructions.md) — full protocol
- [.github/agents/Code-Conductor.agent.md](../../.github/agents/Code-Conductor.agent.md) — D12/D13 detection, step commit gate, diff-scoping prerequisite
- [CUSTOMIZATION.md](../../CUSTOMIZATION.md) — consumer-facing opt-out documentation
- [pre-commit-formatting.md](pre-commit-formatting.md) — independent formatting gate
