---
name: session-startup
description: "Automatic startup cleanup guard for new conversations. Use when deciding whether to run the session cleanup detector before the first reply, handling stale-state prompts, or preserving run-once startup semantics. DO NOT USE FOR: post-merge archival workflows (use post-pr-review) or general workflow troubleshooting outside startup detection (use process-troubleshooting)."
---

# Session Startup

Run-once startup guard for the automatic session-cleanup detector.

## When to Use

- When the SessionStart hook injects `additionalContext` into the agent's first turn
- When deciding whether the automatic startup detector should run
- When interpreting stale-state detector output and optionally running cleanup
- When checking whether the installed Claude plugin version has drifted behind the marketplace
- When preserving manual detector access after the automatic startup path fires

## Purpose

The trigger mechanism is now a plugin-distributed `hooks/hooks.json` SessionStart hook rather than an LLM-interpreted per-agent directive. Apply a session-memory run-once guard after that hook fires so the detector runs at most once automatically per conversation while remaining available for explicit manual use. The same run-once pass also owns the Claude-only plugin drift backstop: when `agent-orchestra@agent-orchestra` is installed but behind the resolved marketplace version, surface the update result and a restart-vs-continue decision without blocking the session on failures.

## Session Startup Check

Follow these steps exactly.

> **Survival**: `SMC-07` owns the startup run-once marker. Hook-driven marker writes are `within-conversation:hooks`; the honest gaps are the inline run-once marker write, the inline-vs-subagent enforcement split, the headless-Claude prompt skip, and the freshness-step fail-open user-visible surface. Do not add a second marker or new persistence mechanic.

### Canonical Automatic Startup Guard Contract

```json
{
  "sessionStartupMarkerPath": "/memories/session/session-startup-check-complete.md",
  "checkMarkerBeforeAutomaticDetectorRun": true,
  "recordMarkerAfterFirstAutomaticStartupCheck": true,
  "recordMarkerRegardlessOfCleanupChoice": true,
  "failOpenOnSessionMemoryAccessError": true,
  "manualDetectorRunsRemainAllowed": true,
  "confirmSharedBodyLoadForAgentShells": true
}
```

### Step 1 — Check prerequisites

For automatic startup runs, first use any hook-injected `additionalContext` if it is already present in the agent's first turn. Resolve the detector script path relative to this skill file for manual fallback: the wrapper at `scripts/session-cleanup-detector.ps1` (in this skill's directory) self-resolves its repo root via `$PSScriptRoot`, so no environment variables are required. If `pwsh` is unavailable or the script is missing, skip the entire check silently and continue with the user's request.

**Scratch-containment net (AC5)**: As part of the SessionStart hook invocation, `session-cleanup-detector.ps1` calls `scripts/Ensure-ScratchGitignore.ps1` (fail-open) before running the cleanup detector. That script idempotently appends `.tmp/` and the mangle-literal gitignore patterns from `skills/terminal-hygiene/SKILL.md ## Scratch & Temp-File Hygiene` to the consumer repo's `.gitignore` when any are absent. Running it twice produces no duplicate lines. Failures in this step are swallowed — they never crash the hook or affect the cleanup-detector output.

### Step 2 — Check the automatic run-once guard

Before any automatic startup detector run, check session memory for the marker at `/memories/session/session-startup-check-complete.md`. If that marker is present, skip the automatic detector run and continue silently with the user's request. If session-memory lookup, read, or other access fails, fail open and still run the detector rather than suppressing the check.

### Step 3 — Run the detector script

For automatic startup runs, the plugin-distributed SessionStart hook runs the detector before the agent sees the user's request and injects the resulting `additionalContext`. This step preserves the manual fallback command contract and any contributor-side direct invocation. The wrapper self-resolves its repo root via `$PSScriptRoot`, so no env vars are needed — but the terminal's working directory in a consumer repo is usually the consumer's workspace, **not** the orchestra plugin. Invoke the script by a path that resolves from wherever the `agent-orchestra` content actually lives.

**Repo clone** (contributors, CWD is the repo root — relative path works):

```powershell
pwsh -NoProfile -NonInteractive -File "skills/session-startup/scripts/session-cleanup-detector.ps1"
```

