#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Core logic for the agent-memory-compaction index check. Dot-source and call
    Invoke-MemoryIndexPolicyCheck; the entry point Test-MemoryIndexPolicy.ps1 only renders
    the result and sets the exit code.

.DESCRIPTION
    Nothing here writes, prompts, or exits. Every terminal condition is expressed as a report
    object with a Result and an ExitCode, so the whole surface is reachable in-process from a
    test without spawning a child shell.

    Result values and their exit codes:
      clean        0 - conforms on all three axes
      defects      1 - at least one axis reports a defect
      refused      2 - input not fully recognized; no counts are reported
      usage-error  3 - the invocation itself was wrong
#>

Set-StrictMode -Version Latest

$script:CanonicalBeginMarker = '<!-- policy-canonical-begin -->'
$script:CanonicalEndMarker = '<!-- policy-canonical-end -->'
$script:AdaptNoteHeadingLabel = '## Adapting this to your store (not part of the compared text)'

# Closed set of generic filler. Text that reduces to one of these is not a hook, wherever it
# sits - in a clause or in the link text itself.
$script:FillerPhrases = @(
    'see body', 'see the body', 'read the body', 'in the body', 'details in body',
    'details in the body', 'details inside', 'more inside', 'more in body',
    'see file', 'see notes', 'see above', 'tbd', 'na', 'n a'
)

# Words carrying no subject-identifying information, dropped before comparing a link's words
# against its target filename.
$script:StopWords = @(
    'a', 'an', 'the', 'is', 'are', 'was', 'were', 'be', 'been', 'being',
    'of', 'to', 'in', 'on', 'at', 'for', 'and', 'or', 'it', 'its',
    'this', 'that', 'with', 'by', 'from', 'as'
)

# A leading or trailing note needs at least this many words before it reads as a note rather
# than a short topic label ("Git/CI truth:", "PowerShell syntax:"). A documented proxy.
$script:NoteWordFloor = 4

# Everything after a ']' that markdown accepts as a link destination: an optional <bracketed>
# target, an optional #anchor, and an optional title.
$script:LinkTailPattern = '^\(\s*(?<target><[^>]*>|[^()\s]+)(?:\s+(?:"[^"]*"|''[^'']*''|\([^)]*\)))?\s*\)'

$script:PointerLinePattern = '^\s*(?:[-*+]|\d+[.)])\s'
$script:SeparatorTrimHead = '^[\s—–\-:;,·|]+'
$script:SeparatorTrimTail = '[\s—–\-:;,·|]+$'

function Get-MIPLinksInLine {
    <#
        .SYNOPSIS
        Returns every markdown link in one line, in order, plus any ']( ' construct the tail
        pattern could not parse.

        A single left-to-right scan with a bracket stack, so link text may itself contain
        square brackets (a literal [ref], say) and the cost stays linear in line length.
    #>
    param([string]$Text)

    $links = [System.Collections.Generic.List[object]]::new()
    $unparsed = [System.Collections.Generic.List[string]]::new()
    $open = [System.Collections.Generic.Stack[int]]::new()

    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($ch -eq '[') { $open.Push($i); continue }
        if ($ch -ne ']') { continue }
        if ($open.Count -eq 0) { continue }
        $openIdx = $open.Pop()
        if ($i + 1 -ge $Text.Length -or $Text[$i + 1] -ne '(') { continue }

        $m = [regex]::Match($Text.Substring($i + 1), $script:LinkTailPattern)
        if (-not $m.Success) {
            $unparsed.Add($Text.Substring($i, [Math]::Min(40, $Text.Length - $i)))
            continue
        }
        $target = $m.Groups['target'].Value.Trim('<', '>')
        $path = ($target -split '#', 2)[0]
        $links.Add([pscustomobject]@{
                LinkText  = $Text.Substring($openIdx + 1, $i - $openIdx - 1)
                Target    = $path
                Start     = $openIdx
                End       = $i + 1 + $m.Length
                IsSubject = $path -match '\.md$'
            })
    }
    return [pscustomobject]@{ Links = $links; Unparsed = $unparsed }
}

function Get-MIPWordTokens {
    param([string]$Text)

    $spaced = [regex]::Replace($Text.ToLowerInvariant(), '[^a-z0-9]+', ' ')
    return @($spaced -split '\s+' | Where-Object { $_ -ne '' -and $script:StopWords -notcontains $_ })
}

