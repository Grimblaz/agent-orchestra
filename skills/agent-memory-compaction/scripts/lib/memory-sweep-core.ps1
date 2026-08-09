<#
.SYNOPSIS
    Shared logic for the sweep procedure's instruments: the pre-sweep inventory, the partition
    check, the disposition gates, and the destination measurement.

.DESCRIPTION
    The procedure these serve is skills/agent-memory-compaction/references/sweep-procedure.md and
    the record shapes are defined in references/store-records.md. Nothing here writes to a store.
    The sweep writes; these read and report, so that each procedural check produces an artifact a
    later reader can re-run rather than a claim the sweep makes about itself.

    Four verdicts are kept apart on purpose, because collapsing any two is how a live entry gets
    treated as already-handled: a record that says something; a record this parser could not read
    (malformed); no record at all; and a question this parser cannot decide (undecidable). A crash
    is not one of them - every parse uses TryParseExact and every unreadable input becomes a
    reported verdict, never an exception out of an instrument.

    Two disciplines run through the whole file:

    - Nothing fails OPEN. Where a value is missing, unreadable, or outside its vocabulary, the
      gate refuses and says why. The one exception the design permits - an entry with no critical
      assessment - refuses too, because "nobody has looked" is not "ordinary".
    - Identity is the life key, everywhere. A name is not an identity: an ordinary lesson removed
      re-earns its place under the same slug, so any check keyed on a bare name will sooner or
      later answer a question about life 2 with a fact about life 1.

    Marked-region reading, link parsing and the character-counting rule are taken from
    lib/memory-index-policy-core.ps1 rather than reimplemented, so the sweep and the check can
    never disagree about what a pointer is or how big a file is. That is a deliberate, declared
    dependency: this file consumes Get-MIPMarkedRegion, Get-MIPLinksInLine, Measure-MIPCharacters,
    Test-MIPRegionDuplicated, Get-MIPStoreStanza and Resolve-MIPPolicyFilePath, and it re-declares
    the two pattern constants it needs rather than reaching into that file's private scope.
#>

. (Join-Path $PSScriptRoot 'memory-index-policy-core.ps1')

# Set here as well as in the sibling core: dot-sourcing means the sibling's mode leaks into every
# consumer of this file, which is fine but must not be the only reason this file is strict.
Set-StrictMode -Version Latest

# The record regions have an OPENING marker and no closing one: records run from the marker to the
# end of file. That is not a shortcut - it is what makes the append-only discipline true. A region
# bounded at both ends cannot be appended to, because an O_APPEND write lands after the closing
# marker and outside the region, where no reader ever sees it. Bounded at one end, `Add-Content`
# is a real append and survives a concurrent writer.
$script:MSLedgerBeginMarker = '<!-- memory-ledger-begin -->'
$script:MSSlateBeginMarker = '<!-- memory-slate-begin -->'

$script:MSStatuses = @('proposed', 'executed', 'reconciled')

# 'presence' is deliberately absent. An earlier revision carried it, and it had a producer, a
# documented behaviour, and no reader - so a lawfully exited entry whose body remained was
# re-surfaced at every later sweep, in the critical-first group if it was critical. The fact it
# tried to carry ("this entry has left") is the ledger's fact, and the corpus walk now reads it
# from there. Two stores asserting one fact is how they come to disagree.
$script:MSSlateTracks = @('critical', 'deferral', 'landing')
$script:MSCriticalValues = @('yes', 'no')
$script:MSLandingValues = @('none', 'in-flight', 'landed')

# Dispositions that remove a pointer from the index.
$script:MSExitDispositions = @(
    'promote', 'demote', 'remove-fails-admission', 'evaporate-on-close', 'dedupe-into', 'remove-obsolete')
# Entry dispositions that do not remove a pointer. 'settle-in-place' is the settled-section sense
# of the canonical text's "demote"; 'restore' brings a demoted pointer back and SUPERSEDES the
# earlier exit record for that life.
$script:MSNonExitDispositions = @('keep-hot-with-expiry', 'settle-in-place', 'restore')
# Records the sweep writes about itself rather than about an entry. Their identity uses a reserved
# name so they can never collide with an entry: 'sweep@<date>' and 'ledger@<date>'.
$script:MSSelfDispositions = @('sweep-complete', 'ledger-compaction')
$script:MSSelfNames = @('sweep', 'ledger')

$script:MSUnknownAdmission = 'unknown'
$script:MSFrontmatterFence = '---'
$script:MSEntryNodeTypePattern = '^\s*node_type:\s*memory\s*$'
# Re-declared rather than reached for in the sibling core's private scope, so a rename there is a
# visible break here instead of a silent behaviour change.
$script:MSPointerLinePattern = '^\s*(?:[-*+]|\d+[.)])\s'
$script:MSMeasurementUnit = 'characters'

function Set-MSMalformed {
    <#
        .SYNOPSIS
        Marks a parsed record or row malformed with its reason, and returns it.

        Hoisted rather than declared inside each parser: a nested 'function script:Fail' would
        redefine a very generic name in script scope on every call.
    #>
    param([Parameter(Mandatory = $true)]$Record, [Parameter(Mandatory = $true)][string]$Why)

    $Record.Malformed = $true
    $Record.Why = $Why
    return $Record
}

