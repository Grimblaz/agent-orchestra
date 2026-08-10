# Multi-line command-capture audit (issue #977)

**What this records.** Issue #977 was a *wrong-input* defect: PowerShell captures multi-line
external-process stdout as `[System.Object[]]` — one element per line — and `-split` over an array
is vectorized, so `Get-AcRefsFromIssue` and `Get-AcTermsFromIssue` never isolated the
acceptance-criteria section. They read the **second line of the issue body** instead. This file
records which other command-capture sites in the repository share that exposure. **No second live
defect exists** — and the point of this file is to make that claim reproducible rather than
inherited.

Audit run on branch `claude/goal-977-a14fe5`, base `d5f9611`, and revised after adversarial review
of PR #982 found the first revision materially wrong (see § What the first revision got wrong).
Every command below is copy-pasteable and was executed as written.

## The exposure has two halves

A site is exposed only if **both** hold:

1. the captured command emits **multi-line** stdout, and
2. the captured variable is consumed as a **single string** — `-split`, `-match`, `-replace`,
   `[regex]::Matches`, a `[string]` cast, `.Substring(...)` — without being joined first.

Either half alone is harmless. `git diff --name-only` is multi-line but is *meant* to be a list.
`gh repo view --json nameWithOwner --jq '.nameWithOwner'` is fed to `-match` but emits a
single-line scalar, so the capture is a plain `[String]`.

Two joins are NOT equivalent. `-join "\n"` and `| Out-String` reconstruct line structure; a
`[string]` cast joins with `$OFS`, which is a **space**. A `[string]` cast is safe only for
patterns that never anchor to a line.

## What a positive would have looked like

```powershell
$body = gh issue view $N --json body --jq '.body' 2>$null   # multi-line -> Object[]
$parts = $body -split '(?im)^##\s+acceptance criteria\s*$', 2   # vectorized -> wrong result
```

A capture of a **multi-line** field assigned to a variable that is later split or matched with no
`-join`, no `Out-String`, and no line-safe intent. That is exactly the shape the two helpers had.

## The three searches

They are phrased independently on purpose. A single search that could only have returned the sites
already known is not evidence of absence.

**P1 — flag-scoped.** Every `--jq` in any PowerShell file.

```bash
grep -rn --include='*.ps1' -- "--jq" .
```

> `--include` must come **before** `--`. The first revision of this file published
> `grep -rn -- "--jq" --include='*.ps1' .`, where `--` terminates option parsing and `--include`
> becomes a nonexistent file operand: grep errors and the search silently runs unfiltered.

**P2 — assignment-shaped.** Every variable capturing a native command, regardless of flags. Finds
sites P1 structurally cannot: `gh api graphql`, `gh pr view --json comments`, `git diff`,
`git config`, `git show`.

```bash
grep -rnE '^\s*\$[A-Za-z_:][A-Za-z0-9_:]*\s*=\s*\(?\s*(&\s*)?(gh|git|jq)\b' --include='*.ps1' .
```

> The `\(?` is load-bearing and was **missing** from the first revision. Without it, every
> parenthesized capture — `$x = (git ...)`, `$x = (& git ...)` — is invisible. That omission is
> what made the first revision's site table incomplete.

**P3 — consumption-shaped.** Starts from the *string operation* instead of the capture, then keeps
only those whose variable came from a native command and was not joined in between. This is the
only phrasing that can find an exposed site using a tool nobody thought to grep for. Published in
full so the count is reproducible from this record alone:

