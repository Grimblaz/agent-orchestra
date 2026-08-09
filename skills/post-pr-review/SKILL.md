---
name: post-pr-review
description: "Post-merge checklist for archiving, documentation, versioning, and release tagging. Use when completing post-merge cleanup, archiving tracking files, updating docs, or running the pre-merge strategic assessment (Step 6). DO NOT USE FOR: pre-PR readiness checks (use verification-before-completion) or processing GitHub review comments (use code-review-intake)."
provides: post-pr
suggested-next-step: Run /orchestrate {ISSUE} or follow post-pr-review skill workflow
---

# Post-PR Review

## When to Use

Execute this workflow **after**:

- Pull Request has been reviewed
- All feedback has been addressed
- PR has been merged to the main branch
- CI/CD pipeline has completed successfully

Or use the strategic assessment section only (Step 6) **before merging** to evaluate design alignment and long-term implications before approving a PR.

**Step 9 (Close-Out Record) is not gated on a merged PR.** It fires whenever an issue that was opened for work is about to be closed, including an issue closed without a pull request. Do not read the merged-PR trigger above as a reason to skip it.

**And on a run that will open a pull request, the record is owed earlier than this document is read at all** — before the PR-creation action, stated on the brief that run is dispatched against (`skills/plan-authoring/SKILL.md` § The close-out obligation on an affirmation-record issue). Step 9 owns the record's shape at both moments; it is not the only place the obligation is stated, and by the time a reader arrives here through the post-merge trigger above, moment 1 has already passed.

Be clear about who reaches it on that path, because no dispatcher does: the post-merge checklist is invoked by Code-Conductor's cleanup path, which presupposes a PR. For a PR-less close the reader is the **conversation closing the issue**, routed here by `skills/open-for-work/SKILL.md` § Resuming an issue already opened for work (`complete` state). That is a documented reader, not an automated one — nothing fires Step 9 on its own, so an issue closed by hand outside any conversation will not get a close-out record unless someone runs this step deliberately.

> **Note for plugin-only users**: Step 6 (Strategic Assessment) is available without cloning — it's pure analysis using GitHub tools.

## Purpose

This document provides a standardized checklist for agents to follow after a Pull Request has been reviewed, approved, and merged. These steps ensure proper cleanup, documentation, and project maintenance.

## Standard Post-Merge Checklist

### 1. Archive Tracking Files

**Action**: Move completed tracking files into the local archive. These directories are gitignored — they stay on your machine only.

```powershell
# Preferred: use the cleanup script (handles archival, branch deletion, git sync).
# The script is shipped with the agent-orchestra plugin/clone and self-resolves its paths.
pwsh "skills/session-startup/scripts/post-merge-cleanup.ps1" -IssueNumber {ID} -FeatureBranch feature/issue-{ID}-description
# Optional: also pass sibling worktrees or orphan branches for composite cleanup (see session-startup SKILL.md § Permission allowlist):
# pwsh "skills/session-startup/scripts/post-merge-cleanup.ps1" -IssueNumber {ID} -FeatureBranch feature/issue-{ID}-description -OrphanBranches @('claude/old-branch') -SiblingWorktrees @('path/to/worktree')

# Or manual archive only (PowerShell):
$archivePath = Join-Path ".copilot-tracking-archive" (Get-Date -Format 'yyyy') (Get-Date -Format 'MM') "issue-{ID}"
New-Item -Path $archivePath -ItemType Directory -Force
Get-ChildItem .copilot-tracking -Recurse -File |
    Where-Object { (Get-Content $_.FullName -Raw) -match 'issue_id:\s*{ID}' } |
    ForEach-Object { Move-Item -LiteralPath $_.FullName -Destination $archivePath }
```

**Note**: Both `.copilot-tracking/` and `.copilot-tracking-archive/` are gitignored. These files are agent scaffolding — the durable record lives in GitHub issues, PRs, commits, and `Documents/Design/`. Do not commit tracking files.

**Verify**:

- Files moved to `.copilot-tracking-archive/{year}/{month}/issue-{ID}/`
- No tracking files remain in `.copilot-tracking/research/` for this issue

