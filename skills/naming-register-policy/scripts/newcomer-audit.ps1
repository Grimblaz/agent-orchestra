#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    CLI wrapper for the newcomer-audit detector (issue #751, plan step s3).

.DESCRIPTION
    Dot-sources skills/naming-register-policy/scripts/newcomer-audit-core.ps1 and
    exposes two mutually exclusive input modes:

      -Path <files>   Whole-file scan carrying issue-body escape-hatch semantics.
                       Used by the draft-scan seam on wholly new prose (e.g. a
                       drafted issue body) -- an unexpanded stable code always
                       requires first-use expansion to suppress on this surface.

      -Changed        Repo-file scan over the files this branch changed, carrying
                       repo-file escape-hatch semantics. Runs
                       `git diff --diff-filter=ACMR $(git merge-base main HEAD)..HEAD`
                       (merge-base, NOT two-dot `main..HEAD` against the branch tip
                       -- so an advanced `main` does not misreport; ACMR, not ACM,
                       so a renamed-and-edited file is still included in the diff),
                       filtered to the human-facing surface class list from
                       skills/naming-register-policy/SKILL.md (CLAUDE.md, READMEs,
                       skill SKILL.md files carrying `description:` frontmatter,
                       Documents/Design/ orientation docs, issue/PR templates,
                       HOW-IT-WORKS.md).

    Load-bearing split in -Changed mode (plan-issue-751 MF5, sustained on
    adversarial review): escape-hatch suppression is evaluated against the FULL
    post-image file content read via `git show HEAD:<path>` -- so a vocab-pointer
    link living in a file's footer still suppresses a term even when the changed
    line is elsewhere in the file -- but findings are then filtered down to only
    those whose line number falls inside an added/modified diff hunk. A finding
    that exists only on an unchanged line of a touched file is never emitted.

    Output: by default, prints a human-readable summary (findings grouped by
    file) followed by a JSON array of the same findings. Pass -Json to suppress
    the human-readable summary and emit only the JSON array (for machine
    consumption / piping into a parser). Exit code is 1 if any findings exist,
    0 otherwise -- nothing consumes this exit code yet in v1; it is specified for
    future seams (draft-scan warn-only lane, PR-gate warn-only lane in s5). Exit
    code 2 signals a usage or operational error (bad arguments, missing file,
    git failure) and is distinct from both.

    Assumption (documented, not enforced): -Changed mode compares merge-base..HEAD
    diff hunks (from the commit graph) against `git show HEAD:<path>` content (also
    from the commit graph), so it is correct regardless of working-tree state. This
    matches its intended invocation context: Code-Conductor's PR-creation gate,
    where the branch has already been committed.

.PARAMETER Path
    One or more file paths to scan whole-file, issue-body escape-hatch semantics.

.PARAMETER Changed
    Scan files changed on this branch since it diverged from main, repo-file
    escape-hatch semantics, emission scoped to added/modified lines.

.PARAMETER Json
    Emit only the JSON findings array (suppresses the human-readable summary).

.EXAMPLE
    pwsh skills/naming-register-policy/scripts/newcomer-audit.ps1 -Path draft-issue-body.md

.EXAMPLE
    pwsh skills/naming-register-policy/scripts/newcomer-audit.ps1 -Changed -Json
#>

[CmdletBinding()]
param(
    # -Path and -Changed are intentionally NOT split into distinct
    # ParameterSetNames: that would make PowerShell's own parameter binder
    # reject "-Path x -Changed" with an ambiguous-parameter-set error before
    # this script's body ever runs, pre-empting the deterministic exit-code-2
    # usage validation below (and its own test coverage). Both mutual
    # exclusivity and "neither supplied" are validated manually instead.
    [string[]]$Path,

    [switch]$Changed,

    [switch]$Json
)

. (Join-Path $PSScriptRoot 'newcomer-audit-core.ps1')

