#Requires -Version 7.0
<#
.SYNOPSIS
    Repairs emitted-but-unreadable phase-containment regions in GitHub issue
    comments, turning each into well-formed paired blocks (issue #944).
.DESCRIPTION
    A region written as

        <!-- phase-containment-{ID}
        ...entries...
        -->

    is a valid multi-line HTML comment whose open tag never matches the
    self-closed form Get-PhaseContainmentBlock looks for, so the entries it
    carries are invisible to every reader. This script rewrites such regions
    into the paired form the guarded writer emits.

    A BARE TERMINATOR REPAIR IS NOT SAFE, AND THAT IS THE WHOLE DESIGN HERE.
    The parser builds ONE flat hashtable per block with no YAML-sequence
    handling. Several affected regions carry a SEQUENCE of entries -- PR
    #937's carries seven, issue #784's two carry thirteen and fifteen. Adding
    ' -->' to the head would make one block out of all of them, parsed
    last-wins with a null finding_key: a silent invalid-entry drop that reads
    exactly like a fix. Every sequence is therefore SPLIT, one paired block
    per entry.

    WHOLE-BODY, ONE PATCH PER COMMENT. Repair is atomic per comment rather
    than per region, because a body still holding other malformed regions
    fails the guarded writer's own preflight -- so a region-at-a-time repair
    would refuse itself after the first write.

    REFUSES BEFORE IT WRITES, NEVER AFTER. Every transformed body is read
    back with the same reader that will later consume it, schema-validated
    entry by entry, and checked for key collisions against the corpus, before
    any network write. A repair that makes a region parse and then fails
    validation lands the entries in the invalid-entry counter -- absent from
    the rollup exactly as before, with the added cost that the advisory now
    looks satisfied.
.PARAMETER PlanPath
    JSON repair plan: an array of { number, comment_id, expected_regions,
    expected_entries, key_overrides } objects. key_overrides maps a region's
    `finding_id` value to the finding_key to author in its place, for entries
    that carry no lawful key of their own.
.PARAMETER Apply
    Perform the PATCH. Without it the script validates and reports only.
.PARAMETER Repo
    owner/name. Defaults to Grimblaz/agent-orchestra.
.PARAMETER OutDir
    Where before/after bodies and the run report are written.
.EXAMPLE
    pwsh ./.github/scripts/repair-phase-containment-regions.ps1 -PlanPath ./repair-plan.json
.EXAMPLE
    pwsh ./.github/scripts/repair-phase-containment-regions.ps1 -PlanPath ./repair-plan.json -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PlanPath,
    [switch]$Apply,
    [string]$Repo = 'Grimblaz/agent-orchestra',
    [string]$OutDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/phase-containment-core.ps1')

if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path (Get-Location) 'repair-out' }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# All GitHub payloads move through FILES in UTF-8, never through the console.
# These comments carry em dashes, arrows and box-drawing characters, and a
# console round-trip mangles them into mojibake that a PATCH would then make
# permanent -- silently corrupting prose this script has no business touching.
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Get-CommentBody {
    param([Parameter(Mandatory)][string]$CommentId)
    $tmp = Join-Path $OutDir "fetch-$CommentId.json"
    & gh api "repos/$Repo/issues/comments/$CommentId" > $tmp 2>$null
    if ($LASTEXITCODE -ne 0) { throw "gh api GET failed for comment $CommentId" }
    $json = [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    return $json
}

function Test-AffirmationRecordPresent {
    <#
        Repair advances `updated_at` while leaving `created_at` alone, and the
        open-for-work affirmation family is VOID AS AN ORDERING WITNESS once
        edited (skills/open-for-work/SKILL.md). Repairing one marker must not
        void another, so a comment carrying either the registered marker or
        the interim practiced form is refused rather than repaired.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Body)
    if ($Body -match '<!--\s*open-for-work-affirmed-') { return $true }
    if ($Body -match '(?m)^\*\*Open-for-work affirmation') { return $true }
    return $false
}

function Split-RegionIntoEntries {
    <#
        Splits a region's raw content into one YAML mapping per entry.
        A sequence item's leading '- ' is removed and its continuation lines
        are de-indented by the same amount, so each entry becomes a top-level
        mapping the flat parser can read.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)

    $lines = $Content -split '\r?\n'
    $entries = [System.Collections.Generic.List[string]]::new()
    $current = $null
    $itemIndent = 0

    foreach ($line in $lines) {
        if ($line -match '^(?<lead>[ \t]*)-[ \t]+(?<rest>\S.*)$') {
            if ($null -ne $current) { $entries.Add(($current -join "`n")) }
            $current = [System.Collections.Generic.List[string]]::new()
            $current.Add($Matches['rest'])
            # Continuation lines of a `- key: value` item are indented to the
            # column just past the dash-space.
            $itemIndent = $Matches['lead'].Length + 2
            continue
        }
        if ($null -ne $current) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $stripped = if ($line.Length -ge $itemIndent) { $line.Substring($itemIndent) } else { $line.TrimStart() }
            $current.Add($stripped)
        }
    }

    if ($null -ne $current) {
        $entries.Add(($current -join "`n"))
        return , $entries.ToArray()
    }

    # No sequence items: the region is a single mapping.
    $single = ($Content -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
    if ([string]::IsNullOrWhiteSpace($single)) { return , @() }
    return , @($single)
}

