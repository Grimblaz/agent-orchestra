---
agent: agent
description: "Release wizard — bumps version files, commits, tags, and creates the GitHub release in one coordinated sequence."
---

# Release Wizard

This prompt coordinates the full release sequence: version bump → commit → tag → GitHub release. Run it from the `main` branch after all PRs are merged.

---

## Step 0 — Pre-flight checks

Run these before doing anything else:

1. **Branch check**: Run `git branch --show-current`. If not on `main`, stop and tell the user: "Switch to `main` before creating a release (`git checkout main && git pull`)."

2. **Clean working tree**: Run `git status --short`. If any uncommitted changes exist, stop and tell the user to commit or stash them first.

3. **Current state**: Run these in parallel and display the results:
   - `gh release list --limit 3` — show the last 3 releases
   - `git log --oneline $(git describe --tags --abbrev=0)..HEAD` — show commits since the last tag
   - `pwsh .github/scripts/bump-version.ps1 -Version 0.0.0 -DryRun 2>&1 | Select-String "Current version"` — extract current version from files

   Display the current version, last release tag, and commit list so the user can see what's going into this release.

---

## Step 1 — Determine next version

Ask the user:

> **What type of release is this?**
>
> - `patch` — bug fixes, docs corrections, small tweaks (e.g., 1.9.0 → 1.9.1)
> - `minor` — new features, new agents/skills, non-breaking changes (e.g., 1.9.0 → 1.10.0)
> - `major` — breaking changes, architecture overhauls (e.g., 1.9.0 → 2.0.0)
> - `custom` — enter a specific version manually

Compute the next version from the current version (extracted in Step 0) and the selected bump type. Show the computed version and ask for confirmation before proceeding.

---

## Step 2 — Dry run

Run the version bump in dry-run mode to preview changes:

```powershell
pwsh .github/scripts/bump-version.ps1 -Version {next-version} -DryRun
```

Show the output. If the dry run shows a version drift error (files out of sync), stop and tell the user to resolve the drift manually before proceeding.

---

## Step 3 — Apply version bump

Run the live bump:

```powershell
pwsh .github/scripts/bump-version.ps1 -Version {next-version}
```

Then commit and push:

```powershell
git add .github/plugin/plugin.json .github/plugin/marketplace.json README.md
git commit -m "chore: bump version to {next-version}"
git push
```

---

## Step 4 — Tag the release

```powershell
git tag v{next-version}
git push origin v{next-version}
```

---

## Step 5 — Generate release notes

Before creating the release, draft the release notes. Read the commit list from Step 0 and the PR titles/descriptions for any merged PRs since the last tag:

```powershell
gh log --oneline $(git describe --tags --abbrev=0 HEAD^)..HEAD
```

Format the notes to match the established release pattern:

```markdown
## What's Changed

* {commit or PR summary} by @{author}

## Highlights

**{Feature name (issue #N)}** — {2–3 sentence description of what changed and why}
- {Bullet point detail}
- {Bullet point detail}

**Full Changelog**: https://github.com/Grimblaz/copilot-orchestra/compare/{previous-tag}...v{next-version}
```

Show the drafted release notes and ask the user to confirm or edit before creating the release.

---

## Step 6 — Create GitHub release

Once release notes are confirmed, create the release:

```powershell
gh release create v{next-version} --title "v{next-version}" --notes '{release-notes}'
```

Show the release URL when complete.

---

## Step 7 — Confirm completion

Display a summary:

- ✅ Version bumped: `{previous-version}` → `{next-version}`
- ✅ Committed: `chore: bump version to {next-version}`
- ✅ Tagged: `v{next-version}`
- ✅ Release created: `{release-url}`

Done. No further action required.
