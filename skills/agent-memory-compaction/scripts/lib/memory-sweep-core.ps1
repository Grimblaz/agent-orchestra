<#
.SYNOPSIS
    Shared logic for the sweep procedure's three instruments: the pre-sweep inventory, the
    partition check, and the destination measurement.

.DESCRIPTION
    The procedure these serve is skills/agent-memory-compaction/references/sweep-procedure.md and
    the record shapes are defined in references/store-records.md. Nothing here writes to a store.
    The sweep writes; these read and report, so that each of the three procedural checks produces
    an artifact a later reader can re-run rather than a claim the sweep makes about itself.

    The record parsers deliberately keep three verdicts apart that are easy to collapse into one:
    a record that says something, a record this parser could not read (malformed), and no record
    at all. Collapsing them is how a live entry gets treated as already-handled.

    Marked-region reading, link parsing and the character-counting rule are taken from
    lib/memory-index-policy-core.ps1 rather than reimplemented, so the sweep and the check can
    never disagree about what a pointer is or how big a file is.
#>

. (Join-Path $PSScriptRoot 'memory-index-policy-core.ps1')

$script:MSLedgerBeginMarker = '<!-- memory-ledger-begin -->'
$script:MSLedgerEndMarker = '<!-- memory-ledger-end -->'
$script:MSSlateBeginMarker = '<!-- memory-slate-begin -->'
$script:MSSlateEndMarker = '<!-- memory-slate-end -->'

$script:MSStatuses = @('proposed', 'executed', 'reconciled')
$script:MSSlateTracks = @('critical', 'deferral', 'landing', 'presence')

# The dispositions that remove a pointer from the index. 'keep-hot-with-expiry' and
# 'settle-in-place' are absent on purpose: neither is an exit, and the settled-section move is
# the one the canonical text's second sense of "demote" names.
$script:MSExitDispositions = @(
    'promote', 'demote', 'remove-fails-admission', 'evaporate-on-close', 'dedupe-into', 'remove-obsolete')
$script:MSNonExitDispositions = @('keep-hot-with-expiry', 'settle-in-place', 'ledger-compaction')

$script:MSUnknownAdmission = 'unknown'
$script:MSFrontmatterFence = '---'

function Get-MSRecordLines {
    <#
        .SYNOPSIS
        The raw record lines inside a marked region, or an empty set when the file is absent.

        A file that does not exist is not the same as a file with no records, and neither is the
        same as a file whose markers are missing - the last is a store that tried to record
        something this parser cannot find. All three are reported distinctly.
    #>
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$BeginMarker, [Parameter(Mandatory = $true)][string]$EndMarker)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ State = 'absent'; Lines = @() }
    }
    $lines = @([System.IO.File]::ReadAllLines($Path))
    $region = Get-MIPMarkedRegion -Lines $lines -BeginMarker $BeginMarker -EndMarker $EndMarker
    if (-not $region.MarkersPresent) {
        return [pscustomobject]@{ State = 'unmarked'; Lines = @() }
    }
    $records = @($region.Block | Where-Object { $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#') })
    return [pscustomobject]@{ State = 'present'; Lines = $records }
}

function ConvertTo-MSLedgerRecord {
    <#
        .SYNOPSIS
        Parses one ledger line: date | status | disposition | identity | reason | destination.

        A line missing its status, or carrying one outside the vocabulary, is MALFORMED and is
        never read as executed. Proposals are the high-frequency traffic in this file, so a
        parser that defaulted a missing status would eventually read one as a completed exit.
    #>
    param([Parameter(Mandatory = $true)][string]$Line, [int]$Number = 0)

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
        Malformed   = $false
        Why         = ''
    }
    if ($fields.Count -lt 6) {
        $record.Malformed = $true
        $record.Why = "expected 6 pipe-separated fields (date | status | disposition | identity | reason | destination); found $($fields.Count)"
        return $record
    }
    $parsedDate = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($fields[0], 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsedDate)) {
        $record.Malformed = $true
        $record.Why = "date must be yyyy-MM-dd; found '$($fields[0])'"
        return $record
    }
    $record.Date = $parsedDate
    if ($script:MSStatuses -cnotcontains $fields[1]) {
        $record.Malformed = $true
        $record.Why = "status must be one of $($script:MSStatuses -join ', '); found '$($fields[1])'"
        return $record
    }
    $record.Status = $fields[1]
    $known = @($script:MSExitDispositions) + @($script:MSNonExitDispositions)
    if ($known -cnotcontains $fields[2]) {
        $record.Malformed = $true
        $record.Why = "disposition '$($fields[2])' is not one the sweep procedure names"
        return $record
    }
    $record.Disposition = $fields[2]
    $identity = $fields[3]
    if ($identity -notmatch '^(?<name>.+)@(?<admitted>\d{4}-\d{2}-\d{2}|unknown)$') {
        $record.Malformed = $true
        $record.Why = "identity must read '<entry-name>@<yyyy-MM-dd>' or '<entry-name>@unknown'; found '$identity'"
        return $record
    }
    $record.Identity = $identity
    $record.Name = $Matches['name']
    $record.Admitted = $Matches['admitted']
    $record.Reason = $fields[4]
    $record.Destination = ($fields[5..($fields.Count - 1)] -join ' | ')
    return $record
}

