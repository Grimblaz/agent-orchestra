# Multi-line command-capture audit (issue #977)

**What this records.** Issue #977 was a *wrong-input* defect: PowerShell captures multi-line
external-process stdout as `[System.Object[]]` — one element per line — and `-split` over an
array is vectorized, so `Get-AcRefsFromIssue` and `Get-AcTermsFromIssue` never isolated the
acceptance-criteria section. They read the **second line of the issue body** instead. This file
records which other command-capture sites in the repository share that exposure. The answer is
**none** — and the point of this file is to make that claim reproducible rather than inherited.

Audit run on branch `claude/goal-977-a14fe5`, base `d5f9611`. Re-run the three commands below to
reproduce it; the fourth is the control that proves they can come out positive.

## The exposure has two halves

A site is exposed only if **both** hold:

1. the captured command emits **multi-line** stdout, and
2. the captured variable is consumed by a **string operation** — `-split`, `-match`, `-replace`,
   `.Substring(...)` — without being joined first.

Either half alone is harmless. `git diff --name-only` is multi-line but is *meant* to be a list.
`gh repo view --json nameWithOwner --jq '.nameWithOwner'` is fed to `-match` but emits a
single-line scalar, so the capture is a plain `[String]`.

## What a positive would have looked like

```powershell
$body = gh issue view $N --json body --jq '.body' 2>$null   # multi-line -> Object[]
$parts = $body -split '(?im)^##\s+acceptance criteria\s*$', 2   # vectorized -> wrong result
```

A capture of a **multi-line** field assigned to a variable that is later split or matched with no
`-join` and no `Out-String` in between. That is exactly the shape the two helpers had.

## The three searches

They are phrased independently on purpose. A single search that could only have returned the
sites already known is not evidence of absence.

**P1 — flag-scoped.** Every `--jq` in any PowerShell file.

```bash
grep -rn -- "--jq" --include='*.ps1' .
```

**P2 — assignment-shaped.** Every variable capturing a native command, regardless of flags. Finds
sites P1 structurally cannot: `gh api graphql`, `gh pr view --json comments`, `git diff`,
`git config`.

```bash
grep -rnE '^\s*\$[A-Za-z_:][A-Za-z0-9_:]*\s*=\s*(&\s*)?(gh|git|jq)\b' --include='*.ps1' .
```

**P3 — consumption-shaped.** Starts from the *string operation* instead of the capture, then keeps
only those whose variable came from a native command and was not joined in between. This is the
only phrasing that can find an exposed site using a tool nobody thought to grep for. The script is
in the issue #977 working notes; the logic is: match `^\s*$var = [&] (gh|git|jq|pwsh|...)`, then
scan the next 20 lines for `$var` alongside `-split|-match|-replace|.Substring(|.IndexOf(`, and
flag it only when no `-join` appeared first.

**Counts on this branch:** P1 = 58 hits (all file types), P2 = 126, P3 = 39 candidates.

## Every multi-line capture site, and its disposition

These are the only `.ps1` sites where the captured stdout is multi-line. Everything else P1 and P2
returned captures a single-line scalar (`.id`, `.state`, `.login`, `.full_name`, `.nameWithOwner`,
`.headRefName`, `.mergedAt`, a remote URL, an issue URL), for which array capture cannot occur.

| Site | Captured | Disposition |
| --- | --- | --- |
| `skills/review-judgment/scripts/Get-AcRefsFromIssue.ps1:36` | `--jq '.body'` | **Was exposed. Fixed in #977** — joined before the split. |
| `skills/review-judgment/scripts/Get-AcTermsFromIssue.ps1:77` | `--jq '.body'` | **Was exposed. Fixed in #977** — joined before the split. |
| `.github/scripts/Tests/code-conductor-responsibility-map.Tests.ps1:22` | `--jq .body` | Safe — joins at `:27` (`return ($body -join "\n")`). Pre-dates #977. |
| `.github/scripts/Tests/ac-helper-capture-path.Tests.ps1:142` | `--jq '.body'` | Deliberately **not** joined. It is the harness self-check that asserts the capture arrives as `Object[]`; joining it would defeat its purpose. |
| `.github/scripts/frame-credit-ledger.ps1:350` | `git diff --name-only` | Safe — consumed as a list (`Where-Object` / `ForEach-Object`), which is the correct use of an array capture. |
| `skills/subagent-env-handshake/scripts/New-SubagentDispatchPrompt.ps1:46` | `git status --porcelain` | Safe — pipes through `Out-String` at the capture site, which joins. Same shape as the defect, different tool, already correct. |

The GitHub Actions workflows (`cost-pattern-presence-check.yml`, `copilot-sunset-review.yml`) also
capture `--jq '.body'`, but in **bash**, where `$( )` yields one string. Not exposed; different
language, not a PowerShell capture.

## The control: a planted positive

An absence claim needs a check that could have fired. A file with the defective shape was written
to `.github/scripts/lib/`, all three searches were re-run, and all three flagged it (P3 went
39 → 40 candidates and named the planted file, capture line, and consume line). It was then
deleted. Without this step the three counts above would be consistent with three searches that
were simply incapable of returning anything.

```powershell
# the plant, verbatim
$body = gh issue view 1 --json body --jq '.body' 2>$null
$parts = $body -split "(?im)^##\s+acceptance criteria\s*$", 2
return $parts[1]
```

## If you are adding a new capture site

Ask which half you are on. If the command emits more than one line and you intend to treat the
result as text, join it at the capture site — `-join "\n"` or `| Out-String`. If you intend to
treat it as a list, leave it alone and say so. The failure mode is silent: the helpers in this
skill returned plausible-looking results for months.

And do not prove such a site with an in-process `gh` function or a script stand-in that returns one
string. Both yield `[String]` with count 1 and pass against broken code. See the header comment of
`.github/scripts/Tests/ac-helper-capture-path.Tests.ps1` for the measured comparison.