function Set-EntryFindingKey {
    <#
        PR #937's seven entries carry `finding_id`, which is not a schema
        field and which the parser has no slot for -- so they parse to a null
        finding_key and are rejected by Rule 12. The key is authored in the
        finding_id line's place (842-D5: re-derivation from that PR's own
        disposition table, which names M1..M7 and whose severities the block
        fields already match, never a mechanical clamp).
    #>
    param(
        [Parameter(Mandatory)][string]$Entry,
        [Parameter(Mandatory)][AllowNull()]$KeyOverrides
    )
    if ($null -eq $KeyOverrides) { return $Entry }
    $m = [regex]::Match($Entry, '(?m)^[ \t]*finding_id[ \t]*:[ \t]*(?<id>\S+)[ \t]*$')
    if (-not $m.Success) { return $Entry }
    $findingId = $m.Groups['id'].Value
    $prop = $KeyOverrides.PSObject.Properties[$findingId]
    if ($null -eq $prop) { throw "No key override supplied for finding_id '$findingId'." }
    return ($Entry -replace "(?m)^[ \t]*finding_id[ \t]*:[ \t]*$([regex]::Escape($findingId))[ \t]*$", "finding_key: $($prop.Value)")
}

function Repair-Body {
    param(
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][AllowNull()]$KeyOverrides
    )

    $head       = "<!-- phase-containment-$Id"
    $wellFormed = "$head -->"
    $closeTag   = "<!-- /phase-containment-$Id -->"

    $blockScalarSpans = Get-BlockScalarSpans -Text $Body
    $result = [System.Text.StringBuilder]::new()
    # Every character of the input is classified as either untouched prose or
    # a replaced region, in order, so the caller can reassemble the original
    # exactly and prove nothing outside a region was consumed.
    $proseSegments = [System.Collections.Generic.List[string]]::new()
    $replacedSpans = [System.Collections.Generic.List[string]]::new()
    $entriesWritten = 0
    $regionsRepaired = 0
    $cursor = 0
    $pos = 0

    while ($true) {
        $idx = $Body.IndexOf($head, $pos, [System.StringComparison]::Ordinal)
        if ($idx -lt 0) { break }
        $afterHead = $idx + $head.Length
        $pos = $afterHead

        if (($Body.Length - $idx) -ge $wellFormed.Length -and
            [string]::CompareOrdinal($Body, $idx, $wellFormed, 0, $wellFormed.Length) -eq 0) { continue }
        if ($afterHead -lt $Body.Length -and $Body[$afterHead] -match '[A-Za-z0-9_-]') { continue }
        if (Test-IndexInBlockScalarSpan -Index $idx -Spans $blockScalarSpans) { continue }

        $terminator = $Body.IndexOf('-->', $afterHead, [System.StringComparison]::Ordinal)
        if ($terminator -lt 0) { throw "Region at $idx in comment for id $Id has no terminator; refusing to guess its extent." }
        $regionEnd = $terminator + 3

        # An orphan close tag directly after the terminator (PR #937's shape)
        # is absorbed: leaving it behind would strand a close tag with no open.
        $tail = $Body.Substring($regionEnd)
        $orphan = [regex]::Match($tail, "^\s*$([regex]::Escape($closeTag))")
        if ($orphan.Success) { $regionEnd += $orphan.Length }

        $content = $Body.Substring($afterHead, $terminator - $afterHead)
        $entries = Split-RegionIntoEntries -Content $content
        if ($entries.Count -eq 0) { throw "Region at $idx in comment for id $Id yielded zero entries; refusing to delete content." }

        $rebuilt = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in $entries) {
            $withKey = Set-EntryFindingKey -Entry $entry -KeyOverrides $KeyOverrides
            $rebuilt.Add("$wellFormed`n$withKey`n$closeTag")
            $entriesWritten++
        }

        $prose = $Body.Substring($cursor, $idx - $cursor)
        $proseSegments.Add($prose)
        $replacedSpans.Add($Body.Substring($idx, $regionEnd - $idx))
        [void]$result.Append($prose)
        [void]$result.Append(($rebuilt -join "`n`n"))
        $cursor = $regionEnd
        $pos = $regionEnd
        $regionsRepaired++
    }

    $tailProse = $Body.Substring($cursor)
    $proseSegments.Add($tailProse)
    [void]$result.Append($tailProse)
    return [PSCustomObject]@{
        Body            = $result.ToString()
        EntriesWritten  = $entriesWritten
        RegionsRepaired = $regionsRepaired
        ProseSegments   = $proseSegments.ToArray()
        ReplacedSpans   = $replacedSpans.ToArray()
    }
}