function Get-MSLedger {
    param([Parameter(Mandatory = $true)][string]$Path)

    $raw = Get-MSRecordLines -Path $Path -BeginMarker $script:MSLedgerBeginMarker -EndMarker $script:MSLedgerEndMarker
    $records = [System.Collections.Generic.List[object]]::new()
    $n = 0
    foreach ($line in $raw.Lines) {
        $n++
        $records.Add((ConvertTo-MSLedgerRecord -Line $line -Number $n))
    }
    return [pscustomobject]@{
        Path      = $Path
        State     = $raw.State
        Records   = @($records)
        Malformed = @($records | Where-Object { $_.Malformed })
    }
}

function ConvertTo-MSSlateRow {
    <#
        .SYNOPSIS
        Parses one slate row: date | identity | track | value | detail.
    #>
    param([Parameter(Mandatory = $true)][string]$Line, [int]$Number = 0)

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
    if ($fields.Count -lt 4) {
        $row.Malformed = $true
        $row.Why = "expected at least 4 pipe-separated fields (date | identity | track | value [| detail]); found $($fields.Count)"
        return $row
    }
    $parsedDate = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($fields[0], 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsedDate)) {
        $row.Malformed = $true
        $row.Why = "date must be yyyy-MM-dd; found '$($fields[0])'"
        return $row
    }
    $row.Date = $parsedDate
    if ($fields[1] -notmatch '^(?<name>.+)@(?<admitted>\d{4}-\d{2}-\d{2}|unknown)$') {
        $row.Malformed = $true
        $row.Why = "identity must read '<entry-name>@<yyyy-MM-dd>' or '<entry-name>@unknown'; found '$($fields[1])'"
        return $row
    }
    $row.Identity = $fields[1]
    $row.Name = $Matches['name']
    if ($script:MSSlateTracks -cnotcontains $fields[2]) {
        $row.Malformed = $true
        $row.Why = "track must be one of $($script:MSSlateTracks -join ', '); found '$($fields[2])'"
        return $row
    }
    $row.Track = $fields[2]
    $row.Value = $fields[3]
    if ($fields.Count -gt 4) { $row.Detail = ($fields[4..($fields.Count - 1)] -join ' | ') }

    if ($row.Track -eq 'deferral') {
        # The count is carried in the row rather than derived by counting rows: a derived count
        # goes wrong the moment the slate file is compacted, and the never-deferred-twice rule
        # is exactly the thing that must not quietly become false.
        $count = 0
        if (-not [int]::TryParse($row.Value, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$count) -or $count -lt 1) {
            $row.Malformed = $true
            $row.Why = "a deferral's value is its running count, a positive whole number; found '$($row.Value)'"
            return $row
        }
        $row.Value = $count
        $untilMatch = [regex]::Match($row.Detail, 'until\s+(?<until>\d{4}-\d{2}-\d{2})')
        if (-not $untilMatch.Success) {
            # There is no indefinite deferral. A row without an expiry would be one, so it is
            # malformed rather than treated as a deferral that never comes back.
            $row.Malformed = $true
            $row.Why = "a deferral must carry 'until <yyyy-MM-dd>' in its detail; found '$($row.Detail)'"
            return $row
        }
        $row.Until = [datetime]::ParseExact($untilMatch.Groups['until'].Value, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($row.Track -eq 'landing' -and $row.Value -ceq 'in-flight' -and [string]::IsNullOrWhiteSpace($row.Detail)) {
        $row.Malformed = $true
        $row.Why = "an in-flight landing must name its vehicle in the detail field"
        return $row
    }
    return $row
}

function Get-MSSlateState {
    <#
        .SYNOPSIS
        Reads SLATE.md and folds it to the current state: the latest row per identity AND track.

        Four independent tracks rather than one state column, because the states are orthogonal -
        an entry can be critical and deferred and have a landing in flight at the same time, and
        a single latest-row-wins column would silently drop two of the three.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $raw = Get-MSRecordLines -Path $Path -BeginMarker $script:MSSlateBeginMarker -EndMarker $script:MSSlateEndMarker
    $rows = [System.Collections.Generic.List[object]]::new()
    $n = 0
    foreach ($line in $raw.Lines) {
        $n++
        $rows.Add((ConvertTo-MSSlateRow -Line $line -Number $n))
    }
    $current = @{}
    foreach ($row in @($rows | Where-Object { -not $_.Malformed })) {
        $key = "$($row.Identity)`0$($row.Track)"
        # Latest by date, ties broken by file order - the same append discipline the values
        # record already carries, where the freshest governs.
        if (-not $current.ContainsKey($key) -or $row.Date -ge $current[$key].Date) { $current[$key] = $row }
    }
    return [pscustomobject]@{
        Path      = $Path
        State     = $raw.State
        Rows      = @($rows)
        Malformed = @($rows | Where-Object { $_.Malformed })
        Current   = $current
    }
}

function Get-MSTrackValue {
    param([Parameter(Mandatory = $true)]$SlateState, [Parameter(Mandatory = $true)][string]$Identity, [Parameter(Mandatory = $true)][string]$Track)

    $key = "$Identity`0$Track"
    if ($SlateState.Current.ContainsKey($key)) { return $SlateState.Current[$key] }
    return $null
}

function Get-MSEntryAdmission {
    <#
        .SYNOPSIS
        The admission date an entry body records in its own frontmatter, or 'unknown'.

        This is the life-binding on the LIVING side. Without it a reconciliation cannot tell one
        life of a reused name from another, and 'unknown' has to stay a distinct answer: an entry
        whose life cannot be established is undecidable, not exited and not not-exited.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $script:MSUnknownAdmission }
    $lines = @([System.IO.File]::ReadAllLines($Path))
    if ($lines.Count -eq 0 -or $lines[0].Trim() -cne $script:MSFrontmatterFence) { return $script:MSUnknownAdmission }
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -ceq $script:MSFrontmatterFence) { break }
        $m = [regex]::Match($lines[$i], '^\s*admitted:\s*(?<d>\d{4}-\d{2}-\d{2})\s*$')
        if ($m.Success) { return $m.Groups['d'].Value }
    }
    return $script:MSUnknownAdmission
}