function Get-MSOrdinalMap {
    <#
        .SYNOPSIS
        A case-SENSITIVE dictionary. PowerShell's @{} literal is case-insensitive, which would make
        every identity and name lookup in this file disagree with the -ceq comparisons beside them.
    #>
    return [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
}

function ConvertTo-MSDate {
    <#
        .SYNOPSIS
        Parses a yyyy-MM-dd date, or returns why it could not. Never throws.

        TryParseExact, not ParseExact: '2026-02-30' has the right shape and is not a date, and an
        instrument that dies on it produces no artifact at all - a fourth outcome alongside the
        three this file keeps apart. Future dates are refused for the reason the sibling record
        already refuses them: the freshest row governs, and the record is append-only, so a
        mistyped year outranks every honest row appended after it, permanently.
    #>
    param([Parameter(Mandatory = $true)][string]$Text, [Parameter(Mandatory = $true)][datetime]$AsOf, [string]$Label = 'date')

    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($Text, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        return [pscustomobject]@{ Ok = $false; Value = $null; Why = "$Label must be a real date in yyyy-MM-dd form; found '$Text'" }
    }
    if ($parsed.Date -gt $AsOf.Date) {
        return [pscustomobject]@{ Ok = $false; Value = $null; Why = "$Label is dated $Text, in the future; the freshest row governs and the record is append-only, so a future date would outrank every honest row appended after it" }
    }
    return [pscustomobject]@{ Ok = $true; Value = $parsed; Why = '' }
}

function ConvertTo-MSIdentity {
    <#
        .SYNOPSIS
        Splits a life key into its name and admitted date, or returns why it could not.

        Anchored on the LAST '@' and refusing a name that contains one: 'a@b@2026-01-01' would
        otherwise decode two ways, and the two sides of a comparison would decode it differently.
    #>
    param([Parameter(Mandatory = $true)][string]$Text, [Parameter(Mandatory = $true)][datetime]$AsOf)

    $at = $Text.LastIndexOf('@')
    if ($at -lt 1 -or $at -eq $Text.Length - 1) {
        return [pscustomobject]@{ Ok = $false; Name = $null; Admitted = $null; Why = "identity must read '<entry-name>@<yyyy-MM-dd>' or '<entry-name>@unknown'; found '$Text'" }
    }
    $name = $Text.Substring(0, $at)
    $admitted = $Text.Substring($at + 1)
    if ($name.Contains('@')) {
        return [pscustomobject]@{ Ok = $false; Name = $null; Admitted = $null; Why = "an entry name may not contain '@'; '$Text' does not decode to one identity" }
    }
    if ($admitted -ceq $script:MSUnknownAdmission) {
        return [pscustomobject]@{ Ok = $true; Name = $name; Admitted = $script:MSUnknownAdmission; Why = '' }
    }
    $date = ConvertTo-MSDate -Text $admitted -AsOf $AsOf -Label 'the admitted date in an identity'
    if (-not $date.Ok) { return [pscustomobject]@{ Ok = $false; Name = $null; Admitted = $null; Why = $date.Why } }
    return [pscustomobject]@{ Ok = $true; Name = $name; Admitted = $admitted; Why = '' }
}

function Get-MSRecordLines {
    <#
        .SYNOPSIS
        The record lines of an append-only region: everything after the opening marker.

        Four states, kept apart. 'absent' - no such file. 'unmarked' - the file exists and does not
        declare a region, which is not the same as declaring an empty one. 'duplicated' - more than
        one opening marker, so which region governs has no answer; the sibling core ships
        Test-MIPRegionDuplicated for exactly this and reports rather than silently taking the first.
        'present' - one marker, and every line after it is a record.

        Blank lines are skipped. NOTHING else is: a line that cannot be parsed becomes a malformed
        record the next slate sees. An earlier revision skipped '#'-prefixed lines, which meant one
        typed character in front of an exit record erased it with the machinery still reporting
        clean - an in-place unrecord, in a file whose whole purpose is that nothing leaves without
        a trace.
    #>
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$BeginMarker)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ State = 'absent'; Lines = @(); Why = "no file at '$Path'" }
    }
    $lines = @([System.IO.File]::ReadAllLines($Path))
    $at = -1
    $count = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -ceq $BeginMarker) {
            $count++
            if ($at -lt 0) { $at = $i }
        }
    }
    if ($count -eq 0) {
        return [pscustomobject]@{ State = 'unmarked'; Lines = @(); Why = "no '$BeginMarker' in '$Path'" }
    }
    if ($count -gt 1) {
        return [pscustomobject]@{ State = 'duplicated'; Lines = @(); Why = "'$Path' carries $count '$BeginMarker' markers; which region governs has no answer, so no record in this file is read" }
    }
    $records = @()
    if ($at -lt $lines.Count - 1) {
        $records = @($lines[($at + 1)..($lines.Count - 1)] | Where-Object { $_.Trim() -ne '' })
    }
    return [pscustomobject]@{ State = 'present'; Lines = $records; Why = '' }
}

function ConvertTo-MSLedgerRecord {
    <#
        .SYNOPSIS
        Parses one ledger line: date | status | disposition | identity | reason | destination.

        EXACTLY six fields. An earlier revision rejoined field 6 onward into the destination, which
        meant a '|' in a prose reason silently shifted one fragment into the field that says
        whether an entry left recall or merely moved section - the one field a later reader
        depends on to tell those apart. A pipe in a reason is now a reported record, not a quietly
        wrong one.

        A line missing its status, or carrying one outside the vocabulary, is MALFORMED and is never
        read as executed. Proposals are the high-frequency traffic in this file, so a parser that
        defaulted a missing status would eventually read one as a completed exit.
    #>
    param([Parameter(Mandatory = $true)][string]$Line, [Parameter(Mandatory = $true)][datetime]$AsOf, [int]$Number = 0)

    $fields = @($Line -split '\|' | ForEach-Object { $_.Trim() })
    $record = [pscustomobject]@{
        Number      = $Number
        Raw         = $Line.Trim()
        Date        = $null
        Status      = $null
        Disposition = $null
        Identity    = $null
        Name        = $null
        Admitted    = $null
        Reason      = ''
        Destination = ''
        IsExit      = $false
        IsSelf      = $false
        Malformed   = $false
        Why         = ''
    }
    if ($fields.Count -ne 6) {
        return Set-MSMalformed -Record $record -Why "expected exactly 6 pipe-separated fields (date | status | disposition | identity | reason | destination); found $($fields.Count). No field may contain a pipe."
    }
    $date = ConvertTo-MSDate -Text $fields[0] -AsOf $AsOf -Label 'a ledger record date'
    if (-not $date.Ok) { return Set-MSMalformed -Record $record -Why $date.Why }
    $record.Date = $date.Value

    if ($script:MSStatuses -cnotcontains $fields[1]) {
        return Set-MSMalformed -Record $record -Why "status must be one of $($script:MSStatuses -join ', '); found '$($fields[1])'"
    }
    $record.Status = $fields[1]

    $known = @($script:MSExitDispositions) + @($script:MSNonExitDispositions) + @($script:MSSelfDispositions)
    if ($known -cnotcontains $fields[2]) {
        return Set-MSMalformed -Record $record -Why "disposition '$($fields[2])' is not one the sweep procedure names"
    }
    $record.Disposition = $fields[2]
    $record.IsExit = ($script:MSExitDispositions -ccontains $fields[2])
    $record.IsSelf = ($script:MSSelfDispositions -ccontains $fields[2])

    $identity = ConvertTo-MSIdentity -Text $fields[3] -AsOf $AsOf
    if (-not $identity.Ok) { return Set-MSMalformed -Record $record -Why $identity.Why }
    # A self-record is about the ledger or the sweep, not about an entry, and an entry may not
    # borrow those names - otherwise a sweep's own record and an entry's record collide.
    if ($record.IsSelf -and $script:MSSelfNames -cnotcontains $identity.Name) {
        return Set-MSMalformed -Record $record -Why "a '$($record.Disposition)' record's identity must use a reserved name ($($script:MSSelfNames -join ', ')); found '$($identity.Name)'"
    }
    if (-not $record.IsSelf -and $script:MSSelfNames -ccontains $identity.Name) {
        return Set-MSMalformed -Record $record -Why "'$($identity.Name)' is reserved for the sweep's own records and may not name an entry"
    }
    $record.Identity = $fields[3]
    $record.Name = $identity.Name
    $record.Admitted = $identity.Admitted

    if ([string]::IsNullOrWhiteSpace($fields[4])) { return Set-MSMalformed -Record $record -Why 'a record must state its reason' }
    $record.Reason = $fields[4]
    if ([string]::IsNullOrWhiteSpace($fields[5])) { return Set-MSMalformed -Record $record -Why 'a record must state its destination, or "none" with what is accepted' }
    $record.Destination = $fields[5]
    return $record
}

