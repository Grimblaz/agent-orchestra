#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Reports whether a memory store's recall index conforms to the agent-memory-compaction policy.

.DESCRIPTION
    A read-only diagnostic. It has no trigger and no schedule: it runs when a person or a
    session runs it, and it never writes to the index or anywhere else.

    Three axes are reported:

      1. header        - is the policy header present at the top of the index, before any
                         pointer line, and textually complete against the shipped copy?
      2. hooks         - how many linked subjects carry no recall hook (R1)?
      3. shared notes  - how many segments attach one trailing note to several links (R2)?

    Two refusals come before any count is printed, so that a store the check does not
    understand gets a loud failure instead of a plausible wrong verdict:

      - structure not recognized (no section headings, or no pointer lines at all)
      - no linked entry matches the entry-kind vocabulary the policy names, which means
        the policy text has not been adapted to this store

    The hook axis is a syntactic proxy for a question about meaning. It rejects a small
    closed set of generic filler as non-hooks, and it treats a pointer whose words all
    already appear in its target's filename as a bare title. Novel filler evades it, and a
    pointer using words absent from the filename passes it while saying nothing. It is a
    floor, not a judge.

.PARAMETER IndexPath
    Path to the index file to check.

.PARAMETER PolicyReferencePath
    Path to the SKILL.md carrying the canonical policy text. Defaults to the SKILL.md
    beside this script. The comparison uses only the 'Policy text (canonical)' section;
    the 'Adapting this to your store' section is excluded by construction, so an adapted
    store and the shipped copy can still match on the text that matters.

.PARAMETER Json
    Emit the report as a single JSON object instead of human-readable lines.

.OUTPUTS
    Exit 0 - clean. Exit 1 - defects found. Exit 2 - refused: structure or entry-kind
    vocabulary not recognized, or the reference copy is missing or malformed.
    Exit 3 - usage error.

.EXAMPLE
    pwsh Test-MemoryIndexPolicy.ps1 -IndexPath ~/.claude/projects/my-project/memory/MEMORY.md
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$IndexPath,

    [Parameter()]
    [string]$PolicyReferencePath,

    [Parameter()]
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Section headings the reference copy must carry. The adapt-note heading is named here
# because excluding it from the comparison is a documented property, not an accident.
$script:CanonicalHeadingPattern = '^##\s+Policy text \(canonical\)\s*$'
$script:AdaptNoteHeadingPattern = '^##\s+Adapting this to your store'
$script:AdaptNoteHeadingLabel = '## Adapting this to your store (not part of the compared text)'

# Closed set of generic filler. A clause that reduces to one of these is not a hook.
$script:FillerPhrases = @(
    'see body', 'see the body', 'read the body', 'in the body', 'details in body',
    'details in the body', 'details inside', 'more inside', 'more in body',
    'see file', 'see notes', 'see above', 'tbd', 'na'
)

# Words carrying no subject-identifying information, dropped before comparing a link's
# words against its target filename.
$script:StopWords = @(
    'a', 'an', 'the', 'is', 'are', 'was', 'were', 'be', 'been', 'being',
    'of', 'to', 'in', 'on', 'at', 'for', 'and', 'or', 'it', 'its',
    'this', 'that', 'with', 'by', 'from', 'as'
)

function Get-LinksInText {
    <#
        .SYNOPSIS
        Returns every markdown link to a .md target in $Text, with its span.

        Link text may itself contain square brackets (for example a literal [ref]), so the
        opening bracket is found by scanning backwards with depth counting rather than by a
        naive character-class match.
    #>
    param([string]$Text)

    $found = [System.Collections.Generic.List[object]]::new()
    foreach ($m in ([regex]'\]\((?<target>[^()\s]+\.md)\)').Matches($Text)) {
        $closeIdx = $m.Index
        $depth = 0
        $openIdx = -1
        for ($i = $closeIdx; $i -ge 0; $i--) {
            if ($Text[$i] -eq ']') { $depth++ }
            elseif ($Text[$i] -eq '[') {
                $depth--
                if ($depth -eq 0) { $openIdx = $i; break }
            }
        }
        if ($openIdx -lt 0) { continue }
        $found.Add([pscustomobject]@{
                LinkText = $Text.Substring($openIdx + 1, $closeIdx - $openIdx - 1)
                Target   = $m.Groups['target'].Value
                End      = $m.Index + $m.Length
            })
    }
    return $found
}

