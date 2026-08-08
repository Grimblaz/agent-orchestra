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
      clean        0 - conforms on all four axes
      defects      1 - at least one axis reports a defect
      refused      2 - input not fully recognized; no counts are reported
      usage-error  3 - the invocation itself was wrong

    Two store shapes are recognized, and the shape is read from the index, not configured:

      legacy - the index carries the full policy text as its own header, above the first
               section heading. This is the pre-split shape and stays supported.
      split  - the index carries only the canonical stanza, wrapped in
               'memory-policy-stanza-begin: <path>' / 'memory-policy-stanza-end' markers, and
               the path names a policy file beside the index holding the canonical policy
               text plus this store's own values.

    A store carrying the stanza whose policy file does not exist yet is 'split-incomplete' -
    half-migrated. That is a defect with its own wording, deliberately distinct from a policy
    file that exists and cannot be read, which is a refusal. Collapsing the two would report
    a store mid-migration as broken and a broken store as mid-migration.

    The size axis is data-driven: it is evaluated only for a store that records budget inputs.
    A store that records none reports 'not evaluated' - the legacy shape has nowhere to record
    them, and an axis that fired anyway would be migration pressure rather than a measurement.
    A store that records inputs the check cannot use reports 'could not verify' on that axis
    alone, with the other three still counted.
#>

Set-StrictMode -Version Latest

# --- reference-side markers (the shipped SKILL.md, or an adapted copy) ---------------------
$script:CanonicalBeginMarker = '<!-- policy-canonical-begin -->'
$script:CanonicalEndMarker = '<!-- policy-canonical-end -->'
$script:StanzaCanonicalBeginMarker = '<!-- stanza-canonical-begin -->'
$script:StanzaCanonicalEndMarker = '<!-- stanza-canonical-end -->'
$script:AdaptNoteHeadingLabel = '## Adapting this to your store (not part of the compared text)'

# --- store-side markers -------------------------------------------------------------------
# The opening stanza marker carries the policy file's path. That is an instance value, and it
# sits on the marker line precisely so it stays outside every compared region: naming a
# different file must never read as a divergence from the shipped text.
$script:StoreStanzaBeginPattern = '^<!--\s*memory-policy-stanza-begin\s*:\s*(?<path>.+?)\s*-->$'
$script:StoreStanzaEndMarker = '<!-- memory-policy-stanza-end -->'
$script:StoreValuesBeginMarker = '<!-- store-values-begin -->'
$script:StoreValuesEndMarker = '<!-- store-values-end -->'

# --- size axis ----------------------------------------------------------------------------
# The unit is pinned, not inferred. An observation recorded in any other unit is rejected
# rather than converted: a budget compared against a measurement in a different unit passes or
# fails by accident, and the two units differ on exactly the characters a memory index is full
# of (em dashes, arrows, box drawing).
$script:SizeAxisUnit = 'characters'
$script:DefaultBudgetFraction = 0.80
$script:DefaultStalenessBoundDays = 30

# --- policy-presence probe ----------------------------------------------------------------
# Presence asks one question: does this index carry a policy header at all, as opposed to
# none? It is answered by overlap with the reference text, scoped to the header region, and
# NOT by any specific opening line. Keying on fixed opening lines made the verdict hostage to
# the reference's own wording - a rewrite that changed them would have turned every existing
# store's diverged header into "absent" and silently dropped the divergence message with it.
# Only lines long enough to be distinctive count, so a stray code fence cannot answer yes.
$script:PresenceProbeMinLength = 30

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

function Get-MIPMarkedRegion {
    <#
        .SYNOPSIS
        Returns the normalized block between two literal marker lines, with the indices of the
        markers themselves. Found is false when either marker is missing or they are adjacent.
    #>
    param([string[]]$Lines, [string]$BeginMarker, [string]$EndMarker)

    $beginIdx = -1
    $endIdx = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($beginIdx -lt 0 -and $Lines[$i].Trim() -eq $BeginMarker) { $beginIdx = $i; continue }
        if ($beginIdx -ge 0 -and $endIdx -lt 0 -and $Lines[$i].Trim() -eq $EndMarker) { $endIdx = $i }
    }
    if ($beginIdx -lt 0 -or $endIdx -lt 0 -or $endIdx -le $beginIdx + 1) {
        return [pscustomobject]@{ Found = $false; Block = @(); BeginIndex = $beginIdx; EndIndex = $endIdx }
    }
    return [pscustomobject]@{
        Found      = $true
        Block      = @(Get-MIPNormalizedBlock -Lines $Lines[($beginIdx + 1)..($endIdx - 1)])
        BeginIndex = $beginIdx
        EndIndex   = $endIdx
    }
}

