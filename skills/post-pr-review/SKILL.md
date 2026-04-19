---
name: post-pr-review
description: "Post-merge checklist for archiving, documentation, versioning, and release tagging. Use when completing post-merge cleanup, archiving tracking files, updating docs, or running the pre-merge strategic assessment (Step 6). DO NOT USE FOR: pre-PR readiness checks (use verification-before-completion) or processing GitHub review comments (use code-review-intake)."
---

## When to Use

Execute this workflow **after**:

- Pull Request has been reviewed
- All feedback has been addressed
- PR has been merged to the main branch
- CI/CD pipeline has completed successfully

Or use the strategic assessment section only (Step 6) **before merging** to evaluate design alignment and long-term implications before approving a PR.

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

> **Automation**: The `.github/copilot-instructions.md` "Session Startup Check" detects stale tracking files and prompts you at the start of your next conversation — cleanup requires one confirmation. You can also run the script directly: `pwsh "skills/session-startup/scripts/post-merge-cleanup.ps1" -IssueNumber {ID} -FeatureBranch feature/issue-{ID}-description` (script path is relative to the agent-orchestra plugin or repo clone).

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

The script updates `plugin.json`, `marketplace.json` (2 occurrences), and `README.md` (badge line) — 4 occurrences total. It validates pre-bump consistency and exits with an error if any file has drifted.

**Plugin-only users** (scripts not distributed via plugin): If you're using this workflow as a plugin install without cloning, use targeted `replace_string_in_file` edits for each file individually, then commit and push.

**WRONG** (do not use):

```
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

**Action**: Update external project management tools if used.

**Common Tools**:

- GitHub Projects - Move cards to "Done"
- Issue trackers - Close related issues
- Sprint boards - Update sprint progress
- Team dashboards - Reflect completion

**Verification**:

- [ ] Related issues closed or updated
- [ ] Project board reflects current state
- [ ] No orphaned or stale references

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

## Validation Checklist

Before considering work fully complete, verify:

- [ ] All tests passing in main branch
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

- Mark the original issue as closed
- Remove any temporary resources
- Archive any temporary documentation
- Update team status boards

The work is now fully complete and properly documented.

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