function Get-WordTokens {
    param([string]$Text)

    $lowered = $Text.ToLowerInvariant()
    $spaced = [regex]::Replace($lowered, '[^a-z0-9]+', ' ')
    $tokens = @($spaced -split '\s+' | Where-Object { $_ -ne '' -and $script:StopWords -notcontains $_ })
    return $tokens
}

function Test-IsFiller {
    param([string]$Clause)

    $normalized = ([regex]::Replace($Clause.ToLowerInvariant(), '[^a-z0-9 ]+', ' ') -replace '\s+', ' ').Trim()
    return ($script:FillerPhrases -contains $normalized)
}

function Get-NormalizedBlock {
    <#
        .SYNOPSIS
        Right-trims each line and drops leading and trailing blank lines, so that two
        surfaces differing only in surrounding whitespace still compare equal.
    #>
    param([string[]]$Lines)

    $trimmed = @($Lines | ForEach-Object { $_.TrimEnd() })
    $start = 0
    $end = $trimmed.Count - 1
    while ($start -le $end -and $trimmed[$start] -eq '') { $start++ }
    while ($end -ge $start -and $trimmed[$end] -eq '') { $end-- }
    if ($start -gt $end) { return @() }
    return @($trimmed[$start..$end])
}

function Exit-Refused {
    param([string]$Reason, [string[]]$Detail = @())

    if ($Json) {
        [pscustomobject]@{
            result = 'refused'
            reason = $Reason
            detail = $Detail
            index  = $IndexPath
        } | ConvertTo-Json -Depth 5
    }
    else {
        Write-Host 'RESULT: refused'
        Write-Host "reason: $Reason"
        foreach ($d in $Detail) { Write-Host "  $d" }
        Write-Host 'No counts are reported: a verdict on input this check does not recognize would be a guess.'
    }
    exit 2
}

# --- inputs -----------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $IndexPath -PathType Leaf)) {
    Write-Host 'RESULT: usage-error'
    Write-Host "reason: index not found at '$IndexPath'"
    exit 3
}

if ([string]::IsNullOrWhiteSpace($PolicyReferencePath)) {
    $PolicyReferencePath = Join-Path $PSScriptRoot '..' 'SKILL.md'
}
if (-not (Test-Path -LiteralPath $PolicyReferencePath -PathType Leaf)) {
    Exit-Refused -Reason 'policy reference copy not found' -Detail @("looked for: $PolicyReferencePath")
}

$indexLines = @([System.IO.File]::ReadAllLines((Resolve-Path -LiteralPath $IndexPath).Path))
$refLines = @([System.IO.File]::ReadAllLines((Resolve-Path -LiteralPath $PolicyReferencePath).Path))

# --- reference copy: canonical text + named exclusion ------------------------------------

$canonicalStart = -1
$canonicalEnd = -1
$adaptNoteFound = $false
for ($i = 0; $i -lt $refLines.Count; $i++) {
    if ($refLines[$i] -match $script:AdaptNoteHeadingPattern) { $adaptNoteFound = $true }
    if ($canonicalStart -lt 0) {
        if ($refLines[$i] -match $script:CanonicalHeadingPattern) { $canonicalStart = $i + 1 }
        continue
    }
    if ($canonicalEnd -lt 0 -and $refLines[$i] -match '^##\s') { $canonicalEnd = $i - 1 }
}
if ($canonicalStart -lt 0) {
    Exit-Refused -Reason 'policy reference copy is malformed' -Detail @(
        "no section heading matching '## Policy text (canonical)' in $PolicyReferencePath")
}
if ($canonicalEnd -lt 0) { $canonicalEnd = $refLines.Count - 1 }
if (-not $adaptNoteFound) {
    Exit-Refused -Reason 'policy reference copy is malformed' -Detail @(
        "no '$script:AdaptNoteHeadingLabel' section in $PolicyReferencePath",
        'that section must exist because it is the block excluded from the comparison')
}
if ($canonicalEnd -lt $canonicalStart) {
    Exit-Refused -Reason 'policy reference copy is malformed' -Detail @('the canonical policy section is empty')
}
$canonicalBlock = @(Get-NormalizedBlock -Lines $refLines[$canonicalStart..$canonicalEnd])
if ($canonicalBlock.Count -eq 0) {
    Exit-Refused -Reason 'policy reference copy is malformed' -Detail @('the canonical policy section is empty')
}