function Get-MIPNormalizedPhrase {
    param([string]$Text)

    return ([regex]::Replace($Text.ToLowerInvariant(), '[^a-z0-9 ]+', ' ') -replace '\s+', ' ').Trim()
}

function Test-MIPIsFiller {
    param([string]$Text)

    return ($script:FillerPhrases -contains (Get-MIPNormalizedPhrase -Text $Text))
}

function Test-MIPSaysSomething {
    <#
        .SYNOPSIS
        True when text carries at least one real word and is not generic filler. Punctuation,
        bold markers and a lone period reduce to nothing and are not hooks.
    #>
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    if ((Get-MIPNormalizedPhrase -Text $Text) -eq '') { return $false }
    if (Test-MIPIsFiller -Text $Text) { return $false }
    return $true
}

function Test-MIPIsBareTitle {
    <#
        .SYNOPSIS
        True when every word of the link text already appears in its target's filename, so the
        pointer tells a reader nothing the filename does not.

        Matching is substring-against-the-filename's-letters, so hyphen and apostrophe splits
        ("pre-existing" vs "preexisting", "can't" vs "cannot") do not read as novel words.
    #>
    param([string]$LinkText, [string]$Target)

    $tokens = @(Get-MIPWordTokens -Text $LinkText)
    if ($tokens.Count -eq 0) { return $true }
    $soup = [regex]::Replace(([System.IO.Path]::GetFileNameWithoutExtension($Target)).ToLowerInvariant(), '[^a-z0-9]+', '')
    foreach ($t in $tokens) { if ($soup -notlike "*$t*") { return $false } }
    return $true
}

function Get-MIPNormalizedBlock {
    param([string[]]$Lines)

    $trimmed = @($Lines | ForEach-Object { $_.TrimEnd() })
    $start = 0
    $end = $trimmed.Count - 1
    while ($start -le $end -and $trimmed[$start] -eq '') { $start++ }
    while ($end -ge $start -and $trimmed[$end] -eq '') { $end-- }
    if ($start -gt $end) { return @() }
    return @($trimmed[$start..$end])
}

function Get-MIPKindPrefixes {
    param([string]$Text)

    return @(([regex]'`(?<k>[A-Za-z][A-Za-z0-9-]*_)`').Matches($Text) |
            ForEach-Object { $_.Groups['k'].Value } | Sort-Object -Unique)
}

function New-MIPRefusal {
    param([string]$Reason, [string[]]$Detail = @(), [string]$IndexPath)

    return [pscustomobject]@{
        Result = 'refused'; ExitCode = 2; Reason = $Reason; Detail = @($Detail); Index = $IndexPath
    }
}

