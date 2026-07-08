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

$script:NewcomerAuditAllowlist = @('ISO-8601', 'UTF-8', 'draft-07')

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
                Component = $row.term
                Pattern   = $row.instance_pattern
                MatchType = 'instance'
                Row       = $row
            }
            continue
        }

        if ($row.term -match '\s/\s') {
            foreach ($component in (ConvertTo-NewcomerAuditComponents -Term $row.term)) {
                $matchers += [pscustomobject]@{
                    Component = $component
                    Pattern   = [regex]::Escape($component)
                    MatchType = 'component'
                    Row       = $row
                }
            }
            continue
        }

        $matchers += [pscustomobject]@{
            Component = $row.term
            Pattern   = [regex]::Escape($row.term)
            MatchType = 'literal'
            Row       = $row
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

    return "(?<!\w)$Pattern(?!\w)"
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

    $match = [regex]::Match($Content, $BoundaryPattern)
    if (-not $match.Success) {
        return $false
    }

    $afterText = $Content.Substring($match.Index + $match.Length)
    $parenMatch = [regex]::Match($afterText, '^\s*\(([^)]+)\)')
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
        [array]$Matchers
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
            $boundaryPattern = Get-NewcomerAuditBoundaryPattern -Pattern $matcher.Pattern
            $regexMatches = [regex]::Matches($Content, $boundaryPattern)
            if ($regexMatches.Count -eq 0) {
                continue
            }

            if ($row.register -eq 'rename-candidate') {
                $first = $regexMatches[0]
                $findings += [pscustomobject]@{
                    token          = $first.Value
                    line           = Get-NewcomerAuditLineNumber -Content $Content -Index $first.Index
                    register_state = 'rename-candidate'
                    suggestion     = $row.replacement
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

            $first = $regexMatches[0]
            $findings += [pscustomobject]@{
                token          = $first.Value
                line           = Get-NewcomerAuditLineNumber -Content $Content -Index $first.Index
                register_state = 'stable-code'
                suggestion     = "expand on first use (preferred): $($row.expansion)"
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
        if ($Token -match "^$($matcher.Pattern)$") {
            return $true
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
        [array]$Matchers
    )

    # Token shape: an alphanumeric run, optionally chained with '_'/'-' segments,
    # optionally suffixed with a literal '[]'. Boundaries use lookaround (not \b)
    # so a trailing '[]' -- whose ']' is a non-word char -- does not break the
    # match the way a trailing \b would.
    $tokenPattern = '(?<!\w)[A-Za-z0-9]+(?:[_-][A-Za-z0-9]+)*(?:\[\])?(?!\w)'

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

        if ($script:NewcomerAuditAllowlist -contains $token) {
            continue
        }

        if (Test-NewcomerAuditKnownToken -Token $token -Matchers $Matchers) {
            continue
        }

        if (-not $seenTokens.Add($token)) {
            continue
        }

        $findings += [pscustomobject]@{
            token          = $token
            line           = Get-NewcomerAuditLineNumber -Content $Content -Index $tokenMatch.Index
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
        [array]$Register
    )

    $normalized = ConvertTo-NewcomerAuditNormalizedText -Text $Content
    $stripped = Remove-NewcomerAuditMachineZones -Content $normalized
    $matchers = ConvertTo-NewcomerAuditMatcher -Register $Register

    $findings = @()
    $findings += Get-NewcomerAuditKnownTermFindings -Content $stripped -Surface $Surface -Matchers $matchers
    $findings += Get-NewcomerAuditUnknownTokenFindings -Content $stripped -Matchers $matchers

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