**Plugin-cache install** (Copilot or Claude Code consumers, CWD is the consumer workspace — pass the plugin's absolute path). Resolve the plugin directory from the installed plugin cache rather than any `chat.*Locations` setting (Copilot: the VS Code `agentPlugins/.../agent-orchestra` cache path under the active product profile; Claude Code: `<plugins-cache-root>/agent-orchestra/`), then:

```powershell
pwsh -NoProfile -NonInteractive -File "<plugin-root>/skills/session-startup/scripts/session-cleanup-detector.ps1"
```

If neither path resolves (the script is genuinely missing), skip the check silently per Step 1.

### Step 4 — Record the run-once marker

Record or write the session-memory marker at `/memories/session/session-startup-check-complete.md` after the first automatic startup check runs so later agent hops in the same conversation skip the automatic detector run. Record the marker regardless of whether cleanup is needed and regardless of whether the user later confirms, declines, or skips cleanup. If session-memory write or other access fails, fail open: continue with the detector result you already obtained, and allow later automatic checks rather than risking a missed cleanup warning.

### Step 5 — Parse the output

The detector returns one of two JSON shapes.

**No stale state found**: continue silently and do not mention the check to the user.

```json
{}
```

**Stale state found**: prompt the user.

````json
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "**Post-merge cleanup detected** - stale tracking artifacts found:\n\n- `.copilot-tracking/issue-42-my-feature.yml`\n\nTo clean up, run:\n```powershell\n# Run in a PowerShell (pwsh) terminal:\npwsh '/path/to/agent-orchestra/skills/session-startup/scripts/post-merge-cleanup.ps1' -IssueNumber 42 -FeatureBranch 'feature/issue-42-my-feature'\n```\n"
  }
}
````

The `additionalContext` field is a Markdown-formatted description of what was found plus the command block to clean it up.

**Multi-category example** (when sibling worktrees or orphan branches are also found, the cleanup command uses the composite form; `-TmpRoot '.tmp'` is auto-wired when `-IssueNumber` is present and a `.tmp/` directory exists at the repo root):

```powershell
pwsh '/path/to/agent-orchestra/skills/session-startup/scripts/post-merge-cleanup.ps1' -IssueNumber 42 -FeatureBranch 'feature/issue-42-my-feature' -TmpRoot '.tmp' -SiblingWorktrees @('/path/to/worktree') -OrphanBranches @('claude/old-feature')
```

When writing a `.claude/settings.json` allowlist entry, match against `Bash(pwsh*post-merge-cleanup.ps1*)` — this covers both the single-issue form and the composite form with `-SiblingWorktrees` and `-OrphanBranches` arguments.

Detector findings are reported in this order when present:

- **Current branch**: flags the current branch when its upstream was merged/deleted, and flags a current `claude/*` no-upstream branch only when it is reachable from the resolved remote default branch. The current branch — whether it has an issue ID (`feature/issue-N-…`) or not — is rolled into the same composite `pwsh ... post-merge-cleanup.ps1 ... -FeatureBranch '<branch>'` invocation as the other categories, so confirming cleanup triggers exactly one permission prompt. The script switches to the default branch, pulls, and deletes the now-stale current branch on your behalf. (The `Documents/Design/session-hooks.md` note about running current-worktree cleanup from another checkout still applies if you choose to bypass the script and run the underlying git commands manually — but the recommended path is the composite invocation.)
- **Tracking files**: flags issue-scoped `.copilot-tracking/` files whose remote `feature/issue-*` branch is gone; persistent calibration data remains excluded.
- **`.tmp/` scratch clearing**: per-issue `.tmp/{N}-*` and `.tmp/issue-{N}*` scratch files are cleared at cleanup time (not detected). `-TmpRoot '.tmp'` is auto-wired into the composite invocation when `-IssueNumber` is present and a `.tmp/` directory exists at the repo root; the `Remove-IssueTmpScratch` function handles removal and emits a summary line.
- **Sibling worktrees**: flags sibling worktrees on merged `claude/*` no-upstream branches or upstream-deleted `feature/issue-*` branches. Their cleanup is rolled into the single composite `pwsh ... post-merge-cleanup.ps1 -SiblingWorktrees @(...) -OrphanBranches @(...)` invocation appearing inside the fenced PowerShell block — not as individual `git` commands.
- **Orphan branches**: flags unattached merged `claude/*` no-upstream branches and unattached upstream-deleted `feature/issue-*` branches. Their cleanup is rolled into the single composite `pwsh ... post-merge-cleanup.ps1 -SiblingWorktrees @(...) -OrphanBranches @(...)` invocation appearing inside the fenced PowerShell block — not as individual `git` commands. Squash-merged branches are automatically classified as merged via tree-equivalence (`git diff --quiet` exit 0) even when `git cherry` reports their commits as unique. `feature/issue-N-*` orphan branches that differ from the remote default carry a `; eligible for auto-resolve at cleanup time` per-line suffix in the detector output: at cleanup time `Remove-OrphanBranch` calls `Test-OrphanBranchAutoResolveEligible` and deletes the branch automatically when the parent issue is CLOSED, a merged PR with matching `headRefOid` exists, and every residual commit is absorbed by main (ancestor-on-main / patch-equivalent / spike-only confined to `.tmp/issue-N/` / tree-at-HEAD-matches-main). When auto-resolve is not authorized, the skip message is `auto-resolve declined`; when auto-resolve signals cannot be verified, the skip message is `could not verify auto-resolve signals` (fail-open: branch retained). A race-condition path emits `branch not reachable from default (merged-state re-check returned false)` if the merged-state re-check returns false immediately before force-delete. Non-`feature/issue-N-*` orphans (e.g., `claude/*`) are not eligible for auto-resolve and retain the previous behavior.
- **Fail-open behavior**: fetch, worktree-list, for-each-ref, per-candidate merge-base, and ref-lookup failures suppress only the unverifiable candidate and do not fail the startup session.
- **Opt-in cleanup**: the detector only reports findings. Nothing is removed unless the user confirms, and explicit manual detector runs remain available after the automatic guard fires.

