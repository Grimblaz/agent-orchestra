# Step Commit Protocol

## Purpose

This protocol captures validated step work as discrete commits during Code-Conductor's implementation loop. Each step commit records the pre-formatting validated state with structured metadata (plan reference, agent attribution, validation tier).

Code-Conductor loads this file by reference to keep its own directive count stable.

---

## Protocol

### Step 1 — Opt-out check

Code-Conductor's step commit gate checks `auto_commit_enabled` before loading this file — if opted out, this protocol is never loaded. This step is a documentation cross-reference only; no runtime check is needed here.

### Step 2 — Branch safety

Verify the current branch is not a protected branch:

```powershell
$branch = git branch --show-current
if ($branch -in 'main', 'develop', 'master') {
    Write-Warning "On protected branch '$branch' — skipping step commit"
    return
}
```

If on a protected branch, warn and skip — do not commit.

### Step 3 — File capture

Use `get_changed_files` with filter `sourceControlState: ['unstaged', 'staged']` to detect files with changes. The VS Code SCM model's `'unstaged'` state covers both modified tracked files AND untracked/new files — no separate filter needed.

If no files are detected, skip the commit (nothing to commit).

### Step 4 — Stage files

Stage files using the explicit file list from Step 3 — **never** use `git add -A`:

```powershell
git add "file1.ext" "file2.ext" ...
```

Use the file list from Step 3's `get_changed_files` output. This avoids sweeping unrelated working-tree changes into the step commit.

### Step 5 — Commit

Commit with the `--no-verify` flag (validated state — hooks are unnecessary overhead):

```powershell
git commit --no-verify -m "step(N): {step-title}

Plan: issue-{ID}, Step N of M
Agents: {comma-separated agent list}
Validation: Tier 1 ✅"
```

Where:

- `N` = current plan step number
- `{step-title}` = brief step title from the plan
- `{ID}` = issue number
- `M` = total step count
- `{agent list}` = agents that worked on this step (e.g., `Code-Smith, Test-Writer`)

### Step 6 — SHA recording

After successful commit, record the commit SHA for informational purposes:

```powershell
git rev-parse HEAD
```

The existing post-fix diff recipe `git diff HEAD -- {files}` remains correct — HEAD advances with each step commit, so at post-fix time only specialist fix changes appear as uncommitted.

### Step 7 — Failure handling

Commit failure is **non-blocking** — the step's work is complete regardless.

On failure:

1. Warn in conversation output
2. Increment a consecutive-failure counter (tracked in conversation context)
3. Reset the counter to zero after any successful step commit.
4. If the consecutive-failure counter reaches ≥2, escalate via `#tool:vscode/askQuestions`:

   > Step commits failing repeatedly — check hooks/git state. Continue without auto-commits?
   >
   > (a) Disable auto-commits for remaining steps (set `auto_commit_enabled` to `false` — Code-Conductor's step commit gate checks this flag before loading this protocol)
   > (b) Investigate and retry

5. Report failure status to Code-Conductor so the progress checkpoint annotates the step as `— ✅ DONE (uncommitted)` rather than plain `— ✅ DONE`

---

## Formatting Note

Formatting stays in Code-Conductor's Step 4 (Create PR) — step commits capture the pre-formatting validated state. The formatting gate runs at PR creation time (Step 4), not per step. Pre-commit hooks are bypassed during step commits via `--no-verify`.