function Test-NewcomerAuditSurfaceClassPath {
    <#
    .SYNOPSIS
        True when a repo-relative path belongs to the human-facing prose surface
        class list from skills/naming-register-policy/SKILL.md § Human-Facing
        Prose Surfaces.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $normalized = $Path -replace '\\', '/'

    if ($normalized -eq 'CLAUDE.md') { return $true }
    if ($normalized -eq 'HOW-IT-WORKS.md') { return $true }
    if ($normalized -match '(^|/)README(\.[A-Za-z0-9]+)?$') { return $true }
    if ($normalized -match '^skills/[^/]+/SKILL\.md$') { return $true }
    if ($normalized -match '^Documents/Design/') { return $true }
    if ($normalized -match '^\.github/(ISSUE_TEMPLATE|PULL_REQUEST_TEMPLATE)(/|$)') { return $true }
    if ($normalized -match '^\.github/.*_TEMPLATE\.md$') { return $true }

    return $false
}

function ConvertTo-NewcomerAuditParsedDiff {
    <#
    .SYNOPSIS
        Parses `git diff` unified-diff text into per-file added-line sets.

    .DESCRIPTION
        Tracks the new-file (post-image) line cursor per hunk (`@@ -a,b +c,d @@`)
        and records only lines that start with '+' (excluding the '+++' file
        header) as added. Context lines (' ') advance the cursor without being
        recorded; removed lines ('-') do not advance the new-file cursor at all.
        File identity is taken from the '+++ b/<path>' line, which is the
        post-image path git already emits for adds/copies/modifies.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$DiffLines
    )

    $files = @()
    $current = $null
    $newLineCursor = 0

    foreach ($line in $DiffLines) {
        if ($line -match '^diff --git ') {
            if ($current) { $files += $current }
            $current = $null
            $newLineCursor = 0
            continue
        }

        # Only treat '+++ b/...' as a genuine file header when it immediately
        # follows a 'diff --git' reset (i.e. $current is still null/freshly
        # reset here). An ADDED PROSE LINE that happens to quote diff syntax
        # verbatim (e.g. a design-doc example showing '+++ b/foo.md') is
        # otherwise indistinguishable from a real header by text alone, and
        # would wrongly reset the parser's current-file state and discard
        # the real file's already-accumulated added-line record. When
        # $current is already established, such a line falls through to the
        # normal '+' added-line handling below instead.
        if ((-not $current) -and ($line -match '^\+\+\+ b/(.+)$')) {
            $current = [pscustomobject]@{
                Path       = $Matches[1].TrimEnd("`t")
                AddedLines = [System.Collections.Generic.HashSet[int]]::new()
            }
            continue
        }

        if (-not $current) { continue }

        if ($line -match '^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@') {
            $newLineCursor = [int]$Matches[1]
            continue
        }

        if ($line.StartsWith('+')) {
            [void]$current.AddedLines.Add($newLineCursor)
            $newLineCursor++
            continue
        }

        if ($line.StartsWith('-')) {
            continue
        }

        if ($line.StartsWith(' ')) {
            $newLineCursor++
            continue
        }

        # Other marker lines (e.g. "\ No newline at end of file", a
        # "Binary files ... differ" summary line with no hunks): no-op.
    }

    if ($current) { $files += $current }

    return , @($files)
}

function Get-NewcomerAuditMergeBase {
    <#
    .SYNOPSIS
        Resolves the merge-base commit of 'main' and 'HEAD' -- the corrected,
        non-misreporting basis for the -Changed diff (plan-issue-751 AC7).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot
    )

    Push-Location $RepoRoot
    try {
        $result = & git merge-base main HEAD 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($result -join ''))) {
            throw "newcomer-audit: could not resolve merge-base of 'main' and 'HEAD' -- is there a local 'main' branch?"
        }
        return ($result | Select-Object -First 1).ToString().Trim()
    }
    finally {
        Pop-Location
    }
}