function Invoke-MemoryIndexPolicyCheck {
    <#
        .SYNOPSIS
        Checks one memory index against the canonical policy text and returns a report object.
        Reads two files and nothing else; never writes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$IndexPath,
        [Parameter()][string]$PolicyReferencePath
    )

    if (-not (Test-Path -LiteralPath $IndexPath -PathType Leaf)) {
        return [pscustomobject]@{
            Result = 'usage-error'; ExitCode = 3; Reason = "index not found at '$IndexPath'"; Index = $IndexPath
        }
    }
    if ([string]::IsNullOrWhiteSpace($PolicyReferencePath)) {
        $PolicyReferencePath = Join-Path (Split-Path -Parent $PSScriptRoot) '..' 'SKILL.md'
    }
    if (-not (Test-Path -LiteralPath $PolicyReferencePath -PathType Leaf)) {
        return New-MIPRefusal -IndexPath $IndexPath -Reason 'policy reference copy not found' `
            -Detail @("looked for: $PolicyReferencePath")
    }

    # A present-but-unreadable file (locked by another writer, permissions) is a refusal, not a
    # defect verdict - the store is written by many sessions, so a transient lock is expected.
    try { $indexLines = @([System.IO.File]::ReadAllLines((Resolve-Path -LiteralPath $IndexPath).Path)) }
    catch { return New-MIPRefusal -IndexPath $IndexPath -Reason 'index could not be read' -Detail @($_.Exception.Message) }
    try { $refLines = @([System.IO.File]::ReadAllLines((Resolve-Path -LiteralPath $PolicyReferencePath).Path)) }
    catch { return New-MIPRefusal -IndexPath $IndexPath -Reason 'policy reference copy could not be read' -Detail @($_.Exception.Message) }

    # --- reference copy: canonical text between explicit markers ---------------------------
    $beginIdx = -1
    $endIdx = -1
    for ($i = 0; $i -lt $refLines.Count; $i++) {
        if ($beginIdx -lt 0 -and $refLines[$i].Trim() -eq $script:CanonicalBeginMarker) { $beginIdx = $i; continue }
        if ($beginIdx -ge 0 -and $endIdx -lt 0 -and $refLines[$i].Trim() -eq $script:CanonicalEndMarker) { $endIdx = $i }
    }
    if ($beginIdx -lt 0 -or $endIdx -lt 0 -or $endIdx -le $beginIdx + 1) {
        return New-MIPRefusal -IndexPath $IndexPath -Reason 'policy reference copy is malformed' -Detail @(
            "expected '$script:CanonicalBeginMarker' and '$script:CanonicalEndMarker' around the policy text",
            "in: $PolicyReferencePath")
    }
    $canonicalBlock = @(Get-MIPNormalizedBlock -Lines $refLines[($beginIdx + 1)..($endIdx - 1)])
    if ($canonicalBlock.Count -eq 0) {
        return New-MIPRefusal -IndexPath $IndexPath -Reason 'policy reference copy is malformed' `
            -Detail @('the canonical policy block is empty')
    }
    # The index-side header ends at the index's first section heading, so a '## ' inside the
    # policy text would silently truncate the compared region on one side only.
    if (@($canonicalBlock | Where-Object { $_ -match '^##\s' }).Count -gt 0) {
        return New-MIPRefusal -IndexPath $IndexPath -Reason 'policy reference copy is malformed' -Detail @(
            'the canonical policy block contains a "## " section heading',
            'that would make the index-side header boundary ambiguous; use "###" or deeper inside the policy')
    }
    $canonicalText = ($canonicalBlock -join "`n")

    # --- index structure --------------------------------------------------------------------
    $firstSectionIdx = -1
    $firstPointerIdx = -1
    $parsedLines = @{}
    $unparsedReports = [System.Collections.Generic.List[string]]::new()

    for ($i = 0; $i -lt $indexLines.Count; $i++) {
        if ($firstSectionIdx -lt 0 -and $indexLines[$i] -match '^##\s') { $firstSectionIdx = $i }
        if ($indexLines[$i] -notmatch $script:PointerLinePattern) { continue }
        $parsed = Get-MIPLinksInLine -Text $indexLines[$i]
        foreach ($u in $parsed.Unparsed) { $unparsedReports.Add("line $($i + 1): $u") }
        if (@($parsed.Links | Where-Object { $_.IsSubject }).Count -eq 0) { continue }
        $parsedLines[$i] = $parsed.Links
        if ($firstPointerIdx -lt 0) { $firstPointerIdx = $i }
    }

    if ($firstSectionIdx -lt 0) {
        return New-MIPRefusal -IndexPath $IndexPath -Reason 'index structure not recognized' -Detail @(
            'no "## " section heading found; the policy header is delimited by the first section heading')
    }
    if ($firstPointerIdx -lt 0) {
        return New-MIPRefusal -IndexPath $IndexPath -Reason 'index structure not recognized' -Detail @(
            'no pointer line found (a list item linking a .md entry)')
    }
    if ($unparsedReports.Count -gt 0) {
        return New-MIPRefusal -IndexPath $IndexPath -Reason 'a link-like construct could not be parsed' -Detail (@(
                'these would have been judged silently, so no counts are reported:') + @($unparsedReports))
    }

    # --- header (computed before the vocabulary refusal: the two axes are independent) --------
    $headerBlock = @(if ($firstSectionIdx -gt 0) { @(Get-MIPNormalizedBlock -Lines $indexLines[0..($firstSectionIdx - 1)]) } else { @() })
    $headerText = ($headerBlock -join "`n")

    # Presence keys off the canonical block's first three NON-BLANK lines, so a header whose
    # opening line was lightly edited reports INCOMPLETE with a divergence rather than
    # vanishing into "absent". A blank probe line would match any blank line anywhere.
    $probeLines = @($canonicalBlock | Where-Object { $_.Trim() -ne '' } | Select-Object -First 3)
    $headerPresent = $false
    $headerFoundAtLine = 0
    for ($i = 0; $i -lt $indexLines.Count; $i++) {
        if ($probeLines -ccontains $indexLines[$i].TrimEnd()) { $headerPresent = $true; $headerFoundAtLine = $i + 1; break }
    }
    $headerBeforeFirstPointer = ($firstSectionIdx -le $firstPointerIdx)
    $pointerInsideHeader = @($headerBlock | Where-Object { $_ -match $script:PointerLinePattern -and $_ -match '\]\(' }).Count -gt 0
    $headerComplete = $headerPresent -and $headerBeforeFirstPointer -and -not $pointerInsideHeader -and
        ($headerText -ceq $canonicalText)

    $headerDiff = ''
    if ($headerPresent -and -not $headerComplete) {
        if ($pointerInsideHeader) {
            $headerDiff = 'a pointer line sits inside the header region, above the first section heading'
        }
        elseif (-not $headerBeforeFirstPointer) {
            $headerDiff = 'the policy text does not sit before the first pointer line'
        }
        elseif ($headerBlock.Count -eq 0) {
            $headerDiff = "the policy text appears at line $headerFoundAtLine but not in the header region (above the first section heading)"
        }
        else {
            $limit = [Math]::Max($headerBlock.Count, $canonicalBlock.Count)
            for ($i = 0; $i -lt $limit; $i++) {
                $a = if ($i -lt $headerBlock.Count) { $headerBlock[$i] } else { '<end of header>' }
                $b = if ($i -lt $canonicalBlock.Count) { $canonicalBlock[$i] } else { '<end of canonical text>' }
                if (-not ($a -ceq $b)) {
                    $headerDiff = "first divergence at header line $($i + 1): header has '$a'; reference has '$b'"
                    break
                }
            }
        }
    }

    # --- entry-kind vocabulary ----------------------------------------------------------------
    # Read the kinds from the store's own header when it carries them, so a store that adapted
    # its policy text is checked against the kinds it actually names; fall back to the reference.
    $kindPrefixes = @(Get-MIPKindPrefixes -Text $headerText)
    $kindSource = 'index header'
    if ($kindPrefixes.Count -eq 0) {
        $kindPrefixes = @(Get-MIPKindPrefixes -Text $canonicalText)
        $kindSource = 'reference copy'
    }
    if ($kindPrefixes.Count -eq 0) {
        return New-MIPRefusal -IndexPath $IndexPath -Reason 'policy reference copy is malformed' -Detail @(
            'neither the index header nor the canonical policy text names any entry-kind prefix')
    }

    # --- subjects -------------------------------------------------------------------------------
    $subjects = [System.Collections.Generic.List[object]]::new()
    $sharedNotes = [System.Collections.Generic.List[object]]::new()

    foreach ($lineNo in ($parsedLines.Keys | Sort-Object)) {
        $line = $indexLines[$lineNo]
        $all = @($parsedLines[$lineNo])
        $subjectLinks = @($all | Where-Object { $_.IsSubject })

        $prefix = $line.Substring(0, $all[0].Start) -replace $script:PointerLinePattern, ''
        $prefix = ($prefix -replace $script:SeparatorTrimHead, '') -replace $script:SeparatorTrimTail, ''

        $withoutHook = 0
        for ($k = 0; $k -lt $all.Count; $k++) {
            $link = $all[$k]
            $sliceEnd = if ($k -lt $all.Count - 1) { $all[$k + 1].Start } else { $line.Length }
            $clause = $line.Substring($link.End, $sliceEnd - $link.End)
            $clause = ($clause -replace $script:SeparatorTrimHead, '') -replace $script:SeparatorTrimTail, ''
            $clauseIsHook = Test-MIPSaysSomething -Text $clause
            if (-not $link.IsSubject) { continue }

            # R1 is disjunctive: a subject conforms on EITHER its own clause or its link text.
            # The link-text test therefore runs on its own merits, never as a consolation branch
            # reached only when the clause failed.
            $hasHook = $false
            $why = ''
            if ($clauseIsHook) { $hasHook = $true }
            elseif (Test-MIPIsFiller -Text $link.LinkText) { $why = 'link text is generic filler' }
            elseif (-not (Test-MIPIsBareTitle -LinkText $link.LinkText -Target $link.Target)) { $hasHook = $true }
            elseif ($clause -ne '') { $why = 'clause is generic filler, and the link text is a bare title' }
            else { $why = 'bare title: every word already appears in the filename' }

            if (-not $hasHook) { $withoutHook++ }
            $subjects.Add([pscustomobject]@{
                    Line = $lineNo + 1; Target = $link.Target; LinkText = $link.LinkText
                    Clause = $clause; HasHook = $hasHook; Reason = $why
                })
        }

        # R2: one note before or after a run of subjects that are themselves left bare. Keyed on
        # missing hooks, not missing clauses - a grouped line whose link texts each state their
        # lesson is the shape the chunked-delivery brief carves out, not the defect. A trailing
        # shared note is syntactically indistinguishable from the last link's own clause, so the
        # signal that it is shared is that a sibling subject on the line is bare.
        if ($subjectLinks.Count -ge 2 -and $withoutHook -ge 1) {
            $trailing = $line.Substring($all[$all.Count - 1].End)
            $trailing = ($trailing -replace $script:SeparatorTrimHead, '') -replace $script:SeparatorTrimTail, ''
            foreach ($candidate in @(@{ p = 'leading'; t = $prefix }, @{ p = 'trailing'; t = $trailing })) {
                if (-not (Test-MIPSaysSomething -Text $candidate.t)) { continue }
                if (@(Get-MIPWordTokens -Text $candidate.t).Count -lt $script:NoteWordFloor) { continue }
                $sharedNotes.Add([pscustomobject]@{
                        Line = $lineNo + 1; Position = $candidate.p
                        Subjects = @($subjectLinks | ForEach-Object { $_.Target }); Note = $candidate.t
                    })
            }
        }
    }

    $matchingKind = @($subjects | Where-Object {
            $name = [System.IO.Path]::GetFileName($_.Target)
            $hit = $false
            foreach ($p in $kindPrefixes) { if ($name.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase)) { $hit = $true } }
            $hit
        })
    if ($matchingKind.Count -eq 0) {
        return New-MIPRefusal -IndexPath $IndexPath -Reason 'entry-kind vocabulary not recognized' -Detail @(
            ("policy names: " + ($kindPrefixes -join ', ') + " (read from the $kindSource)"),
            'no linked entry in this index carries any of those prefixes',
            "adapt the policy text to this store first - see '$script:AdaptNoteHeadingLabel' in $PolicyReferencePath")
    }

    $noHook = @($subjects | Where-Object { -not $_.HasHook })
    $clean = $headerComplete -and ($noHook.Count -eq 0) -and ($sharedNotes.Count -eq 0)

    return [pscustomobject]@{
        Result                   = if ($clean) { 'clean' } else { 'defects' }
        ExitCode                 = if ($clean) { 0 } else { 1 }
        Index                    = $IndexPath
        Reference                = $PolicyReferencePath
        ExcludedFromComparison   = $script:AdaptNoteHeadingLabel
        KindPrefixes             = $kindPrefixes
        KindPrefixSource         = $kindSource
        EntriesMatchingKind      = $matchingKind.Count
        EntriesNotMatchingKind   = $subjects.Count - $matchingKind.Count
        SubjectsTotal            = $subjects.Count
        HeaderPresent            = $headerPresent
        HeaderComplete           = $headerComplete
        HeaderBeforeFirstPointer = $headerBeforeFirstPointer
        HeaderDivergence         = $headerDiff
        SubjectsWithoutHook      = $noHook.Count
        UnattributedSharedNotes  = $sharedNotes.Count
        WithoutHook              = @($noHook)
        SharedNotes              = @($sharedNotes)
    }
}

