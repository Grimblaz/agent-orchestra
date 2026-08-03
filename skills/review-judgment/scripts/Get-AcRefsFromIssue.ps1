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
    file-path-like tokens. Returns a unique, sorted collection of strings.

    Returns empty on any failure (unresolvable gh, gh error, missing section,
    no matches) so callers can pass the result directly to -AcRefs without
    null checks.

    RETURN SHAPE — exact, because two of these are easy to assert wrongly:
      * no results   -> `@()`, which PowerShell collapses on assignment, so a
                        caller's `$x = Get-AcRefsFromIssue ...` sees $null, not
                        an empty array. `@($x).Count` is 0 either way.
      * ONE result   -> unrolls to a bare [string], NOT a one-element array.
      * two or more  -> [System.Object[]] of [string].
    All three bind correctly to `Get-StructuralVerdict -AcRefs`, which declares
    [string[]] and coerces. Callers that do their own indexing or type checks
    must wrap in @(). Verified by test, not assumed (issue #977).
#>

function Get-AcRefsFromIssue {
    param(
        [Parameter(Mandatory=$true)]
        [string]$IssueNumber
    )

    # Read issue body via gh.
    #
    # Two distinct failure modes, and `2>$null` only covers one of them:
    #   * gh EXISTS and fails (bad issue, no auth, network) -> stderr is
    #     redirected, stdout is empty, execution continues.
    #   * gh is UNRESOLVABLE (not installed, not on PATH) -> PowerShell's own
    #     command lookup throws CommandNotFoundException BEFORE any process
    #     starts. `2>$null` cannot suppress that; without the catch below the
    #     helper throws and the caller's next statement never runs, which
    #     contradicts the empty-on-any-failure contract above. Callers pass
    #     this result straight into Get-StructuralVerdict with no try/catch.
    #
    # `--jq '.body'` emits RAW MULTI-LINE TEXT, and PowerShell captures
    # multi-line external-process stdout as [System.Object[]] — one element per
    # line. The section split below is vectorized over an array, so an unjoined
    # capture never isolates the section and `$parts[1]` becomes the body's
    # SECOND LINE. Join first (issue #977). Do not remove the join, and do not
    # prove this path with an in-process `gh` function: a function mock returns
    # a single string and cannot reproduce the array capture at all.
    try {
        $bodyLines = gh issue view $IssueNumber --json body --jq '.body' 2>$null
        # gh EXISTS-and-fails does not throw — it sets $LASTEXITCODE and leaves
        # stdout empty, which the -not $body check below already collapses to
        # the same @() return as a genuinely empty issue body (the documented
        # contract, unchanged here). Checked anyway, matching this repo's
        # dominant gh-capture convention, so a -Verbose run can tell "gh
        # failed" from "issue body is empty" instead of guessing from output
        # alone.
        #
        # Read via Get-Variable, not a bare $LASTEXITCODE reference. In an
        # in-process test harness that mocks `gh` as a PowerShell function
        # (every existing suite for THIS repo except the real-capture one),
        # no native process ever runs and $LASTEXITCODE is never set in this
        # scope. Under Set-StrictMode -Version Latest, a bare reference to an
        # unset variable THROWS — caught by the surrounding try/catch below,
        # which silently returns @() even when the mock returned real content.
        # That is the exact silent-empty-return failure class issue #977 was
        # about, self-inflicted by this diagnostic. Reproduced: with -Version
        # Latest and an in-process mock, a bare $LASTEXITCODE check turns a
        # correct 1-result return into 0.
        $lastExit = Get-Variable -Name LASTEXITCODE -ValueOnly -ErrorAction SilentlyContinue
        if ($null -ne $lastExit -and $lastExit -ne 0) {
            Write-Verbose "Get-AcRefsFromIssue: gh issue view exited $lastExit for issue $IssueNumber; treating as empty body."
        }
    }
    catch {
        return @()
    }
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
