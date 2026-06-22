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

    Returns @() (never $null) on any failure path (missing gh, missing section, gh error).
    Emits Write-Warning when the ## Acceptance Criteria section is absent entirely.
    Does NOT emit a warning when the section exists but has no backtick tokens.

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

    # Step 1 — fetch issue body via gh; collapse any gh error to empty body.
    $body = gh issue view $IssueNumber --json body --jq '.body' 2>$null
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
