# git, `gh`, worktree and repo-script traps

Traps in the tools this repository uses to inspect state and to write to GitHub. Like the
[PowerShell traps](../../terminal-hygiene/references/powershell-traps.md), these share one property:
**they produce a confident, wrong answer rather than an error.** A green check table for a commit you
have moved past, a "pre-existing failure" verdict that cannot detect the defect it was asked about,
a successful `PATCH` that destroys content nobody will notice is gone.

Read this before reporting CI state, before claiming a failure is pre-existing, before writing to a
GitHub comment body, before trusting a cleanup detector's silence, before running a script across the
Bash/PowerShell boundary, and before bumping the plugin version.

Three sections, in order: establishing what is true about a branch; writing to GitHub; and
worktrees, paths and this repository's own scripts.

## Establishing what is true about a branch

### `git stash` cannot prove a failure is pre-existing

**Trap.** Stashing to "clean" the tree and re-running the suite shelves only *uncommitted* changes.
Every earlier commit already on the branch stays in the tree, so a defect introduced by one of those
commits survives the stash untouched.

**Why it's silent.** The check reports *"reproduces on the unmodified tree"*, which reads as
exoneration but is structurally incapable of detecting a defect that was already committed. There is
no error — just a false negative.

**Fix.** Bisect per commit against the real merge-base, using a **detached worktree per commit**,
created outside the repository root:

```bash
OUT=/some/path/outside/the/repo/bisect
for c in <merge-base> <commit1> <commit2> <HEAD>; do
  rm -rf "$OUT"
  git worktree add --detach "$OUT" "$c"
  (cd "$OUT" && <run the suite>)
  git worktree remove --force "$OUT"
done
```

**Why not `git archive`.** Its output carries no `.git`, so git discovery walks *upward*. Extract
into `.tmp/bisect` inside the repo and every `git rev-parse HEAD`, `git status` and
`git branch --show-current` the suite runs reports the **working tree's** state, identically at all
four commits — so any git-state-dependent assertion is evaluated against the un-bisected tree, and
the loop produces exactly the confident-wrong verdict this section exists to prevent. In this
repository 14 files under `.github/scripts/Tests/` invoke such commands.

**And `git init` in the extract does not rescue it.** An extract plus `git init -q` is an *empty*
repository: measured, `git rev-parse HEAD` exits 128 with `unknown revision`, and `git status`
reports every extracted file as untracked (`?? …`). That trades a wrong answer for a failing one —
still not the commit's real state. A `git archive` extract is only safe for checks that read files
and never ask git anything.

A detached worktree is a genuine checkout: `git rev-parse HEAD` resolves to the commit you meant.

Any "pre-existing" or "unrelated" claim needs a merge-base comparison, never a stash.

`skills/terminal-hygiene/SKILL.md` § Pester Scope states this rule in one line for suite baselines
specifically; this section is the general form and the reasoning behind it.

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
will never fire. Tracked: **#844** owns the YAML parse failure, **#970** owns the retirement deadline.

**Scope.** This entry is specific to this repository. If you are reading it from an installed plugin
copy in another repository, neither `copilot-sunset-review.yml` nor the named real blockers
(`pester`, `frame-enforce`, `release-gate`) exist there, and nothing here licenses dismissing a red
check you actually have. Re-derive the recognition procedure — path-as-name fallback, `event` not
matching the declared triggers, zero jobs — rather than inheriting the verdict.

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
the phase-containment blocks that had been appended to it after the original write. It was caught only because a separate check reported
`GAP -- sustained=16 blocks=11`, and recovered by re-running the original emission script.

**Adjacent accounting gotcha.** `phase-containment-emission-check.ps1` reads a single
`finding_dispositions` block per marker, so a marker carrying two of them reports `sustained` from
only one and produces a false GAP on a legitimately complete ledger. It is warn-only; verify by
listing `finding_key` values rather than trusting the count.

### `-f` and `-F` are different flags, and only `-F` reads files

**Trap.** `-f` is **not** the short form of `--field`. From `gh api --help` (gh 2.80.0):

```text
-F, --field key=value       Add a typed parameter in key=value format
-f, --raw-field key=value   Add a string parameter in key=value format
```

and, of `-F/--field` only:

> if the value starts with `@`, the rest of the value is interpreted as a filename to read the value
> from. Pass `-` to read from standard input.

So `-f body=@-` does not *sometimes* post the literal two characters `@-` — it **always** does,
deterministically and by design, because `--raw-field` performs no `@` expansion at all. Likewise
`-f body=@/path/to/file.md` always posts the literal path string, whether or not the path was
interpolated from a variable and whether or not it was quoted.

**Why it's silent.** The call succeeds and posts *something*. Exit code 0 tells you nothing, and the
posted body is a plausible-looking short string rather than an error.