function Get-MSLedger {
    <#
        .SYNOPSIS
        Reads LEDGER.md and folds it to EFFECTIVE state.

        Two folds, both needed and both append-representable:

        - EFFECTIVE STATUS. A record's status changes by appending a later row with the same
          identity and disposition, because nothing in this file is ever edited in place. So the
          status of a disposition is the status of its latest row. Without this fold "eligible for
          compaction when its status is reconciled" can never fire for any executed record, and the
          retention bound - which exists so this file does not become the eternal forensic ledger
          the parent design rejected by name - is inert.
        - SUPERSESSION. A 'restore' record for an identity supersedes the exits recorded for it,
          because the pointer is back in the index. Without it a lawfully restored entry is
          reported as an interrupted disposition at every sweep for the life of the store.
    #>
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][datetime]$AsOf)

    $raw = Get-MSRecordLines -Path $Path -BeginMarker $script:MSLedgerBeginMarker
    $records = [System.Collections.Generic.List[object]]::new()
    $n = 0
    foreach ($line in $raw.Lines) {
        $n++
        $records.Add((ConvertTo-MSLedgerRecord -Line $line -AsOf $AsOf -Number $n))
    }
    $good = @($records | Where-Object { -not $_.Malformed })

    $effective = Get-MSOrdinalMap
    foreach ($r in $good) {
        $key = "$($r.Identity)`0$($r.Disposition)"
        if (-not $effective.ContainsKey($key) -or $r.Date -ge $effective[$key].Date) { $effective[$key] = $r }
    }
    $restored = Get-MSOrdinalMap
    foreach ($r in @($good | Where-Object { $_.Disposition -ceq 'restore' -and $_.Status -ceq 'executed' })) {
        if (-not $restored.ContainsKey($r.Identity) -or $r.Date -ge $restored[$r.Identity].Date) { $restored[$r.Identity] = $r }
    }

    # An exit is IN FORCE when its latest row is executed or reconciled and no later restore
    # undoes it. This is the set every other reader wants; the raw records stay available.
    $inForce = Get-MSOrdinalMap
    foreach ($key in $effective.Keys) {
        $r = $effective[$key]
        if (-not $r.IsExit) { continue }
        if ($r.Status -ceq 'proposed') { continue }
        if ($restored.ContainsKey($r.Identity) -and $restored[$r.Identity].Date -ge $r.Date) { continue }
        $inForce[$r.Identity] = $r
    }

    return [pscustomobject]@{
        Path        = $Path
        State       = $raw.State
        StateWhy    = $raw.Why
        Records     = @($records)
        Malformed   = @($records | Where-Object { $_.Malformed })
        Effective   = $effective
        ExitsInForce = $inForce
    }
}

function ConvertTo-MSSlateRow {
    <#
        .SYNOPSIS
        Parses one slate row: date | identity | track | value | detail.

        EXACTLY five fields, and every track's VALUE is checked against its own vocabulary. An
        earlier revision validated the track name and took the value raw, so a row reading
        'critical | Yes' parsed clean, counted as an assessment, and let the entry exit with no
        landing verification at all - one capitalized letter past the gate that exists to keep a
        critical lesson from leaving unlanded.
    #>
    param([Parameter(Mandatory = $true)][string]$Line, [Parameter(Mandatory = $true)][datetime]$AsOf, [int]$Number = 0)

    $fields = @($Line -split '\|' | ForEach-Object { $_.Trim() })
    $row = [pscustomobject]@{
        Number    = $Number
        Raw       = $Line.Trim()
        Date      = $null
        Identity  = $null
        Name      = $null
        Track     = $null
        Value     = $null
        Detail    = ''
        Until     = $null
        Malformed = $false
        Why       = ''
    }
    if ($fields.Count -ne 5) {
        return Set-MSMalformed -Record $row -Why "expected exactly 5 pipe-separated fields (date | identity | track | value | detail); found $($fields.Count). No field may contain a pipe."
    }
    $date = ConvertTo-MSDate -Text $fields[0] -AsOf $AsOf -Label 'a slate row date'
    if (-not $date.Ok) { return Set-MSMalformed -Record $row -Why $date.Why }
    $row.Date = $date.Value

    $identity = ConvertTo-MSIdentity -Text $fields[1] -AsOf $AsOf
    if (-not $identity.Ok) { return Set-MSMalformed -Record $row -Why $identity.Why }
    if ($script:MSSelfNames -ccontains $identity.Name) {
        return Set-MSMalformed -Record $row -Why "'$($identity.Name)' is reserved for the sweep's own records and may not name an entry"
    }
    $row.Identity = $fields[1]
    $row.Name = $identity.Name

    if ($script:MSSlateTracks -cnotcontains $fields[2]) {
        return Set-MSMalformed -Record $row -Why "track must be one of $($script:MSSlateTracks -join ', '); found '$($fields[2])'"
    }
    $row.Track = $fields[2]
    $row.Detail = $fields[4]

    switch ($row.Track) {
        'critical' {
            if ($script:MSCriticalValues -cnotcontains $fields[3]) {
                return Set-MSMalformed -Record $row -Why "a critical row's value must be one of $($script:MSCriticalValues -join ', ') - lower case, exactly; found '$($fields[3])'"
            }
            $row.Value = $fields[3]
            if ([string]::IsNullOrWhiteSpace($row.Detail)) { return Set-MSMalformed -Record $row -Why 'a critical row must say why the two-part test does or does not hold' }
        }
        'deferral' {
            # The count is carried in the row rather than derived by counting rows: a derived count
            # goes wrong the moment the slate file is compacted, and the never-deferred-twice rule
            # is exactly the thing that must not quietly become false.
            $count = 0
            if (-not [int]::TryParse($fields[3], [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$count) -or $count -lt 1) {
                return Set-MSMalformed -Record $row -Why "a deferral's value is its running count, a positive whole number; found '$($fields[3])'"
            }
            $row.Value = $count
            $m = [regex]::Match($row.Detail, 'until\s+(?<until>\S+)')
            if (-not $m.Success) {
                # There is no indefinite deferral. A row without an expiry would be one.
                return Set-MSMalformed -Record $row -Why "a deferral must carry 'until <yyyy-MM-dd>' in its detail; found '$($row.Detail)'"
            }
            $until = ConvertTo-MSDate -Text $m.Groups['until'].Value -AsOf ([datetime]::MaxValue) -Label "a deferral's until date"
            if (-not $until.Ok) { return Set-MSMalformed -Record $row -Why $until.Why }
            $row.Until = $until.Value
        }
        'landing' {
            if ($script:MSLandingValues -cnotcontains $fields[3]) {
                return Set-MSMalformed -Record $row -Why "a landing row's value must be one of $($script:MSLandingValues -join ', '); found '$($fields[3])'"
            }
            $row.Value = $fields[3]
            if ($row.Value -ceq 'in-flight' -and [string]::IsNullOrWhiteSpace($row.Detail)) {
                return Set-MSMalformed -Record $row -Why 'an in-flight landing must name its vehicle in the detail field'
            }
        }
    }
    return $row
}

function Get-MSSlateState {
    <#
        .SYNOPSIS
        Reads SLATE.md and folds it to the current state: the latest row per identity AND track.

        Three independent tracks rather than one state column, because the states are orthogonal -
        an entry can be critical and deferred and have a landing in flight at the same time, and a
        single latest-row-wins column would silently drop two of the three.

        Malformed rows are reported at FILE level and make the gates refuse. A row can fail before
        its identity parses, so it cannot always be attributed to an entry; a fix that only
        attributed what it could would have missed exactly the rows that are most broken.
    #>
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][datetime]$AsOf)

    $raw = Get-MSRecordLines -Path $Path -BeginMarker $script:MSSlateBeginMarker
    $rows = [System.Collections.Generic.List[object]]::new()
    $n = 0
    foreach ($line in $raw.Lines) {
        $n++
        $rows.Add((ConvertTo-MSSlateRow -Line $line -AsOf $AsOf -Number $n))
    }
    $current = Get-MSOrdinalMap
    foreach ($row in @($rows | Where-Object { -not $_.Malformed })) {
        $key = "$($row.Identity)`0$($row.Track)"
        if (-not $current.ContainsKey($key) -or $row.Date -ge $current[$key].Date) { $current[$key] = $row }
    }
    return [pscustomobject]@{
        Path      = $Path
        State     = $raw.State
        StateWhy  = $raw.Why
        Rows      = @($rows)
        Malformed = @($rows | Where-Object { $_.Malformed })
        Current   = $current
        # One flag every gate consults. A slate this parser cannot fully read is a slate whose
        # deferral history might say anything, and the twice-rule is not a rule that may be
        # applied to a guess.
        Trustworthy = ($raw.State -ne 'duplicated' -and @($rows | Where-Object { $_.Malformed }).Count -eq 0)
    }
}