> **Automation**: The plugin's `SessionStart` hook detects stale tracking files, sibling worktrees, and orphan branches and prompts you at the start of your next conversation — cleanup requires one confirmation and runs as a single composite `pwsh ...post-merge-cleanup.ps1 ...` invocation (no per-branch permission prompts). You can also run the script directly: `pwsh "skills/session-startup/scripts/post-merge-cleanup.ps1" -IssueNumber {ID} -FeatureBranch feature/issue-{ID}-description` (script path is relative to the agent-orchestra plugin or repo clone). See the `### Permission allowlist (recommended)` subsection in `skills/session-startup/SKILL.md` for opt-in allowlist entries that suppress the single prompt.

### 2. Update Documentation

**Action**: Ensure all relevant documentation reflects the changes.

**Common Documentation to Review**:

- [ ] README.md - Updated if features/setup changed
- [ ] CHANGELOG.md - Entry added for this change
- [ ] API documentation - Updated if interfaces changed
- [ ] Architecture docs - Updated if structure changed
- [ ] User guides - Updated if user-facing changes
- [ ] Configuration examples - Updated if settings changed

**Guidelines**:

- Be specific about what changed
- Include version numbers where applicable
- Link to related issues or PRs
- Update any diagrams or visual documentation

### 3. Version Badge Updates (If Applicable)

**Action**: Use the bump-version script to update version strings consistently across all files in one invocation:

```powershell
pwsh .github/scripts/bump-version.ps1 -Version X.Y.Z -DryRun  # preview first
pwsh .github/scripts/bump-version.ps1 -Version X.Y.Z           # apply
```

The script updates `plugin.json`, `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` (2 occurrences), `.github/plugin/marketplace.json` (2 occurrences), and `README.md` (badge line) — 7 occurrences across 5 files. It validates pre-bump consistency and exits with an error if any file has drifted.

**Plugin-only users** (scripts not distributed via plugin): If you're using this workflow as a plugin install without cloning, use targeted `replace_string_in_file` edits for each file individually, then commit and push.

**WRONG** (do not use):

```text
# mcp_github_create_or_update_file with partial file content
# This tool REPLACES the entire file. Only use it for net-new files.
# Using it with partial content silently truncates the rest of the file.
```

**Rule**: `mcp_github_create_or_update_file` is only safe for **new files**. For any edit to an existing file, use the bump script (cloned repo) or `replace_string_in_file` + `git commit` + `git push` (plugin-only).

### 4. Tag Releases (If Applicable)

**Action**: Create version tags for significant releases.

**When to Tag**:

- Feature releases (minor version bump)
- Bug fix collections (patch version bump)
- Breaking changes (major version bump)
- Milestone completions

**Semantic Versioning**:

- `MAJOR.MINOR.PATCH` (e.g., `v1.2.3`)
- **MAJOR**: Breaking changes
- **MINOR**: New features (backward compatible)
- **PATCH**: Bug fixes (backward compatible)

**Process**:

```bash
# Example commands (adapt to your project)
git tag -a v1.2.0 -m "Release version 1.2.0: Added feature X"
git push origin v1.2.0
```

**Release Notes**:

- Summarize changes from CHANGELOG
- Highlight breaking changes
- Include upgrade instructions if needed

### 5. Clean Up Branches

**Action**: Remove merged feature branches.

```bash
# Delete local branch
git branch -d feature/issue-{ID}-description

# Delete remote branch (if not auto-deleted by PR merge)
git push origin --delete feature/issue-{ID}-description
```

**Note**: Some projects auto-delete branches on PR merge. Verify your project settings.

> **Automation**: Branch deletion is also handled by `skills/session-startup/scripts/post-merge-cleanup.ps1` when invoked via the "Session Startup Check" cleanup flow (see Section 1 above).

### 6. Strategic Assessment (Pre-Merge)

**Action**: Before approving a PR, evaluate strategic alignment on three dimensions.

**Design Alignment**:

- Does the implementation match the design doc (`Documents/Design/{domain}.md`)?
- Are any design decisions reversed or partially implemented?
- If the design doc doesn't exist yet, does the implementation align with the issue's stated goals?

**Roadmap Integration**:

- Does this change fit the project's stated direction?
- Any unintended coupling introduced that will constrain future work?
- Are there deprecations triggered or migration concerns created?

**Long-Term Implications**:

- Tech debt introduced — is it tracked (labeled issue or comment)?
- Are there performance, scale, or maintenance concerns not covered in tests?
- Would this pass the "6-month-later developer" readability test?

**Output**: Emit one of:

- `✅ Strategic assessment: aligned` — no concerns
- `⚠️ Strategic assessment: concerns noted` — list specific items; may block PR
- `⏭️ Strategic assessment: skipped — {reason}` — e.g., documentation-only change

### 7. Update Project Tracking

**Action**: Close related issues. The portfolio tracker issue updates automatically.

The derived portfolio tracker (`Documents/Planning/sequence.yaml` + `render-portfolio.yml` workflow) re-renders the control-tower issue after every merge to `main` — no manual board update is required. The board model (ranked-umbrella zones, derived Triage) is documented in [Documents/Design/control-tower-v2.md](../../Documents/Design/control-tower-v2.md).

**Manual fallback** (if the workflow did not run or needs a forced refresh):

```powershell
# Guard: skip silently in consumer repos that lack the renderer
if ((Test-Path 'Documents/Planning/sequence.yaml') -and (Test-Path '.github/scripts/render-portfolio.ps1')) {
    pwsh .github/scripts/render-portfolio.ps1
}
```

> **Consumer repos**: if `Documents/Planning/sequence.yaml` or `.github/scripts/render-portfolio.ps1` is absent, this step is a no-op — skip silently.

**Verification**:

- [ ] Related issues closed or updated
- [ ] Control-tower issue reflects current state (auto-rendered or manual fallback run)

### 8. Notify Stakeholders (If Applicable)

**Action**: Communicate completion to relevant parties.

**Notification Scenarios**:

- Feature releases → Announce to users/team
- Breaking changes → Alert dependent teams
- Bug fixes → Notify affected users
- Security patches → Follow security disclosure process

**Communication Channels** (adapt to your project):

- GitHub issue comments
- Team chat channels
- Email notifications
- Release announcements
- Documentation updates

### 9. Close-Out Record (Issues Opened For Work)

**Applies to**: an issue that was **opened for work** through the open-for-work entrance — one carrying an affirmation record. **Does not apply otherwise.** An ordinary pull-request close on an issue that never ran that flow has no close-out record to write and no re-route count to report; check for the affirmation record first, and when there is none, skip this step and say so rather than manufacturing an empty record.

**How to check** — run the lookup in `skills/open-for-work/SKILL.md` § Resuming an issue already opened for work. That section is the only place both recognised record forms are defined, and it is the instruction here, not an inference: read the issue's comments through `gh api repos/{owner}/{repo}/issues/{ID}/comments --paginate` (never `gh issue view --json comments`, which carries no `updated_at`), accept either the registered marker form or the interim practiced form's exact first line, and discard any record edited after creation. **Zero lawful records → skip this step.**

**Action**: write one close-out comment on the issue, carrying three things.