function Get-MSEntryIdentity {
    param([Parameter(Mandatory = $true)][string]$Path)

    $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    return "$name@$(Get-MSEntryAdmission -Path $Path)"
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
        if ($lines[$i] -notmatch $script:PointerLinePattern) { continue }
        $parsed = Get-MIPLinksInLine -Text $lines[$i]
        foreach ($link in @($parsed.Links | Where-Object { $_.IsSubject })) {
            $subjects.Add([pscustomobject]@{
                    Name   = [System.IO.Path]::GetFileNameWithoutExtension($link.Target)
                    Target = $link.Target
                    Line   = $i + 1
                    Text   = $lines[$i]
                })
        }
    }
    return @($subjects)
}

function Get-MSCorpus {
    <#
        .SYNOPSIS
        The two populations a sweep walks: the index's linked subjects, and every entry file in
        the store directory that no pointer points at.

        Orphan bodies are outside recall already and invisible to the checker, whose whole
        subject is the index. They still hold lessons and can still be critical, so a walk that
        skips them reports a complete sweep of a store it never fully looked at.
    #>
    param([Parameter(Mandatory = $true)][string]$IndexPath, [string[]]$ExcludeNames = @())

    $dir = Split-Path -Parent (Resolve-Path -LiteralPath $IndexPath).Path
    $indexName = [System.IO.Path]::GetFileNameWithoutExtension($IndexPath)
    $reserved = @($ExcludeNames) + @($indexName, 'POLICY', 'LEDGER', 'SLATE', 'ARCHIVE')

    $subjects = @(Get-MSIndexSubjects -IndexPath $IndexPath)
    $pointed = @{}
    foreach ($s in $subjects) { $pointed[$s.Name] = $true }

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($s in $subjects) {
        $body = Join-Path $dir "$($s.Name).md"
        $entries.Add([pscustomobject]@{
                Name       = $s.Name
                Identity   = if (Test-Path -LiteralPath $body -PathType Leaf) { Get-MSEntryIdentity -Path $body } else { "$($s.Name)@$script:MSUnknownAdmission" }
                Population = 'pointer'
                Line       = $s.Line
                BodyExists = (Test-Path -LiteralPath $body -PathType Leaf)
            })
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $dir -Filter '*.md' -File | Sort-Object -Property Name)) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        if ($reserved -ccontains $name -or $pointed.ContainsKey($name)) { continue }
        $entries.Add([pscustomobject]@{
                Name       = $name
                Identity   = Get-MSEntryIdentity -Path $file.FullName
                Population = 'orphan-body'
                Line       = 0
                BodyExists = $true
            })
    }
    return @($entries)
}