function Get-MSTrackValue {
    param([Parameter(Mandatory = $true)]$SlateState, [Parameter(Mandatory = $true)][string]$Identity, [Parameter(Mandatory = $true)][string]$Track)

    $key = "$Identity`0$Track"
    if ($SlateState.Current.ContainsKey($key)) { return $SlateState.Current[$key] }
    return $null
}

function Get-MSEntryFacts {
    <#
        .SYNOPSIS
        What a file on disk says about itself: whether it is a memory entry at all, and the
        admission date that binds its life key.

        The admitted date is the life-binding on the LIVING side. Without it a reconciliation
        cannot tell one life of a reused name from another, and 'unknown' has to stay a distinct
        answer rather than collapse into either verdict.

        Today, in a store whose admission rule has not yet landed, EVERY entry answers 'unknown'.
        That is not an edge case to note in passing - it is the default, and it is why the
        producer obligation is written into the interface chunk 3 consumes.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $facts = [pscustomobject]@{ IsEntry = $false; Admitted = $script:MSUnknownAdmission; HasFrontmatter = $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $facts }
    $lines = @([System.IO.File]::ReadAllLines($Path))
    if ($lines.Count -eq 0 -or $lines[0].Trim() -cne $script:MSFrontmatterFence) { return $facts }
    $facts.HasFrontmatter = $true
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -ceq $script:MSFrontmatterFence) { break }
        if ($lines[$i] -match $script:MSEntryNodeTypePattern) { $facts.IsEntry = $true }
        $m = [regex]::Match($lines[$i], '^\s*admitted:\s*(?<d>\S+)\s*$')
        if ($m.Success) { $facts.Admitted = $m.Groups['d'].Value }
    }
    return $facts
}

function Get-MSEntryIdentity {
    param([Parameter(Mandatory = $true)][string]$Path)

    $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    return "$name@$((Get-MSEntryFacts -Path $Path).Admitted)"
}

function Get-MSIndexSubjects {
    <#
        .SYNOPSIS
        Every linked subject on the index's pointer lines, read FROM DISK.

        Never from a caller-supplied copy of the text: a store big enough to be worth sweeping is
        one whose session load may be truncated, and enumerating from that view produces a corpus
        already missing the tail - which every later reconciliation then agrees with perfectly,
        because both halves came from the same short list.
    #>
    param([Parameter(Mandatory = $true)][string]$IndexPath)

    $lines = @([System.IO.File]::ReadAllLines($IndexPath))
    $subjects = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch $script:MSPointerLinePattern) { continue }
        $parsed = Get-MIPLinksInLine -Text $lines[$i]
        foreach ($link in @($parsed.Links | Where-Object { $_.IsSubject })) {
            $subjects.Add([pscustomobject]@{
                    Name   = [System.IO.Path]::GetFileNameWithoutExtension($link.Target)
                    Target = $link.Target
                    Line   = $i + 1
                })
        }
    }
    return @($subjects)
}

function Get-MSReservedNames {
    <#
        .SYNOPSIS
        The store files that are not entries: the index, the record files, and the policy file
        WHATEVER THE STORE CALLS IT.

        The policy filename is store-declared data - chunk 1's stanza carries it on the marker line
        and the checker resolves any path beside the index. Hardcoding 'POLICY' made a store that
        exercised that option report its own policy file as an unaccounted lesson at every sweep,
        with no lawful disposition available for it.
    #>
    param([Parameter(Mandatory = $true)][string]$IndexPath)

    $names = [System.Collections.Generic.List[string]]::new()
    $names.Add([System.IO.Path]::GetFileNameWithoutExtension($IndexPath))
    foreach ($n in @('LEDGER', 'SLATE', 'ARCHIVE', 'POLICY')) { $names.Add($n) }

    $lines = @([System.IO.File]::ReadAllLines($IndexPath))
    $stanza = Get-MIPStoreStanza -Lines $lines
    if ($null -ne $stanza -and $stanza.PSObject.Properties.Name -contains 'DeclaredPath' -and -not [string]::IsNullOrWhiteSpace($stanza.DeclaredPath)) {
        $names.Add([System.IO.Path]::GetFileNameWithoutExtension($stanza.DeclaredPath))
    }
    return @($names)
}