function Get-MIPKindPrefixes {
    param([string]$Text)

    return @(([regex]'`(?<k>[A-Za-z][A-Za-z0-9-]*_)`').Matches($Text) |
            ForEach-Object { $_.Groups['k'].Value } | Sort-Object -Unique)
}

function Get-MIPFirstDivergence {
    <#
        .SYNOPSIS
        Names the first line on which an adopted text departs from the reference, in the
        adopted text's own line numbering.
    #>
    param([string[]]$Actual, [string[]]$Expected, [string]$Label)

    $limit = [Math]::Max($Actual.Count, $Expected.Count)
    for ($i = 0; $i -lt $limit; $i++) {
        $a = if ($i -lt $Actual.Count) { $Actual[$i] } else { "<end of $Label>" }
        $b = if ($i -lt $Expected.Count) { $Expected[$i] } else { '<end of reference text>' }
        if (-not ($a -ceq $b)) {
            return "first divergence at $Label line $($i + 1): $Label has '$a'; reference has '$b'"
        }
    }
    return ''
}

function Format-MIPCount {
    <#
        .SYNOPSIS
        Thousands-separated, in the invariant culture, so a report reads the same on every
        machine that runs it and a test can assert on it.
    #>
    param([int]$Value)

    return $Value.ToString('N0', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Measure-MIPCharacters {
    <#
        .SYNOPSIS
        The pinned counting rule: UTF-8 decoded, CRLF and lone CR normalized to LF, length in
        UTF-16 code units. Stated in the shipped policy text so a measurement reproduces.
    #>
    param([string]$Text)

    return ($Text -replace "`r`n", "`n" -replace "`r", "`n").Length
}

function Get-MIPStoreStanza {
    <#
        .SYNOPSIS
        Finds the split-shape stanza in an index and the policy-file path its opening marker
        carries. Found is true as soon as the opening marker appears: a store that has
        declared itself split is never silently read back as legacy, even when the rest of the
        declaration is broken.
    #>
    param([string[]]$Lines)

    $beginIdx = -1
    $policyPath = ''
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $m = [regex]::Match($Lines[$i].Trim(), $script:StoreStanzaBeginPattern)
        if ($m.Success) { $beginIdx = $i; $policyPath = $m.Groups['path'].Value.Trim(); break }
    }
    if ($beginIdx -lt 0) {
        return [pscustomobject]@{ Found = $false; Malformed = $false; Reason = ''; PolicyPath = ''; Block = @(); BeginIndex = -1; EndIndex = -1 }
    }

    $endIdx = -1
    for ($i = $beginIdx + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].Trim() -eq $script:StoreStanzaEndMarker) { $endIdx = $i; break }
    }
    if ($endIdx -lt 0) {
        return [pscustomobject]@{
            Found = $true; Malformed = $true; PolicyPath = $policyPath; Block = @(); BeginIndex = $beginIdx; EndIndex = -1
            Reason = "the stanza opens at line $($beginIdx + 1) and is never closed by '$script:StoreStanzaEndMarker'"
        }
    }
    $block = @(Get-MIPNormalizedBlock -Lines $Lines[($beginIdx + 1)..($endIdx - 1)])
    if ($block.Count -eq 0) {
        return [pscustomobject]@{
            Found = $true; Malformed = $true; PolicyPath = $policyPath; Block = @(); BeginIndex = $beginIdx; EndIndex = $endIdx
            Reason = "the stanza at line $($beginIdx + 1) is empty"
        }
    }
    return [pscustomobject]@{
        Found = $true; Malformed = $false; Reason = ''; PolicyPath = $policyPath
        Block = $block; BeginIndex = $beginIdx; EndIndex = $endIdx
    }
}

