#Requires -Version 7.0
<#
.SYNOPSIS
    Extracts behavioral and identifier terms from the Acceptance Criteria section of a GitHub issue.

.DESCRIPTION
    Companion to Get-AcRefsFromIssue.ps1. Where Get-AcRefsFromIssue extracts file-path tokens,
    Get-AcTermsFromIssue extracts ALL backtick-quoted identifier tokens and annotates each with
    whether the source AC line contains a behavioral keyword (must, shall, gate, etc.).

    Used by Get-StructuralVerdict (s2) to perform behavioral-AC matching for CR8/CR9-style
    findings that reference semantic identifiers without file-path extensions.

    Returns a sorted, deduplicated array of PSCustomObject entries:
        {
            term           = <string>   # backtick-quoted identifier (backticks stripped)
            source_ac_line = <string>   # full AC line the term was extracted from (trimmed)
            is_behavioral  = <bool>     # true if AC line contains a behavioral keyword
        }

    Returns empty on any failure path (unresolvable gh, gh error, missing section).
    Emits Write-Warning when the ## Acceptance Criteria section is absent entirely.
    Does NOT emit a warning when the section exists but has no backtick tokens.

    RETURN SHAPE — exact, because two of these are easy to assert wrongly:
      * no results   -> `@()`, which PowerShell collapses on assignment, so a
                        caller's `$x = Get-AcTermsFromIssue ...` sees $null, not
                        an empty array. `@($x).Count` is 0 either way. An earlier
                        revision of this line claimed "never $null" — that was
                        false at direct assignment (issue #977).
      * ONE result   -> unrolls to a bare [PSCustomObject], NOT a one-element array.
      * two or more  -> [System.Object[]] of [PSCustomObject].
    All three bind correctly to `Get-StructuralVerdict -AcTerms`, which declares
    [PSCustomObject[]] and coerces. Callers that do their own indexing or type
    checks must wrap in @(). Verified by test, not assumed.

.NOTES
    H3-resilience: sub-headers inside the AC section (### ...) are NOT treated as section
    boundaries — only a new H2 (^##\s) terminates the AC section. Text under ### sub-headers
    is still parsed for backtick terms.

    Stop-list: tokens in $Script:AC_TERM_STOP_LIST are silently skipped (case-insensitive).
    Behavioral keywords: $Script:AC_BEHAVIORAL_KEYWORDS (case-insensitive word-boundary match).
#>

# ---------------------------------------------------------------------------
# Named constants — exposed at script scope so Pester can use them as the
# falsifiable test oracle (MF8).
# ---------------------------------------------------------------------------

# Closed behavioral-keyword set (AC lines containing any of these are is_behavioral=true)
$Script:AC_BEHAVIORAL_KEYWORDS = @(
    'must', 'shall', 'should', 'required', 'enforced', 'blocked',
    'cannot', 'never', 'always', 'unconditionally', 'autonomously',
    'force', 'mandatory', 'gate', 'guard', 'prohibit'
)

# Stop-list: backtick tokens that must NOT be extracted as terms
# (common prose words, boolean literals, command names, etc.)
$Script:AC_TERM_STOP_LIST = @(
    'true', 'false', 'null', 'undefined', 'none', 'n/a',
    'get', 'set', 'add', 'remove', 'list', 'run', 'call',
    'new', 'if', 'else', 'then', 'and', 'or', 'not',
    'schema_version', 'ac_cross_check', 'matched', 'source',
    'routed', 'result', 'stage', 'pass', 'fail',
    'dismiss', 'defer', 'incorporate', 'escalate'
)

# ---------------------------------------------------------------------------
# Function
# ---------------------------------------------------------------------------

function Get-AcTermsFromIssue {
    param(
        [Parameter(Mandatory=$true)]
        [string]$IssueNumber
    )

    # Step 1 — fetch issue body via gh; collapse any gh failure to empty body.
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
    # line. Step 2's split is vectorized over an array, so an unjoined capture
    # never isolates the section, `$parts[1]` becomes the body's SECOND LINE,
    # and the `Count -lt 2` guard (with its warning) never fires. Join first
    # (issue #977). Do not remove the join, and do not prove this path with an
    # in-process `gh` function: a function mock returns a single string and
    # cannot reproduce the array capture at all.
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
            Write-Verbose "Get-AcTermsFromIssue: gh issue view exited $lastExit for issue $IssueNumber; treating as empty body."
        }
    }
    catch {
        return @()
    }
    $body = @($bodyLines) -join "`n"
    if (-not $body) { return @() }

    # Step 2 — isolate the ## Acceptance Criteria H2 section (case-insensitive).
    $parts = $body -split "(?im)^##\s+acceptance criteria\s*$", 2
    if ($parts.Count -lt 2) {
        Write-Warning "Get-AcTermsFromIssue: No '## Acceptance Criteria' section found in issue $IssueNumber"
        return @()
    }
    $acSection = $parts[1]

    # Step 3 — cut off at the next H2 (^## ), NOT at H3 (^### ).
    # Split on lines that start with exactly "## " (two hashes then a space),
    # which preserves ### sub-headers as part of the AC content.
    $acSection = ($acSection -split "(?m)^##\s", 2)[0]

    # Empty section — no warning, just return empty.
    if (-not $acSection.Trim()) { return @() }

    # Step 4 — iterate lines, extract backtick tokens, annotate behavioral flag.
    $stopListLower = $Script:AC_TERM_STOP_LIST | ForEach-Object { $_.ToLowerInvariant() }

    # Build a single regex alternation for behavioral keywords with word boundaries.
    $kwPattern = ($Script:AC_BEHAVIORAL_KEYWORDS |
        ForEach-Object { [regex]::Escape($_) }) -join '|'
    $behavioralRegex = [regex]::new(
        "(?i)\b(?:$kwPattern)\b",
        [System.Text.RegularExpressions.RegexOptions]::None
    )

    $backtickRegex = [regex]::new('`([^`]+)`')

    # Collect entries; track first-seen term for deduplication.
    $seen    = [System.Collections.Generic.HashSet[string]]::new(
                    [System.StringComparer]::OrdinalIgnoreCase)
    $entries = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($line in ($acSection -split "`n")) {
        $trimmedLine = $line.Trim()
        if (-not $trimmedLine) { continue }

        $tokenMatches = $backtickRegex.Matches($trimmedLine)
        if ($tokenMatches.Count -eq 0) { continue }

        # Determine behavioral flag once per line (applies to all tokens on that line).
        $isBehavioral = $behavioralRegex.IsMatch($trimmedLine)

        foreach ($m in $tokenMatches) {
            $token = $m.Groups[1].Value

            # Skip whitespace-only tokens (e.g. a backtick pair containing only spaces).
            if ([string]::IsNullOrWhiteSpace($token)) { continue }

            # Stop-list check (case-insensitive).
            if ($stopListLower -contains $token.ToLowerInvariant()) { continue }

            # Deduplication — keep first occurrence.
            if (-not $seen.Add($token)) { continue }

            $entries.Add([PSCustomObject]@{
                term           = $token
                source_ac_line = $trimmedLine
                is_behavioral  = $isBehavioral
            })
        }
    }

    if ($entries.Count -eq 0) { return @() }

    # Step 5 — sort by term (case-insensitive stable sort).
    return @($entries | Sort-Object { $_.term.ToLowerInvariant() })
}