Claude cleanup findings are capped at 10 concrete `claude/*` entries; additional entries are summarized with a `+N more` hint.

### Step 6 — Prompt the user

If the output contains `hookSpecificOutput`, present the `additionalContext` text to the user and ask for confirmation before running cleanup. Use `#tool:vscode/askQuestions` with two options: "Yes — run cleanup" and "No — skip for now". The confirmation covers only the fenced cleanup block; inline current-worktree commands are deliberately narrative and require a separate manual run from another checkout.

### Step 7 — Run cleanup (only if confirmed)

If the user confirms, run all lines from the fenced code block inside `additionalContext` in the terminal. Skip blank lines; `#`-prefixed comment lines are safe to include. Do not scrape or execute inline current-worktree cleanup text outside the fenced block. Report what was cleaned up when complete.

### Step 7b — Run the Claude plugin drift check

After the cleanup path completes, run this Claude-only sub-step before continuing with the user's request. Copilot skips this sub-step silently because it has no version-cache analog.

**Ordered procedure (must follow this exact sequence):**

1. **Refresh marketplace view**: Run `claude plugin marketplace update` with a 5-second timeout. If it fails or times out, emit `marketplace freshness check failed — using cached view` and continue with the cached view. Do not retry transient freshness failures.

2. **Resolve installed state**: Read `~/.claude/plugins/installed_plugins.json`. Find the `agent-orchestra@agent-orchestra` entry and read its installed `version` plus `marketplace` field. If the file is missing, the entry is absent, or the entry has no `marketplace` field, fail open: silent-skip or emit a one-line minimal error and continue.

3. **Resolve marketplace latest**: Read `~/.claude/plugins/marketplaces/{marketplace}/.claude-plugin/plugin.json`. If the installed version matches, continue silently (verified-current silence).

4. **Detect drift and emit marker**: If the installed version is behind the marketplace version, emit `Drift detected — updating…` as an inline status line. This marker signals that the install is about to begin.

5. **Run the install**: Run `claude plugin update agent-orchestra@agent-orchestra --yes` with a 30-second timeout. On success, emit:
   `Updated 'agent-orchestra@agent-orchestra' from {old} -> {new}. Current session runs under old code until restart.`
   On failure, retry once on transient errors. If the retry also fails, emit a failure summary and the manual fallback command:
   `Plugin update failed: {error}. Manual fallback: claude plugin install agent-orchestra@agent-orchestra`

6. **Present structured question (only after step 5 completes)**: The structured question MUST NOT be presented while the install is in flight or before it has been attempted (success or announced failure). After step 5 completes — whether it succeeded or failed — present the appropriate prompt (see the `Drift Failure-Mode Prompt` subsection below).

**Silent skip conditions for this sub-step**: when `pwsh` is missing; when the `claude` CLI is missing or fails; when the marketplace registration points at a non-git local directory, dirty tree, or detached HEAD (the local-path classification already surfaces remediation).

**Local-path marketplace classification** (run before step 4 when a local path is detected):

- Clean git repo behind `origin/main`: surface that the marketplace path is behind and include `claude plugin marketplace remove agent-orchestra` and `claude plugin marketplace add Grimblaz/agent-orchestra` remediation commands
- Non-git local directory: surface that the registration is a non-git local directory
- Dirty tree or detached HEAD: surface that local marketplace remediation is skipped because the clone has local work
- Fetch failure: fail open and continue

