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
#
# Both patterns are anchored at column 0 and matched against the line with only its TRAILING
# whitespace removed. An indented marker does not declare anything - the shipped documentation
# prints this marker inside examples, and a store that quotes those examples must not thereby
# change what shape it is. Scoping (the header region only) is the primary guard; refusing
# indentation is the second, because prose can quote a marker at column 0 too.
$script:StoreStanzaBeginPattern = '^<!--\s*memory-policy-stanza-begin\s*:\s*(?<path>.+?)\s*-->$'
# Anything that is recognisably an opening stanza marker, however malformed. A store whose
# marker matches this but not the pattern above declared the split shape and got the
# declaration wrong, which is a refusal - never a silent fall back to the legacy shape.
$script:StoreStanzaLooseBeginPattern = '^<!--\s*memory-policy-stanza-begin\b.*-->$'
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
        Returns every markdown link in one line, ordered by where it starts, plus any ']( '
        construct that could not be parsed unambiguously.

        A single left-to-right scan with a bracket stack, so link text may itself contain
        square brackets (a literal [ref], say) and the cost stays linear in line length.

        The stack closes inner links first, so the raw scan yields links in CLOSING order. The
        caller slices each subject's clause from one link's end to the next link's start, which
        needs starting order - and a nested link ([a [b](x.md) c](y.md)) has no consistent
        order at all, because one link's span contains the other's. So the result is sorted by
        start, and any pair that still overlaps is reported as unparsed: the caller's existing
        refusal is the honest answer, since which subject a clause belongs to is genuinely
        ambiguous there. Left unhandled this computed a negative substring length and threw,
        exiting 1 with no report and an empty -Json payload.
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

    $ordered = @($links | Sort-Object -Property Start)
    for ($k = 0; $k -lt $ordered.Count - 1; $k++) {
        if ($ordered[$k].End -gt $ordered[$k + 1].Start) {
            $at = $ordered[$k].Start
            $unparsed.Add('nested or overlapping links: ' + $Text.Substring($at, [Math]::Min(40, $Text.Length - $at)))
        }
    }
    return [pscustomobject]@{ Links = $ordered; Unparsed = $unparsed }
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
        markers themselves.

        Three facts about a region, kept apart because callers need different ones:
          MarkersPresent - both markers were found, in order. Says the region was DECLARED.
          Found          - MarkersPresent and the region holds at least one line. Says it has
                           CONTENT.
          BeginCount     - how many opening markers the file carries. More than one means the
                           file has two regions and this function silently chose the first, so
                           a caller that cares about being governed by the right one must check.
    #>
    param([string[]]$Lines, [string]$BeginMarker, [string]$EndMarker)

    $beginIdx = -1
    $endIdx = -1
    $beginCount = 0
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].Trim() -eq $BeginMarker) {
            $beginCount++
            if ($beginIdx -lt 0) { $beginIdx = $i }
            continue
        }
        if ($beginIdx -ge 0 -and $endIdx -lt 0 -and $Lines[$i].Trim() -eq $EndMarker) { $endIdx = $i }
    }
    $markersPresent = ($beginIdx -ge 0 -and $endIdx -gt $beginIdx)
    if (-not $markersPresent -or $endIdx -le $beginIdx + 1) {
        return [pscustomobject]@{
            Found = $false; MarkersPresent = $markersPresent; Block = @()
            BeginIndex = $beginIdx; EndIndex = $endIdx; BeginCount = $beginCount
        }
    }
    return [pscustomobject]@{
        Found          = $true
        MarkersPresent = $true
        Block          = @(Get-MIPNormalizedBlock -Lines $Lines[($beginIdx + 1)..($endIdx - 1)])
        BeginIndex     = $beginIdx
        EndIndex       = $endIdx
        BeginCount     = $beginCount
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
        Finds the split-shape stanza in an index's HEADER REGION and the policy-file path its
        opening marker carries.

        Two scoping rules, and both are load-bearing rather than defensive habit. The search
        covers only the lines above the index's first section heading, because that is the only
        place a stanza may lawfully sit; and a marker counts only at column 0, because the
        shipped documentation prints these markers inside examples. Scanning the whole file
        meant an index that merely QUOTED the adoption snippet stopped being read as the shape
        it actually is - and, worse, made the preserved-text route report the shipped reference
        as malformed. The sibling policy-presence probe was scoped for the same reason; this one
        was not, and that asymmetry was the defect.

        Found is true as soon as a recognisable opening marker appears in that region, matched
        by the deliberately loose pattern: a store that has declared the split shape is never
        silently read back as legacy, even when the declaration is broken - including the
        marker written without its ': <path>' suffix.
    #>
    param([string[]]$Lines, [int]$HeaderLineCount)

    $bound = [Math]::Min($HeaderLineCount, $Lines.Count)
    $beginIdx = -1
    $policyPath = ''
    $wellFormedBegin = $false
    for ($i = 0; $i -lt $bound; $i++) {
        $line = $Lines[$i].TrimEnd()
        if ($line -notmatch $script:StoreStanzaLooseBeginPattern) { continue }
        $beginIdx = $i
        $m = [regex]::Match($line, $script:StoreStanzaBeginPattern)
        if ($m.Success) { $wellFormedBegin = $true; $policyPath = $m.Groups['path'].Value.Trim() }
        break
    }
    if ($beginIdx -lt 0) {
        return [pscustomobject]@{ Found = $false; Malformed = $false; Reason = ''; PolicyPath = ''; Block = @(); BeginIndex = -1; EndIndex = -1 }
    }
    if (-not $wellFormedBegin -or [string]::IsNullOrWhiteSpace($policyPath)) {
        return [pscustomobject]@{
            Found = $true; Malformed = $true; PolicyPath = ''; Block = @(); BeginIndex = $beginIdx; EndIndex = -1
            Reason = ("the stanza opens at line $($beginIdx + 1) and names no policy file; " +
                "expected '<!-- memory-policy-stanza-begin: POLICY.md -->'")
        }
    }

    $endIdx = -1
    for ($i = $beginIdx + 1; $i -lt $bound; $i++) {
        if ($Lines[$i].TrimEnd() -eq $script:StoreStanzaEndMarker) { $endIdx = $i; break }
    }
    if ($endIdx -lt 0) {
        return [pscustomobject]@{
            Found = $true; Malformed = $true; PolicyPath = $policyPath; Block = @(); BeginIndex = $beginIdx; EndIndex = -1
            Reason = ("the stanza opens at line $($beginIdx + 1) and is never closed by " +
                "'$script:StoreStanzaEndMarker' above the index's first section heading")
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

function Resolve-MIPPolicyFilePath {
    <#
        .SYNOPSIS
        Resolves the stanza's declared policy-file path against the index's own directory and
        says whether the declaration is usable at all.

        A declaration that cannot name a file - rooted, empty, syntactically impossible on this
        filesystem, or pointing outside the store - is a MALFORMED DECLARATION, and that is a
        different thing from a policy file that has not been created yet. Collapsing them told
        an owner to "create the policy file the stanza names" when the name could never exist.
    #>
    param([string]$StoreDirectory, [string]$DeclaredPath)

    if ([System.IO.Path]::IsPathRooted($DeclaredPath)) {
        return [pscustomobject]@{ Ok = $false; Path = ''; Reason = "the stanza names an absolute path ('$DeclaredPath'); the path is relative to the index's own directory" }
    }
    try {
        $storeFull = [System.IO.Path]::GetFullPath($StoreDirectory)
        $candidate = [System.IO.Path]::GetFullPath((Join-Path $storeFull $DeclaredPath))
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Path = ''; Reason = "the stanza names a path this filesystem cannot express ('$DeclaredPath'): $($_.Exception.Message)" }
    }
    $prefix = $storeFull.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Ok = $false; Path = $candidate; Reason = "the stanza names '$DeclaredPath', which resolves outside the index's own directory (to $candidate); the policy file lives beside the index" }
    }
    return [pscustomobject]@{ Ok = $true; Path = $candidate; Reason = '' }
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

        The record is validated AS A RECORD, not only line by line. Every check below exists
        because per-line validation passed while the record as a whole said something false:
        a second values region (a documentation example left above the real one) silently
        governed; a repeated scalar silently replaced the first; and a mistyped year outranked
        every honest observation forever, since the freshest date governs and the format is
        append-only. Syntax-valid lines, nonsense record.
    #>
    param([string[]]$Lines, [datetime]$AsOf)

    $region = Get-MIPMarkedRegion -Lines $Lines -BeginMarker $script:StoreValuesBeginMarker -EndMarker $script:StoreValuesEndMarker
    if (-not $region.MarkersPresent) {
        return [pscustomobject]@{ Present = $false; Fraction = $null; StalenessBoundDays = $null; Observations = @(); Errors = @() }
    }

    $fraction = $null
    $staleness = $null
    $observations = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    $seenScalar = @{}

    # Declared twice is not the same as declared once: this function would silently take the
    # first region and never say the second exists.
    if ($region.BeginCount -gt 1) {
        $errors.Add("the policy file carries $($region.BeginCount) '$script:StoreValuesBeginMarker' regions; only the first would govern, so which values apply is ambiguous")
    }

    foreach ($raw in $region.Block) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('```') -or $line.StartsWith('<!--') -or $line.StartsWith('#')) { continue }

        $split = $line.IndexOf(':')
        if ($split -lt 1) { $errors.Add("not a 'key: value' line: '$line'"); continue }
        $key = $line.Substring(0, $split).Trim().ToLowerInvariant()
        $value = $line.Substring($split + 1).Trim()

        # 'limit_observation' is the one key designed to repeat - that is the append path. A
        # repeated scalar is a contradiction, and taking the last one silently is how a budget
        # moves by a factor of eight without a word.
        if ($key -ne 'limit_observation') {
            if ($seenScalar.ContainsKey($key)) {
                $errors.Add("'$key' is recorded more than once; it is not a repeatable key, so which value applies is ambiguous")
                continue
            }
            $seenScalar[$key] = $true
        }

        switch ($key) {
            'budget_fraction' {
                $parsed = 0.0
                # IsFinite first: TryParse accepts 'NaN' and 'Infinity', and every comparison
                # against NaN is false, so a range guard alone waves it through to a cast that
                # throws - exit 1 with no report and an empty -Json payload.
                if (-not [double]::TryParse($value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -or
                    -not [double]::IsFinite($parsed) -or $parsed -le 0 -or $parsed -gt 1) {
                    $errors.Add("budget_fraction must be a finite number greater than 0 and at most 1; found '$value'")
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
                # The freshest observation governs, so a date after today outranks every honest
                # one - permanently, because the record is append-only and a later honest
                # re-observation can never overtake it. A store then reads clean while its index
                # truncates, which is the one outcome this axis exists to make impossible.
                if ($observedOn.Date -gt $AsOf.Date) {
                    $errors.Add("limit_observation is dated $($fields[0]), in the future; the freshest observation governs, so a future date would outrank every later one that is honest")
                    continue
                }
                $observedValue = 0
                if (-not [int]::TryParse($fields[1], [ref]$observedValue) -or $observedValue -le 0) {
                    $errors.Add("limit_observation value must be a positive whole number; found '$($fields[1])'")
                    continue
                }
                # Case-sensitive on purpose: the unit is pinned, not inferred, and this file
                # uses -ceq / -ccontains everywhere else for exactly that reason.
                if ($fields[2] -cne $script:SizeAxisUnit) {
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

    # Scoped to the header region: see Get-MIPStoreStanza for why the whole-file scan was wrong.
    $stanza = Get-MIPStoreStanza -Lines $indexLines -HeaderLineCount $firstSectionIdx
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
            else {
                $policyDivergence = Get-MIPFirstDivergence -Actual $headerBlock -Expected $canonicalBlock -Label 'header'
            }
            # Emitted for every diverged legacy header, because recognizing WHICH text a store
            # carries is machinery this release deliberately does not add. Every clause is
            # therefore conditional in its own right - including the remedies. An earlier
            # revision stated the remedies flatly, which made "pass the pre-supersession text
            # for a clean verdict" false advice to a store whose divergence was an ordinary
            # typo in the current text: following it diverges at line 1 instead.
            $policyExplanation = @(
                'this check cannot tell which policy text this store adopted, so both readings are stated:',
                '  - if this header predates the supersession of the never-retire ratchet, the divergence IS that',
                '    rewrite, not a defect in this store. Three onward paths, and nothing here obliges any of them:',
                '    adopt the split shape (see "Adopting the split shape" in the reference copy); or keep a clean',
                '    verdict by passing -PolicyReferencePath with the preserved pre-supersession text, shipped at',
                '    skills/agent-memory-compaction/templates/policy-pre-supersession.md; or do nothing, since a',
                '    diverged verdict is an honest report and not a failure.',
                '  - if this store had already adopted the text it is being compared against, the divergence is an',
                '    ordinary drift in this store - repair it to match the reference it was adopted from. Passing',
                '    the pre-supersession text will NOT produce a clean verdict in that case.')
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

        # The stanza is the ONLY policy text the split shape puts in the index. Leftover policy
        # prose above or below it is migration residue that contradicts the governing policy
        # file, and without this check a store that "split" without removing the text it was
        # splitting out reads exactly like one that did - silently, until the size axis
        # eventually catches it, which is never for a store with room to spare.
        $probeLines = @($canonicalBlock | Where-Object { $_.Trim().Length -ge $script:PresenceProbeMinLength })
        $stanzaLineNumbers = @($stanza.BeginIndex..$stanza.EndIndex)
        $residue = @(for ($i = 0; $i -lt [Math]::Min($firstSectionIdx, $indexLines.Count); $i++) {
                if ($stanzaLineNumbers -contains $i) { continue }
                if ($probeLines -ccontains $indexLines[$i].TrimEnd()) { $indexLines[$i].TrimEnd() }
            })

        # Detection is already scoped to the header region, so "the stanza sits above the first
        # section heading" is true by construction and is not re-tested here.
        $stanzaComplete = (-not $pointerInsideHeader) -and ($stanzaText -ceq $canonicalStanzaText) -and $residue.Count -eq 0

        $resolved = Resolve-MIPPolicyFilePath -StoreDirectory (Split-Path -Parent $indexResolved) -DeclaredPath $stanza.PolicyPath
        if (-not $resolved.Ok) {
            # A declaration that cannot name a file is not a store waiting to create one.
            return New-MIPRefusal -IndexPath $IndexPath -Reason 'split-store stanza is malformed' -Detail @(
                $resolved.Reason,
                'this is a malformed declaration, not the half-migrated state')
        }
        $policyFilePath = $resolved.Path

        $policyTextComplete = $false
        $policyFileDivergence = ''
        # Something that exists at the path but is not a file has not "not been created yet".
        if (Test-Path -LiteralPath $policyFilePath -PathType Container) {
            return New-MIPRefusal -IndexPath $IndexPath -Reason "this store's policy file could not be read" -Detail @(
                "path: $policyFilePath", 'a directory sits where the policy file should be',
                'something exists there, so this is not the half-migrated state')
        }
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
            # The vocabulary comes from the COMPARED region only. Harvesting it from the whole
            # file let a store name a kind in text no comparison ever sees, while the same
            # report asserted the policy file matched the reference - a verdict about an audited
            # region governing behaviour sourced from an unaudited one.
            $policySourceText = ($storePolicyBlock -join "`n")
            $storeValues = Get-MIPStoreValues -Lines $policyLines -AsOf $AsOf
        }

        $policyComplete = $stanzaComplete -and $policyTextComplete
        $headerPresent = $policyTextComplete -or ($storeShape -ne 'split-incomplete' -and $policyFileDivergence -ne '')
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
                if ($pointerInsideHeader) { $parts.Add('a pointer line sits inside the header region, above the first section heading') }
                elseif ($residue.Count -gt 0) {
                    $parts.Add(("the index's header region still carries policy text outside the stanza " +
                            "($($residue.Count) line(s), first: '$($residue[0])') - the split moves that text to the policy file"))
                }
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
    # The refusal is the documented signal that a store has not adapted the policy to its own
    # entry kinds. It cannot mean that for a HALF-MIGRATED store: that store's policy text is
    # in a file it has not created yet, so its vocabulary is knowably unavailable rather than
    # missing. Refusing there told an adapted store to "adapt the policy text first" - which it
    # had done - and suppressed every count, in the one state chunk 3 puts every store through.
    $vocabularyKnowable = ($storeShape -ne 'split-incomplete')
    if ($matchingKind.Count -eq 0 -and $vocabularyKnowable) {
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
                # policy_* is the axis's real name since the split; header_* is retained because
                # every consumer is external, and is populated with the SAME truth rather than a
                # convenient constant. A half-migrated store used to report header_present: true
                # while carrying no policy text anywhere.
                $payload['policy_present'] = $Report.HeaderPresent
                $payload['policy_complete'] = $Report.HeaderComplete
                $payload['policy_divergence'] = $Report.HeaderDivergence
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