function Get-MSCorpus {
    <#
        .SYNOPSIS
        The two populations a sweep walks: the index's linked subjects, and every entry file in the
        store directory that no pointer points at.

        Orphan bodies are outside recall already and invisible to the checker, whose whole subject
        is the index. They still hold lessons and can still be critical, so a walk that skips them
        reports a complete sweep of a store it never fully looked at.

        A file is an entry when it says so - frontmatter carrying 'node_type: memory'. An earlier
        revision took every '*.md' that was not on a hardcoded reserved list, so a README beside the
        index was enumerated as a lesson and the partition check reported loss on a store where
        nothing had been swept at all. A non-entry file is reported separately, never as a subject.
    #>
    param([Parameter(Mandatory = $true)][string]$IndexPath, [string[]]$ExcludeNames = @())

    $dir = Split-Path -Parent (Resolve-Path -LiteralPath $IndexPath).Path
    # Case-INSENSITIVE, matching Test-Path on the platforms these stores live on: an earlier
    # revision compared reserved names case-sensitively while locating the same files
    # case-insensitively, so a store with 'ledger.md' had its ledger read AND enumerated as a lesson.
    $reserved = [System.Collections.Generic.HashSet[string]]::new([string[]](@(Get-MSReservedNames -IndexPath $IndexPath) + @($ExcludeNames)), [System.StringComparer]::OrdinalIgnoreCase)

    $subjects = @(Get-MSIndexSubjects -IndexPath $IndexPath)
    # Case-INSENSITIVE, matching how a pointer's body is located: Join-Path + Test-Path finds
    # 'Reference_Foo.md' for a pointer that names 'reference_foo.md' on the platforms these stores
    # live on. Compared case-sensitively, that one file is enumerated TWICE - once as a pointer
    # subject and once as an orphan body - and the partition check then asks the sweep to account
    # for an orphan that is not one.
    $pointed = [System.Collections.Generic.HashSet[string]]::new([string[]]@($subjects | ForEach-Object { $_.Name }), [System.StringComparer]::OrdinalIgnoreCase)

    $entries = [System.Collections.Generic.List[object]]::new()
    $nonEntries = [System.Collections.Generic.List[string]]::new()

    foreach ($s in $subjects) {
        $body = Join-Path $dir "$($s.Name).md"
        $facts = Get-MSEntryFacts -Path $body
        $entries.Add([pscustomobject]@{
                Name       = $s.Name
                Identity   = "$($s.Name)@$($facts.Admitted)"
                Population = 'pointer'
                Line       = $s.Line
                BodyExists = (Test-Path -LiteralPath $body -PathType Leaf)
            })
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $dir -Filter '*.md' -File | Sort-Object -Property Name)) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        if ($reserved.Contains($name) -or $pointed.Contains($name)) { continue }
        $facts = Get-MSEntryFacts -Path $file.FullName
        if (-not $facts.IsEntry) { $nonEntries.Add($name); continue }
        $entries.Add([pscustomobject]@{
                Name       = $name
                Identity   = "$name@$($facts.Admitted)"
                Population = 'orphan-body'
                Line       = 0
                BodyExists = $true
            })
    }
    return [pscustomobject]@{ Entries = @($entries); NonEntryFiles = @($nonEntries) }
}

function Get-MSIncompleteDispositions {
    <#
        .SYNOPSIS
        Exits in force whose act is not reflected in the store.

        Record-before-act makes an interruption between the two visible instead of silent. It is
        NOT resolved here: re-executing and dropping are both plausible and the record cannot tell
        which is right, so the state is surfaced for a person.

        Exits IN FORCE, not every executed record ever written: a later 'restore' undoes an exit,
        and reading the raw records instead pinned every lawfully restored entry into this group
        for the life of the store.
    #>
    param([Parameter(Mandatory = $true)]$Ledger, [Parameter(Mandatory = $true)]$Corpus, [string[]]$ArchiveNames = @())

    $hot = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Corpus.Entries | Where-Object { $_.Population -eq 'pointer' } | ForEach-Object { $_.Identity }), [System.StringComparer]::Ordinal)
    $archived = [System.Collections.Generic.HashSet[string]]::new([string[]]@($ArchiveNames), [System.StringComparer]::OrdinalIgnoreCase)
    $incomplete = [System.Collections.Generic.List[object]]::new()
    foreach ($identity in @($Ledger.ExitsInForce.Keys)) {
        $r = $Ledger.ExitsInForce[$identity]
        if ($hot.Contains($identity)) {
            $incomplete.Add([pscustomobject]@{ Identity = $identity; Disposition = $r.Disposition; Why = 'the record says it exited, but its pointer is still in the index' })
            continue
        }
        if ($r.Disposition -ceq 'demote' -and -not $archived.Contains($r.Name)) {
            $incomplete.Add([pscustomobject]@{ Identity = $identity; Disposition = $r.Disposition; Why = 'the record says it was demoted, but no archive line carries it' })
        }
    }
    return @($incomplete)
}

function Get-MSArchiveNames {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @([System.IO.File]::ReadAllLines($Path))) {
        if ($line -notmatch $script:MSPointerLinePattern) { continue }
        foreach ($link in @((Get-MIPLinksInLine -Text $line).Links | Where-Object { $_.IsSubject })) {
            $names.Add([System.IO.Path]::GetFileNameWithoutExtension($link.Target))
        }
    }
    return @($names)
}

function Get-MSSweepGroup {
    <#
        .SYNOPSIS
        Which of step 2's five groups an entry falls in. First match wins.

        Unassessed is tested BEFORE expired deferral: an entry nobody has assessed cannot be
        dispositioned at all, so labelling it by its deferral state tells a reader the one thing
        that is not the next question about it.
    #>
    param([Parameter(Mandatory = $true)]$Entry, [Parameter(Mandatory = $true)]$SlateState, [string[]]$IncompleteIdentities = @(), [Parameter(Mandatory = $true)][datetime]$AsOf)

    if ($IncompleteIdentities -ccontains $Entry.Identity) { return '1-incomplete-disposition' }
    $critical = Get-MSTrackValue -SlateState $SlateState -Identity $Entry.Identity -Track 'critical'
    if ($null -ne $critical -and $critical.Value -ceq 'yes') { return '2-critical' }
    # No row on EITHER polarity means nobody has looked. That is not the same as assessed and
    # found ordinary, and treating it as ordinary is how a critical entry never gets surfaced.
    if ($null -eq $critical) { return '3-unassessed' }
    $deferral = Get-MSTrackValue -SlateState $SlateState -Identity $Entry.Identity -Track 'deferral'
    if ($null -ne $deferral -and $deferral.Until.Date -le $AsOf.Date) { return '4-expired-deferral' }
    return '5-other'
}