function Get-MSIncompleteDispositions {
    <#
        .SYNOPSIS
        Executed exit records whose act is not reflected in the store.

        Record-before-act makes an interruption between the two visible instead of silent. It is
        NOT resolved here: re-executing and dropping are both plausible and the record cannot
        tell which is right, so the state is surfaced for a person.
    #>
    param([Parameter(Mandatory = $true)]$Ledger, [Parameter(Mandatory = $true)]$Corpus, [string[]]$ArchiveNames = @())

    $hot = @{}
    foreach ($e in @($Corpus | Where-Object { $_.Population -eq 'pointer' })) { $hot[$e.Identity] = $true }
    $incomplete = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @($Ledger.Records | Where-Object { -not $_.Malformed -and $_.Status -ceq 'executed' -and $script:MSExitDispositions -ccontains $_.Disposition })) {
        if ($hot.ContainsKey($r.Identity)) {
            $incomplete.Add([pscustomobject]@{ Identity = $r.Identity; Disposition = $r.Disposition; Why = 'the record says it exited, but its pointer is still in the index' })
            continue
        }
        if ($r.Disposition -ceq 'demote' -and $ArchiveNames -cnotcontains $r.Name) {
            $incomplete.Add([pscustomobject]@{ Identity = $r.Identity; Disposition = $r.Disposition; Why = 'the record says it was demoted, but no archive line carries it' })
        }
    }
    return @($incomplete)
}

function Get-MSArchiveNames {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @([System.IO.File]::ReadAllLines($Path))) {
        if ($line -notmatch $script:PointerLinePattern) { continue }
        foreach ($link in @((Get-MIPLinksInLine -Text $line).Links | Where-Object { $_.IsSubject })) {
            $names.Add([System.IO.Path]::GetFileNameWithoutExtension($link.Target))
        }
    }
    return @($names)
}

function Get-MSSweepGroup {
    <#
        .SYNOPSIS
        Which of step 2's five groups an entry falls in. First match wins, so a critical entry
        that is also an expired deferral is still handled as critical.
    #>
    # IncompleteIdentities is NOT Mandatory: PowerShell's mandatory binding rejects an empty
    # array, and "no interrupted disposition" is the ordinary case - a store with none would
    # otherwise throw out of the enumeration rather than enumerate cleanly.
    param([Parameter(Mandatory = $true)]$Entry, [Parameter(Mandatory = $true)]$SlateState, [string[]]$IncompleteIdentities = @(), [Parameter(Mandatory = $true)][datetime]$AsOf)

    if ($IncompleteIdentities -ccontains $Entry.Identity) { return '1-incomplete-disposition' }
    $critical = Get-MSTrackValue -SlateState $SlateState -Identity $Entry.Identity -Track 'critical'
    if ($null -ne $critical -and $critical.Value -ceq 'yes') { return '2-critical' }
    $deferral = Get-MSTrackValue -SlateState $SlateState -Identity $Entry.Identity -Track 'deferral'
    if ($null -ne $deferral -and $deferral.Until.Date -le $AsOf.Date) { return '3-expired-deferral' }
    # No row on EITHER polarity means nobody has looked. That is not the same as assessed and
    # found ordinary, and treating it as ordinary is how a critical entry never gets surfaced.
    if ($null -eq $critical) { return '4-unassessed' }
    return '5-other'
}

