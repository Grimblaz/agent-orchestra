#Requires -Version 7.0
<#
.SYNOPSIS
    Library for the newcomer-audit detector. Dot-source this file and call
    Get-NewcomerAuditFindings (content-based) or Get-NewcomerAuditFindingsFromFile
    (file-based).

.DESCRIPTION
    Deterministic, offline detector core: flags undefined insider terms in new
    human-facing prose using the skills/naming-register-policy/assets/register.json
    classification data. No network calls, no clock reads -- same input always
    produces the same findings.

    Pipeline:
      1. Read with explicit UTF-8, normalize CRLF -> LF (file-based entry point only;
         Get-NewcomerAuditFindings accepts already-in-memory content and normalizes it too).
      2. Strip machine-citation zones (fenced code blocks, HTML comments, YAML
         frontmatter) while blanking out only non-newline characters, so line
         numbers reported in findings stay accurate. Inline single-backtick prose
         tokens are NOT stripped -- only full triple-backtick fences and
         comment/frontmatter blocks are zones.
      3. Build the match set from each register row's 'term' field -- the term is
         a display label, not a matcher: rows carrying 'instance_pattern' use that
         regex; compound/slash rows ("a / b (paren)") are tokenized into
         independent components with trailing parentheticals stripped; everything
         else matches its literal term text. A registered component must never
         fall through to the unknown-token pass (see the credits[] fixture in
         newcomer-audit.Tests.ps1 for the specific defect this fixes).
      4. Known-term pass with a split-by-surface escape hatch:
           - issue-body: a stable-code match always requires first-use expansion
             to suppress -- no other escape hatch exists on this surface.
           - repo-file: suppress when the file exhibits ANY of (a) a first-use
             expansion of this specific term, (b) a surviving prose link line
             containing HOW-IT-WORKS.md#vocab (a generic, file-wide pointer --
             not the stripped <!-- vocab-pointer --> comment sentinel), or
             (c) a surviving link to the term's owning reference skill (derived
             from the row's decode/expansion text).
         "Expanded on first use" is a loose predicate: the term's first
         occurrence is immediately followed by a non-empty parenthetical. This is
         NOT compared against the register's own 'expansion' field text.
         rename-candidate rows always flag (no escape hatch) and emit the
         'replacement' field as the suggestion. self-describing rows never flag.
      5. Unknown-token pass: token shapes containing a digit, underscore, or a
         trailing [] that did not resolve via step 3/4, minus a small inline
         allowlist for non-jargon digit-bearing tokens (ISO-8601, UTF-8, draft-07).
         Bare ALL-CAPS acronyms with no digit/underscore/bracket are out of scope
         for v1.
      6. Return structured findings as [pscustomobject]@{token; line;
         register_state; suggestion} -- this core does not serialize to JSON or
         set an exit code; that is the wrapper's (s3) job.
#>

# Register rows carry author-supplied regex text (instance_pattern) that can
# be pathological (e.g. nested quantifiers). Every regex match against
# register-derived pattern text is executed with this timeout, and a timeout
# is treated as a no-match (fail open, warn loudly) rather than hanging the
# process indefinitely.
$script:NewcomerAuditRegexTimeout = [timespan]::FromSeconds(2)

$script:NewcomerAuditAllowlist = @('ISO-8601', 'UTF-8', 'draft-07', '^v\d+$')

function Test-NewcomerAuditAllowlisted {
    <#
    .SYNOPSIS
        True when a candidate unknown token is exempted by the inline
        allowlist. Entries shaped like a full-string regex (start with '^'
        and end with '$') are matched as a pattern; all other entries are
        matched as an exact literal string.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Token
    )

    foreach ($entry in $script:NewcomerAuditAllowlist) {
        if ($entry -match '^\^.*\$$') {
            if ($Token -cmatch $entry) {
                return $true
            }
            continue
        }

        if ($Token -ceq $entry) {
            return $true
        }
    }

    return $false
}

function Get-NewcomerAuditNormalizedContent {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $raw = [System.IO.File]::ReadAllText($Path, $utf8NoBom)
    return ConvertTo-NewcomerAuditNormalizedText -Text $raw
}

function ConvertTo-NewcomerAuditNormalizedText {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    return ($Text -replace "`r`n", "`n") -replace "`r", "`n"
}