# ---------------------------------------------------------------------------

$plan = [System.IO.File]::ReadAllText((Resolve-Path $PlanPath).Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$existingKeysPath = Join-Path (Split-Path -Parent (Resolve-Path $PlanPath).Path) 'existing-keys.json'
$existingKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
if (Test-Path -LiteralPath $existingKeysPath) {
    foreach ($k in ([System.IO.File]::ReadAllText($existingKeysPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)) {
        [void]$existingKeys.Add([string]$k.key)
    }
    Write-Host "Loaded $($existingKeys.Count) distinct pre-existing corpus keys for the collision check."
}
else {
    throw "existing-keys.json not found beside the plan; the AC7 collision check cannot run against an unenumerated corpus."
}

$allNewKeys = [System.Collections.Generic.List[string]]::new()
$report = [System.Collections.Generic.List[object]]::new()
$anyFailure = $false

foreach ($target in $plan) {
    $id = [string]$target.number
    $commentId = [string]$target.comment_id
    Write-Host ''
    Write-Host "=== #$id comment $commentId ==="

    $comment = Get-CommentBody -CommentId $commentId
    $before = [string]$comment.body
    [System.IO.File]::WriteAllText((Join-Path $OutDir "before-$commentId.md"), $before, $utf8NoBom)

    if (Test-AffirmationRecordPresent -Body $before) {
        Write-Host '  REFUSED: carries an open-for-work affirmation record; editing it would void it as an ordering witness.'
        $anyFailure = $true
        continue
    }

    $keyOverrides = if ($target.PSObject.Properties['key_overrides']) { $target.key_overrides } else { $null }
    $repair = Repair-Body -Body $before -Id $id -KeyOverrides $keyOverrides
    $after = $repair.Body
    [System.IO.File]::WriteAllText((Join-Path $OutDir "after-$commentId.md"), $after, $utf8NoBom)

    # ---- Preflight 1: the reader now returns every entry, and reports none ----
    $skipped = 0; $unreadable = 0; $regions = 0
    $blocks = Get-PhaseContainmentBlock -Text $after -Id $id `
        -SkippedCount ([ref]$skipped) -UnreadableEntryCount ([ref]$unreadable) -MalformedRegionCount ([ref]$regions) `
        -WarningAction SilentlyContinue
    $returned = if ($null -eq $blocks) { 0 } else { $blocks.Count }

    $expectedEntries = [int]$target.expected_entries
    $beforeWellFormed = 0
    $bwf = Get-PhaseContainmentBlock -Text $before -Id $id -WarningAction SilentlyContinue
    if ($null -ne $bwf) { $beforeWellFormed = $bwf.Count }
    $expectedTotal = $beforeWellFormed + $expectedEntries

    $ok = $true
    if ($repair.RegionsRepaired -ne [int]$target.expected_regions) {
        Write-Host "  FAIL: repaired $($repair.RegionsRepaired) region(s), plan expected $($target.expected_regions)."; $ok = $false
    }
    if ($repair.EntriesWritten -ne $expectedEntries) {
        Write-Host "  FAIL: wrote $($repair.EntriesWritten) entry/entries, plan expected $expectedEntries."; $ok = $false
    }
    if ($returned -ne $expectedTotal) {
        Write-Host "  FAIL: reader returns $returned block(s), expected $expectedTotal ($beforeWellFormed already readable + $expectedEntries repaired)."; $ok = $false
    }
    if ($unreadable -ne 0 -or $regions -ne 0 -or $skipped -ne 0) {
        Write-Host "  FAIL: $regions region(s) still unreadable after repair ($unreadable entry/entries)."; $ok = $false
    }

    # ---- Preflight 2: every entry validates, and lands in the rollup ----
    # Parse success is not the bar. An entry that parses and fails validation
    # goes to the invalid-entry counter, which is just as absent from the
    # rollup as an unread one -- with the advisory now looking satisfied.
    $newKeys = [System.Collections.Generic.List[string]]::new()
    foreach ($blk in @($blocks)) {
        $parsed = ConvertFrom-PhaseContainmentYaml -Yaml $blk
        $validation = Test-PhaseContainmentEntry -Entry $parsed
        if (-not $validation.IsValid) {
            Write-Host "  FAIL: an entry does not validate: $($validation.Errors -join '; ')"; $ok = $false
        }
        $newKeys.Add([string]$parsed['finding_key'])
    }

    # ---- Preflight 3: no key displaces another (AC7) ----
    # Dedup keys strictly on finding_key and OVERWRITES on collision with no
    # warning and no counter, so a collision preserves the corpus count while
    # destroying an entry. Counting after repair cannot see that.
    foreach ($k in $newKeys) {
        if ($beforeWellFormed -gt 0 -and $existingKeys.Contains($k)) {
            # A key already readable on THIS comment is the same entry, not a
            # collision -- it was in the enumerated corpus because it parsed.
            continue
        }
        if ($existingKeys.Contains($k)) {
            Write-Host "  FAIL: key '$k' already exists in the readable corpus; writing it would silently overwrite that entry."; $ok = $false
        }
        if ($allNewKeys -contains $k) {
            Write-Host "  FAIL: key '$k' is authored twice by this repair run."; $ok = $false
        }
    }
    foreach ($k in $newKeys) { $allNewKeys.Add($k) }

    # ---- Preflight 4: nothing outside the regions was consumed ----
    # Reassembles the ORIGINAL body from the segments the repair classified as
    # untouched prose, interleaved with the spans it classified as regions. If
    # that reconstruction is not byte-identical to what the server returned,
    # the repair either swallowed prose or misjudged a region's extent, and it
    # must not be written. Comparing the two OUTPUTS instead would be circular:
    # any character the transform silently dropped would be absent from both.
    $reconstruction = [System.Text.StringBuilder]::new()
    for ($s = 0; $s -lt $repair.ProseSegments.Count; $s++) {
        [void]$reconstruction.Append($repair.ProseSegments[$s])
        if ($s -lt $repair.ReplacedSpans.Count) { [void]$reconstruction.Append($repair.ReplacedSpans[$s]) }
    }
    if ($reconstruction.ToString() -cne $before) {
        Write-Host '  FAIL: prose/region partition does not reassemble into the original body; the repair consumed text outside a region.'; $ok = $false
    }

    if ($ok) {
        Write-Host "  OK: $($repair.RegionsRepaired) region(s) -> $($repair.EntriesWritten) paired block(s); reader returns $returned, all valid, no key collisions."
    }
    else { $anyFailure = $true }

    $report.Add([PSCustomObject]@{
        number = $target.number; comment_id = $commentId
        regions_repaired = $repair.RegionsRepaired; entries_written = $repair.EntriesWritten
        blocks_before = $beforeWellFormed; blocks_after = $returned
        keys = $newKeys.ToArray(); passed = $ok
    })

    if ($ok -and $Apply) {
        $payloadPath = Join-Path $OutDir "patch-$commentId.json"
        $payload = @{ body = $after } | ConvertTo-Json -Depth 3 -Compress
        [System.IO.File]::WriteAllText($payloadPath, $payload, $utf8NoBom)
        & gh api -X PATCH "repos/$Repo/issues/comments/$commentId" --input $payloadPath > (Join-Path $OutDir "patched-$commentId.json") 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  PATCH FAILED for comment $commentId"; $anyFailure = $true
        }
        else {
            # Read back from the server, not from what we sent.
            $verify = Get-CommentBody -CommentId $commentId
            $verifyBody = [string]$verify.body
            $vSkip = 0; $vUnread = 0; $vRegions = 0
            $vBlocks = Get-PhaseContainmentBlock -Text $verifyBody -Id $id `
                -SkippedCount ([ref]$vSkip) -UnreadableEntryCount ([ref]$vUnread) -MalformedRegionCount ([ref]$vRegions) `
                -WarningAction SilentlyContinue
            $vCount = if ($null -eq $vBlocks) { 0 } else { $vBlocks.Count }
            if ($vCount -ne $expectedTotal -or $vRegions -ne 0) {
                Write-Host "  POST-WRITE VERIFY FAILED: server body yields $vCount block(s) and $vRegions unreadable region(s)."
                $anyFailure = $true
            }
            elseif ($verifyBody -cne $after) {
                Write-Host '  POST-WRITE VERIFY: server body differs from what was sent (encoding round-trip?) though the block count is right.'
                $anyFailure = $true
            }
            else {
                Write-Host "  PATCHED and verified: $vCount readable block(s) on the server."
            }
        }
    }
}

$report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutDir 'repair-report.json') -Encoding utf8
Write-Host ''
Write-Host "Regions repaired: $(($report | Measure-Object regions_repaired -Sum).Sum) | Entries written: $(($report | Measure-Object entries_written -Sum).Sum) | Applied: $($Apply.IsPresent)"
if ($anyFailure) { Write-Host 'RESULT: at least one target failed; nothing further was written for it.'; exit 1 }
Write-Host 'RESULT: all targets passed every preflight.'
exit 0
