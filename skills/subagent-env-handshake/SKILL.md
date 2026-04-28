---
name: subagent-env-handshake
description: "Subagent environment-handshake contract for Claude Code Agent-tool dispatch. Use when a parent session dispatches a subagent that may make tree-grounded claims (file X exists, branch is Y, commit Z landed) — the handshake lets the subagent verify its live working-tree view matches the parent's before it prosecutes tree-grounded findings. DO NOT USE FOR: research subagents that never touch git/tree state; Copilot subagent dispatch (execution model differs)."
scope: claude-only
---

# Subagent Environment Handshake (v1)

Shared contract for parent → subagent handoff of live working-tree state in Claude Code `Agent`-tool dispatch. Exists to eliminate the failure mode from [#380](https://github.com/Grimblaz/agent-orchestra/issues/380) / [#383](https://github.com/Grimblaz/agent-orchestra/issues/383) where a subagent confidently reported tree-grounded claims (file existence, branch identity) grounded in a stale `<env>` block injected once at dispatch time and never refreshed.

> **Survival**: `SMC-14` governs this handshake as `per-dispatch`: the block is prompt-carried, delegated/informational, and intentionally not persisted.

## When to use

Use this handshake for any dispatch where the subagent **may claim**:

- `file X exists` / `file X does not exist`
- `branch is Y`
- `commit Z landed` / `commit Z is not in this branch`
- any equivalent tree-grounded assertion

Skip the handshake for dispatches that only consume task descriptions, web content, or passed-in documents without live-verifying against the working tree. The opt-in rubric keeps the prompt tax off research/non-tree subagents (ND-3).

## Scope (ND-4)

The handshake covers exactly four working-tree facts that can appear stale in a subagent's injected `<env>` block:

**In-scope fields:**

- `parent_head` — parent's live `git rev-parse HEAD`
- `parent_branch` — parent's live `git rev-parse --abbrev-ref HEAD`
- `parent_cwd` — parent's live `pwd`
- `parent_dirty_fingerprint` — SHA-256 (first 12 hex chars) of `git status --porcelain` output with line endings normalized to LF

**Explicitly out of scope:**

- Environment variables (`PATH`, `NODE_ENV`, etc.) — subagent has its own shell env; not reflected in the `<env>` block.
- Tool versions (node, pwsh, gh) — orthogonal to tree-state divergence.
- Terminal/TTY state — not a tree property.
- File permissions, symlink targets — outside the symptom class.

A handshake covering additional fields is a v2 schema change, not a v1 extension.

## Reserved values

- `workspace_mode: 'shared'` — default. Parent and subagent share a working tree (Claude Code's default dispatch model per the Claude Code subagents docs).
- `workspace_mode: 'worktree'` — **reserved, not defined in v1**. The `isolation: worktree` frontmatter opt-in exists in Claude Code, but v1 subagent-side verifiers MUST treat `workspace_mode: worktree` as an error path (equivalent to missing handshake). v2 will define worktree-specific verification rules.

## Schema (v1)

Authoritative schema block — the dispatch prompt-text carrier. Consumer scripts and prose templates below grep between the sentinel comment lines to build or verify the block.

```yaml
# --- subagent-env-handshake v1 schema begin ---
parent_head: <sha> # string, 40 hex chars, output of `git rev-parse HEAD` in the parent
parent_branch: <branch-name> # string, output of `git rev-parse --abbrev-ref HEAD` in the parent
# Note: on detached HEAD, this field is the literal string `HEAD` on both sides — comparison succeeds; commit identity is still verified via `parent_head`
parent_cwd: <absolute-path> # string, output of `pwd` in the parent
parent_dirty_fingerprint: <12-hex> # string, SHA-256(LF-normalized `git status --porcelain`) truncated :12
workspace_mode: <shared|worktree> # enum. v1: 'shared' is the only active value; 'worktree' is reserved → error path.
handshake_issued_at: <iso-8601-utc> # string, parent-side `(Get-Date).ToUniversalTime().ToString('o')` or equivalent
# --- subagent-env-handshake v1 schema end ---
```

Six fields, no optional fields. The block is emitted as a Markdown HTML-comment-wrapped fenced code region (see template below) so it survives intact through prompt concatenation.

## Inline prompt template (prose form)

Parent dispatch code that cannot invoke PowerShell (e.g., the markdown in `commands/plan.md`) constructs the handshake block directly from Bash-captured values. Copy this template verbatim, substitute the six values, and prepend to the `Agent` tool `prompt` parameter:

```markdown
<!-- subagent-env-handshake v1 -->

parent_head: 0000000000000000000000000000000000000000
parent_branch: main
parent_cwd: /absolute/path/to/repo
parent_dirty_fingerprint: 000000000000
workspace_mode: shared
handshake_issued_at: 1970-01-01T00:00:00.0000000Z

<!-- /subagent-env-handshake -->
```

Field names and order MUST match the schema block above. Drift is locked by the schema-parity Pester test in `.github/scripts/Tests/subagent-env-handshake.Tests.ps1`.

## Subagent contract — match / mismatch / error / missing-handshake

When a dispatched subagent loads, its first action (before shared-body load, before any tree-grounded claim) is:

1. Parse the `<!-- subagent-env-handshake v1 -->` block from the dispatch prompt. If absent → **missing-handshake** path.
2. Run live git verification via `Bash`:
   - `git rev-parse HEAD`
   - `git rev-parse --abbrev-ref HEAD`
   - `pwd`
   - LF-normalized SHA-256 :12 of `git status --porcelain`
3. If any of those commands **exits non-zero** (covers `git` binary missing, repo-outside, permission errors uniformly) → error path.
4. If `workspace_mode` is `worktree` → error path (reserved in v1).
5. Compare observed to handshake field-by-field.

### Match path

All **four** working-tree fields match. The subagent proceeds to shared-body load / role work with no environmental caveat. Tree-grounded findings carry implicit environmental consistency because the handshake matched.

### Mismatch path (ND-2 default: halt)

One or more of `parent_head`, `parent_branch`, `parent_cwd`, `parent_dirty_fingerprint` differs. The subagent emits exactly one finding using the template below verbatim and halts role work. No tree-grounded claims are produced on this dispatch.

```markdown
## Finding: environment-divergence (halting)

**Expected (from parent handshake):**

- HEAD: {parent_head}
- branch: {parent_branch}
- CWD: {parent_cwd}
- dirty fingerprint: {parent_dirty_fingerprint}

**Observed (live git verification):**

- HEAD: {observed_head}
- branch: {observed_branch}
- CWD: {observed_cwd}
- dirty fingerprint: {observed_dirty_fingerprint}

**Diverged fields:** {comma-separated list}

The subagent halted role work because its live environment does not match
the parent's dispatched handshake. No tree-grounded claims are emitted
on this dispatch. The parent session should reconcile the divergence
(e.g., commit pending edits, re-dispatch from the intended branch, or
explicitly acknowledge the mismatch) and re-dispatch.
```

### Error path (unverified)

Handshake block is missing, unparseable, or any live-verification command returned non-zero, OR `workspace_mode` is `worktree`. The subagent MAY proceed with role work but MUST tag every tree-grounded finding with `environment-unverified`. Non-tree-grounded findings (claims sourced from the task description, passed-in content, or non-tree web/file lookups) remain untagged.

## Tree-grounded vs non-tree-grounded findings

The error-path tag applies only to tree-grounded findings. The distinction:

- **Tree-grounded finding** — any claim whose truth depends on the current working-tree state. Canonical forms: "file X exists / does not exist at path P", "branch is Y", "commit Z landed / is not in this branch", "file F currently contains Q". These require live git / filesystem verification against the parent's tree.
- **Non-tree-grounded finding** — a claim sourced from the dispatch prompt's task description, from passed-in document content, from a web fetch, or from reasoning that does not reference the working tree. Example: "the proposed API in the spec document has inconsistent field naming." These are unaffected by `<env>` staleness.

Subagent authors: if a finding would read the same whether the subagent was looking at the parent's tree or a stale snapshot, it is non-tree-grounded. Otherwise assume tree-grounded and tag accordingly in the error path.

## Parent-side construction — two helper forms

The SKILL exposes two equivalent carriers so both PowerShell and markdown callers can construct the block:

1. **PowerShell helper** (dot-sourceable): `skills/subagent-env-handshake/scripts/New-SubagentDispatchPrompt.ps1`. Use from PowerShell-driven dispatch sites. Deterministic output; unit-tested for fingerprint stability.
2. **Inline prose template** (above): construct from Bash values in markdown command files. Field order must match the schema block.

Both forms produce field-identical output for identical inputs. Scenario (f) validates field names and order.

### Parent-side error handling

If the parent's `git` invocations fail during construction (non-zero exit on `git rev-parse HEAD`, etc.), the parent SHOULD skip handshake construction entirely and dispatch without the block. The subagent's error path takes over at that point — tagging tree-grounded findings `environment-unverified`. The parent is not responsible for emitting the environment-divergence finding; that is the subagent's role on mismatch.

## Related

**Phase 2 adoption guidance** (tracked in [#379](https://github.com/Grimblaz/agent-orchestra/issues/379)): Phase 2 Claude agent bodies that dispatch tree-dependent subagents — **Code-Conductor**, **Code-Critic**, **Test-Writer**, **Refactor-Specialist**, **Review-Response** — MUST adopt this handshake as follows:

1. **Parent-side construction:** construct the handshake via `New-SubagentDispatchPrompt` (or the inline prose template) in the dispatch prose, prepended to the `Agent` tool `prompt` parameter as its first content.
2. **Subagent-side verification:** include a `## Step 0: Environment Handshake Verification` H2 in the subagent shell (or equivalent first-action section) that executes **before** shared-body load. The Step 0 prose directs parse → live-verify → branch (match/mismatch/error).
3. **ND-2 finding template:** quote the ND-2 `## Finding: environment-divergence (halting)` template verbatim from the block in this SKILL. Do not paraphrase — the schema-parity test enforces byte parity.

Research or non-tree-dependent dispatches may skip the handshake entirely; opt-in is intentional (ND-3).

> **CWD capture (Windows)**: Always capture `parent_cwd` using `pwd` in the Bash tool, not `(Get-Location).Path` in PowerShell. On Windows, PowerShell produces `C:\Users\...` while the Bash tool produces `/c/Users/...`; these formats will never compare equal and will trigger a mismatch halt.

**Cross-references:**

- Pilot site (this feature): `commands/plan.md` → `agents/issue-planner.md` (the only existing real `Agent`-tool dispatch in the Claude plugin as of 2026-04-20).
- Related plan hygiene: [#389](https://github.com/Grimblaz/agent-orchestra/issues/389) — plugin version bump required for cache invalidation when this skill ships.
- Copilot exemption: `scope: claude-only` — Copilot's subagent model shares the parent workspace with different tool bindings, so tree-view divergence does not arise. No Copilot-side port is planned.

## Gotchas

- **CWD format mismatch (Windows):** Always capture `parent_cwd` using `pwd` in the Bash tool, not `(Get-Location).Path` in PowerShell. PowerShell produces `C:\Users\...`; Bash produces `/c/Users/...`. They will never compare equal and will cause a spurious mismatch halt on every Windows dispatch.
- **Detached HEAD:** When the parent is in detached-HEAD state, `git branch --show-current` returns an empty string. `parent_branch` will be recorded as `HEAD` (or empty depending on the capture command). The subagent's live branch check must tolerate this — do not assume `parent_branch` is always a branch name.
- **sha256sum availability:** `sha256sum` is not available on macOS by default (use `shasum -a 256` instead) and may be absent in some CI images. The parent-side helper must guard against missing commands; on failure, skip dirty-fingerprint construction and dispatch without the field rather than halting the parent.
- **Missing-handshake is not an error:** Subagents dispatched without a handshake block (research tasks, Copilot dispatch, pre-adoption callers) route to `missing-handshake` → `environment-unverified`, not to `error`. Do not conflate the two paths.
- **Schema-parity test enforces byte identity:** The Pester contract test verifies that the `## Finding: environment-divergence (halting)` block in the verifier stub is byte-identical to the copy in this SKILL.md. If you edit the finding template here, you must update the fixture too (and vice versa), or the test will fail.

## Reproducer Evidence (from design phase)

Pinned from the ND-5 reproducer run during the #383 design phase (2026-04-20). This appendix lives in-repo so the evidence is durably grep-able, not dependent on the rotating GitHub issue timeline.

**Original hypothesis (from issue body):** the Claude `Agent` tool spawns subagents against a worktree snapshot taken at conversation start; subagents therefore see a frozen tree that diverges from the parent's live edits.

**Reproducer — Claude Code official docs (`code.claude.com/docs/en/sub-agents`, verified 2026-04-20):**

- **Line 225** (default dispatch model): _"A subagent starts in the main conversation's current working directory. Within a subagent, `cd` commands do not persist between Bash or PowerShell tool calls and do not affect the main conversation's working directory."_ → The default is **shared live working tree**, not a snapshot.
- **Line 246** (opt-in isolation): _"[isolation: worktree] runs the subagent in a temporary git worktree, giving it an isolated copy of the repository."_ → Worktree isolation is a **frontmatter opt-in**, not the default.
- **Line 223** (injected env context): _"Subagents receive only this system prompt (plus basic environment details like working directory), not the full Claude Code system prompt."_ → The subagent receives a small `<env>` block (working dir, branch, status, recent commits) **injected once at dispatch time**.

**In-session parent evidence:** the parent session's own injected `<env>` block captured at conversation start became stale within the session — at dispatch time the `<env>` said `feature/issue-382-runtime-shared-body-enforcement` / HEAD `a9bc897`, while the live `git rev-parse HEAD` returned `feature/issue-383-subagent-env-consistency` / HEAD `6bf7aaa`. Divergence reproduced live.

**Reproduced mechanism:** the divergence is **not** "subagent runs on a snapshot." It is **"LLM trusts stale injected `<env>` context instead of running live `git` verification."** The `<env>` block is captured once and never refreshes. Any tree-grounded claim the subagent makes that relies on the injected `<env>` rather than on a live `git` call will be wrong whenever the parent has switched branches or committed since the `<env>` was captured.

**Why four fields (ND-4), not one:** HEAD, branch, CWD, and dirty-tree state each appear in the injected `<env>` block and each can go stale independently. A handshake that covered only HEAD would miss the CWD-drift and uncommitted-edit failure modes the reproducer exposed.