function Remove-NewcomerAuditMachineZones {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content
    )

    $blankEvaluator = [System.Text.RegularExpressions.MatchEvaluator] {
        param($match)
        return ($match.Value -replace '[^\n]', ' ')
    }

    $result = $Content

    # YAML frontmatter: only a leading '---' block at the very start of the file.
    $result = [regex]::Replace($result, '(?s)\A---\n.*?\n---\n', $blankEvaluator)

    # Fenced code blocks: triple-or-more backtick fences. Inline single-backtick
    # prose tokens are untouched because this only matches line-anchored fences.
    $result = [regex]::Replace($result, '(?ms)^`{3,}[^\n]*\n.*?^`{3,}[ \t]*$', $blankEvaluator)

    # HTML comments (single- or multi-line), including the vocab-pointer sentinel.
    $result = [regex]::Replace($result, '(?s)<!--.*?-->', $blankEvaluator)

    return $result
}

function Get-NewcomerAuditLineNumber {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter(Mandatory)]
        [int]$Index
    )

    if ($Index -le 0) {
        return 1
    }

    $prefix = $Content.Substring(0, $Index)
    $newlineCount = ($prefix.ToCharArray() | Where-Object { $_ -eq "`n" }).Count
    return $newlineCount + 1
}

function ConvertTo-NewcomerAuditComponents {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Term
    )

    $components = $Term -split '\s*/\s*'
    return @($components | ForEach-Object {
            ($_ -replace '\s*\([^)]*\)\s*$', '').Trim()
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function ConvertTo-NewcomerAuditMatcher {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [array]$Register
    )

    $matchers = @()
    foreach ($row in $Register) {
        $hasInstancePattern = ($row.PSObject.Properties.Name -contains 'instance_pattern') -and `
            -not [string]::IsNullOrWhiteSpace($row.instance_pattern)

        if ($hasInstancePattern) {
            $matchers += [pscustomobject]@{
                Pattern     = $row.instance_pattern
                Row         = $row
                EmitFinding = $true
            }
            continue
        }

        if ($row.term -match '\s/\s') {
            # component_matchers: false (e.g. the D1/D2/D3 family) means the
            # tokenizer must still recognize each component as a KNOWN token
            # (so it never falls through to the unknown-token pass) but must
            # not generate a known-term FINDING for it -- that would recreate
            # the exact local-decision-ID collision the register schema
            # deliberately withheld an instance_pattern to avoid.
            $emitFinding = -not (
                ($row.PSObject.Properties.Name -contains 'component_matchers') -and
                ($row.component_matchers -eq $false)
            )

            foreach ($component in (ConvertTo-NewcomerAuditComponents -Term $row.term)) {
                # Skip standalone-matcher generation for a component that is a
                # single all-lowercase word with no internal punctuation (e.g.
                # 'frame', 'adapter') -- ordinary prose would otherwise get
                # flagged. Components with internal punctuation (hyphens,
                # underscores, brackets) or more than one word are unaffected.
                if ($component -cmatch '^[a-z]+$') {
                    continue
                }

                $matchers += [pscustomobject]@{
                    Pattern     = [regex]::Escape($component)
                    Row         = $row
                    EmitFinding = $emitFinding
                }
            }
            continue
        }

        $matchers += [pscustomobject]@{
            Pattern     = [regex]::Escape($row.term)
            Row         = $row
            EmitFinding = $true
        }
    }

    return $matchers
}

function Get-NewcomerAuditBoundaryPattern {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Pattern
    )

    # $Pattern is wrapped in a non-capturing group so a top-level alternation
    # (e.g. an instance_pattern like '\bstep_id\b|(?<![\w-])s\d+(?![\w-])')
    # gets the hyphen-boundary applied across the WHOLE pattern -- regex
    # alternation precedence otherwise binds the boundary only to the
    # first/last alternative. This is a no-op for any single-alternative
    # pattern (adding a non-capturing group around it changes nothing).
    return "(?<![\w-])(?:$Pattern)(?![\w-])"
}

function Test-NewcomerAuditFirstUseExpanded {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter(Mandatory)]
        [string]$BoundaryPattern
    )

    try {
        $regex = [regex]::new($BoundaryPattern, [System.Text.RegularExpressions.RegexOptions]::None, $script:NewcomerAuditRegexTimeout)
        $match = $regex.Match($Content)
    }
    catch [System.Text.RegularExpressions.RegexMatchTimeoutException] {
        Write-Warning "newcomer-audit: regex match timed out evaluating first-use expansion for pattern '$BoundaryPattern' -- treating as not expanded."
        return $false
    }

    if (-not $match.Success) {
        return $false
    }

    $afterText = $Content.Substring($match.Index + $match.Length)

    try {
        $parenRegex = [regex]::new('^\s*\(([^)]+)\)', [System.Text.RegularExpressions.RegexOptions]::None, $script:NewcomerAuditRegexTimeout)
        $parenMatch = $parenRegex.Match($afterText)
    }
    catch [System.Text.RegularExpressions.RegexMatchTimeoutException] {
        Write-Warning "newcomer-audit: regex match timed out checking the first-use parenthetical -- treating as not expanded."
        return $false
    }

    return $parenMatch.Success -and -not [string]::IsNullOrWhiteSpace($parenMatch.Groups[1].Value)
}

function Get-NewcomerAuditOwningSkillPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        $Row
    )

    $decodeText = if ($Row.PSObject.Properties.Name -contains 'decode') { [string]$Row.decode } else { '' }
    $expansionText = if ($Row.PSObject.Properties.Name -contains 'expansion') { [string]$Row.expansion } else { '' }
    $combined = "$decodeText $expansionText"

    $skillMatch = [regex]::Match($combined, 'skills/[A-Za-z0-9_.\-/]+\.md')
    if ($skillMatch.Success) {
        return $skillMatch.Value
    }

    return $null
}

function Test-NewcomerAuditIssueBodySuppressed {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter(Mandatory)]
        [string]$BoundaryPattern
    )

    return Test-NewcomerAuditFirstUseExpanded -Content $Content -BoundaryPattern $BoundaryPattern
}

function Test-NewcomerAuditRepoFileSuppressed {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter(Mandatory)]
        $Row,

        [Parameter(Mandatory)]
        [string]$BoundaryPattern
    )

    if ($Content -match 'HOW-IT-WORKS\.md#vocab') {
        return $true
    }

    $skillPath = Get-NewcomerAuditOwningSkillPath -Row $Row
    if ($skillPath -and ($Content -match [regex]::Escape($skillPath))) {
        return $true
    }

    return Test-NewcomerAuditFirstUseExpanded -Content $Content -BoundaryPattern $BoundaryPattern
}

function Get-NewcomerAuditLineDedupedOccurrences {
    <#
    .SYNOPSIS
        Reduces a match collection to the occurrences that should actually be
        emitted, honoring -AllOccurrences semantics without multiplying
        same-line findings.

    .DESCRIPTION
        Without -AllOccurrences: only the first match in the whole collection
        (unchanged legacy behavior for -Path mode).

        With -AllOccurrences: one match per distinct line (the first match on
        each line), not every raw regex match -- a token/term repeated
        multiple times on the SAME line is the same finding, not new
        information, so it collapses to a single occurrence for that line.
        Distinct lines each still surface their own occurrence.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$MatchList,

        [Parameter(Mandatory)]
        [bool]$AllOccurrences
    )

    if (-not $AllOccurrences) {
        return @($MatchList[0])
    }

    $seenLines = New-Object System.Collections.Generic.HashSet[int]
    $result = @()
    foreach ($occurrence in $MatchList) {
        $line = Get-NewcomerAuditLineNumber -Content $Content -Index $occurrence.Index
        if ($seenLines.Add($line)) {
            $result += $occurrence
        }
    }

    return $result
}

function Get-NewcomerAuditKnownTermFindings {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter(Mandatory)]
        [ValidateSet('issue-body', 'repo-file')]
        [string]$Surface,

        [Parameter(Mandatory)]
        [array]$Matchers,

        # Emit one finding per occurrence of a matcher instead of only the
        # first. Used only by the wrapper's -Changed path (immediately before
        # its added-lines filter) so a genuinely new occurrence on an added
        # line is not silently dropped just because an earlier, unchanged
        # occurrence of the same term exists elsewhere in the file. -Path
        # mode's single-finding-per-term behavior is unchanged by default.
        [switch]$AllOccurrences
    )

    $findings = @()

    # Group matchers by owning register row so escape-hatch suppression is
    # evaluated once per component, not once per row.
    $rowGroups = [ordered]@{}
    foreach ($matcher in $Matchers) {
        $key = $matcher.Row.term
        if (-not $rowGroups.Contains($key)) {
            $rowGroups[$key] = @()
        }
        $rowGroups[$key] += $matcher
    }

    foreach ($key in $rowGroups.Keys) {
        $group = $rowGroups[$key]
        $row = $group[0].Row

        if ($row.register -eq 'self-describing') {
            continue
        }

        foreach ($matcher in $group) {
            # component_matchers: false rows (e.g. D1/D2/D3) still need their
            # components resolved as known tokens elsewhere (see
            # Test-NewcomerAuditKnownToken, which receives the full $Matchers
            # array independent of this filter) but must never surface a
            # known-term finding of their own.
            if (-not $matcher.EmitFinding) {
                continue
            }

            $boundaryPattern = Get-NewcomerAuditBoundaryPattern -Pattern $matcher.Pattern

            try {
                $regex = [regex]::new($boundaryPattern, [System.Text.RegularExpressions.RegexOptions]::None, $script:NewcomerAuditRegexTimeout)
                # [regex]::Matches() returns a lazily-evaluated MatchCollection --
                # the timeout is only actually enforced once the collection is
                # enumerated, not at the .Matches() call itself. Force eager
                # materialization with @() here so a timeout surfaces inside
                # this try block instead of later, unguarded, at .Count access.
                $regexMatches = @($regex.Matches($Content))
            }
            catch [System.Text.RegularExpressions.RegexMatchTimeoutException] {
                Write-Warning "newcomer-audit: regex match timed out for register row '$($row.term)' pattern '$boundaryPattern' -- treating as no-match."
                continue
            }

            if ($regexMatches.Count -eq 0) {
                continue
            }

            if ($row.register -eq 'rename-candidate') {
                $occurrences = Get-NewcomerAuditLineDedupedOccurrences -Content $Content -MatchList $regexMatches -AllOccurrences $AllOccurrences.IsPresent
                foreach ($occurrence in $occurrences) {
                    $findings += [pscustomobject]@{
                        token          = $occurrence.Value
                        line           = Get-NewcomerAuditLineNumber -Content $Content -Index $occurrence.Index
                        register_state = 'rename-candidate'
                        suggestion     = $row.replacement
                    }
                }
                continue
            }

            # stable-code
            $suppressed = if ($Surface -eq 'issue-body') {
                Test-NewcomerAuditIssueBodySuppressed -Content $Content -BoundaryPattern $boundaryPattern
            }
            else {
                Test-NewcomerAuditRepoFileSuppressed -Content $Content -Row $row -BoundaryPattern $boundaryPattern
            }

            if ($suppressed) {
                continue
            }

            $occurrences = Get-NewcomerAuditLineDedupedOccurrences -Content $Content -MatchList $regexMatches -AllOccurrences $AllOccurrences.IsPresent
            foreach ($occurrence in $occurrences) {
                $findings += [pscustomobject]@{
                    token          = $occurrence.Value
                    line           = Get-NewcomerAuditLineNumber -Content $Content -Index $occurrence.Index
                    register_state = 'stable-code'
                    suggestion     = "expand on first use (preferred): $($row.expansion)"
                }
            }
        }
    }

    return $findings
}

function Test-NewcomerAuditKnownToken {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Token,

        [Parameter(Mandatory)]
        [array]$Matchers
    )

    foreach ($matcher in $Matchers) {
        try {
            # RegexOptions.None (no IgnoreCase) makes this case-sensitive,
            # matching the known-term pass's case sensitivity so a mis-cased
            # token (e.g. 'smc-05') correctly surfaces as 'unknown' instead
            # of silently vanishing between the two passes.
            #
            # $matcher.Pattern is wrapped in a non-capturing group so a
            # top-level alternation (e.g. an instance_pattern combining a
            # \b-bounded literal with a hyphen-boundary numeric form) is
            # anchored as a whole -- otherwise '^' / '$' bind only to the
            # first/last alternative and a token like 'step_id-x' can be
            # wrongly classified as known via the trailing alternative alone.
            $regex = [regex]::new("^(?:$($matcher.Pattern))$", [System.Text.RegularExpressions.RegexOptions]::None, $script:NewcomerAuditRegexTimeout)
            if ($regex.IsMatch($Token)) {
                return $true
            }
        }
        catch [System.Text.RegularExpressions.RegexMatchTimeoutException] {
            Write-Warning "newcomer-audit: regex match timed out for known-token pattern '$($matcher.Pattern)' -- treating as no-match."
            continue
        }
    }

    return $false
}

function Get-NewcomerAuditUnknownTokenFindings {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter(Mandatory)]
        [array]$Matchers,

        # See Get-NewcomerAuditKnownTermFindings -AllOccurrences: when set,
        # every occurrence of a repeat unknown coinage is emitted instead of
        # only the first (deduped) occurrence.
        [switch]$AllOccurrences
    )

    # Token shape: an alphanumeric run, optionally chained with '_'/'-' segments,
    # optionally suffixed with a literal '[]'. Boundaries use lookaround (not \b)
    # so a trailing '[]' -- whose ']' is a non-word char -- does not break the
    # match the way a trailing \b would.
    $tokenPattern = '(?<![\w.])[A-Za-z0-9]+(?:[_-][A-Za-z0-9]+)*(?:\[\])?(?!\w)'

    $findings = @()
    $seenTokens = New-Object System.Collections.Generic.HashSet[string]

    foreach ($tokenMatch in [regex]::Matches($Content, $tokenPattern)) {
        $token = $tokenMatch.Value

        if (-not ($token -match '[A-Za-z]')) {
            continue
        }

        # In-scope shapes only: digit, underscore, or a trailing '[]'.
        if (-not ($token -match '[0-9_]' -or $token.EndsWith('[]'))) {
            continue
        }

        # Bare ALL-CAPS-only acronyms (no digit/underscore/bracket) are already
        # excluded by the check above; nothing further needed for that case.

        if (Test-NewcomerAuditAllowlisted -Token $token) {
            continue
        }

        if (Test-NewcomerAuditKnownToken -Token $token -Matchers $Matchers) {
            continue
        }

        # Dedup key is computed BEFORE the seen-set check (not the token
        # alone) so -AllOccurrences relaxes dedup across distinct lines
        # without disabling it entirely: a token repeated multiple times on
        # the SAME line is still collapsed to one finding (no new
        # information), while the same token on a DIFFERENT line still gets
        # its own finding. Without -AllOccurrences the key is the token
        # alone, preserving the original first-occurrence-only behavior
        # exactly.
        $line = Get-NewcomerAuditLineNumber -Content $Content -Index $tokenMatch.Index
        $dedupKey = if ($AllOccurrences) { "$token|$line" } else { $token }

        if (-not $seenTokens.Add($dedupKey)) {
            continue
        }

        $findings += [pscustomobject]@{
            token          = $token
            line           = $line
            register_state = 'unknown'
            suggestion     = 'expand on first use (preferred), rename to a self-describing form, or add to the register (heavier path)'
        }
    }

    return $findings
}

function Get-NewcomerAuditFindings {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content,

        [Parameter(Mandatory)]
        [ValidateSet('issue-body', 'repo-file')]
        [string]$Surface,

        [Parameter(Mandatory)]
        [array]$Register,

        # See Get-NewcomerAuditKnownTermFindings -AllOccurrences. Default
        # ($false) preserves the original first-occurrence-only behavior
        # relied on by -Path mode.
        [switch]$AllOccurrences
    )

    $normalized = ConvertTo-NewcomerAuditNormalizedText -Text $Content
    $stripped = Remove-NewcomerAuditMachineZones -Content $normalized
    $matchers = ConvertTo-NewcomerAuditMatcher -Register $Register

    $findings = @()
    $findings += Get-NewcomerAuditKnownTermFindings -Content $stripped -Surface $Surface -Matchers $matchers -AllOccurrences:$AllOccurrences
    $findings += Get-NewcomerAuditUnknownTokenFindings -Content $stripped -Matchers $matchers -AllOccurrences:$AllOccurrences

    $sorted = @($findings | Sort-Object line, token)
    return , $sorted
}

function Get-NewcomerAuditFindingsFromFile {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateSet('issue-body', 'repo-file')]
        [string]$Surface,

        [Parameter(Mandatory)]
        [array]$Register
    )

    $content = Get-NewcomerAuditNormalizedContent -Path $Path
    return Get-NewcomerAuditFindings -Content $content -Surface $Surface -Register $Register
}