function New-MSInventory {
    <#
        .SYNOPSIS
        The pre-sweep enumeration artifact: the corpus, read from disk, ordered as step 2 orders
        it, with the slate state folded in.
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

    $ledger = Get-MSLedger -Path $LedgerPath
    $slate = Get-MSSlateState -Path $SlatePath
    $corpus = @(Get-MSCorpus -IndexPath $resolvedIndex)
    $archiveNames = @(Get-MSArchiveNames -Path $ArchivePath)
    $incomplete = @(Get-MSIncompleteDispositions -Ledger $ledger -Corpus $corpus -ArchiveNames $archiveNames)
    $incompleteIds = @($incomplete | ForEach-Object { $_.Identity })

    $rows = foreach ($e in $corpus) {
        $critical = Get-MSTrackValue -SlateState $slate -Identity $e.Identity -Track 'critical'
        $deferral = Get-MSTrackValue -SlateState $slate -Identity $e.Identity -Track 'deferral'
        $landing = Get-MSTrackValue -SlateState $slate -Identity $e.Identity -Track 'landing'
        [pscustomobject]@{
            name           = $e.Name
            identity       = $e.Identity
            population     = $e.Population
            index_line     = $e.Line
            group          = (Get-MSSweepGroup -Entry $e -SlateState $slate -IncompleteIdentities $incompleteIds -AsOf $AsOf)
            critical       = if ($null -eq $critical) { 'unassessed' } else { $critical.Value }
            deferral_count = if ($null -eq $deferral) { 0 } else { $deferral.Value }
            deferred_until = if ($null -eq $deferral) { $null } else { $deferral.Until.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) }
            landing        = if ($null -eq $landing) { 'none' } else { $landing.Value }
            landing_vehicle = if ($null -eq $landing) { '' } else { $landing.Detail }
        }
    }

    return [pscustomobject]@{
        enumerated_on   = $AsOf.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        # Named so a reader can tell an honest enumeration from one composed out of a session's
        # loaded view of the index, which on a large store is missing its tail without saying so.
        source          = 'disk'
        index           = $resolvedIndex
        index_sha256    = $sha
        index_characters = (Measure-MIPCharacters -Text $indexText)
        ledger          = [pscustomobject]@{ path = $LedgerPath; state = $ledger.State; records = $ledger.Records.Count; malformed = $ledger.Malformed.Count }
        slate           = [pscustomobject]@{ path = $SlatePath; state = $slate.State; rows = $slate.Rows.Count; malformed = $slate.Malformed.Count }
        archive         = [pscustomobject]@{ path = $ArchivePath; present = (Test-Path -LiteralPath $ArchivePath -PathType Leaf); pointers = $archiveNames.Count }
        incomplete_dispositions = @($incomplete)
        subject_count   = @($rows).Count
        subjects        = @(@($rows) | Sort-Object -Property @{ Expression = 'group' }, @{ Expression = 'name' })
    }
}