**Fix.** Use `-F` / `--field` for anything carrying file content, and verify the result:

```bash
gh api -X PATCH repos/{owner}/{repo}/issues/comments/{id} --field body=@- < "$SOME_VAR/path/file.md"
gh api repos/{owner}/{repo}/pulls/{pr}/comments/{id}/replies --field body=@- < reply.md
```

`-F body=@file` is the same flag in short form and is equally correct. Reach for `-f`/`--raw-field`
only when you genuinely want the literal string, including a literal leading `@`.

Verify after **any** write carrying file content — re-fetch the body, or inspect the POST response's
own `.body`, and check it against the intended content rather than the exit code.

**A correction worth carrying.** This entry previously said `-f` and `--field` were "documented as
aliases" and blamed quoting and variable interpolation for the first failure. Both are wrong, and the
error was load-bearing in the unsafe direction: a reader who kept `-f` and merely stopped
interpolating would still corrupt every body they wrote. The flag is the whole cause.

**Seen in:** #886 (corrupted a live issue-comment body) and PR #971 (posted a body that was literally
`@-`; caught in the same turn only because the POST response was inspected).

### `--edit-last` edits the last comment you posted, not the one you mean

**Trap.** `gh issue comment {N} --edit-last` targets the author's most recently posted comment on the
issue. In a burst — plan comment, then engagement comment, then credit comment, then a
phase-containment sibling — the last-posted is the sibling, so an intent to edit the *plan* comment
silently overwrites the *sibling*.

**Why it's silent.** The edit succeeds against a comment. Just the wrong one.

**Fix — for marker-family comments, use the primitive that owns this.**
`skills/session-memory-contract/scripts/persist-marker.ps1` exists precisely to make both this trap
and the previous one unrepresentable: it targets by **numeric REST comment id**, never `--edit-last`.
`Documents/Design/marker-write-primitive.md` files `--edit-last` clobbering and substring
mis-targeting under one failure class and states the rule plainly — *never `--edit-last`; always
targeted by numeric REST comment id*. Reach for the primitive before hand-composing transport.

**`Find-OrUpsertComment` is not a safe default, and carries both hazards.** It targets by marker
**substring** using `-like`, which
`skills/session-memory-contract/references/handoff-markers.md` records as able to *"cause an entirely
wrong comment to be selected as the target for a write"*. And its `-Body` parameter **replaces the
existing body verbatim on the PATCH path** — it never re-reads and merges — so pointing it at a
marker comment a helper has appended to reproduces the destroy-server-side-appends trap in the
section above. The #922 incident that destroyed 16 blocks was exactly a marker-targeted upsert.

If you are hand-writing the call anyway, target by id:

```bash
gh api -X PATCH repos/{owner}/{repo}/issues/comments/{comment_id} -F body=@file --jq '.id'
```

Two Git Bash quirks travel with it: omit the leading slash from the endpoint (`repos/...`, not
`/repos/...`) or MSYS rewrites it into a filesystem path; and `-F body=@file` reads the file as the
field value (see the flag section above — `-f` would post the literal string). Capture each comment's
id from the returned `#issuecomment-{id}` URL at post time so it can be targeted later.

### Round-tripping a body through `gh ... view > file` can mojibake it

**Trap.** On the toolchain PR #829 was written on, `gh pr view N --json body --jq '.body' > file`
OEM-re-encoded non-ASCII characters on the way out, and a subsequent
`gh pr edit N --body-file file` wrote that corrupted text back as the durable body. One round-trip
turned `—`, `§`, `…` and `→` into strings like `Γò¼├┤Γö£├ºΓö£Γòó`; a second double-corrupted it.

The corruption is on the **output** side. The input side reads file bytes faithfully, so a freshly
authored file posts cleanly.

**Scope, because it is version-dependent.** This does **not** reproduce on gh 2.80.0 / pwsh 7.6.3 as
of 2026-08. Five shapes were re-run against a body carrying seven em dashes — Git Bash `>` redirect
(the shell originally named), `gh api` redirect, pwsh `>` at default encoding, and pwsh with
`[Console]::OutputEncoding` pinned to `ibm437` and to `850` — and all five recovered all seven em
dashes with zero mojibake bytes. Treat the prohibition as toolchain-conditional, not a law: verify on
yours before relying on either polarity. The #829 observation is not thereby falsified; it is
undated, which is the defect.

**Fix.** Prefer not to round-trip: rebuild the body from a clean source and post it with
`--body-file`. Where you must, verify by reading back through PowerShell with
`[Console]::OutputEncoding` pinned to UTF-8 first, and grep for the mojibake byte patterns
`Γ`, `╬`, `├`, `┬`.

