# git, `gh`, worktree and repo-script traps

Traps in the tools this repository uses to inspect state and to write to GitHub. Like the
[PowerShell traps](../../terminal-hygiene/references/powershell-traps.md), these share one property:
**they produce a confident, wrong answer rather than an error.** A green check table for a commit you
have moved past, a "pre-existing failure" verdict that cannot detect the defect it was asked about,
a successful `PATCH` that destroys content nobody will notice is gone.

Read this before reporting CI state, before claiming a failure is pre-existing, before writing to a
GitHub comment body, and before trusting a cleanup detector's silence.

## Establishing what is true about a branch

### `git stash` cannot prove a failure is pre-existing

**Trap.** Stashing to "clean" the tree and re-running the suite shelves only *uncommitted* changes.
Every earlier commit already on the branch stays in the tree, so a defect introduced by one of those
commits survives the stash untouched.

**Why it's silent.** The check reports *"reproduces on the unmodified tree"*, which reads as
exoneration but is structurally incapable of detecting a defect that was already committed. There is
no error — just a false negative.

**Fix.** Bisect per commit against the real merge-base, materializing each tree with `git archive` so
no working-tree state can contaminate it:

```bash
for c in <merge-base> <commit1> <commit2> <HEAD>; do
  rm -rf .tmp/bisect && mkdir -p .tmp/bisect
  git archive $c | tar -x -C .tmp/bisect
  (cd .tmp/bisect && <run the suite>)
done
```

Any "pre-existing" or "unrelated" claim needs a merge-base comparison, never a stash.

**Seen in:** PR #917. A failure was declared pre-existing on a stash check and filed as its own
issue; bisect showed `origin/main` green at 29/29 and the branch's own commit red at 28/1. The
misfiled issue had to be corrected and closed.

### `git merge-tree` answers a merge-base question, not a containment one

**Trap.** Using "merge-tree merges cleanly **and** the result differs from the remote default" as the
sole producer of a *definitively-unmerged* verdict is wrong whenever the branch shipped and the
default branch later **deleted or renamed** files the branch touched. Merging re-adds the file, the
tree differs, and a fully merged branch reads as unmerged.

Its exit code is overloaded too. A genuine conflict exits 1 **and still writes the merged tree OID to
stdout**; a bad or unresolvable ref also exits 1 but with empty stdout; unrelated histories exit 128
(measured on git 2.50.1). Branching on the exit code alone conflates a gathering failure with a
conflict.

**Why it's silent.** Both failure modes produce a conclusive-looking verdict rather than an error.

**Fix.** Keep a corroborating rung reachable — a merged-PR lookup pinned by OID to the branch's
current tip (a shipped branch whose tip has not moved matches; an in-flight one does not) — and never
let the merge-tree signal short-circuit it.

**Verified sweep, issue #922:**

| shape | verdict |
| --- | --- |
| squash-merged, default later changes unrelated files | merged (merge-tree no-op) — correct |
| squash-merged, file later deleted on default | definitively-unmerged — **wrong** |
| squash-merged, file later renamed on default | definitively-unmerged — **wrong** |
| squash-merged, content later reverted on default | undetermined (conflict) — correct |
| genuinely in-flight | definitively-unmerged — correct |

**Reviewing lesson.** When a change makes a class render *nothing* — deliberate silence — enumerate
everything that can reach that class wrongly. A false positive there is undetectable by construction.

### `gh pr checks` can be green for a commit you have moved past

**Trap.** `gh pr checks <PR>` reports whatever runs exist server-side, keyed to the **last pushed
head SHA**, not local HEAD. Nothing in the output names the SHA it covers.

**Why it's silent.** Mid-review-loop, before changes are pushed, the all-pass table looks reassuring
while describing a commit two fixes ago.

**Fix.** Confirm the SHA explicitly and compare it with local HEAD:

```bash
gh run view <run-id> --json headSha,conclusion --jq '"\(.headSha) \(.conclusion)"'
git rev-parse HEAD
```

Before reporting CI state, either the run's `headSha` equals local HEAD, or say plainly: "CI is green
as of `<sha>`; N local commits are unverified."