function Get-MSReconciliation {
    <#
        .SYNOPSIS
        Whether a LIVING entry has already exited, decided on its life key.

        Three verdicts, kept apart on purpose. 'exited' needs an executed exit record for THIS
        life. 'not-exited' is the answer for a life with no such record - which is the answer a
        re-earned lesson must get, even though its name carries an exit record from a previous
        life. 'undecidable' is what an entry with no admission date on the living side gets: the
        read cannot establish which life this is, and guessing either way is how a live entry
        gets removed as already-handled.
    #>
    param([Parameter(Mandatory = $true)][string]$EntryPath, [Parameter(Mandatory = $true)]$Ledger)

    $identity = Get-MSEntryIdentity -Path $EntryPath
    $name = [System.IO.Path]::GetFileNameWithoutExtension($EntryPath)
    $recordsForName = @($Ledger.Records | Where-Object { -not $_.Malformed -and $_.Name -ceq $name -and $_.Status -ceq 'executed' -and $script:MSExitDispositions -ccontains $_.Disposition })
    if ($identity.EndsWith("@$script:MSUnknownAdmission", [System.StringComparison]::Ordinal)) {
        return [pscustomobject]@{
            Identity = $identity; Verdict = 'undecidable'
            Why      = "this entry records no admitted date, so which life it is cannot be established; $($recordsForName.Count) executed exit record(s) carry its name"
            Matching = @()
        }
    }
    $matching = @($recordsForName | Where-Object { $_.Identity -ceq $identity })
    if ($matching.Count -gt 0) {
        return [pscustomobject]@{ Identity = $identity; Verdict = 'exited'; Why = "an executed exit record carries this life key"; Matching = $matching }
    }
    return [pscustomobject]@{
        Identity = $identity; Verdict = 'not-exited'
        Why      = "no executed exit record carries this life key ($($recordsForName.Count) carry the name under a different life)"
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
    #>
    param(
        [Parameter(Mandatory = $true)]$Inventory,
        [Parameter(Mandatory = $true)][string]$IndexPath,
        [string]$LedgerPath,
        [string]$ArchivePath,
        [string]$SlatePath)

    $resolvedIndex = (Resolve-Path -LiteralPath $IndexPath).Path
    $dir = Split-Path -Parent $resolvedIndex
    if ([string]::IsNullOrWhiteSpace($LedgerPath)) { $LedgerPath = Join-Path $dir 'LEDGER.md' }
    if ([string]::IsNullOrWhiteSpace($ArchivePath)) { $ArchivePath = Join-Path $dir 'ARCHIVE.md' }
    if ([string]::IsNullOrWhiteSpace($SlatePath)) { $SlatePath = Join-Path $dir 'SLATE.md' }

    $hot = @{}
    foreach ($s in @(Get-MSIndexSubjects -IndexPath $resolvedIndex)) { $hot[$s.Name] = $true }
    $archived = @{}
    foreach ($n in @(Get-MSArchiveNames -Path $ArchivePath)) { $archived[$n] = $true }
    $ledger = Get-MSLedger -Path $LedgerPath
    $slate = Get-MSSlateState -Path $SlatePath
    $exited = @{}
    foreach ($r in @($ledger.Records | Where-Object { -not $_.Malformed -and $_.Status -ceq 'executed' -and $script:MSExitDispositions -ccontains $_.Disposition })) {
        $exited[$r.Identity] = $r
    }

    $accounted = [System.Collections.Generic.List[object]]::new()
    $unaccounted = [System.Collections.Generic.List[object]]::new()
    foreach ($subject in @($Inventory.subjects)) {
        # Order matters where two could apply. A demotion writes BOTH an archive line and an exit
        # record, and 'demoted' is the more informative of the two true answers; a pointer that is
        # still hot despite an exit record is an interrupted disposition, which the inventory
        # surfaces separately - here it is simply still in recall.
        $how = $null
        if ($hot.ContainsKey($subject.name)) { $how = 'still-hot' }
        elseif ($archived.ContainsKey($subject.name)) { $how = 'demoted' }
        elseif ($exited.ContainsKey($subject.identity)) { $how = 'exited-with-record' }
        elseif ($subject.population -eq 'orphan-body' -and (Get-MSTrackValue -SlateState $slate -Identity $subject.identity -Track 'critical')) { $how = 'orphan-assessed' }

        if ($null -eq $how) {
            $unaccounted.Add([pscustomobject]@{
                    name     = $subject.name
                    identity = $subject.identity
                    population = $subject.population
                    why      = if ($subject.population -eq 'orphan-body') {
                        'an orphan body the sweep neither dispositioned nor assessed'
                    }
                    else {
                        'its pointer is gone from the index, no archive line carries it, and no executed exit record names this life'
                    }
                })
            continue
        }
        $accounted.Add([pscustomobject]@{ name = $subject.name; identity = $subject.identity; how = $how })
    }

    return [pscustomobject]@{
        index            = $resolvedIndex
        enumerated_on    = $Inventory.enumerated_on
        enumerated_from  = $Inventory.source
        subjects_checked = @($Inventory.subjects).Count
        accounted        = @($accounted)
        unaccounted      = @($unaccounted)
        ledger_malformed = @($ledger.Malformed | ForEach-Object { $_.Raw })
        slate_malformed  = @($slate.Malformed | ForEach-Object { $_.Raw })
        result           = if (@($unaccounted).Count -eq 0 -and @($ledger.Malformed).Count -eq 0 -and @($slate.Malformed).Count -eq 0) { 'accounted' } else { 'unaccounted' }
    }
}

function Test-MSDeferralAllowed {
    <#
        .SYNOPSIS
        Whether this entry may take a keep-hot-with-expiry disposition now.

        A critical entry may not be deferred twice. The rule is applied from the slate state, not
        from the exit record: replaying the ledger to answer "was this deferred before?" makes
        the slate's first step unexecutable at any population worth sweeping.

        A landing in flight is NOT a deferral, so it does not count toward the limit. That is
        what keeps a once-deferred critical entry from having no lawful move at all while its
        promotion sits in an open vehicle.
    #>
    param([Parameter(Mandatory = $true)]$SlateState, [Parameter(Mandatory = $true)][string]$Identity)

    $critical = Get-MSTrackValue -SlateState $SlateState -Identity $Identity -Track 'critical'
    $deferral = Get-MSTrackValue -SlateState $SlateState -Identity $Identity -Track 'deferral'
    $count = if ($null -eq $deferral) { 0 } else { [int]$deferral.Value }
    $isCritical = ($null -ne $critical -and $critical.Value -ceq 'yes')

    if ($isCritical -and $count -ge 1) {
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

        "Someone will write it up later" is not a destination, and neither is a destination
        nobody read. This reads the file.
    #>
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Probe)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Carries = $false; Why = "no file at '$Path'" }
    }
    $text = [System.IO.File]::ReadAllText($Path)
    if ($text.Contains($Probe, [System.StringComparison]::Ordinal)) {
        return [pscustomobject]@{ Carries = $true; Why = '' }
    }
    return [pscustomobject]@{ Carries = $false; Why = "the destination does not carry the lesson at this moment" }
}

