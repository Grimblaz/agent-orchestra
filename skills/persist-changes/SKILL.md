---
name: persist-changes
description: "Git-portable commit+push primitive for applied changes. Caller-parameterized; no Code-Conductor session flags. Use after a validated terminal step to commit staged fix files and push to the current branch's PR head remote. DO NOT USE FOR: new-PR creation (that is Code-Conductor Step 4 git push -u origin); force-push; or any scenario requiring git add -A."
---

<!-- markdownlint-disable-file MD041 -->

## When to Use

- After a validated terminal step that applied changes to the working tree.
- After the CE Gate when one runs (idempotent re-invoke is safe — if no new changes, the helper returns `nothing-to-push`).
- From any orchestrator that has the caller-supplied inputs available.
- From both Code-Conductor review loops and the spine-runner (#678) review loops.

## When Not to Use

- **New-PR creation** — that is Code-Conductor Step 4's `git push -u origin {branch}` + `gh pr create`.
- **Force-push** — this skill never emits `--force` or `--force-with-lease`.
- **When `git add -A` would be required** — the caller must supply the specific file list; bulk-staging is not permitted.
- **From adversarial review passes** (Code-Critic / Code-Review-Response) — persist/push is a non-adversarial action and must not be triggered from within adversarial executor scope.

## Caller Inputs

The executor (orchestrator) must supply all of the following before invoking `Resolve-PersistDecision.ps1`:

| Input | Type | Acquisition |
|---|---|---|
| `fixFiles` | `string[]` | Repo-relative paths to the changed/fixed files. Never `git add -A`. |
| `branch` | `string` | Current branch name from `git branch --show-current`. |
| `isDetached` | `bool` | `true` if `git branch --show-current` returns empty. |
| `defaultBranch` | `string` | Dynamically resolved via `git symbolic-ref refs/remotes/origin/HEAD` (strip `refs/remotes/origin/`) or `gh repo view --json defaultBranchRef --jq .defaultBranchRef.name`. **Never hardcoded.** |
| `headRemote` | `string` | The remote that owns the PR branch. Resolved via `gh pr view --json headRepositoryOwner,headRefName`. Default `origin` on non-fork. |
| `headRemoteWritable` | `bool` | Whether the executor has write access to `headRemote`. Acquired by the executor (side-effecting — not inside the helper). |
| `commitPolicyDisabled` | `bool` | From D12 Commit-Policy read (see `## Commit-Policy Opt-Out`). |
| `hasFixFiles` | `bool` | `true` if `fixFiles` is non-empty. |
| `isUpToDate` | `bool` | `true` if the working tree has no staged/unstaged changes after `git add {fixFiles}`. |
| `nonFastForwardProbe` | `bool` | `true` if `git merge-base --is-ancestor HEAD {headRemote}/{branch}` exits non-zero (after `git fetch {headRemote} {branch}`). **Executor-owned acquisition — NOT computed inside the helper.** |

## Guard Decision Helper (Resolve-PersistDecision.ps1)

The side-effect-free helper lives at `skills/persist-changes/scripts/Resolve-PersistDecision.ps1`. It takes all inputs and returns a decision struct. It performs no git operations itself.

### Inputs

Pass as a hashtable or named parameters:

```text
{ branch, isDetached, defaultBranch, headRemote, headRemoteWritable,
  commitPolicyDisabled, hasFixFiles, isUpToDate, nonFastForwardProbe }
```

Edge case: if `headRemote` is null or empty, treat as `"origin"`.

### Outputs

```text
{ commit: bool, push: bool, push_target_remote: string|null,
  refuse_reason: string|null, not_pushed_reason: string|null,
  manual_instruction: string|null }
```

`push_target_remote` format is the git remote name (e.g. `"origin"`, `"upstream"`), not a URL.

**No force-push field**: the output struct MUST NOT contain a `force` or `forcePush` field. `push=true` always means a standard non-force push.

### `refuse_reason` / `not_pushed_reason` enum (exhaustive)

```text
'detached' | 'default-branch' | 'fork-no-write' | 'non-ff' | 'opt-out' | 'nothing-to-push'
```

### Guard Precedence

Evaluated in this exact order. The first matching condition wins and short-circuits.

1. `isDetached == true`
   → `commit=false, push=false, refuse_reason='detached'`

2. `branch == defaultBranch`
   → `commit=false, push=false, refuse_reason='default-branch'`

3. `!hasFixFiles || isUpToDate`
   → `commit=false, push=false, not_pushed_reason='nothing-to-push'`

4. Else → `commit=true`, then evaluate the push gate in order:

   a. `commitPolicyDisabled == true`
      → `push=false, not_pushed_reason='opt-out'`, set `manual_instruction` to:
      `"Commit-Policy disabled — changes committed to '{branch}'. Push manually: git push {headRemote} HEAD:{branch}"`

   b. `!headRemoteWritable`
      → `push=false, not_pushed_reason='fork-no-write'`

   c. `nonFastForwardProbe == true`
      → `push=false, not_pushed_reason='non-ff'`

   d. Else → `push=true, push_target_remote=headRemote`

## Executor Contract

The orchestrating executor is responsible for the following steps in order.

### Step 1: Acquire side-effecting inputs

Acquire the following before calling the helper (these involve git I/O and must not be inside the pure helper):

- **`nonFastForwardProbe`**: run `git fetch {headRemote} {branch}` then `git merge-base --is-ancestor HEAD {headRemote}/{branch}`. Non-zero exit = `true` (non-ff).
- **`headRemoteWritable`**: attempt a dry-run push (`git push --dry-run {headRemote} HEAD:{branch}`) or use `gh repo view` to confirm write access.

### Step 2: Call `Resolve-PersistDecision.ps1`

Pass all inputs. Capture the output struct.

### Step 3: If `commit=false`

Surface the `refuse_reason` loudly and stop. Do not attempt any git operations. Return the reason to the caller for routing.

### Step 4: If `commit=true`

Execute in order:

1. `git add {fixFiles}` (file list only — never `git add -A`).
2. Load `skills/pre-commit-formatting/SKILL.md` and execute format-before-commit.
3. `git commit -m "fix(#679): apply review-accepted changes"` (or an equivalent commit message reflecting the actual issue and context).

### Step 5: Consume `push_target_remote`

Use exactly the value returned by the helper. Do NOT re-resolve the remote independently.

### Step 6: If `push=true`

`git push {push_target_remote} HEAD:{branch}`

**MUST NOT add `--force` or `--force-with-lease`** to any push command.

On non-zero exit from `git push`, surface the failure loudly — emit git's stderr and exit code to the user. Do not silently absorb a runtime push failure or claim success in the Response Summary.

### Step 7: If `push=false`

Surface the `not_pushed_reason` loudly. If `not_pushed_reason='opt-out'`, emit the `manual_instruction` text verbatim to the user — do not silently drop it.

### Cross-reference note

<!-- related: persist-changes <-> step-commit (separate by design)
  step-commit is VS Code-SCM-coupled and Conductor-scoped and uses a hardcoded
  branch list (skills/step-commit/SKILL.md:28) that DD1 forbids. persist-changes
  is git-portable and uses dynamic default-branch resolution. -->

This executor contract is step-commit separate by design from `skills/step-commit/SKILL.md`. That skill is VS Code-SCM-coupled and Conductor-scoped; this skill is git-portable and designed for use from any orchestrator including the spine-runner.

## Commit-Policy Opt-Out

How to detect `commitPolicyDisabled` (D12 read):

1. Read `.github/copilot-instructions.md` (if it exists).
2. Find the `## Commit Policy` heading via regex `^## Commit Policy`.
3. Under that heading, find the `auto-commit:` line.
4. Value `disabled` (case-insensitive) → `commitPolicyDisabled = true`.
5. Any other value, missing line, or missing file → `commitPolicyDisabled = false`. Log a warning if the heading exists but the `auto-commit:` line is absent or malformed.

When `commitPolicyDisabled = true`:

- The executor **commits** the changes (so work is not lost).
- The executor does **NOT push**.
- The executor emits the `manual_instruction` from the helper verbatim:
  `"Commit-Policy disabled — changes committed to '{branch}'. Push manually: git push {headRemote} HEAD:{branch}"`
- This instruction is emitted loudly — not silently dropped.

## Response Summary Shape

After the persist attempt completes, the executor assembles a Response Summary containing all of the following:

1. **Per-finding disposition summary** — from the review judgment: which findings were accepted, rejected, or escalated.
2. **Commit SHA(s) applied** — from `git rev-parse HEAD` immediately after the commit step.
3. **Push ref/result** — one of:
   - `{headRemote}/{branch}` if push succeeded (standard non-force push).
   - The `not_pushed_reason` value + `manual_instruction` text if push was skipped.
   - `attempted-and-failed: {stderr} (exit {code})` if `git push` executed but returned non-zero — surface loudly; do not claim success.
4. **Explicit not-pushed list** — when any accepted findings were NOT pushed, list each one with its `not_pushed_reason`. This includes the distinct "nothing to push (all deferred/rejected/escalated)" state when zero findings were accepted and `not_pushed_reason='nothing-to-push'`.

## Validation

Run these checks after authoring or modifying this skill:

```sh
markdownlint-cli2 skills/persist-changes/SKILL.md
```

```sh
grep -n "Resolve-PersistDecision" skills/persist-changes/SKILL.md
```

Must find references in both the `## Guard Decision Helper` section and the `## Executor Contract` section.

```sh
grep -n "refuse_reason\|not_pushed_reason" skills/persist-changes/SKILL.md
```

Must find the enum definition.

```sh
grep -n "step-commit" skills/persist-changes/SKILL.md
```

Must find the cross-reference comment in `## Executor Contract`.

```sh
grep -n "pre-commit-formatting" skills/persist-changes/SKILL.md
```

Must find the format-before-commit reference in `## Executor Contract`.

## Related

- `skills/step-commit/SKILL.md` — VS Code-SCM-coupled step commit (separate by design; see executor contract cross-reference note)
- `skills/pre-commit-formatting/SKILL.md` — format-before-commit gate loaded by the executor in Step 4
- `skills/code-review-intake/SKILL.md` — the convergence contract that fires this skill as a terminal step (s5)
- `skills/validation-methodology/references/review-reconciliation.md` — the SSOT for Response Summary shape (s4)
