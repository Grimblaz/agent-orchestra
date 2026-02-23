# Post-PR Review Instructions

## Purpose

This document provides a standardized checklist for agents to follow after a Pull Request has been reviewed, approved, and merged. These steps ensure proper cleanup, documentation, and project maintenance.

## When to Use

Execute this workflow **after**:

- Pull Request has been reviewed
- All feedback has been addressed
- PR has been merged to the main branch
- CI/CD pipeline has completed successfully

## Standard Post-Merge Checklist

### 1. Archive Tracking Files

**Action**: Move completed tracking files to archive, then **commit and push the cleanup itself**.

```bash
# Create archive directory for this issue
mkdir -p .copilot-tracking-archive/YYYY/MM/issue-{ID}/

# Move plan and research files
mv .copilot-tracking/plans/issue-{ID}-*.md .copilot-tracking-archive/YYYY/MM/issue-{ID}/
mv .copilot-tracking/research/*{ID}*.md .copilot-tracking-archive/YYYY/MM/issue-{ID}/

# REQUIRED: commit and push the archive move
git add -A
git commit -m "chore: archive tracking files for issue-{ID}"
git push
```

**Critical**: The archive move is a working-tree change. Without `git add` + `git commit` + `git push`, the moved files remain as untracked local changes that are never reflected in the remote repository.

**Verify**:

- Files moved to `.copilot-tracking-archive/YYYY/MM/issue-{ID}/`
- Commit pushed: `git status` shows clean working tree
- No untracked files in `.copilot-tracking-archive/`

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

**Action**: If a version badge in `README.md` (or equivalent) needs updating, use a targeted line edit — **never** the GitHub file API.

```bash
# CORRECT: targeted replace + git commit
# Use replace_string_in_file tool to change only the badge line, then:
git add README.md
git commit -m "chore: bump version badge to vX.Y.Z"
git push
```

**WRONG** (do not use):

```
# mcp_github_create_or_update_file with partial file content
# This tool REPLACES the entire file. Only use it for net-new files.
# Using it with partial content silently truncates the rest of the file.
```

**Rule**: `mcp_github_create_or_update_file` is only safe for **new files**. For any edit to an existing file, use `replace_string_in_file` + `git commit` + `git push`.

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

### 6. Update Project Tracking

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

### 7. Notify Stakeholders (If Applicable)

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
- [ ] Tracking files archived and **committed + pushed** (`git status` clean)
- [ ] Documentation is current and accurate
- [ ] Version badge updated (if version bumped) via `replace_string_in_file` + git — not GitHub file API
- [ ] Release tagged (if applicable) via `git tag` + `git push origin <tag>`
- [ ] GitHub release created with release notes
- [ ] Branches cleaned up
- [ ] Project tracking updated
- [ ] Stakeholders notified (if needed)
- [ ] Working tree clean: `git status` shows no untracked or modified files

## Common Pitfalls to Avoid

1. **Archiving tracking files without committing**

   - The `mv` or `Move-Item` only changes the local working tree
   - Always follow with `git add -A && git commit -m "chore: archive tracking files" && git push`
   - Verify with `git status` — working tree should be clean

2. **Using the GitHub file API to edit existing files**

   - `mcp_github_create_or_update_file` replaces the **entire file**
   - Passing partial content silently truncates the file in the repo
   - Always use `replace_string_in_file` + `git commit` + `git push` for existing files

3. **Using `Set-Content` / `Out-File` to restore files from git history**

   - PowerShell file-write cmdlets may introduce CRLF endings or BOM characters
   - This creates a trivial but visible `+1 -1` diff that VS Code surfaces for review
   - Use `git restore --source=<sha> <file>` instead — git handles encoding correctly

4. **Incomplete documentation updates**

   - Causes confusion for future contributors
   - Creates technical debt

5. **Skipping release tags**

   - Makes version history unclear
   - Complicates rollback procedures

6. **Leaving stale branches**

   - Clutters repository
   - May cause confusion about active work

7. **Not closing related issues**
   - Leaves project tracking inaccurate
   - May cause duplicate work

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