**Its first line is exactly** `**Close-out record - issue {ID}**` (bold, ASCII only — a plain hyphen, deliberately no em dash given this repository's console-encoding history; `{ID}` is the issue number). This is identification, not decoration: the record is amendable in place (`skills/plan-authoring/SKILL.md` § The close-out obligation on an affirmation-record issue), and a later run cannot amend a comment it cannot pick out. Recognise a record by that line. **This is a first-line convention, not a marker family** — no marker, no `persist-marker.ps1` write path, and deliberately so, since a new family is machinery this work declined.

**An amendment says it is one.** A run amending an existing record appends a dated line naming itself and what changed — *"Amended {date} by the run for PR #{N}: {what changed}."* — rather than silently rewriting. The record is a public artifact whose first writer is often a person, not this run, and an unannounced in-place rewrite of someone else's comment leaves a reader unable to tell an amendment from the original. When the comment's author is not the amending run, say so in that line.

**Render marker-like text inert.** Item 1 folds in finding text, including findings derived from external reviewers, and this repository's findings routinely name marker families. A literal HTML-comment marker in the record is live to the raw-text scanners that read real comments, so strip the delimiters when quoting one (`skills/session-memory-contract/references/handoff-markers.md` § Writing about markers safely). Backticks do not neutralise it.

The three things:

1. **One line per sustained finding** — where it was introduced, where it was catchable, where it was caught. This is the phase-containment ledger's own grain, and this step **does not emit ledger blocks**: the emission mechanics belong to `Documents/Design/phase-containment-ledger.md` and the plan-surface ledger those blocks already live on. Point at that ledger and summarise from it; do not re-emit it here.

   **When no ledger exists** — reachable on a PR-less close, and on a novel-arm parent closed after its chunks carried their own reviews — say exactly that: *"No phase-containment ledger was produced for this issue; no sustained findings to summarise."* Do not invent a ledger reference, and do not silently omit the item. An absent ledger is a fact about the issue, not a gap in the record.

   **Not-yet is a different state from absent, and at moment 1 it is the normal one.** A record written before the PR-creation action necessarily predates its own review, so no ledger exists *yet* — and the sentence above would be a false claim about the issue rather than a true one. Say instead: *"No phase-containment ledger exists yet; this record is provisional and is amended once review completes."* Reserve the absent form for a close where no ledger will ever be produced.
2. **A dead-premises note** — which filed premises beat 1's grounding falsified and amended in place, so the next reader does not resurrect them.
3. **The beat-2 re-route count** — how many times the escape hatch re-ran the routing. Zero is the common case and is reportable. **The count is what the run observed, not an arithmetic on comment counts.** Records-minus-one is a cross-check that legitimately disagrees in three directions: a record voided by a later edit still evidences a re-route that happened, a re-affirmation with an unchanged what-statement can append nothing at all, and a retried write can append twice for one re-route. Report the observed count, note how many affirmation records the issue carries and how many are lawful, and when those disagree say so and why.

**When to write it — two moments, and the second is not a fallback for the first.**

1. **Before the PR-creation action**, on a run that will open a pull request. That run meets this obligation earlier than this step: it is stated on the brief the run is dispatched against, at `skills/plan-authoring/SKILL.md` § The close-out obligation on an affirmation-record issue. This step owns the record's shape; that section owns when the obligation is read.
2. **Before the close** (`## Completion` below), **whenever moment 1 did not already produce the record on this issue**. Keyed on whether the record exists, **not** on whether a pull request exists. An issue closed by hand **without a pull request** is the obvious instance; it is not the only one. An issue also closes on a **closing keyword in a pull request belonging to a different issue** — a designed parent auto-closed by one of its own chunk PRs is exactly that, and moment 1 never fired for it, because the parent has no brief and the chunk that closed it owes no record of its own. A backstop keyed on PR-absence would miss that population while reading as complete.

**Why it binds: the run ends at the close.** Afterwards there is no conversation left to write anything — which is how two of the six issues that owed a record got none at all.

**It is not, as this step used to say, that a closed issue cannot be found.** That reason was false at the grain this step itself reads: the lookup above is number-keyed and state-blind, so a record written a minute *after* the close sits on the issue exactly as reachably as one written a minute before.

**The limit that does hold — do not over-read the correction into "ordering never matters."** A closed issue stays reachable by a number-keyed read and **ages out of time-windowed sweeps**: this repository's portfolio render and its rolling-history ledger both scan closed issues through a `closed:>=` / `closed:>` search window. A late record is not lost, but it can fall outside a sweep that goes looking for it by date.

## Validation Checklist

Before considering work fully complete, verify:

- [ ] Close-out record written (issues opened for work only — Step 9; skip with a stated reason when the issue carries no affirmation record)
- [ ] No test failure in main branch that this work introduced, measured against a named baseline commit; any failure already present at that baseline is named and routed rather than carried silently (`skills/verification-before-completion/SKILL.md` § The Completion Account)
- [ ] No merge conflicts or issues
- [ ] Tracking files moved to `.copilot-tracking-archive/{year}/{month}/issue-{ID}/` (local only — do not commit)
- [ ] Documentation is current and accurate
- [ ] Version badge updated (if version bumped) via bump script (`pwsh .github/scripts/bump-version.ps1 -Version X.Y.Z`); plugin-only installs: `replace_string_in_file` + git — not GitHub file API
- [ ] Release tagged (if applicable) via `git tag` + `git push origin <tag>`
- [ ] GitHub release created with release notes
- [ ] Branches cleaned up
- [ ] Project tracking updated
- [ ] Stakeholders notified (if needed)
- [ ] Working tree clean: `git status` shows no untracked or modified files

## Project-Specific Customization

**[CUSTOMIZE]** Add project-specific steps:

- Deployment procedures
- Database migration verification
- Cache invalidation
- CDN purging
- Monitoring setup
- Alert configuration
- Dependency updates
- Security scans
- Performance benchmarks

## Emergency Rollback

If critical issues are discovered post-merge:

1. **Immediate**: Revert the merge commit
2. **Communication**: Alert team and stakeholders
3. **Investigation**: Identify root cause
4. **Resolution**: Create hotfix PR
5. **Documentation**: Record incident and resolution

```bash
# Revert merge commit
git revert -m 1 <merge-commit-hash>
git push origin main
```

## Completion

Once all checklist items are verified:

- Write the close-out record if the issue was opened for work (Step 9) — this happens **before** the close, not after, and on a run that opened a pull request it was already owed **before the PR-creation action**; if it is not there by now, it is late, so write it and say so
- Mark the original issue as closed
- Remove any temporary resources
- Archive any temporary documentation
- Verify control-tower issue updated (auto-rendered by workflow after merge)

The work is now fully complete and properly documented.

## Structured Outcome Contract

When invoked from Code-Conductor's post-merge cleanup path, this skill returns a structured outcome hashtable with the following shape:

```powershell
@{
    archive    = 'passed' | 'failed' | 'skipped'
    docs       = 'passed' | 'failed' | 'skipped'
    version    = 'passed' | 'failed' | 'skipped'
    releaseTag = 'passed' | 'failed' | 'skipped'
}
```

**Per-key outcome determination**:

- `archive`: `passed` when tracking files were moved/archived and `git status` is clean; `failed` when archiving was attempted but incomplete; `skipped` when no tracking files existed.
- `docs`: `passed` when README, CLAUDE.md, or ROADMAP edits land or explicit skip rationale is documented; `failed` when documentation is known to be out of date; `skipped` when no documentation scope applied.
- `version`: `passed` when plugin manifest version bumps are verified (`bump-version.ps1` completed or version is already correct); `failed` when manifests are out of sync; `skipped` when no version-bump scope applied.
- `releaseTag`: `passed` when the release tag exists on the merged commit or explicit skip rationale exists; `failed` when the tag was expected but is absent; `skipped` when no release-tag scope applied.

Code-Conductor passes this hashtable to `Build-PostPrCreditRow -ChecklistOutcomes @{...}` to emit the `post-pr` credit row into the PR-body pipeline-metrics block.

**Step 9 (close-out record) is deliberately not a key here.** The contract's four keys are the ones `Build-PostPrCreditRow` consumes; adding a fifth would change a shape Code-Conductor already reads. The close-out record is an issue comment written at Step 9, and its absence on an issue that was opened for work is a checklist miss rather than a credit-row outcome.

## Gotchas

| Trigger                                                                    | Gotcha                                                                                 | Fix                                                                                    |
| -------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `git status` shows `.copilot-tracking/` files as untracked                 | These are gitignored local scaffolding, not team artifacts                             | Never `git add` them; use GitHub issues and `Documents/Design/` for durable records    |
| Updating an existing file using `mcp_github_create_or_update_file`         | Tool replaces the entire file; partial content silently truncates to just the new text | Use `replace_string_in_file` + `git commit` + `git push` for existing files            |
| Restoring a file from git history using `Set-Content` or `Out-File`        | PowerShell may add BOM or CRLF causing noisy diffs                                     | Use `git restore --source=<sha> <file>` instead                                        |
| Looking for the `Documents/Design/` file before the PR is merged           | The file is created by Code-Conductor in the PR diff, not in the repo pre-merge        | Check the PR diff, not the repo, for the design doc                                    |
| Version bump using `mcp_github_create_or_update_file` with partial content | Tool replaces entire file; version bump deletes all other content                      | Use `pwsh .github/scripts/bump-version.ps1 -Version X.Y.Z` or `replace_string_in_file` |
| "PR merged — done" without running the cleanup checklist                   | Stale branches persist; related issues stay open; version history unclear              | Run the full post-merge checklist (Steps 1–5) before declaring done                    |
| Skipping the pre-merge strategic assessment (Step 6 / SAR)                 | Missing the window to catch low-quality patterns before they set precedent             | Complete Step 6 SAR before committing to merge on any >Medium impact PR                |
| Archiving tracking files before committing documentation                   | PR created without updated design docs and changelog                                   | Follow checklist order: documentation first, then archive                              |

## Frame Ports Filled By This Skill

| Port | Work adapter | Explicit-skip adapter |
| --- | --- | --- |
| `post-pr` | This `SKILL.md` frontmatter declares `provides: post-pr` | [adapters/post-pr-explicit-skip-adapter.md](adapters/post-pr-explicit-skip-adapter.md) |