**On dropping corrupted sections.** Sourcery and CodeRabbit *summary* comments are regenerable, so
dropping a corrupted one of those costs nothing. That is the whole warrant, and it does not
generalize: bot-appended content in another repository may be a coverage delta, a deploy-preview URL,
a signed-CLA record or a compliance attestation, none of which regenerate. Establish that a
particular section regenerates before discarding it.

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

**Owner: [`skills/subagent-env-handshake/SKILL.md`](../../subagent-env-handshake/SKILL.md).** That
skill defines the handshake contract this trap breaks and already carries the sibling CWD hazards; if
you are constructing a dispatch, read it rather than relying on finding this entry.

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

**Fix.** Find the offending prose and reword it apostrophe-free, never touching genuine string
literals or hashtable indexers. **Prose inside a here-string body counts** — the regex scans raw file
text with no awareness of what quoting construct it is inside, so a contraction between `@'` and `'@`
is exactly as dangerous as one in a `#` comment. Only the here-string *delimiters* are safe.

Grep with:

```bash
grep -noE "[a-zA-Z0-9]+'[a-zA-Z]+" <file>
```

**Diagnose before you guess.** The grep lists *candidate* apostrophes; it cannot say which one
desynced, which is why fixing by grep alone takes two or three rounds. Dot-source the audit script's
own functions and print the uncategorized family text — that shows the garbled span directly,
starting right after the last legitimately paired literal and ending at the stray apostrophe:

```powershell
. { . .github/scripts/audit-hub-artifact-paths.ps1 -InputFile 'CLAUDE.md' } *> $null
$yamlPath = Join-Path (Get-Location).Path 'Documents/Design/hub-artifact-paths-classification.yml'
$familyKeys = @(Get-ClassificationFamilyKeys -YamlPath $yamlPath)
$inventory = Build-Inventory -FilePaths (Get-ScopeFiles -Root (Get-Location).Path)
@($inventory | ForEach-Object { $_.path_family } | Sort-Object -Unique) |
  Where-Object { -not (Test-FamilyMatchesYaml -PathFamily $_ -FamilyKeys $familyKeys) }
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

**Owner: [`skills/plugin-release-hygiene/SKILL.md`](../../plugin-release-hygiene/SKILL.md).** It
carries the authoritative occurrence count, the patch/minor/major classification rules and the
guardrail hook. Go there first; what follows is the operational residue that skill does not state,
kept here because it is where a session hits it.

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

### Squash-merge makes ancestry the wrong test

**Trap.** `git cherry` marks every commit on a squash-merged branch `+` — N commits collapse into one
new SHA, so no patch-id survives. So does `git merge-base --is-ancestor`: a squash-merged branch is
never an ancestor of the branch it merged into. Any "is this merged?" check built on either signal
answers **no** for work that shipped.

**Fix.** Use tree equivalence, not ancestry — tree-identical means fully merged:

```bash
git diff --quiet <branch> origin/main
```

**Live signals on one squash-merged branch:**

```text
git merge-base --is-ancestor <branch> origin/main  -> NO   (squash merge)
git diff --quiet <branch> origin/main              -> YES  (tree-identical = fully merged)
git cherry origin/main <branch>                    -> 20 false "unique" commits
```

**What the detector does today.** Issue #922 removed the ancestry pre-filter that used to gate the
current-branch, no-upstream arm. Per `skills/session-startup/SKILL.md`, a current `claude/*`
no-upstream branch is now a candidate on **branch shape alone** — prefix and upstream state — and
candidates are routed through the removal-eligibility check, with eligible and unverifiable ones
surfaced. **Deliberate silence is reserved for definitively-live work.** So an empty cleanup block is
normally a real answer, not a dropped candidate.

An earlier revision of this entry said the opposite — that a squash-merged `claude/*` worktree is
silently dropped and an empty block emitted. That was a *bug report* (#922), and it described
behavior the fix removed. It was promoted here as current behavior, which would have sent operators
hand-checking a detector that now handles this case. That revision also described a second drop path
for `feature/issue-*` worktrees via a failing `@{u}` probe; it is not restated here because it could
not be confirmed against the current detector, which routes both prefixes through the shared
eligibility primitive and reports unverifiable candidates for manual review rather than dropping
them. If you hit a silently-missing candidate, that is a detector bug to file, not a documented
behavior to work around.

**Before deleting anything, four signals, not one.** Tree equivalence alone is not sufficient
authority to delete a branch. The standard is: a merged PR whose `headRefName` matches, the parent
issue closed, the work present on `main` as its squash commit, and the remote branch already gone.
And `git branch -D` is reflog-recoverable **only if you capture the SHA first** — do that before,
not after.

**Cleanup is opt-in and stays opt-in.** The detector only reports; nothing is removed unless the user
confirms. Nothing in this entry authorizes an agent to skip that confirmation, and "check it
yourself" means gather the four signals for the user's decision, not act on one of them.

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