function Get-MIPStoreValues {
    <#
        .SYNOPSIS
        Parses a store's own values out of its policy file: the budget fraction, the staleness
        bound, and every recorded limit observation.

        The record is append-only by construction. 'limit_observation' repeats, one line per
        observation, and the freshest by date governs - so re-observing the limit adds a line
        and never rewrites one.

        A line the parser does not understand becomes an error rather than a skipped line: a
        budget silently computed from a partially-understood record is exactly the wrong
        failure.
    #>
    param([string[]]$Lines)

    $region = Get-MIPMarkedRegion -Lines $Lines -BeginMarker $script:StoreValuesBeginMarker -EndMarker $script:StoreValuesEndMarker
    if (-not $region.Found) {
        return [pscustomobject]@{ Present = $false; Fraction = $null; StalenessBoundDays = $null; Observations = @(); Errors = @() }
    }

    $fraction = $null
    $staleness = $null
    $observations = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()

    foreach ($raw in $region.Block) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('```') -or $line.StartsWith('<!--') -or $line.StartsWith('#')) { continue }

        $split = $line.IndexOf(':')
        if ($split -lt 1) { $errors.Add("not a 'key: value' line: '$line'"); continue }
        $key = $line.Substring(0, $split).Trim().ToLowerInvariant()
        $value = $line.Substring($split + 1).Trim()

        switch ($key) {
            'budget_fraction' {
                $parsed = 0.0
                if (-not [double]::TryParse($value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -or $parsed -le 0 -or $parsed -gt 1) {
                    $errors.Add("budget_fraction must be a number greater than 0 and at most 1; found '$value'")
                }
                else { $fraction = $parsed }
            }
            'staleness_bound_days' {
                $parsedDays = 0
                if (-not [int]::TryParse($value, [ref]$parsedDays) -or $parsedDays -le 0) {
                    $errors.Add("staleness_bound_days must be a positive whole number of days; found '$value'")
                }
                else { $staleness = $parsedDays }
            }
            'limit_observation' {
                $fields = @($value -split '\|' | ForEach-Object { $_.Trim() })
                if ($fields.Count -lt 3) {
                    $errors.Add("limit_observation must read 'date | value | unit | method'; found '$value'")
                    continue
                }
                $observedOn = [datetime]::MinValue
                if (-not [datetime]::TryParseExact($fields[0], 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$observedOn)) {
                    $errors.Add("limit_observation date must be yyyy-MM-dd; found '$($fields[0])'")
                    continue
                }
                $observedValue = 0
                if (-not [int]::TryParse($fields[1], [ref]$observedValue) -or $observedValue -le 0) {
                    $errors.Add("limit_observation value must be a positive whole number; found '$($fields[1])'")
                    continue
                }
                if ($fields[2] -ne $script:SizeAxisUnit) {
                    $errors.Add("limit_observation unit must be '$script:SizeAxisUnit'; found '$($fields[2])' - this check does not convert between units")
                    continue
                }
                $observations.Add([pscustomobject]@{
                        ObservedOn = $observedOn
                        Value      = $observedValue
                        Unit       = $fields[2]
                        Method     = if ($fields.Count -ge 4) { ($fields[3..($fields.Count - 1)] -join ' | ') } else { '' }
                    })
            }
            default { $errors.Add("unrecognized key '$key'") }
        }
    }

    return [pscustomobject]@{
        Present            = $true
        Fraction           = $fraction
        StalenessBoundDays = $staleness
        Observations       = @($observations)
        Errors             = @($errors)
    }
}