**Headless Claude behavior**: Headless Claude runs perform the same steps 1–5 and same fail-open emission; only step 6 (the stop/continue structured question) is suppressed. The verified-current silence guarantee applies only on the freshness-success branch; on freshness failure, cached comparison is a documented accepted limitation.

This sub-step shares the existing Step 4 run-once marker; do not introduce a second marker or persistence mechanism.

### Drift Failure-Mode Prompt

The canonical `### Inline-Dispatch Option Labels` YAML block keeps exactly 4 keys (`cleanup_yes`, `cleanup_no`, `drift_stop`, `drift_continue`) — no additional keys are added for failure-mode labels.

**On install success** (step 5 of Step 7b succeeded): present the structured question using the canonical `drift_stop` and `drift_continue` option labels verbatim:

- `Stop — I'll restart now` (maps to `drift_stop`)
- `Continue — run under old code` (maps to `drift_continue`)

**On install failure** (step 5 of Step 7b failed, including post-retry): render a one-off failure-recovery prompt (not a canonical labeled option — these labels are session-ephemeral only):

- `Stop — I'll restart and try the install again`
- `Continue — under old code (install failed)`

Include the manual fallback command in the failure prompt body so the user has something concrete to act on when they choose to restart: `claude plugin install agent-orchestra@agent-orchestra`.

This conditional rendering keeps the `inline-dispatch-contract.Tests.ps1` `ExpectedCount 4` and `Should -Be 4` assertions green because failure-mode labels are prose-rendered and session-ephemeral, not added to the canonical YAML block.

### Permission allowlist (recommended)

To avoid repeated per-command permission prompts when the session-startup cleanup runs, add these entries to your project's `.claude/settings.json` `allow` list:

```json
{
  "permissions": {
    "allow": [
      "Bash(pwsh*post-merge-cleanup.ps1*)",
      "Bash(git branch -D feature/*)",
      "Bash(git branch -D claude/*)"
    ]
  }
}
```

The first entry covers the composite cleanup-script invocation that the session-startup hook emits. The second and third entries cover edge cases where manual cleanup commands are needed outside the script (for example, when the current-worktree narrative guidance is followed manually from another checkout).

Automated detection or installation of these allowlist rules is out of scope for this issue and would be a follow-up. AC4 of issue #500 is satisfied by this documentation per the Experience-Owner framing: "documents how the cleanup confirmation answer translates into permission."

On Windows, the existing `Bash(pwsh*post-merge-cleanup.ps1*)` allowlist entry covers `pwsh` invocations through Claude Code's Bash tool surface; no separate `PowerShell(...)` entry is required.