# The entry-kind vocabulary is read out of the policy text rather than hardcoded, so an
# adapted copy is checked against the kinds it actually names.
$kindPrefixes = @(([regex]'`(?<k>[A-Za-z][A-Za-z0-9-]*_)`').Matches(($canonicalBlock -join "`n")) |
        ForEach-Object { $_.Groups['k'].Value } | Sort-Object -Unique)
if ($kindPrefixes.Count -eq 0) {
    Exit-Refused -Reason 'policy reference copy is malformed' -Detail @(
        'the canonical policy text names no entry-kind prefixes')
}

# --- index structure ---------------------------------------------------------------------

$firstSectionIdx = -1
$firstPointerIdx = -1
for ($i = 0; $i -lt $indexLines.Count; $i++) {
    if ($firstSectionIdx -lt 0 -and $indexLines[$i] -match '^##\s') { $firstSectionIdx = $i }
    if ($firstPointerIdx -lt 0 -and $indexLines[$i] -match '^\s*-\s' -and
        @(Get-LinksInText -Text $indexLines[$i]).Count -gt 0) { $firstPointerIdx = $i }
}
if ($firstSectionIdx -lt 0) {
    Exit-Refused -Reason 'index structure not recognized' -Detail @(
        'no "## " section heading found; this check delimits the policy header by the first section heading')
}
if ($firstPointerIdx -lt 0) {
    Exit-Refused -Reason 'index structure not recognized' -Detail @(
        'no pointer line found (a list item linking a .md entry)')
}

# --- subjects ------------------------------------------------------------------------------

$subjects = [System.Collections.Generic.List[object]]::new()
$sharedNotes = [System.Collections.Generic.List[object]]::new()
for ($i = 0; $i -lt $indexLines.Count; $i++) {
    $line = $indexLines[$i]
    if ($line -notmatch '^\s*-\s') { continue }
    if (@(Get-LinksInText -Text $line).Count -eq 0) { continue }

    foreach ($segment in ($line -split ' · ')) {
        $links = @(Get-LinksInText -Text $segment)
        if ($links.Count -eq 0) { continue }

        $last = $links[$links.Count - 1]
        $clause = $segment.Substring($last.End).Trim()
        $clause = ($clause -replace '^[—–\-:;,·]+\s*', '').Trim()
        $clauseIsHook = ($clause -ne '') -and -not (Test-IsFiller -Clause $clause)

        if ($links.Count -gt 1 -and $clauseIsHook) {
            $sharedNotes.Add([pscustomobject]@{
                    Line     = $i + 1
                    Subjects = @($links | ForEach-Object { $_.Target })
                    Note     = $clause
                })
        }

        for ($k = 0; $k -lt $links.Count; $k++) {
            $link = $links[$k]
            $isLast = ($k -eq $links.Count - 1)
            $ownClause = if ($isLast) { $clause } else { '' }
            $hasHook = $false
            $why = ''
            if ($isLast -and $clause -ne '' -and -not $clauseIsHook) {
                $why = 'clause is generic filler'
            }
            elseif ($isLast -and $clauseIsHook) {
                $hasHook = $true
            }
            else {
                $linkTokens = @(Get-WordTokens -Text $link.LinkText)
                $targetTokens = @(Get-WordTokens -Text ([System.IO.Path]::GetFileNameWithoutExtension($link.Target)))
                $novel = @($linkTokens | Where-Object { $targetTokens -notcontains $_ })
                if ($linkTokens.Count -eq 0) { $why = 'link text carries no words' }
                elseif ($novel.Count -eq 0) { $why = 'bare title: every word already appears in the filename' }
                else { $hasHook = $true }
            }

            $subjects.Add([pscustomobject]@{
                    Line     = $i + 1
                    Target   = $link.Target
                    LinkText = $link.LinkText
                    Clause   = $ownClause
                    HasHook  = $hasHook
                    Reason   = $why
                })
        }
    }
}

# --- entry-kind vocabulary refusal ---------------------------------------------------------

$matchingKind = @($subjects | Where-Object {
        $name = [System.IO.Path]::GetFileName($_.Target)
        $hit = $false
        foreach ($p in $kindPrefixes) { if ($name.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase)) { $hit = $true } }
        $hit
    })
if ($matchingKind.Count -eq 0) {
    Exit-Refused -Reason 'entry-kind vocabulary not recognized' -Detail @(
        ("policy names: " + ($kindPrefixes -join ', ')),
        'no linked entry in this index carries any of those prefixes',
        "adapt the policy text to this store first - see '$script:AdaptNoteHeadingLabel' in $PolicyReferencePath")
}