**Seen in:** PR #926 — `gh pr checks` showed pester passing while two local fix commits had turned a
required gate red. The run was against `b03d6f6`; local HEAD was `6154ee1`. Combined with a baselining
error it produced a confident, entirely false green, caught only by a judge pass re-deriving the
baseline from the merge-base.

### `copilot-sunset-review.yml` is always red, and gates nothing

**Trap.** `.github/workflows/copilot-sunset-review.yml` shows a failed run in `gh run list` on every
branch including `main`, on every push. It is not caused by your branch.

**How to recognize it.** The run's workflow name falls back to the literal file path rather than its
declared `name:` — GitHub's signature for a workflow file it could not load. `event` is `push` even
though the file declares only `schedule` and `workflow_dispatch`.
`gh api .../actions/runs/{id}/jobs` returns `total_count: 0`, so no job ever starts and
`gh run view --log-failed` reports "log not found".

**It cannot block a merge.** `gh pr checks <PR>` never lists it, so an `UNSTABLE` mergeStateStatus is
never explained by it. Look at `pester`, `frame-enforce` and `release-gate` for real blockers.

**Latent risk, separate from the noise.** The workflow's actual purpose is to fire on or after
2026-08-31 to surface the Copilot retire-or-keep decision. Because GitHub cannot load the file, it
will never fire. If that review matters, the file has to load before that date.

**Evidence:** five-plus consecutive red runs from 2026-08-01 (`7f6baa7`, `d5f9611`, `18a28ba`,
`c43d81d`, `033ed99`), identical on `main`.

## Writing to GitHub

### A `PATCH` from a local file destroys server-side appends

**Trap.** `persist-phase-ledger.ps1` appends `phase-containment-*` blocks **directly to the live
comment**, not to the local scratch file the comment was built from. A later
`gh api -X PATCH ... --field body=@- < local-file` replaces the entire body with the local copy and
destroys every server-side append.

**Why it's silent.** The `PATCH` succeeds and the result looks correct. The destroyed content is
simply gone.

**Fix.** Before patching any comment a helper has written to, re-read the live body and amend
*that*:

```bash
gh api repos/{owner}/{repo}/issues/comments/{id} --jq '.body'
```

Or emit the append *after* the patch. A locally composed body is safe only for a comment nothing else
has touched.

**Seen in:** #922 — amending the `design-phase-complete-922` marker to record an amendment destroyed
**16 phase-containment blocks**. It was caught only because a separate check reported
`GAP -- sustained=16 blocks=11`, and recovered by re-running the original emission script.

**Adjacent accounting gotcha.** `phase-containment-emission-check.ps1` reads a single
`finding_dispositions` block per marker, so a marker carrying two of them reports `sustained` from
only one and produces a false GAP on a legitimately complete ledger. It is warn-only; verify by
listing `finding_key` values rather than trusting the count.

### `-f body=@-` can post the literal string `@-`

**Trap.** Two independent footguns in one call shape:

1. `-f body=@"$SOME_VAR/path/file.md"` — a quoted, variable-interpolated `@filename` — does not
   reliably trigger `gh`'s file-read shorthand. It can send the literal path string as the body.
2. Even the stdin form is flag-sensitive: `gh api ... -f body=@- < file` using the **short** `-f`
   can post the literal two-character string `@-` as the body, although `-f` and `--field` are
   documented as aliases.

**Why it's silent.** Both calls succeed and post *something*. Exit code 0 tells you nothing.

**Fix.** Always use the long `--field` with a stdin redirect, and never interpolate a variable path
inside `@"..."`:

```bash
gh api -X PATCH repos/{owner}/{repo}/issues/comments/{id} --field body=@- < "$SOME_VAR/path/file.md"
gh api repos/{owner}/{repo}/pulls/{pr}/comments/{id}/replies --field body=@- < reply.md
```

Verify after **any** write carrying file content — re-fetch the body, or inspect the POST response's
own `.body`, and check it against the intended content rather than the exit code.

**Seen in:** #886 (corrupted a live issue-comment body) and PR #971 (posted a body that was literally
`@-`; caught in the same turn only because the POST response was inspected).

### `--edit-last` edits the last comment you posted, not the one you mean