function Get-NewcomerAuditRawDiff {
    <#
    .SYNOPSIS
        Runs `git diff --diff-filter=ACMR <MergeBase>..HEAD` and returns the raw
        unified-diff text as a line array. ACMR (not ACM) so a renamed-and-edited
        file (high-similarity rename+edit) is still included -- ACM alone
        silently excludes renames from the diff output entirely.

    .DESCRIPTION
        Takes the already-resolved merge-base commit as an explicit parameter
        (rather than re-resolving 'main' itself) so callers -- and tests -- can
        prove the diff never runs against the literal branch name 'main..HEAD'.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        [string]$MergeBase
    )

    Push-Location $RepoRoot
    try {
        $range = "$MergeBase..HEAD"
        $diffLines = & git diff --diff-filter=ACMR $range 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "newcomer-audit: git diff failed for range '$range'."
        }
        if ($null -eq $diffLines) { return , @() }
        return , @($diffLines)
    }
    finally {
        Pop-Location
    }
}

function Get-NewcomerAuditGitShowContent {
    <#
    .SYNOPSIS
        Reads a file's full post-image content at a given ref via `git show`.

    .DESCRIPTION
        Used for -Changed mode's suppression context: this returns the complete
        committed file so a footer vocab-pointer link suppresses correctly even
        when the diff only touched an earlier line. Returns $null if the ref:path
        cannot be resolved (e.g. a binary file diff artifact).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        [string]$Ref,

        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    Push-Location $RepoRoot
    try {
        $previousEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        try {
            $lines = & git show "${Ref}:${RelativePath}" 2>$null
        }
        finally {
            [Console]::OutputEncoding = $previousEncoding
        }

        if ($LASTEXITCODE -ne 0) {
            return $null
        }
        if ($null -eq $lines) {
            return ''
        }
        return ($lines -join "`n")
    }
    finally {
        Pop-Location
    }
}

function Format-NewcomerAuditSummary {
    <#
    .SYNOPSIS
        Renders decorated findings (with a 'file' property) as a human-readable
        summary grouped by file.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Findings
    )

    if (-not $Findings -or $Findings.Count -eq 0) {
        return 'newcomer-audit: no findings.'
    }

    $lines = @()
    foreach ($group in ($Findings | Group-Object -Property file)) {
        $lines += "File: $($group.Name)"
        foreach ($finding in ($group.Group | Sort-Object line, token)) {
            $lines += "  Line $($finding.line): $($finding.token) [$($finding.register_state)] -- $($finding.suggestion)"
        }
    }

    return ($lines -join "`n")
}

function ConvertTo-NewcomerAuditFindingsJson {
    <#
    .SYNOPSIS
        Serializes decorated findings to a JSON array string, always -- even
        for zero findings.

    .DESCRIPTION
        `@() | ConvertTo-Json -AsArray` returns $null (not '[]') when zero
        objects flow through the pipeline in this PowerShell version -- piping
        an empty collection into a cmdlet skips its output entirely, which
        -AsArray does not compensate for. Handle the zero-findings case
        explicitly so callers always get parseable JSON array text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Findings
    )

    if (-not $Findings -or $Findings.Count -eq 0) {
        return '[]'
    }

    return ($Findings | ConvertTo-Json -Depth 6 -AsArray)
}