If the cleanup script (or a settings.local.json edit applying these recommendations) is silently denied even after explicit user authorization in the same conversation, you are observing the contextual-classifier override pattern documented in [issue #546](https://github.com/Grimblaz/agent-orchestra/issues/546) (see comments [4414368049](https://github.com/Grimblaz/agent-orchestra/issues/546#issuecomment-4414368049) and [4414376114](https://github.com/Grimblaz/agent-orchestra/issues/546#issuecomment-4414376114)). Workaround: apply this allowlist *before* the deny fires by editing `.claude/settings.local.json` directly; do not ask the agent to make the edit on your behalf in the same turn you authorize it.

Issue #548's `gh issue view` and `gh pr list --head` calls run as child processes of `pwsh` inside `post-merge-cleanup.ps1`, so the existing `Bash(pwsh*post-merge-cleanup.ps1*)` allowlist entry above covers them. No new `Bash(gh ...)` entries are needed. The L2 customer-self-verification responsibility documented above (issue #546 contextual-classifier override) applies symmetrically to these gh calls — if a same-turn denial is observed, apply the existing workaround.

### Step 7c — Portfolio snapshot (Claude-only, fail-open)

<!-- scope: claude-only -->

This step runs **outside** the Step 4 run-once guard — it refreshes every session start, not just the first. Skip this step if the user chose `drift_stop` in Step 7b (session is ending; no point rendering a snapshot). Copilot: silent skip.

**Behavior**: If `Documents/Planning/sequence.yaml` exists in the working directory and is parseable (has a `control_tower:` integer field), run:

```powershell
gh issue view {control_tower} --json body --jq '.body' | Select-String 'portfolio-tracker' -Context 0,5 | Select-Object -First 6
```

with a ~3-second timeout. Surface at most **5 lines** of the rendered section, always including the `as of … — rendered by render-portfolio.ps1` footer line so the owner can see render freshness at a glance. Truncate with `(…)` if more lines follow.

Any failure (file absent, parse error, `gh` timeout, network error, missing `control_tower` field, non-zero exit) → **silent skip**. Never block session startup on a portfolio snapshot.

See `platforms/claude.md` for the Claude Code tool invocation note.

### Step 8 — Continue with the user's request

After the automatic startup path is complete, continue with the user's original request only after completing any other applicable startup steps below, including Step 7b and Step 9 when they apply. In hook-driven runs, this means consuming any injected `additionalContext`, recording the run-once marker, and then proceeding. This automatic run-once guard applies only to the cleanup-detector plus Claude drift-check path; explicit or manual detector runs still remain allowed after the automatic guard fires.

### Step 9 — Confirm paired shared-body load (agent shells with a paired body)

This step is not gated by the session-startup run-once marker and fires on every agent-role adoption in the conversation, including every subagent dispatch. Do not wrap this step in the Step 2 or Step 4 marker guard.

If you are operating as an agent shell at `agents/{name}.md` whose body contains a `## Shared methodology` section naming a paired `agents/{Name}.agent.md`, **or if you are an inline slash-command dispatch at `commands/{name}.md` that names a paired `agents/{Name}.agent.md` body in its load reference**, load that paired file via the platform's file-read tool before proceeding. Use the D1 plugin-cache-first body resolution sequence documented in your host file's own `### Step 9 — Paired-body halt-on-fail` block (each agent shell and each command file carries its own per-body cascade).

If that load fails, emit exactly: `⚠️ Shared-body load failed for agents/{Name}.agent.md — {error}. This run cannot continue without the canonical methodology; surface this to the user and stop.` After emitting that message, do not make any further tool calls, subagent dispatches, structured-question calls, or any other agent actions.

If the paired load succeeds, cite it with `Shared body loaded — proceeding as {AgentName}` and include the full-form H2 body names exactly as they appear in the shared body, excluding `Platform-specific invocation`.

If you are not in a paired-body context, skip this step silently.

If the same shared body is loaded more than once in a conversation, the load is idempotent — loading the same file a second time is harmless and does not require deduplication logic.

### Inline-Dispatch Option Labels

```yaml
canonical_option_labels:
  cleanup_yes: "Yes — run cleanup"
  cleanup_no: "No — skip for now"
  drift_stop: "Stop — I'll restart now"
  drift_continue: "Continue — run under old code"
```

Enforcement paths: Claude inline slash-command dispatch (`/experience`, `/design`, `/plan`, `/orchestrate`, and `/polish`) enforces the pre-flight protocol via a load reference to this skill; the per-command prose duplication was removed in issue #498 (DRY pass following #481). Each command file retains a `### Step 9 — Paired-body halt-on-fail` block with its D1 body-resolution cascade immediately after the load reference; Step 9 of this skill now recognizes inline slash-command dispatch as a paired-body context, so the halt-on-fail contract applies to both `Agent` tool subagent dispatches and inline command invocations.

## Silent Skip Conditions

Skip the entire check silently in any of these cases:

- `pwsh` is not available on `PATH`
- The detector script does not exist at the expected path
- The detector script returns an error or non-JSON output

These are normal conditions in repos that have not installed the agent-orchestra plugin or in environments where PowerShell is unavailable.

## Gotchas

| Trigger                            | Gotcha                                                                                | Fix                                                                                         |
| ---------------------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| Session memory read or write fails | Suppressing the detector would hide cleanup warnings for the rest of the conversation | Fail open: still run or keep the existing detector result, and allow later automatic checks |
| `git cherry` labels squash-merged branch commits as unique (patch-id false positive) | Squash-merged branches are reported as "unmerged" and left behind instead of being cleaned up | Merge-detection uses `git diff --quiet` tree-equivalence as primary check; `git cherry` is retained as fallback only (issue #513) |

| Trigger                                     | Gotcha                                                                              | Fix                                                                                   |
| ------------------------------------------- | ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| Running the detector manually after startup | Treating the run-once guard as a global prohibition blocks legitimate manual checks | Keep manual detector runs available; the guard only limits the automatic startup path |

---

> **D3b soft exemption**: unlike the other five platform-split skills, this SKILL.md retains Copilot-specific invocation details (see §Trigger) because the session-startup trigger path is Copilot-native. The canonical routing footer below still applies and is byte-identical across all six split skills; the exemption is specific to this skill's Trigger section, not the footer.

## Platform-specific invocation

This skill's methodology is tool-agnostic. Platform-specific routing lives alongside:

- Copilot: [platforms/copilot.md](platforms/copilot.md)
- Claude Code: [platforms/claude.md](platforms/claude.md)