function Get-MIPSizeAxis {
    <#
        .SYNOPSIS
        Builds the size axis. Four states, kept apart on purpose: nothing recorded, recorded
        but unusable, within budget, over budget. Folding the first two together would report
        a store that has never been measured in the same words as one whose record is broken.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$MeasuredCharacters,
        [Parameter()]$StoreValues,
        [Parameter(Mandatory = $true)][datetime]$AsOf,
        [Parameter()][string]$AbsentCause = 'this store records no budget inputs'
    )

    $axis = [ordered]@{
        State              = 'not-evaluated'
        Cause              = $AbsentCause
        Unit               = $script:SizeAxisUnit
        Measured           = $MeasuredCharacters
        Budget             = $null
        Fraction           = $null
        ObservedValue      = $null
        ObservedOn         = $null
        ObservedMethod     = $null
        StalenessBoundDays = $null
        ObservationAgeDays = $null
        Stale              = $false
    }

    if ($null -eq $StoreValues -or -not $StoreValues.Present) { return [pscustomobject]$axis }

    if ($StoreValues.Errors.Count -gt 0) {
        $axis.State = 'could-not-verify'
        $axis.Cause = 'the recorded budget inputs could not be read: ' + ($StoreValues.Errors -join '; ')
        return [pscustomobject]$axis
    }
    if ($StoreValues.Observations.Count -eq 0) {
        $axis.State = 'could-not-verify'
        $axis.Cause = 'the store records budget inputs but no limit observation'
        return [pscustomobject]$axis
    }

    $freshest = @($StoreValues.Observations | Sort-Object -Property ObservedOn)[-1]
    $fraction = if ($null -ne $StoreValues.Fraction) { $StoreValues.Fraction } else { $script:DefaultBudgetFraction }
    $bound = if ($null -ne $StoreValues.StalenessBoundDays) { $StoreValues.StalenessBoundDays } else { $script:DefaultStalenessBoundDays }
    $age = [int][Math]::Floor(($AsOf.Date - $freshest.ObservedOn.Date).TotalDays)

    $axis.Cause = ''
    $axis.Budget = [int][Math]::Floor($fraction * $freshest.Value)
    $axis.Fraction = $fraction
    $axis.ObservedValue = $freshest.Value
    $axis.ObservedOn = $freshest.ObservedOn.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    $axis.ObservedMethod = $freshest.Method
    $axis.StalenessBoundDays = $bound
    $axis.ObservationAgeDays = $age
    # Staleness is reported, never treated as a defect: the number may still be right, and
    # guessing a fresher one would be worse than saying how old this one is.
    $axis.Stale = ($age -gt $bound)
    $axis.State = if ($MeasuredCharacters -gt $axis.Budget) { 'over' } else { 'within' }

    return [pscustomobject]$axis
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
        Reads the index, the reference copy, and - for a split store - that store's own policy
        file. Never writes.

        .PARAMETER AsOf
        The date the observation's age is measured against. Internal to this function and
        deliberately absent from the entry point's parameter surface: it exists so the
        staleness signal has a red state in a test, not as an option to invoke with.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$IndexPath,
        [Parameter()][string]$PolicyReferencePath,
        [Parameter()][datetime]$AsOf = [datetime]::Now.Date
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
    $indexResolved = (Resolve-Path -LiteralPath $IndexPath).Path
    try {
        $indexLines = @([System.IO.File]::ReadAllLines($indexResolved))
        $indexCharacters = Measure-MIPCharacters -Text ([System.IO.File]::ReadAllText($indexResolved))
    }
    catch { return New-MIPRefusal -IndexPath $IndexPath -Reason 'index could not be read' -Detail @($_.Exception.Message) }
    try { $refLines = @([System.IO.File]::ReadAllLines((Resolve-Path -LiteralPath $PolicyReferencePath).Path)) }
    catch { return New-MIPRefusal -IndexPath $IndexPath -Reason 'policy reference copy could not be read' -Detail @($_.Exception.Message) }

    # --- reference copy: the two canonical texts, each between explicit markers --------------
    $canonicalRegion = Get-MIPMarkedRegion -Lines $refLines -BeginMarker $script:CanonicalBeginMarker -EndMarker $script:CanonicalEndMarker
    if (-not $canonicalRegion.Found -or $canonicalRegion.Block.Count -eq 0) {
        return New-MIPRefusal -IndexPath $IndexPath -Reason 'policy reference copy is malformed' -Detail @(
            "expected '$script:CanonicalBeginMarker' and '$script:CanonicalEndMarker' around a non-empty policy text",
            "in: $PolicyReferencePath")
    }
    $canonicalBlock = @($canonicalRegion.Block)
    # The index-side header ends at the index's first section heading, so a '## ' inside the
    # policy text would silently truncate the compared region on one side only.
    if (@($canonicalBlock | Where-Object { $_ -match '^##\s' }).Count -gt 0) {
        return New-MIPRefusal -IndexPath $IndexPath -Reason 'policy reference copy is malformed' -Detail @(
            'the canonical policy block contains a "## " section heading',
            'that would make the index-side header boundary ambiguous; use "###" or deeper inside the policy')
    }
    $canonicalText = ($canonicalBlock -join "`n")

    # The canonical stanza is judged but NOT demanded here. A reference copy that carries no
    # stanza can still judge a legacy store completely, and one such copy ships: the preserved
    # pre-supersession text, which predates the stanza and must stay usable. Refusing on it
    # eagerly would break the very no-forced-migration route this release exists to keep open.
    # So the problem is recorded now and raised only where the stanza text is actually needed.
    $stanzaRegion = Get-MIPMarkedRegion -Lines $refLines -BeginMarker $script:StanzaCanonicalBeginMarker -EndMarker $script:StanzaCanonicalEndMarker
    $canonicalStanzaBlock = @($stanzaRegion.Block)
    $canonicalStanzaText = ($canonicalStanzaBlock -join "`n")
    $stanzaReferenceProblem = ''
    if (-not $stanzaRegion.Found -or $canonicalStanzaBlock.Count -eq 0) {
        $stanzaReferenceProblem = "expected '$script:StanzaCanonicalBeginMarker' and '$script:StanzaCanonicalEndMarker' around a non-empty stanza"
    }
    elseif (@($canonicalStanzaBlock | Where-Object { $_ -match '^##\s' }).Count -gt 0) {
        $stanzaReferenceProblem = 'the canonical stanza contains a "## " section heading, and the stanza sits above the index''s first section heading, so that would truncate the header region'
    }

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

    # --- store shape ---------------------------------------------------------------------------
    $headerBlock = @(if ($firstSectionIdx -gt 0) { @(Get-MIPNormalizedBlock -Lines $indexLines[0..($firstSectionIdx - 1)]) } else { @() })
    $headerText = ($headerBlock -join "`n")
    $headerBeforeFirstPointer = ($firstSectionIdx -le $firstPointerIdx)
    $pointerInsideHeader = @($headerBlock | Where-Object { $_ -match $script:PointerLinePattern -and $_ -match '\]\(' }).Count -gt 0

    $stanza = Get-MIPStoreStanza -Lines $indexLines
    if ($stanza.Found -and $stanza.Malformed) {
        return New-MIPRefusal -IndexPath $IndexPath -Reason 'split-store stanza is malformed' -Detail @(
            $stanza.Reason,
            'the store declares the split shape, so it is not read back as a legacy store')
    }

    $storeShape = if ($stanza.Found) { 'split' } else { 'legacy' }
    $policyFilePath = ''
    $policySourceText = $headerText
    $storeValues = $null
    $policyComplete = $false
    $policyDivergence = ''
    $policyExplanation = @()
    $headerPresent = $false
    $policyStatus = ''

    if ($storeShape -eq 'legacy') {
        # Presence: overlap with the reference, scoped to the header region, on lines long
        # enough to be distinctive. See $script:PresenceProbeMinLength for why not fixed lines.
        $probeLines = @($canonicalBlock | Where-Object { $_.Trim().Length -ge $script:PresenceProbeMinLength })
        $headerPresent = @($headerBlock | Where-Object { $probeLines -ccontains $_ }).Count -gt 0
        $policyComplete = $headerPresent -and $headerBeforeFirstPointer -and -not $pointerInsideHeader -and ($headerText -ceq $canonicalText)

        if (-not $headerPresent) {
            $policyStatus = 'in-index header - absent'
            $elsewhere = @($indexLines | Where-Object { $probeLines -ccontains $_.TrimEnd() }).Count -gt 0
            if ($elsewhere) {
                $policyDivergence = 'policy text appears in this index but below its first section heading, outside the header region'
            }
        }
        elseif ($policyComplete) {
            $policyStatus = 'in-index header - present, complete'
        }
        else {
            $policyStatus = 'in-index header - present, INCOMPLETE'
            if ($pointerInsideHeader) {
                $policyDivergence = 'a pointer line sits inside the header region, above the first section heading'
            }
            elseif (-not $headerBeforeFirstPointer) {
                $policyDivergence = 'the policy text does not sit before the first pointer line'
            }
            else {
                $policyDivergence = Get-MIPFirstDivergence -Actual $headerBlock -Expected $canonicalBlock -Label 'header'
            }
            # Stated for every diverged legacy header, and conditionally, because recognizing
            # WHICH text a store carries is machinery this release deliberately does not add.
            $policyExplanation = @(
                'if this header predates the supersession of the never-retire ratchet, the divergence is that rewrite, not a defect in this store.',
                'three onward paths, and nothing here obliges any of them:',
                '  - adopt the split shape (see "Adopting the split shape" in the reference copy)',
                '  - keep a clean verdict by passing -PolicyReferencePath with the preserved pre-supersession text,',
                '    shipped at skills/agent-memory-compaction/templates/policy-pre-supersession.md',
                '  - do nothing; a diverged verdict is an honest report, not a failure')
        }
    }
    else {
        if ($stanzaReferenceProblem -ne '') {
            return New-MIPRefusal -IndexPath $IndexPath -Reason 'policy reference copy is malformed' -Detail @(
                $stanzaReferenceProblem,
                'this store declares the split shape, so the canonical stanza is required to judge it',
                "in: $PolicyReferencePath")
        }
        $stanzaBlock = @($stanza.Block)
        $stanzaText = ($stanzaBlock -join "`n")
        $headerPresent = $true
        $stanzaInHeaderRegion = ($stanza.BeginIndex -lt $firstSectionIdx)
        $stanzaComplete = $stanzaInHeaderRegion -and -not $pointerInsideHeader -and ($stanzaText -ceq $canonicalStanzaText)

        if ([string]::IsNullOrWhiteSpace($stanza.PolicyPath)) {
            return New-MIPRefusal -IndexPath $IndexPath -Reason 'split-store stanza is malformed' -Detail @(
                "the stanza's opening marker names no policy file",
                "expected: <!-- memory-policy-stanza-begin: POLICY.md -->")
        }
        $policyFilePath = Join-Path (Split-Path -Parent $indexResolved) $stanza.PolicyPath

        $policyTextComplete = $false
        $policyFileDivergence = ''
        if (-not (Test-Path -LiteralPath $policyFilePath -PathType Leaf)) {
            # Half-migrated: the stanza landed, the policy file has not. A defect with its own
            # wording, and deliberately not the same verdict as a file that cannot be read.
            $storeShape = 'split-incomplete'
            $policyFileDivergence = "the stanza names '$($stanza.PolicyPath)', and no such file sits beside this index (looked for: $policyFilePath)"
        }
        else {
            try { $policyLines = @([System.IO.File]::ReadAllLines((Resolve-Path -LiteralPath $policyFilePath).Path)) }
            catch {
                return New-MIPRefusal -IndexPath $IndexPath -Reason "this store's policy file could not be read" -Detail @(
                    "path: $policyFilePath", $_.Exception.Message,
                    'the file exists, so this is not the half-migrated state')
            }
            $storePolicyRegion = Get-MIPMarkedRegion -Lines $policyLines -BeginMarker $script:CanonicalBeginMarker -EndMarker $script:CanonicalEndMarker
            if (-not $storePolicyRegion.Found -or $storePolicyRegion.Block.Count -eq 0) {
                return New-MIPRefusal -IndexPath $IndexPath -Reason "this store's policy file is malformed" -Detail @(
                    "expected '$script:CanonicalBeginMarker' and '$script:CanonicalEndMarker' around a non-empty policy text",
                    "in: $policyFilePath")
            }
            $storePolicyBlock = @($storePolicyRegion.Block)
            $policyTextComplete = (($storePolicyBlock -join "`n") -ceq $canonicalText)
            if (-not $policyTextComplete) {
                $policyFileDivergence = Get-MIPFirstDivergence -Actual $storePolicyBlock -Expected $canonicalBlock -Label 'policy file'
            }
            $policySourceText = ($policyLines -join "`n")
            $storeValues = Get-MIPStoreValues -Lines $policyLines
        }

        $policyComplete = $stanzaComplete -and $policyTextComplete
        $shapeLabel = if ($storeShape -eq 'split-incomplete') { 'split, half-migrated' } else { 'split' }
        if ($policyComplete) {
            $policyStatus = 'split - stanza and policy file both match the reference'
        }
        else {
            $stanzaWord = if ($stanzaComplete) { 'stanza complete' } else { 'stanza INCOMPLETE' }
            $fileWord = if ($storeShape -eq 'split-incomplete') { 'policy file missing' } elseif ($policyTextComplete) { 'policy file complete' } else { 'policy file INCOMPLETE' }
            $policyStatus = "$shapeLabel - $stanzaWord, $fileWord"
            $parts = [System.Collections.Generic.List[string]]::new()
            if (-not $stanzaComplete) {
                if (-not $stanzaInHeaderRegion) { $parts.Add("the stanza opens at line $($stanza.BeginIndex + 1), below the index's first section heading") }
                elseif ($pointerInsideHeader) { $parts.Add('a pointer line sits inside the header region, above the first section heading') }
                else { $parts.Add((Get-MIPFirstDivergence -Actual $stanzaBlock -Expected $canonicalStanzaBlock -Label 'stanza')) }
            }
            if ($policyFileDivergence -ne '') { $parts.Add($policyFileDivergence) }
            $policyDivergence = ($parts -join '; ')
            if ($storeShape -eq 'split-incomplete') {
                $policyExplanation = @(
                    'this store is half-migrated: create the policy file the stanza names, carrying the canonical',
                    'policy text between its markers and this store''s own values outside them.')
            }
        }
    }

    # --- entry-kind vocabulary ----------------------------------------------------------------
    # Read the kinds from the store's OWN policy text - the policy file under the split shape,
    # the index header otherwise - so a store that adapted its policy is checked against the
    # kinds it actually names; fall back to the reference.
    # Named for where the text was actually read, not for the shape the store aspires to: a
    # half-migrated store has no policy file, so it cannot be the source of anything.
    $kindPrefixes = @(Get-MIPKindPrefixes -Text $policySourceText)
    $kindSource = if ($storeShape -eq 'split') { 'store policy file' } else { 'index header' }
    if ($kindPrefixes.Count -eq 0) {
        $kindPrefixes = @(Get-MIPKindPrefixes -Text $canonicalText)
        $kindSource = 'reference copy'
    }
    if ($kindPrefixes.Count -eq 0) {
        return New-MIPRefusal -IndexPath $IndexPath -Reason 'policy reference copy is malformed' -Detail @(
            "neither this store's policy text nor the canonical policy text names any entry-kind prefix")
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

    # --- size ------------------------------------------------------------------------------------
    # A half-migrated store has no budget inputs because its policy file does not exist yet.
    # Saying that is not the same statement as "records none", and it is the one a reader can act on.
    $absentCause = if ($storeShape -eq 'split-incomplete') {
        "this store's policy file does not exist yet, so it records no budget inputs"
    }
    else { 'this store records no budget inputs' }
    $size = Get-MIPSizeAxis -MeasuredCharacters $indexCharacters -StoreValues $storeValues -AsOf $AsOf -AbsentCause $absentCause

    $noHook = @($subjects | Where-Object { -not $_.HasHook })
    $sizeDefect = ($size.State -eq 'over' -or $size.State -eq 'could-not-verify')
    $clean = $policyComplete -and ($noHook.Count -eq 0) -and ($sharedNotes.Count -eq 0) -and -not $sizeDefect

    return [pscustomobject]@{
        Result                   = if ($clean) { 'clean' } else { 'defects' }
        ExitCode                 = if ($clean) { 0 } else { 1 }
        Index                    = $IndexPath
        Reference                = $PolicyReferencePath
        ExcludedFromComparison   = $script:AdaptNoteHeadingLabel
        StoreShape               = $storeShape
        PolicyFile               = $policyFilePath
        PolicyStatus             = $policyStatus
        PolicyExplanation        = @($policyExplanation)
        KindPrefixes             = $kindPrefixes
        KindPrefixSource         = $kindSource
        EntriesMatchingKind      = $matchingKind.Count
        EntriesNotMatchingKind   = $subjects.Count - $matchingKind.Count
        SubjectsTotal            = $subjects.Count
        HeaderPresent            = $headerPresent
        HeaderComplete           = $policyComplete
        HeaderBeforeFirstPointer = $headerBeforeFirstPointer
        HeaderDivergence         = $policyDivergence
        Size                     = $size
        SubjectsWithoutHook      = $noHook.Count
        UnattributedSharedNotes  = $sharedNotes.Count
        WithoutHook              = @($noHook)
        SharedNotes              = @($sharedNotes)
    }
}