# --- header --------------------------------------------------------------------------------

# The @(...) around the whole conditional is load-bearing: an if-expression yielding an
# empty array assigns $null, and $null.Count throws under StrictMode.
$headerBlock = @(if ($firstSectionIdx -gt 0) { @(Get-NormalizedBlock -Lines $indexLines[0..($firstSectionIdx - 1)]) } else { @() })
$markerLine = $canonicalBlock[0]
$headerPresent = ($headerBlock.Count -gt 0) -and (@($headerBlock | Where-Object { $_ -eq $markerLine }).Count -gt 0)
$headerBeforeFirstPointer = ($firstSectionIdx -le $firstPointerIdx)
$headerComplete = $headerPresent -and $headerBeforeFirstPointer -and
    (($headerBlock -join "`n") -eq ($canonicalBlock -join "`n"))

$headerDiff = ''
if ($headerPresent -and -not $headerComplete) {
    $limit = [Math]::Max($headerBlock.Count, $canonicalBlock.Count)
    for ($i = 0; $i -lt $limit; $i++) {
        $a = if ($i -lt $headerBlock.Count) { $headerBlock[$i] } else { '<end of header>' }
        $b = if ($i -lt $canonicalBlock.Count) { $canonicalBlock[$i] } else { '<end of canonical text>' }
        if ($a -ne $b) {
            $headerDiff = "first divergence at header line $($i + 1): header has '$a'; reference has '$b'"
            break
        }
    }
    if ($headerDiff -eq '' -and -not $headerBeforeFirstPointer) {
        $headerDiff = 'policy text does not sit before the first pointer line'
    }
}

# --- report ---------------------------------------------------------------------------------

$noHook = @($subjects | Where-Object { -not $_.HasHook })
$headerStatus = if (-not $headerPresent) { 'absent' } elseif ($headerComplete) { 'present, complete' } else { 'present, INCOMPLETE' }
$clean = $headerComplete -and ($noHook.Count -eq 0) -and ($sharedNotes.Count -eq 0)

if ($Json) {
    [pscustomobject]@{
        result                   = if ($clean) { 'clean' } else { 'defects' }
        index                    = $IndexPath
        reference                = $PolicyReferencePath
        excluded_from_comparison = $script:AdaptNoteHeadingLabel
        kind_prefixes            = $kindPrefixes
        entries_matching_kind    = $matchingKind.Count
        subjects_total           = $subjects.Count
        header_present           = $headerPresent
        header_complete          = $headerComplete
        header_before_first_pointer = $headerBeforeFirstPointer
        header_divergence        = $headerDiff
        subjects_without_hook    = $noHook.Count
        unattributed_shared_notes = $sharedNotes.Count
        without_hook             = @($noHook | ForEach-Object { @{ line = $_.Line; target = $_.Target; link_text = $_.LinkText; reason = $_.Reason } })
        shared_notes             = @($sharedNotes | ForEach-Object { @{ line = $_.Line; subjects = $_.Subjects; note = $_.Note } })
    } | ConvertTo-Json -Depth 6
}
else {
    Write-Host ("RESULT: " + $(if ($clean) { 'clean' } else { 'defects' }))
    Write-Host "header: $headerStatus"
    if ($headerDiff -ne '') { Write-Host "  $headerDiff" }
    Write-Host "subjects_without_hook: $($noHook.Count)"
    Write-Host "unattributed_shared_notes: $($sharedNotes.Count)"
    Write-Host ''
    Write-Host "index: $IndexPath"
    Write-Host "reference: $PolicyReferencePath"
    Write-Host "excluded from comparison: $script:AdaptNoteHeadingLabel"
    Write-Host ("entry kinds named by the policy: " + ($kindPrefixes -join ', ') + " (matched $($matchingKind.Count) of $($subjects.Count) linked subjects)")
    if ($noHook.Count -gt 0) {
        Write-Host ''
        Write-Host 'subjects without a recall hook:'
        foreach ($s in $noHook) { Write-Host ("  line {0,-4} {1} [{2}] - {3}" -f $s.Line, $s.Target, $s.LinkText, $s.Reason) }
    }
    if ($sharedNotes.Count -gt 0) {
        Write-Host ''
        Write-Host 'unattributed shared notes:'
        foreach ($n in $sharedNotes) { Write-Host ("  line {0,-4} {1} subjects share the note '{2}'" -f $n.Line, $n.Subjects.Count, $n.Note) }
    }
}

exit $(if ($clean) { 0 } else { 1 })