# Guard the CLI entry point so dot-sourcing this file (as the Pester wrapper
# tests do) only defines functions/params -- it never shells out to git or
# calls `exit`, which would otherwise terminate the whole hosting process.
if ($MyInvocation.InvocationName -ne '.') {

    if (-not $Path -and -not $Changed) {
        Write-Error 'newcomer-audit: specify either -Path <files> or -Changed.'
        exit 2
    }
    if ($Path -and $Changed) {
        Write-Error 'newcomer-audit: -Path and -Changed are mutually exclusive.'
        exit 2
    }

    $registerPath = Join-Path $PSScriptRoot '../assets/register.json'
    if (-not (Test-Path -Path $registerPath)) {
        Write-Error "newcomer-audit: register asset not found at '$registerPath'."
        exit 2
    }

    try {
        $register = Get-Content -Path $registerPath -Raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Error "newcomer-audit: register asset at '$registerPath' failed to parse as JSON -- $($_.Exception.Message)"
        exit 2
    }

    if ($null -eq $register -or @($register).Count -eq 0) {
        Write-Error "newcomer-audit: register asset at '$registerPath' parsed to empty or null content."
        exit 2
    }

    foreach ($row in $register) {
        $hasInstancePattern = ($row.PSObject.Properties.Name -contains 'instance_pattern') -and `
            -not [string]::IsNullOrWhiteSpace($row.instance_pattern)
        if (-not $hasInstancePattern) {
            continue
        }

        try {
            [regex]::new($row.instance_pattern) | Out-Null
        }
        catch {
            Write-Error "newcomer-audit: register row '$($row.term)' has an invalid instance_pattern -- $($_.Exception.Message)"
            exit 2
        }
    }

    $allFindings = @()

    if ($Path) {
        foreach ($p in $Path) {
            if (-not (Test-Path -Path $p)) {
                Write-Error "newcomer-audit: path not found -- $p"
                exit 2
            }

            if (Test-Path -Path $p -PathType Container) {
                Write-Error "newcomer-audit: path is a directory, expected a file -- $p"
                exit 2
            }

            $resolved = (Resolve-Path -Path $p).Path
            $fileFindings = Get-NewcomerAuditFindingsFromFile -Path $resolved -Surface 'issue-body' -Register $register
            foreach ($f in $fileFindings) {
                $allFindings += [pscustomobject]@{
                    file           = $p
                    line           = $f.line
                    token          = $f.token
                    register_state = $f.register_state
                    suggestion     = $f.suggestion
                }
            }
        }
    }
    else {
        $gitTopLevel = & git rev-parse --show-toplevel 2>$null
        $repoRoot = if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($gitTopLevel -join ''))) {
            ($gitTopLevel | Select-Object -First 1).ToString().Trim()
        }
        else {
            (Get-Location).Path
        }

        try {
            $mergeBase = Get-NewcomerAuditMergeBase -RepoRoot $repoRoot
            $diffLines = Get-NewcomerAuditRawDiff -RepoRoot $repoRoot -MergeBase $mergeBase
        }
        catch {
            Write-Error $_.Exception.Message
            exit 2
        }

        $parsedFiles = ConvertTo-NewcomerAuditParsedDiff -DiffLines $diffLines

        foreach ($changedFile in $parsedFiles) {
            if ($changedFile.AddedLines.Count -eq 0) { continue }
            if (-not (Test-NewcomerAuditSurfaceClassPath -Path $changedFile.Path)) { continue }

            $content = Get-NewcomerAuditGitShowContent -RepoRoot $repoRoot -Ref 'HEAD' -RelativePath $changedFile.Path
            if ($null -eq $content) { continue }

            # -AllOccurrences: a genuinely new occurrence of a term on an
            # ADDED line must not be silently dropped just because an
            # earlier, unchanged occurrence of the same term exists
            # elsewhere in the file (first-occurrence-only would otherwise
            # filter it out before the added-lines check below ever runs).
            $fileFindings = Get-NewcomerAuditFindings -Content $content -Surface 'repo-file' -Register $register -AllOccurrences
            foreach ($f in $fileFindings) {
                if ($changedFile.AddedLines.Contains([int]$f.line)) {
                    $allFindings += [pscustomobject]@{
                        file           = $changedFile.Path
                        line           = $f.line
                        token          = $f.token
                        register_state = $f.register_state
                        suggestion     = $f.suggestion
                    }
                }
            }
        }
    }

    $allFindings = @($allFindings | Sort-Object file, line, token)

    if (-not $Json) {
        Write-Output (Format-NewcomerAuditSummary -Findings $allFindings)
    }

    Write-Output (ConvertTo-NewcomerAuditFindingsJson -Findings $allFindings)

    if ($allFindings.Count -gt 0) {
        exit 1
    }
    exit 0
}