function Format-MIPSizeLine {
    <#
        .SYNOPSIS
        Renders the size axis. The budget never appears as a bare number: the formula and the
        dated observation behind it travel with it on the same line, so no reader and no
        copy-paste can turn it back into a hand-picked absolute.
    #>
    param([Parameter(Mandatory = $true)]$Size)

    if ($Size.State -eq 'not-evaluated') { return "not evaluated - $($Size.Cause)" }
    if ($Size.State -eq 'could-not-verify') { return "could not verify - $($Size.Cause)" }

    $fraction = $Size.Fraction.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
    $basis = "budget = $fraction of the $(Format-MIPCount -Value $Size.ObservedValue)-$($Size.Unit.TrimEnd('s')) limit observed $($Size.ObservedOn)"
    $line = "$(Format-MIPCount -Value $Size.Measured) of $(Format-MIPCount -Value $Size.Budget) $($Size.Unit) ($basis)"
    if ($Size.State -eq 'over') {
        $over = $Size.Measured - $Size.Budget
        $line = "$(Format-MIPCount -Value $Size.Measured) of $(Format-MIPCount -Value $Size.Budget) $($Size.Unit) - OVER BY $(Format-MIPCount -Value $over) ($basis)"
    }
    if ($Size.Stale) {
        $line += " [the observation is $($Size.ObservationAgeDays) days old against a $($Size.StalenessBoundDays)-day bound - re-observe the limit]"
    }
    return $line
}