**Trap.** `gh issue comment {N} --edit-last` targets the author's most recently posted comment on the
issue. In a burst — plan comment, then engagement comment, then credit comment, then a
phase-containment sibling — the last-posted is the sibling, so an intent to edit the *plan* comment
silently overwrites the *sibling*.

**Why it's silent.** The edit succeeds against a comment. Just the wrong one.

**Fix.** Prefer `Find-OrUpsertComment` (`.github/scripts/lib/find-or-upsert-comment.ps1`), which
targets by marker substring. To edit a specific comment by id:

```bash
gh api -X PATCH repos/{owner}/{repo}/issues/comments/{comment_id} -F body=@file --jq '.id'
```

Two Git Bash quirks travel with it: omit the leading slash from the endpoint (`repos/...`, not
`/repos/...`) or MSYS rewrites it into a filesystem path; and `-F body=@file` reads the file as the
field value. Capture each comment's id from the returned `#issuecomment-{id}` URL at post time so it
can be targeted later.

### Round-tripping a body through `gh ... view > file` mojibakes it

**Trap.** On Windows, `gh pr view N --json body --jq '.body' > file` OEM-re-encodes non-ASCII
characters on the way out, and a subsequent `gh pr edit N --body-file file` writes that corrupted
text back as the durable body.

The corruption is on the **output** side. The input side reads file bytes faithfully, so a freshly
authored file posts cleanly.

**Fix.** Never round-trip. Rebuild the body from a clean source and post it with `--body-file`.
Verify by reading back through PowerShell with `[Console]::OutputEncoding` pinned to UTF-8 first, and
grep for mojibake byte patterns. Bot-appended sections are regenerable, so dropping a corrupted one
is acceptable.

**Seen in:** PR #829 — one round-trip turned `—`, `§`, `…` and `→` into strings like
`Γò¼├┤Γö£├ºΓö£Γòó`; a second round-trip double-corrupted it.

### Verifying a posted body from PowerShell needs a join first

**Trap.** `gh issue view N --json body --jq '.body'` returns multi-line output that PowerShell binds
as a **`string[]` of lines**. So `$b.Length` is the *line count* (a 6 KB body reported `len: 106`),
and `$b -match 'pattern'` returns matching elements — making `[bool](...)` true when *any single
line* matches and false for any pattern spanning a line break.

**Why it's silent.** A negative check such as `if ($b -match 'â€') { 'MOJIBAKE' } else { 'CLEAN' }`
reports CLEAN both when the body is genuinely clean and when the console handed back mangled bytes
that do not match that exact literal. It is structurally unable to distinguish them.

**Fix.** Compare a countable invariant across source and remote in bash, where UTF-8 survives, and
read back with `gh api` rather than `gh issue view`:

```bash
grep -o '—' body.md | wc -l
gh api repos/{owner}/{repo}/issues/N --jq '.body' | grep -o '—' | wc -l
```

Equal counts plus a zero mojibake count is real evidence. If staying in PowerShell, join first.

## Worktrees, paths and repo scripts

### A subagent starts in the parent's *actual* shell pwd

**Trap.** A subagent starts in the main conversation's current working directory — which is the
parent session's real shell pwd, still pinned at the session's launch directory if the parent has
been navigating with `git -C <path>` or absolute paths. Worse, an explicit `cd` in a Bash call does
not persist: the harness resets the shell's cwd after each invocation.

**Consequence.** Subagent shells with a strict Step 0 environment handshake correctly detect the
mismatch and halt with `environment-divergence`. The silence is upstream — nothing warns the
dispatcher that the default-cwd assumption is wrong, so the halt arrives as a surprise.

**Fix.** For any dispatch to a shell with strict handshake verification, instruct it to run
verification as one chained command starting with `cd`, and to prefix every later command the same
way (or use `git -C "<path>"`):

```bash
cd "/absolute/path/to/worktree" && git rev-parse HEAD && git rev-parse --abbrev-ref HEAD && pwd && git status --porcelain | tr -d '\r' | sha256sum | cut -c1-12
```

**Seen in:** #886 — five parallel Code-Critic dispatches all halted this way on the first attempt,
while Senior-Engineer and Doc-Keeper dispatches into the same worktree succeeded, because those
shells self-navigate with an explicit `cd` as their first chained action.