function New-MSInventory {
    <#
        .SYNOPSIS
        The pre-sweep enumeration artifact: the corpus, read from disk, ordered as step 2 orders it,
        with the slate state folded in.

        An orphan body whose life carries an exit in force is NOT surfaced: it has already left, and
        re-presenting it at every subsequent slate is how the critical-first queue fills with
        entries that are already gone.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$IndexPath,
        [string]$SlatePath,
        [string]$LedgerPath,
        [string]$ArchivePath,
        [Parameter(Mandatory = $true)][datetime]$AsOf)

    $resolvedIndex = (Resolve-Path -LiteralPath $IndexPath).Path
    $dir = Split-Path -Parent $resolvedIndex
    if ([string]::IsNullOrWhiteSpace($SlatePath)) { $SlatePath = Join-Path $dir 'SLATE.md' }
    if ([string]::IsNullOrWhiteSpace($LedgerPath)) { $LedgerPath = Join-Path $dir 'LEDGER.md' }
    if ([string]::IsNullOrWhiteSpace($ArchivePath)) { $ArchivePath = Join-Path $dir 'ARCHIVE.md' }

    $indexText = [System.IO.File]::ReadAllText($resolvedIndex)
    $sha = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($indexText))).Replace('-', '').ToLowerInvariant()

    $ledger = Get-MSLedger -Path $LedgerPath -AsOf $AsOf
    $slate = Get-MSSlateState -Path $SlatePath -AsOf $AsOf
    $corpus = Get-MSCorpus -IndexPath $resolvedIndex
    $archiveNames = @(Get-MSArchiveNames -Path $ArchivePath)
    $incomplete = @(Get-MSIncompleteDispositions -Ledger $ledger -Corpus $corpus -ArchiveNames $archiveNames)
    $incompleteIds = @($incomplete | ForEach-Object { $_.Identity })

    $walked = @($corpus.Entries | Where-Object {
            -not ($_.Population -eq 'orphan-body' -and $ledger.ExitsInForce.ContainsKey($_.Identity))
        })

    $rows = foreach ($e in $walked) {
        $critical = Get-MSTrackValue -SlateState $slate -Identity $e.Identity -Track 'critical'
        $deferral = Get-MSTrackValue -SlateState $slate -Identity $e.Identity -Track 'deferral'
        $landing = Get-MSTrackValue -SlateState $slate -Identity $e.Identity -Track 'landing'
        [pscustomobject]@{
            name            = $e.Name
            identity        = $e.Identity
            population      = $e.Population
            index_line      = $e.Line
            group           = (Get-MSSweepGroup -Entry $e -SlateState $slate -IncompleteIdentities $incompleteIds -AsOf $AsOf)
            critical        = if ($null -eq $critical) { 'unassessed' } else { $critical.Value }
            deferral_count  = if ($null -eq $deferral) { 0 } else { $deferral.Value }
            deferred_until  = if ($null -eq $deferral) { $null } else { $deferral.Until.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) }
            landing         = if ($null -eq $landing) { 'none' } else { $landing.Value }
            landing_vehicle = if ($null -eq $landing) { '' } else { $landing.Detail }
        }
    }

    return [pscustomobject]@{
        enumerated_on           = $AsOf.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        # Named so a reader can tell an honest enumeration from one composed out of a session's
        # loaded view of the index, which on a large store is missing its tail without saying so.
        source                  = 'disk'
        index                   = $resolvedIndex
        index_sha256            = $sha
        index_characters        = (Measure-MIPCharacters -Text $indexText)
        ledger                  = [pscustomobject]@{ path = $LedgerPath; state = $ledger.State; records = $ledger.Records.Count; malformed = $ledger.Malformed.Count }
        slate                   = [pscustomobject]@{ path = $SlatePath; state = $slate.State; rows = $slate.Rows.Count; malformed = $slate.Malformed.Count; trustworthy = $slate.Trustworthy }
        archive                 = [pscustomobject]@{ path = $ArchivePath; present = (Test-Path -LiteralPath $ArchivePath -PathType Leaf); pointers = $archiveNames.Count }
        non_entry_files         = @($corpus.NonEntryFiles)
        incomplete_dispositions = @($incomplete)
        subject_count           = @($rows).Count
        subjects                = @(@($rows) | Sort-Object -Property @{ Expression = 'group' }, @{ Expression = 'name' })
    }
}

function Get-MSReconciliation {
    <#
        .SYNOPSIS
        Whether a LIVING entry has already exited, decided on its life key.

        Three verdicts, kept apart on purpose. 'exited' needs an exit in force for THIS life.
        'not-exited' is the answer for a life with no such record - which is the answer a re-earned
        lesson must get, even though its name carries an exit record from a previous life.
        'undecidable' is what an entry with no admission date on the living side gets: the read
        cannot establish which life this is, and guessing either way is how a live entry gets
        removed as already-handled.
    #>
    param([Parameter(Mandatory = $true)][string]$EntryPath, [Parameter(Mandatory = $true)]$Ledger)

    $identity = Get-MSEntryIdentity -Path $EntryPath
    $name = [System.IO.Path]::GetFileNameWithoutExtension($EntryPath)
    $forName = @($Ledger.ExitsInForce.Keys | Where-Object { $Ledger.ExitsInForce[$_].Name -ceq $name })
    if ($identity.EndsWith("@$script:MSUnknownAdmission", [System.StringComparison]::Ordinal)) {
        return [pscustomobject]@{
            Identity = $identity; Verdict = 'undecidable'
            Why      = "this entry records no admitted date, so which life it is cannot be established; $($forName.Count) exit(s) in force carry its name"
            Matching = @()
        }
    }
    if ($Ledger.ExitsInForce.ContainsKey($identity)) {
        return [pscustomobject]@{ Identity = $identity; Verdict = 'exited'; Why = 'an exit in force carries this life key'; Matching = @($Ledger.ExitsInForce[$identity]) }
    }
    return [pscustomobject]@{
        Identity = $identity; Verdict = 'not-exited'
        Why      = "no exit in force carries this life key ($($forName.Count) carry the name under a different life)"
        Matching = @()
    }
}