```powershell
#!/usr/bin/env pwsh
# P3 — consumption-shaped audit for the issue #977 defect class.
# Run from the repository root:  pwsh -NoProfile -File <this-script>
$repo = (Get-Location).Path
$nativeRhs = '=\s*\(?\s*(&\s*)?(\$?\w*[Gg]h\w*|gh|git|jq|pwsh|node|npm)\b'
$strOps = '-split|-match\s|-replace|-notmatch|\.Substring\(|\.IndexOf\(|\.StartsWith\(|\[regex\]::|\[string\]\$'

$files = Get-ChildItem -Path $repo -Recurse -Filter '*.ps1' -File |
    Where-Object { $_.FullName -notmatch '[\\/](node_modules|\.git)[\\/]' }

$hits = [System.Collections.Generic.List[object]]::new()
foreach ($f in $files) {
    $lines = Get-Content -LiteralPath $f.FullName
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch $nativeRhs) { continue }
        if ($lines[$i] -notmatch '^\s*(\$[A-Za-z_:][A-Za-z0-9_:]*)\s*=') { continue }
        $var = $Matches[1]
        if ($var -eq '$null') { continue }
        $escaped = [regex]::Escape($var)
        $joined = $false
        for ($j = $i; $j -lt [Math]::Min($i + 20, $lines.Count); $j++) {
            if ($lines[$j] -match "$escaped\s*-join|-join.*$escaped|$escaped\s*\|\s*Out-String") { $joined = $true }
            if ($j -gt $i -and $lines[$j] -match "$escaped\b" -and $lines[$j] -match $strOps) {
                $hits.Add([PSCustomObject]@{
                    File = ($f.FullName.Substring($repo.Length + 1)).Replace('\', '/')
                    CaptureLn = $i + 1; ConsumeLn = $j + 1; Var = $var; JoinedFirst = $joined
                })
                break
            }
        }
    }
}
"P3 candidates: $($hits.Count)"
$hits | Where-Object { -not $_.JoinedFirst } | ForEach-Object { "{0}:{1} -> :{2}  {3}" -f $_.File, $_.CaptureLn, $_.ConsumeLn, $_.Var }
```

**Measured counts on this branch:** P1 = **31** hits across **22** files; P2 = **126**;
P3 = **43** candidates.

## Every multi-line capture site, and its disposition

Everything P1/P2/P3 returned that is **not** listed here captures a single-line scalar — `.id`,
`.state`, `.login`, `.full_name`, `.nameWithOwner`, `.headRefName`, `.mergedAt`, `.baseRefOid`, a
remote URL, a branch name, a rev-parse SHA, an issue URL — for which array capture cannot occur.

| Site | Captured | Consumed as | Disposition |
| --- | --- | --- | --- |
| `skills/review-judgment/scripts/Get-AcRefsFromIssue.ps1:56` | `--jq '.body'` | `-split` | **Was exposed. Fixed in #977** — joined before the split. |
| `skills/review-judgment/scripts/Get-AcTermsFromIssue.ps1:100` | `--jq '.body'` | `-split` | **Was exposed. Fixed in #977** — joined before the split. |
| `skills/plugin-release-hygiene/scripts/plugin-release-hygiene-hook.ps1:241` | `git show <ref>:<path>` (file content) | `[string]` cast at `:246`, then `[regex]::Matches` at `:249` | **Exposed shape, benign today.** The cast joins with `$OFS` (a space), not a newline, so a line-anchored pattern would misbehave. All five version patterns it runs are within-line. Re-check if any becomes `(?m)^`. |
| `skills/naming-register-policy/scripts/newcomer-audit.ps1:286` | `git show <ref>:<path>` (file content) | joined at `:298` | **Safe, and the reference implementation** — joins with `-join "\n"` *and* pins `[Console]::OutputEncoding` to UTF-8 with a `finally` restore (`:283-290`). This is the only site in the repo that handles both halves. Copy it. |
| `skills/naming-register-policy/scripts/newcomer-audit.ps1:245` | `git diff --diff-filter=ACMR` | list-consumed | Safe — array capture is the correct use. |
| `.github/scripts/frame-credit-ledger.ps1:350` | `git diff --name-only` | list-consumed | Safe — array capture is the correct use. |
| `.github/scripts/migrate-brief-review-corpus.ps1:105` | `gh api --paginate` (multi-line when paginated) | joined via `Out-String` at `:116` | Safe. |
| `.github/scripts/Tests/code-conductor-responsibility-map.Tests.ps1:22` | `--jq .body` | joined at `:27` (`return ($body -join "\n")`) | Safe. Pre-dates #977. |
| `.github/scripts/Tests/path-migration-sweep-gate.Tests.ps1:162`, `:289` | `git ls-files` | `(& git ls-files) -split "\n"` | **Literally both halves of the exposure definition**, benign only because a newline-split of newline-free elements is an identity. Fragile by accident, not by design. |
| `skills/subagent-env-handshake/scripts/New-SubagentDispatchPrompt.ps1:46` | `git status --porcelain` | `Out-String` at the capture site, then `-replace` | Safe — joins at capture. |
| `.github/scripts/Tests/ac-helper-capture-path.Tests.ps1:204` | `--jq '.body'` | inspected, not split | Deliberately **not** joined. It is the harness self-check that asserts the capture arrives as `Object[]`; joining it would defeat its purpose. |