### `/tmp` is not the same directory in Bash and in pwsh on Windows

**Trap.** `/tmp` inside a `pwsh -Command` invocation resolves to `C:\tmp`, which is not where Git
Bash's `/tmp` points. Both accept the literal string without error and resolve to different real
directories.

**Why it's silent.** The PowerShell-side write succeeds; only the later Bash-side read fails, and the
"No such file or directory" looks like an ordinary missing file rather than a path-resolution
divergence.

**Fix.** When a file must cross the Bash/PowerShell boundary, write it to an absolute Windows path
that is unambiguous in both. If a path is already in doubt, look in both `/tmp` and `/c/tmp` before
assuming the write failed.

### A prose apostrophe desyncs the hub-artifact-paths extractor

**Trap.** `audit-hub-artifact-paths.ps1`'s PowerShell path extractor pairs single quotes with a naive
left-to-right regex and has no concept of contractions or possessives. An ordinary apostrophe in a
comment — "don't", "the issue's" — consumes one member of a pairing and desyncs everything after it.
The garbled multi-line span can coincidentally end in a recognized extension and be treated as a
real, phantom path.

**Why it's silent.** The phantom path has no classification entry, so
`hub-artifact-paths-coverage.Tests.ps1` fails with `uncategorized: 1` on a change that looks correct
in every other respect. The failure names nothing about apostrophes.

**Fix.** Find the offending prose and reword it apostrophe-free — comment-only, never touching
genuine string literals, hashtable indexers or here-string delimiters. Grep with:

```bash
grep -noE "[a-zA-Z0-9]+'[a-zA-Z]+" <file>
```

The `0-9` matters: a digit immediately before the apostrophe (`goal-run-halt-core.ps1's`) is a real
hit a letter-only pattern misses.

**Two properties that catch people out.** It is **not diff-scoped** — the regex scans the whole file,
so editing a clean file can break parity for untouched content elsewhere in it; grep and fix the
entire touched file and expect two or three rounds, since each fix can unmask another masked stray.
And baseline against the **merge-base**, never branch HEAD, which can already be regressed.

Markdown and JSON files are unaffected; they use different extractors.

**Seen in:** #866, #912, #951/#956.

### A `$script:` constant does not survive into a cloned runspace

**Trap.** `frame-credit-ledger.ps1` runs work inside a cloned runspace. The clone copies function
definitions plus `Get-Variable -Scope Global` **only** — it never re-runs any file's top-level
dot-source, so `$script:` constants defined at file top level are silently dropped in the worker.

The compounding subtlety: a top-level `$script:` variable *is* global scope under
`pwsh -File script.ps1`, but is **not** under `shell: pwsh` calling `./script.ps1` as a child script —
which is the real production shape in `frame-enforce.yml`. A `-File`-based reproduction therefore
falsely exonerates the code.

**Why it's silent.** A mandatory `[int]` parameter bound to explicit `$null` does not throw — it
coerces to 0. So the unmarshaled constant becomes a zero-second budget, the timeout guard's `-le 0`
branch fires an instant synthetic `TimedOut`, and no fail-open catch runs because nothing threw.
`cost-session-render.ps1`'s own comment asserted the opposite.

**And the suite cannot see it.** Every assertion in `cost-telemetry-budgets.Tests.ps1` was either a
static match on file *text* or an inline dot-sourced call — neither crosses a runspace boundary.
**3818 of 3818 tests passed while production was 100% broken.**

**Fix.** Two mechanisms, chosen deliberately:

1. Re-dot-source inside the worker — correct for constants-only, side-effect-free, idempotent files:

   ```powershell
   . (Join-Path $RepoRootArg 'path/to/file.ps1')
   ```

2. Extend `Get-FCLCostScriptState`'s marshal list — reserved for values living in function-heavy
   files that are unsafe to re-source in a worker.

A correct test for this class builds a real clone and runs the actual extracted worker script block
inside it. Verify with a child-script invocation, never `-File`.

**Seen in:** #496 C-1 and #825 C3 — two independent bugs of this exact class have shipped.

### Bump the version with the script, as the last commit