function Test-MSExitAllowed {
    <#
        .SYNOPSIS
        Whether this entry may take an exiting disposition now.

        For a CRITICAL entry the gate applies to every disposition that removes it from the index
        - promotion, demotion, deduplication, obsolescence and admission removal alike. The
        canonical text is explicit that demotion counts as leaving, and a critical lesson demoted
        to an archive nobody loads is exactly as gone as one deleted.

        Landed, for a repository destination, means merged to the default branch. A lesson read
        off an unmerged branch satisfies "the destination carries it" and loses the lesson when
        the branch is abandoned, which is why Landed is a separate answer from Carries.
    #>
    param(
        [Parameter(Mandatory = $true)]$SlateState,
        [Parameter(Mandatory = $true)][string]$Identity,
        [Parameter(Mandatory = $true)][string]$Disposition,
        [Parameter()][bool]$DestinationCarriesLesson = $false,
        [Parameter()][bool]$DestinationLanded = $false)

    if ($script:MSExitDispositions -cnotcontains $Disposition) {
        return [pscustomobject]@{ Allowed = $true; Why = "'$Disposition' does not remove the entry from the index" }
    }
    $critical = Get-MSTrackValue -SlateState $SlateState -Identity $Identity -Track 'critical'
    if ($null -eq $critical) {
        return [pscustomobject]@{ Allowed = $false; Why = 'this entry has not been assessed for the critical class; assess it before dispositioning it' }
    }
    if ($critical.Value -cne 'yes') { return [pscustomobject]@{ Allowed = $true; Why = '' } }

    if (-not $DestinationCarriesLesson) {
        return [pscustomobject]@{ Allowed = $false; Why = 'a critical entry exits only when its destination is read and confirmed to carry the lesson' }
    }
    if (-not $DestinationLanded) {
        return [pscustomobject]@{ Allowed = $false; Why = 'the destination carries the lesson but has not landed; for a repository destination landed means merged to the default branch. Take the landing-in-flight state instead.' }
    }
    return [pscustomobject]@{ Allowed = $true; Why = '' }
}