function Format-MemoryIndexPolicyReport {
    <#
        .SYNOPSIS
        Renders a report object as human-readable lines, or as one JSON object when -AsJson.
        Every terminal path renders through here, so -Json is honored everywhere, and the JSON
        carries the same new-state information as the text.
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
                $payload['store_shape'] = $Report.StoreShape
                $payload['policy_file'] = $Report.PolicyFile
                $payload['policy_status'] = $Report.PolicyStatus
                $payload['policy_explanation'] = @($Report.PolicyExplanation)
                $payload['kind_prefixes'] = @($Report.KindPrefixes)
                $payload['kind_prefix_source'] = $Report.KindPrefixSource
                $payload['entries_matching_kind'] = $Report.EntriesMatchingKind
                $payload['entries_not_matching_kind'] = $Report.EntriesNotMatchingKind
                $payload['subjects_total'] = $Report.SubjectsTotal
                $payload['header_present'] = $Report.HeaderPresent
                $payload['header_complete'] = $Report.HeaderComplete
                $payload['header_before_first_pointer'] = $Report.HeaderBeforeFirstPointer
                $payload['header_divergence'] = $Report.HeaderDivergence
                $payload['size'] = [ordered]@{
                    state                = $Report.Size.State
                    cause                = $Report.Size.Cause
                    unit                 = $Report.Size.Unit
                    measured             = $Report.Size.Measured
                    budget               = $Report.Size.Budget
                    fraction             = $Report.Size.Fraction
                    observation_value    = $Report.Size.ObservedValue
                    observation_date     = $Report.Size.ObservedOn
                    observation_method   = $Report.Size.ObservedMethod
                    staleness_bound_days = $Report.Size.StalenessBoundDays
                    observation_age_days = $Report.Size.ObservationAgeDays
                    stale                = $Report.Size.Stale
                }
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

    $lines.Add("RESULT: $($Report.Result)")
    $lines.Add("policy: $($Report.PolicyStatus)")
    if ($Report.HeaderDivergence -ne '') { $lines.Add("  $($Report.HeaderDivergence)") }
    foreach ($e in $Report.PolicyExplanation) { $lines.Add("  $e") }
    $lines.Add("size: $(Format-MIPSizeLine -Size $Report.Size)")
    $lines.Add("subjects_without_hook: $($Report.SubjectsWithoutHook)")
    $lines.Add("unattributed_shared_notes: $($Report.UnattributedSharedNotes)")
    $lines.Add('')
    $lines.Add("index: $($Report.Index)")
    $lines.Add("reference: $($Report.Reference)")
    if ($Report.PolicyFile -ne '') { $lines.Add("store policy file: $($Report.PolicyFile)") }
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