**Trap.** Hand-editing any one of the version-string occurrences — across `plugin.json`,
`.claude-plugin/plugin.json`, both marketplace manifests and the `README.md` badge — leaves the repo
release-blocked. The next `bump-version.ps1` invocation aborts with "Version drift detected" before
doing any work, at a point disconnected from the original edit.

**Fix.** Always run the script, which rewrites every occurrence atomically and hard-fails on any
existing disagreement:

```powershell
& .github/scripts/bump-version.ps1 -Version X.Y.Z
```

To recover from existing drift, revert the lone hand-edit to restore a single uniform value, *then*
bump. Never hand-edit the others to match.

**Timing.** Bump as the **last commit before `gh pr create`**, not deferred to "PR finalization".
Deferring it is how a PR ships with red CI. Default to `patch` and surface `minor`/`major` as
explicit maintainer overrides.

**Quoting.** A multi-line `-ChangelogEntry` passed inline from the Bash tool mangles into "Missing an
argument for parameter". Write the entry to a file, then read it inside a single `pwsh -Command`
block.

**Seen in:** PR #781 (a manual one-file bump became a high-severity release-blocking review finding)
and PR #926 (flagged mid-implementation, deferred, then never done — shipping red CI).

### `post-merge-cleanup.ps1` must run from the primary checkout

**Trap.** The script runs `git checkout main` internally. Inside any worktree that fails with
`fatal: 'main' is already used by worktree at ...` and the script aborts with exit 128.

Array arguments are a second trap: `pwsh -File script.ps1 -SiblingWorktrees @('a','b')` lets the
calling shell expand the literal into separate argv entries, `-File` binds only the first, and the
rest spill onto the next positional parameter — which fails binding because a path cannot convert to
int. **The tell is that the worktrees are all still present afterwards.**

**Fix.** Change to the primary checkout first, verify it is clean, and invoke with the call operator
rather than a nested `pwsh -File`:

```powershell
& 'C:\path\to\worktree\skills\session-startup\scripts\post-merge-cleanup.ps1' -SiblingWorktrees @('C:/…/a','C:/…/b')
```

Do not paste the hook's own emitted `pwsh '<path>' -SiblingWorktrees @(…)` block verbatim — it has
the same defect. When handing such a command to a person, fence it as `powershell`, not `bash`: a
bash fence gets a Run button that mangles `@(…)`.

### Squash-merge defeats the cleanup detector's ancestry test

**Trap.** `git cherry` marks every commit on a squash-merged branch `+` — N commits collapse into one
new SHA, so no patch-id survives. Auto-resolve is therefore effectively dead for any multi-commit
branch, and everything ages into manual review. That part is fail-safe.

The silent part is the **detector**: its current-branch, no-upstream arm gates on a merge-base
ancestry test, which squash-merge always fails, so a squash-merged `claude/*` worktree is dropped
without being surfaced and an **empty cleanup block** is emitted — even though the cleanup script,
given the same worktree, evaluates it correctly.

`feature/issue-*` worktrees are dropped by a second, unrelated mechanism: a merged-but-still-present
worktree is never prunable, so it takes the `@{u}` upstream probe; `fetch --prune` has deleted the
remote-tracking ref, so the probe exits 128, the upstream variable becomes null, and control falls
past the upstream-deleted arm into a no-upstream arm whose prefix list is `claude/` only. No match,
silent `continue`.

**Fix.** After any squash-merge, do not read an empty detector block as "nothing to clean". Check it
yourself — tree-identical means fully merged:

```bash
git diff --quiet <branch> origin/main
```

Then invoke the script directly with the explicit parameters. `git cherry` is useless for this
decision.

**Live signals on one squash-merged branch:**

```text
git merge-base --is-ancestor <branch> origin/main  -> NO   (squash merge)
git diff --quiet <branch> origin/main              -> YES  (tree-identical = fully merged)
git cherry origin/main <branch>                    -> 20 false "unique" commits
```

**Note.** Removing the worktree you are currently sitting in leaves an empty root directory Windows
will not release while the shell holds it as cwd. The script reports this honestly as
`removed-partial-root-held`; the worktree is genuinely deregistered and the branch deleted, and the
directory clears when the session ends. That is not a failure.

**Seen in:** #922, #889, #513, #874, #893.
