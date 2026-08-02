#Requires -Version 7.0
<#
.SYNOPSIS
    Extracts acceptance-criterion file-path references from a GitHub issue body.

.DESCRIPTION
    Companion helper to Test-DeferralCriteria.ps1 / Get-StructuralVerdict (M11).
    The conductor calls this before invoking Get-StructuralVerdict so the
    -AcRefs parameter can be populated for AC cross-check precedence (AC2).

    The function reads the issue body via `gh issue view`, isolates the
    `## Acceptance Criteria` H2 section, and extracts backtick-quoted
    file-path-like tokens. Returns a unique, sorted string array.

    Returns an empty array on any failure (missing gh, missing section,
    no matches) so callers can pass the result directly to -AcRefs
    without null checks.
#>

function Get-AcRefsFromIssue {
    param(
        [Parameter(Mandatory=$true)]
        [string]$IssueNumber
    )

    # Read issue body via gh; suppress stderr so missing gh / missing issue
    # collapse to an empty body rather than a hard failure.
    #
    # `--jq '.body'` emits RAW MULTI-LINE TEXT, and PowerShell captures
    # multi-line external-process stdout as [System.Object[]] — one element per
    # line. The section split below is vectorized over an array, so an unjoined
    # capture never isolates the section and `$parts[1]` becomes the body's
    # SECOND LINE. Join first (issue #977). Do not remove the join, and do not
    # prove this path with an in-process `gh` function: a function mock returns
    # a single string and cannot reproduce the array capture at all.
    $bodyLines = gh issue view $IssueNumber --json body --jq '.body' 2>$null
    $body = @($bodyLines) -join "`n"
    if (-not $body) { return @() }

    # Isolate the ## Acceptance Criteria section (case-insensitive, multiline).
    $parts = $body -split "(?im)^##\s+acceptance criteria\s*$", 2
    if ($parts.Count -lt 2) { return @() }
    $acSection = $parts[1]

    # Cut off at the next H2 header so we don't leak into later sections.
    $acSection = ($acSection -split "(?m)^##\s", 2)[0]

    # Extract backtick-quoted file paths with code-relevant extensions.
    $extensionPattern = 'ps1|md|json|yml|yaml|xml|sql|ts|tsx|js|jsx|py|cs|java|go|rs'
    $regex = "``([a-zA-Z0-9_\-./]+\.(?:$extensionPattern))``"
    $matches = [regex]::Matches($acSection, $regex)
    if ($matches.Count -eq 0) { return @() }

    $paths = $matches | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    return @($paths)
}