function Test-MSPartition {
    <#
        .SYNOPSIS
        Reconciles a recorded pre-sweep enumeration against the POST-sweep artifacts.

        The inventory is the input because it was written before any disposition was taken. A
        "nothing was lost" check built as a partition of the sweep's own working list cannot come
        out negative - every branch is drawn from the same list, so it agrees with itself however
        the store actually ended up.

        EVERY branch is keyed on the LIFE KEY. An earlier revision accounted 'still-hot' and
        'demoted' by bare name while accounting the exit branch by life key, so a pointer dropped
        with no record at all read as accounted whenever the name had ever been demoted, or had
        since been re-earned - which the store's own self-healing doctrine guarantees will happen.

        Where the life key cannot be established the answer is UNDECIDABLE, and undecidable is not
        accounted. An entry whose body was lawfully deleted resolves to '@unknown', and calling
        that still-hot would trade the old defect for a quieter one.
    #>
    param(
        [Parameter(Mandatory = $true)]$Inventory,
        [Parameter(Mandatory = $true)][string]$IndexPath,
        [string]$LedgerPath,
        [string]$ArchivePath,
        [string]$SlatePath,
        [datetime]$AsOf = [datetime]::Today)

    $resolvedIndex = (Resolve-Path -LiteralPath $IndexPath).Path
    $dir = Split-Path -Parent $resolvedIndex
    if ([string]::IsNullOrWhiteSpace($LedgerPath)) { $LedgerPath = Join-Path $dir 'LEDGER.md' }
    if ([string]::IsNullOrWhiteSpace($ArchivePath)) { $ArchivePath = Join-Path $dir 'ARCHIVE.md' }
    if ([string]::IsNullOrWhiteSpace($SlatePath)) { $SlatePath = Join-Path $dir 'SLATE.md' }

    # The post-sweep index, resolved to life keys the same way the pre-sweep enumeration was.
    $liveByName = Get-MSOrdinalMap
    foreach ($s in @(Get-MSIndexSubjects -IndexPath $resolvedIndex)) {
        $body = Join-Path $dir "$($s.Name).md"
        $liveByName[$s.Name] = "$($s.Name)@$((Get-MSEntryFacts -Path $body).Admitted)"
    }
    $ledger = Get-MSLedger -Path $LedgerPath -AsOf $AsOf
    $slate = Get-MSSlateState -Path $SlatePath -AsOf $AsOf
    $archived = [System.Collections.Generic.HashSet[string]]::new([string[]]@(Get-MSArchiveNames -Path $ArchivePath), [System.StringComparer]::OrdinalIgnoreCase)

    $enumeratedOn = [datetime]::ParseExact($Inventory.enumerated_on, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)

    $accounted = [System.Collections.Generic.List[object]]::new()
    $unaccounted = [System.Collections.Generic.List[object]]::new()
    foreach ($subject in @($Inventory.subjects)) {
        $how = $null
        $why = $null
        if ($ledger.ExitsInForce.ContainsKey($subject.identity)) {
            $record = $ledger.ExitsInForce[$subject.identity]
            $how = if ($record.Disposition -ceq 'demote') {
                if ($archived.Contains($subject.name)) { 'demoted' } else { $null }
            }
            else { 'exited-with-record' }
            if ($null -eq $how) { $why = 'a demotion is recorded for this life, but no archive line carries it' }
        }
        elseif ($liveByName.ContainsKey($subject.name)) {
            $liveIdentity = $liveByName[$subject.name]
            if ($liveIdentity -ceq $subject.identity) { $how = 'still-hot' }
            elseif ($liveIdentity.EndsWith("@$script:MSUnknownAdmission", [System.StringComparison]::Ordinal)) {
                $why = "a pointer for this name is still in the index, but its body records no admitted date, so whether THIS life is the one still hot cannot be decided"
            }
            else {
                $why = "the pointer for this name now belongs to a different life ($liveIdentity); this life left recall and no exit in force names it"
            }
        }
        elseif ($subject.population -eq 'orphan-body') {
            # An orphan accounts as still-an-orphan only when THIS sweep assessed it. A row from
            # some earlier sweep says the store once looked, not that this sweep did.
            $assessed = Get-MSTrackValue -SlateState $slate -Identity $subject.identity -Track 'critical'
            if ($null -ne $assessed -and $assessed.Date.Date -ge $enumeratedOn.Date) { $how = 'orphan-assessed' }
            else { $why = 'an orphan body this sweep neither dispositioned nor assessed' }
        }
        else {
            $why = 'its pointer is gone from the index, no archive line carries it, and no exit in force names this life'
        }

        if ($null -eq $how) {
            $unaccounted.Add([pscustomobject]@{
                    name       = $subject.name
                    identity   = $subject.identity
                    population = $subject.population
                    why        = $why
                })
            continue
        }
        $accounted.Add([pscustomobject]@{ name = $subject.name; identity = $subject.identity; how = $how })
    }

    $recordProblems = [System.Collections.Generic.List[string]]::new()
    foreach ($m in @($ledger.Malformed)) { $recordProblems.Add("unreadable ledger record: $($m.Raw) - $($m.Why)") }
    foreach ($m in @($slate.Malformed)) { $recordProblems.Add("unreadable slate row: $($m.Raw) - $($m.Why)") }
    foreach ($pair in @(@{ n = 'ledger'; s = $ledger }, @{ n = 'slate'; s = $slate })) {
        if ($pair.s.State -ceq 'duplicated') { $recordProblems.Add("$($pair.n): $($pair.s.StateWhy)") }
    }

    return [pscustomobject]@{
        index            = $resolvedIndex
        enumerated_on    = $Inventory.enumerated_on
        enumerated_from  = $Inventory.source
        subjects_checked = @($Inventory.subjects).Count
        accounted        = @($accounted)
        unaccounted      = @($unaccounted)
        record_problems  = @($recordProblems)
        result           = if (@($unaccounted).Count -eq 0 -and @($recordProblems).Count -eq 0) { 'accounted' } else { 'unaccounted' }
    }
}

function Test-MSDeferralAllowed {
    <#
        .SYNOPSIS
        Whether this entry may take a keep-hot-with-expiry disposition now.

        A critical entry may not be deferred twice. The rule is applied from the slate state, not
        from the exit record: replaying the ledger to answer "was this deferred before?" makes the
        slate's first step unexecutable at any population worth sweeping.

        An UNASSESSED entry may not be deferred either. An earlier revision read "no critical row"
        as "not critical", which made the twice-rule escapable by never assessing the entry - and
        every other gate in this file already reads absence as unassessed.

        A landing in flight is NOT a deferral, so it does not count toward the limit. That is what
        keeps a once-deferred critical entry from having no lawful move at all while its promotion
        sits in an open vehicle.
    #>
    param([Parameter(Mandatory = $true)]$SlateState, [Parameter(Mandatory = $true)][string]$Identity)

    if (-not $SlateState.Trustworthy) {
        return [pscustomobject]@{ Allowed = $false; NextCount = $null; Why = 'this store''s slate state carries rows this parser cannot read, so the deferral history might say anything; repair the slate before dispositioning' }
    }
    $critical = Get-MSTrackValue -SlateState $SlateState -Identity $Identity -Track 'critical'
    if ($null -eq $critical) {
        return [pscustomobject]@{ Allowed = $false; NextCount = $null; Why = 'this entry has not been assessed for the critical class; assess it before deferring it' }
    }
    $deferral = Get-MSTrackValue -SlateState $SlateState -Identity $Identity -Track 'deferral'
    $count = if ($null -eq $deferral) { 0 } else { [int]$deferral.Value }

    if ($critical.Value -ceq 'yes' -and $count -ge 1) {
        return [pscustomobject]@{
            Allowed   = $false
            NextCount = $count
            Why       = "a critical entry may not be deferred twice; this one already carries deferral $count. Land it, initiate a landing and take the in-flight state, or disposition it now."
        }
    }
    return [pscustomobject]@{ Allowed = $true; NextCount = $count + 1; Why = '' }
}

function Test-MSDestinationCarriesLesson {
    <#
        .SYNOPSIS
        Reads the destination and reports whether it carries the probe text at this moment.

        "Someone will write it up later" is not a destination, and neither is a destination nobody
        read. This reads the file.
    #>
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Probe)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Carries = $false; Why = "no file at '$Path'" }
    }
    $text = [System.IO.File]::ReadAllText($Path)
    if ($text.Contains($Probe, [System.StringComparison]::Ordinal)) {
        return [pscustomobject]@{ Carries = $true; Why = '' }
    }
    return [pscustomobject]@{ Carries = $false; Why = 'the destination does not carry the lesson at this moment' }
}