function Test-MSAdmissionRemovalEligible {
    <#
        .SYNOPSIS
        Whether remove-fails-admission may be applied to this entry at all.

        The admission rule lands in the instruction file every session loads, and every entry
        admitted before it landed predates it by definition. An unscoped reading condemns the
        whole existing corpus at the first sweep, with the owner's fatigue as the only guard.
    #>
    param([Parameter(Mandatory = $true)][string]$Identity, [Parameter(Mandatory = $true)][datetime]$AdmissionRuleLandedOn)

    if ($Identity -notmatch '@(?<admitted>\d{4}-\d{2}-\d{2})$') {
        return [pscustomobject]@{ Eligible = $false; Why = 'this entry records no admitted date, so it cannot be shown to postdate the admission rule; it is grandfathered' }
    }
    $admitted = [datetime]::ParseExact($Matches['admitted'], 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    if ($admitted.Date -lt $AdmissionRuleLandedOn.Date) {
        return [pscustomobject]@{ Eligible = $false; Why = "admitted $($Matches['admitted']), before the admission rule landed on $($AdmissionRuleLandedOn.ToString('yyyy-MM-dd')); grandfathered" }
    }
    return [pscustomobject]@{ Eligible = $true; Why = '' }
}

function New-MSSurfaceMeasurement {
    <#
        .SYNOPSIS
        Measures one exit destination in the store's own counting rule and returns a conforming
        record: value, unit, date, surface, method.

        The shipped checker refuses a path that is not an index, by design, so this is the
        instrument the destination-measurement step names. A hand count nobody can reproduce
        fails the evidence bar the same way an unattributed number does.
    #>
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][datetime]$AsOf)

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $text = [System.IO.File]::ReadAllText($resolved)
    return [pscustomobject]@{
        date    = $AsOf.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        value   = (Measure-MIPCharacters -Text $text)
        unit    = $script:SizeAxisUnit
        surface = $resolved
        method  = 'Measure-MemorySurface.ps1 (UTF-8 decoded, CRLF and lone CR normalized to LF, length in UTF-16 code units)'
    }
}

function Format-MSSurfaceMeasurement {
    param([Parameter(Mandatory = $true)]$Measurement)

    return "$($Measurement.date) | $($Measurement.value) | $($Measurement.unit) | $($Measurement.surface) | $($Measurement.method)"
}

function Test-MSSurfaceMeasurement {
    <#
        .SYNOPSIS
        Whether a measurement record carries all four fields the step requires plus its method.

        A measurement with no unit, no date or no surface could never say "this destination is
        filling up", which is the only thing the step exists to say.
    #>
    param([Parameter(Mandatory = $true)][string]$Record)

    $fields = @($Record -split '\|' | ForEach-Object { $_.Trim() })
    $problems = [System.Collections.Generic.List[string]]::new()
    if ($fields.Count -lt 5) {
        $problems.Add("expected 5 pipe-separated fields (date | value | unit | surface | method); found $($fields.Count)")
        return [pscustomobject]@{ Conforming = $false; Problems = @($problems) }
    }
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($fields[0], 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        $problems.Add("date must be yyyy-MM-dd; found '$($fields[0])'")
    }
    $value = 0
    if (-not [int]::TryParse($fields[1], [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value) -or $value -lt 0) {
        $problems.Add("value must be a whole number of $script:SizeAxisUnit; found '$($fields[1])'")
    }
    if ($fields[2] -cne $script:SizeAxisUnit) {
        $problems.Add("unit must be '$script:SizeAxisUnit' - the store's own counting rule; found '$($fields[2])'")
    }
    if ([string]::IsNullOrWhiteSpace($fields[3])) { $problems.Add('surface must name the file measured') }
    if ([string]::IsNullOrWhiteSpace(($fields[4..($fields.Count - 1)] -join ' | '))) { $problems.Add('method must state how the measurement reproduces') }
    return [pscustomobject]@{ Conforming = ($problems.Count -eq 0); Problems = @($problems) }
}