The GitHub Actions workflow `cost-pattern-presence-check.yml` (`:43`, `:75`) also captures
`--jq '.body'`, but in **bash**, where `$( )` yields one string. Not exposed; different language,
not a PowerShell capture. (The first revision of this file also named
`copilot-sunset-review.yml` here — that workflow only captures `--jq 'length'` and
`--jq '.[0].number'`, never `.body`.) That workflow was removed 2026-08-10 by #844; the audited
revision is readable at `git show d610bbe:.github/workflows/copilot-sunset-review.yml`.

## The control: two planted positives

An absence claim needs a check that could have fired — and the control must exercise the shape the
searches are *weakest* at, not the shape they were built around.

**Control 1, unparenthesized** (`$body = gh issue view 1 --json body --jq '.body'` followed by an
unjoined `-split`): written into `.github/scripts/lib/`, all three searches re-run. All three
flagged it. P3 went 39 → 40 and named the file, capture line, and consume line.

**Control 2, parenthesized** (`$body = (& gh issue view 1 --json body --jq '.body' 2>$null)`, same
unjoined split): this is the control the first revision never ran, and it is the one that mattered.

```
original P2 regex  -> 0 hits   (MISSED the plant)
corrected P2 regex -> 1 hit
corrected P3       -> 44 candidates, up from 43, naming the planted file
```

Both plants were deleted after measurement. Without control 2 the counts above would be consistent
with searches structurally incapable of returning the very shape they were meant to rule out.

## What the first revision got wrong

Recorded rather than quietly corrected, because the failure mode is the subject of this file.

1. **P1 did not execute as published** — `--` before `--include`. The reported count of 58
   reproduced under no reading of the command (measured: 27/54 at `d5f9611`, 31/69 at HEAD).
2. **The site table was incomplete and claimed completeness.** Five multi-line captures were
   missing, because P1 is `--jq`-scoped and P2's regex could not match a parenthesized capture.
3. **The planted control validated only the known shape**, so it certified searches that had a
   structural blind spot — the "search that could not have come out positive" trap.
4. **P3 was not in the repository**, so its count could not be re-run from this record. It is now
   published in full above.
5. **A named workflow did not do what it was cited for** (`copilot-sunset-review.yml`).

The *conclusion* — no second live defect — survived all of it, and was independently re-swept twice
during review. But a conclusion that happens to be right is not the same as a record that can be
checked, which is what this file is for.

## If you are adding a new capture site

Two halves, and the second is the one that actually corrupts data.

**Shape.** If the command emits more than one line and you intend to treat the result as text, join
it at the capture site — `-join "\n"` or `| Out-String`. If you intend a list, leave it and say so.
A `[string]` cast is not a newline join; it joins with `$OFS` (a space).

Know one limit of the join: PowerShell's native-output splitter treats a **lone `\r`** as a line
terminator, and `-join "\n"` re-emits it as a real newline. The round trip is lossy in a
semantics-changing direction — a lone CR mid-line can synthesise a markdown header that was not in
the original text. CRLF is unaffected (the `\r` is stripped as part of the terminator). No issue
body in this repository carries a lone CR (measured across the 40 most recent, all states), so this
is a latent hazard, not an observed one.

**Encoding.** On Windows, `[Console]::OutputEncoding` defaults to the OEM codepage, so PowerShell
decodes a UTF-8 subprocess stdout with the wrong table and every multi-byte character is mangled
(measured on issue #968: 12 non-ASCII characters became 36, and every em-dash was lost). Pin it,
and restore it in a `finally` — `skills/naming-register-policy/scripts/newcomer-audit.ps1:283-290`
is the reference implementation. This matters wherever the captured text is persisted rather than
just matched.

**Proving it.** Do not prove such a site with an in-process `gh` function or a script stand-in that
returns one string. Both yield `[String]` with count 1 and pass against broken code. See the header
comment of `.github/scripts/Tests/ac-helper-capture-path.Tests.ps1` for the measured comparison and
for the sentinel technique that distinguishes "my shim answered" from "the real command answered".