function Test-MSExitAllowed {
    <#
        .SYNOPSIS
        Whether this entry may take an exiting disposition now.

        The destination must carry the lesson for EVERY exit. That is the canonical policy's second
        replacement rule and it is stated without qualification: an exit is lawful only when its
        destination verifiably carries the lesson at landing time. An earlier revision enforced it
        for critical entries only, which left the shipped prose and the shipped gate saying
        different things about every ordinary promotion.

        For a CRITICAL entry the destination must additionally have LANDED, and that gate applies
        to every disposition that removes it from the index - promotion, demotion, deduplication,
        obsolescence and admission removal alike. The canonical text is explicit that demotion
        counts as leaving, and a critical lesson demoted to an archive nobody loads is exactly as
        gone as one deleted. Landed, for a repository destination, means merged to the default
        branch: a lesson read off an unmerged branch satisfies "the destination carries it" and is
        lost when the branch is abandoned.

        An unrecognized disposition REFUSES. It used to return "allowed - this does not remove the
        entry from the index", which is a claim, and a false one for any typo or case variant of a
        real exit.
    #>
    param(
        [Parameter(Mandatory = $true)]$SlateState,
        [Parameter(Mandatory = $true)][string]$Identity,
        [Parameter(Mandatory = $true)][string]$Disposition,
        [Parameter()][bool]$DestinationCarriesLesson = $false,
        [Parameter()][bool]$DestinationLanded = $false)

    $known = @($script:MSExitDispositions) + @($script:MSNonExitDispositions) + @($script:MSSelfDispositions)
    if ($known -cnotcontains $Disposition) {
        return [pscustomobject]@{ Allowed = $false; Why = "'$Disposition' is not a disposition the sweep procedure names; it is spelled exactly, in lower case, or it is not that disposition" }
    }
    if ($script:MSExitDispositions -cnotcontains $Disposition) {
        return [pscustomobject]@{ Allowed = $true; Why = "'$Disposition' does not remove the entry from the index" }
    }
    if (-not $SlateState.Trustworthy) {
        return [pscustomobject]@{ Allowed = $false; Why = 'this store''s slate state carries rows this parser cannot read, so the critical assessment might say anything; repair the slate before dispositioning' }
    }
    $critical = Get-MSTrackValue -SlateState $SlateState -Identity $Identity -Track 'critical'
    if ($null -eq $critical) {
        return [pscustomobject]@{ Allowed = $false; Why = 'this entry has not been assessed for the critical class; assess it before dispositioning it' }
    }
    if (-not $DestinationCarriesLesson) {
        return [pscustomobject]@{ Allowed = $false; Why = 'an exit is lawful only when its destination is read and confirmed to carry the lesson at this moment' }
    }
    if ($critical.Value -ceq 'yes' -and -not $DestinationLanded) {
        return [pscustomobject]@{ Allowed = $false; Why = 'the destination carries the lesson but has not landed; for a repository destination landed means merged to the default branch. Take the landing-in-flight state instead.' }
    }
    return [pscustomobject]@{ Allowed = $true; Why = '' }
}

function Test-MSAdmissionRemovalEligible {
    <#
        .SYNOPSIS
        Whether remove-fails-admission may be applied to this entry at all.

        The admission rule lands in the instruction file every session loads, and every entry
        admitted before it landed predates it by definition. An unscoped reading condemns the whole
        existing corpus at the first sweep, with the owner's fatigue as the only guard.
    #>
    param([Parameter(Mandatory = $true)][string]$Identity, [Parameter(Mandatory = $true)][datetime]$AdmissionRuleLandedOn)

    $parsed = ConvertTo-MSIdentity -Text $Identity -AsOf ([datetime]::MaxValue)
    if (-not $parsed.Ok) {
        return [pscustomobject]@{ Eligible = $false; Why = $parsed.Why }
    }
    if ($parsed.Admitted -ceq $script:MSUnknownAdmission) {
        return [pscustomobject]@{ Eligible = $false; Why = 'this entry records no admitted date, so it cannot be shown to postdate the admission rule; it is grandfathered' }
    }
    $admitted = [datetime]::ParseExact($parsed.Admitted, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    if ($admitted.Date -lt $AdmissionRuleLandedOn.Date) {
        return [pscustomobject]@{ Eligible = $false; Why = "admitted $($parsed.Admitted), before the admission rule landed on $($AdmissionRuleLandedOn.ToString('yyyy-MM-dd')); grandfathered" }
    }
    return [pscustomobject]@{ Eligible = $true; Why = '' }
}

function Format-MSStorePath {
    <#
        .SYNOPSIS
        A measured surface's path in a form another machine can compare.

        An absolute path under one account's home directory makes a series of measurements
        incomparable the moment the store is read anywhere else - and the whole point of measuring
        a destination repeatedly is to be able to say it is filling up.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = (Resolve-Path -LiteralPath $Path).Path
    # Not $home: that is an automatic variable, and shadowing it here would be a trap for the next
    # reader of this function.
    $profileDir = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
    if (-not [string]::IsNullOrWhiteSpace($profileDir) -and $full.StartsWith($profileDir, [System.StringComparison]::OrdinalIgnoreCase)) {
        return '~' + ($full.Substring($profileDir.Length) -replace '\\', '/')
    }
    return ($full -replace '\\', '/')
}

function New-MSSurfaceMeasurement {
    <#
        .SYNOPSIS
        Measures one exit destination in the store's own counting rule and returns a conforming
        record: date, value, unit, surface, method.

        The shipped checker refuses a path that is not an index, by design, so this is the
        instrument the destination-measurement step names. A hand count nobody can reproduce fails
        the evidence bar the same way an unattributed number does.
    #>
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][datetime]$AsOf)

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $text = [System.IO.File]::ReadAllText($resolved)
    return [pscustomobject]@{
        date    = $AsOf.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        value   = (Measure-MIPCharacters -Text $text)
        unit    = $script:MSMeasurementUnit
        surface = (Format-MSStorePath -Path $resolved)
        method  = 'Measure-MemorySurface.ps1 (UTF-8 decoded, CRLF and lone CR normalized to LF, length in UTF-16 code units)'
    }
}

function Format-MSSurfaceMeasurement {
    <#
        .SYNOPSIS
        Renders a measurement as the values-region row it is recorded as.
    #>
    param([Parameter(Mandatory = $true)]$Measurement)

    return "x-destination_observation: $($Measurement.date) | $($Measurement.value) | $($Measurement.unit) | $($Measurement.surface) | $($Measurement.method)"
}

function Test-MSSurfaceMeasurement {
    <#
        .SYNOPSIS
        Whether a measurement record carries all four fields the step requires plus its method.

        A measurement with no unit, no date or no surface could never say "this destination is
        filling up", which is the only thing the step exists to say.
    #>
    param([Parameter(Mandatory = $true)][string]$Record)

    $body = $Record
    $prefix = 'x-destination_observation:'
    if ($body.TrimStart().StartsWith($prefix, [System.StringComparison]::Ordinal)) {
        $body = $body.TrimStart().Substring($prefix.Length)
    }
    $fields = @($body -split '\|' | ForEach-Object { $_.Trim() })
    $problems = [System.Collections.Generic.List[string]]::new()
    if ($fields.Count -lt 5) {
        $problems.Add("expected 5 pipe-separated fields (date | value | unit | surface | method); found $($fields.Count)")
        return [pscustomobject]@{ Conforming = $false; Problems = @($problems) }
    }
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($fields[0], 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        $problems.Add("date must be a real date in yyyy-MM-dd form; found '$($fields[0])'")
    }
    $value = 0
    if (-not [int]::TryParse($fields[1], [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value) -or $value -lt 0) {
        $problems.Add("value must be a whole number of $script:MSMeasurementUnit; found '$($fields[1])'")
    }
    if ($fields[2] -cne $script:MSMeasurementUnit) {
        $problems.Add("unit must be '$script:MSMeasurementUnit' - the store's own counting rule; found '$($fields[2])'")
    }
    if ([string]::IsNullOrWhiteSpace($fields[3])) { $problems.Add('surface must name the file measured') }
    if ([string]::IsNullOrWhiteSpace(($fields[4..($fields.Count - 1)] -join ' | '))) { $problems.Add('method must state how the measurement reproduces') }
    return [pscustomobject]@{ Conforming = ($problems.Count -eq 0); Problems = @($problems) }
}