function Format-MemoryIndexPolicyReport {
    <#
        .SYNOPSIS
        Renders a report object as human-readable lines, or as one JSON object when -AsJson.
        Every terminal path renders through here, so -Json is honored everywhere.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Report,
        [Parameter()][switch]$AsJson
    )

    if ($AsJson) {
        $payload = [ordered]@{ result = $Report.Result; index = $Report.Index }
        switch ($Report.Result) {
            'usage-error' { $payload['reason'] = $Report.Reason }
            'refused' { $payload['reason'] = $Report.Reason; $payload['detail'] = @($Report.Detail) }
            default {
                $payload['reference'] = $Report.Reference
                $payload['excluded_from_comparison'] = $Report.ExcludedFromComparison
                $payload['kind_prefixes'] = @($Report.KindPrefixes)
                $payload['kind_prefix_source'] = $Report.KindPrefixSource
                $payload['entries_matching_kind'] = $Report.EntriesMatchingKind
                $payload['entries_not_matching_kind'] = $Report.EntriesNotMatchingKind
                $payload['subjects_total'] = $Report.SubjectsTotal
                $payload['header_present'] = $Report.HeaderPresent
                $payload['header_complete'] = $Report.HeaderComplete
                $payload['header_before_first_pointer'] = $Report.HeaderBeforeFirstPointer
                $payload['header_divergence'] = $Report.HeaderDivergence
                $payload['subjects_without_hook'] = $Report.SubjectsWithoutHook
                $payload['unattributed_shared_notes'] = $Report.UnattributedSharedNotes
                $payload['without_hook'] = @($Report.WithoutHook | ForEach-Object {
                        [ordered]@{ line = $_.Line; target = $_.Target; link_text = $_.LinkText; reason = $_.Reason } })
                $payload['shared_notes'] = @($Report.SharedNotes | ForEach-Object {
                        [ordered]@{ line = $_.Line; position = $_.Position; subjects = @($_.Subjects); note = $_.Note } })
            }
        }
        return ([pscustomobject]$payload | ConvertTo-Json -Depth 6)
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    if ($Report.Result -eq 'usage-error') {
        $lines.Add('RESULT: usage-error')
        $lines.Add("reason: $($Report.Reason)")
        return $lines.ToArray()
    }
    if ($Report.Result -eq 'refused') {
        $lines.Add('RESULT: refused')
        $lines.Add("reason: $($Report.Reason)")
        foreach ($d in $Report.Detail) { $lines.Add("  $d") }
        $lines.Add('No counts are reported: a verdict on input this check does not fully recognize would be a guess.')
        return $lines.ToArray()
    }

    $headerStatus = if (-not $Report.HeaderPresent) { 'absent' } elseif ($Report.HeaderComplete) { 'present, complete' } else { 'present, INCOMPLETE' }
    $lines.Add("RESULT: $($Report.Result)")
    $lines.Add("header: $headerStatus")
    if ($Report.HeaderDivergence -ne '') { $lines.Add("  $($Report.HeaderDivergence)") }
    $lines.Add("subjects_without_hook: $($Report.SubjectsWithoutHook)")
    $lines.Add("unattributed_shared_notes: $($Report.UnattributedSharedNotes)")
    $lines.Add('')
    $lines.Add("index: $($Report.Index)")
    $lines.Add("reference: $($Report.Reference)")
    $lines.Add("excluded from comparison: $($Report.ExcludedFromComparison)")
    $lines.Add("entry kinds named by the policy: " + ($Report.KindPrefixes -join ', ') +
        " (read from the $($Report.KindPrefixSource); matched $($Report.EntriesMatchingKind) of $($Report.SubjectsTotal) linked subjects)")
    if ($Report.EntriesNotMatchingKind -gt 0) {
        $lines.Add("  note: $($Report.EntriesNotMatchingKind) linked subject(s) carry none of those prefixes and were judged under this store's rules anyway")
    }
    if ($Report.SubjectsWithoutHook -gt 0) {
        $lines.Add('')
        $lines.Add('subjects without a recall hook:')
        foreach ($s in $Report.WithoutHook) { $lines.Add(("  line {0,-4} {1} [{2}] - {3}" -f $s.Line, $s.Target, $s.LinkText, $s.Reason)) }
    }
    if ($Report.UnattributedSharedNotes -gt 0) {
        $lines.Add('')
        $lines.Add('unattributed shared notes:')
        foreach ($n in $Report.SharedNotes) { $lines.Add(("  line {0,-4} {1} subjects share a {2} note '{3}'" -f $n.Line, @($n.Subjects).Count, $n.Position, $n.Note)) }
    }
    return $lines.ToArray()
}
