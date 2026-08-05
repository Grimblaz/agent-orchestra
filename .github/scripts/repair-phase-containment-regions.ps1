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
    # PR #1006 review, M17: a PowerShell redirection decodes native stdout via
    # [Console]::OutputEncoding before re-encoding, which on a non-UTF-8
    # console mojibakes exactly the em dashes this file's header names as at
    # risk — and a mojibake body would then pass every preflight and be
    # PATCHed permanently, against a contract of "REFUSES BEFORE IT WRITES,
    # NEVER AFTER". Pinned here rather than assumed from the host that
    # happened to run the first repair.
    $priorEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = $utf8NoBom
        & gh api "repos/$Repo/issues/comments/$CommentId" > $tmp 2>$null
        if ($LASTEXITCODE -ne 0) { throw "gh api GET failed for comment $CommentId" }
    }
    finally {
        [Console]::OutputEncoding = $priorEncoding
    }
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
        A sequence item's leading dash is removed and its continuation lines
        are de-indented to match, so each entry becomes a top-level mapping the
        flat parser can read.

        THREE SILENT-DISCARD SHAPES WERE FIXED HERE (PR #1006 review, M12).
        Each of them lost content that schema validation could not see,
        because the fields they dropped are not required ones:

          (a) EVERY LINE BEFORE THE FIRST SEQUENCE ITEM WAS DROPPED. The append
              branch was gated on having seen a bullet, so a region leading
              with `seed:` or `appended_at:` lost both. `appended_at` is the
              rolling-window dedup recency key, so dropping it changes which
              duplicate wins. Leading lines are now collected and, if they
              carry any field, emitted as their own entry rather than binned.
          (b) THE DE-INDENT GUARDED ON LENGTH, NOT INDENTATION. `Substring($n)`
              on a line merely long enough chopped two characters off any
              under-indented continuation (`severity` -> `everity`). It now
              removes only whitespace that is actually there.
          (c) A BULLET QUOTED INSIDE A BLOCK SCALAR STARTED A NEW ITEM. A
              `rationale: |` scalar listing a decoy entry displaced the real
              one entirely. Block-scalar content is now masked before the scan,
              the same way the reader and the entry counter mask it.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)

    # (c) Mask block-scalar CONTENT so a quoted bullet is string data. The mask
    # preserves length and newline positions, so it indexes $Content exactly
    # and the emitted text is always taken from the ORIGINAL, never the mask.
    $spans = Get-BlockScalarSpans -Text $Content
    $masked = $Content
    if ($spans.Count -gt 0) {
        $sb = [System.Text.StringBuilder]::new($Content)
        foreach ($span in $spans) {
            for ($i = $span.Start; $i -lt $span.End -and $i -lt $sb.Length; $i++) {
                if ($sb[$i] -ne "`n" -and $sb[$i] -ne "`r") { $sb[$i] = ' ' }
            }
        }
        $masked = $sb.ToString()
    }

    $lines = $Content -split '\r?\n'
    $maskedLines = $masked -split '\r?\n'
    $entries = [System.Collections.Generic.List[string]]::new()
    $current = $null
    $leading = [System.Collections.Generic.List[string]]::new()
    $itemIndent = 0

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $maskedLine = if ($i -lt $maskedLines.Count) { $maskedLines[$i] } else { $line }

        # Bullet detection reads the MASKED line; the text kept is the original.
        if ($maskedLine -match '^(?<lead>[ \t]*)-[ \t]+(?<rest>\S.*)$') {
            if ($null -ne $current) { $entries.Add(($current -join "`n")) }
            $current = [System.Collections.Generic.List[string]]::new()
            $bulletMatch = [regex]::Match($line, '^(?<lead>[ \t]*)-[ \t]+')
            $itemIndent = if ($bulletMatch.Success) { $bulletMatch.Length } else { $Matches['lead'].Length + 2 }
            $current.Add($line.Substring([Math]::Min($itemIndent, $line.Length)))
            continue
        }

        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        if ($null -eq $current) {
            # (a) Content before the first bullet is kept, not binned.
            $leading.Add($line)
            continue
        }

        # (b) Remove only whitespace that is actually present.
        $actualIndent = [regex]::Match($line, '^[ \t]*').Length
        $current.Add($line.Substring([Math]::Min($itemIndent, $actualIndent)))
    }

    if ($null -ne $current) {
        $entries.Add(($current -join "`n"))
        # A leading run beside a sequence is its own mapping, and a caller that
        # expected N entries will see N+1 and fail preflight 1 loudly -- which
        # is the point. Silence here is what let (a) through.
        if ($leading.Count -gt 0 -and ($leading -join "`n") -match '(?m)^[ \t]*[A-Za-z_][A-Za-z0-9_.-]*[ \t]*:') {
            $entries.Insert(0, ($leading -join "`n"))
        }
        return , $entries.ToArray()
    }

    # No sequence items: the region is a single mapping.
    $single = ($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
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

        # THE TERMINATOR SEARCH SKIPS BLOCK SCALARS (PR #1006 review, M9). An
        # earlier revision took the first terminator after the head, and
        # $blockScalarSpans was consulted only for the head-index test above.
        # A region whose `disposition_rationale: |` scalar quoted a literal
        # terminator was therefore truncated mid-scalar: the rationale spilled
        # outside the block, a close tag was injected mid-sentence, an orphan
        # terminator was left behind, and the field parsed as empty — with all
        # four preflights and the post-write verify reporting success. Silent
        # permanent corruption of a live comment under a green check is this
        # work class's signature failure, so the region's extent is taken from
        # the first terminator that is real structure.
        $terminator = -1
        $searchAt = $afterHead
        while ($true) {
            $candidate = $Body.IndexOf('-->', $searchAt, [System.StringComparison]::Ordinal)
            if ($candidate -lt 0) { break }
            if (-not (Test-IndexInBlockScalarSpan -Index $candidate -Spans $blockScalarSpans)) {
                $terminator = $candidate
                break
            }
            $searchAt = $candidate + 3
        }
        if ($terminator -lt 0) { throw "Region at $idx in comment for id $Id has no terminator outside a block scalar; refusing to guess its extent." }
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

$allNewKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
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
    $beforeKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $bwf = Get-PhaseContainmentBlock -Text $before -Id $id -WarningAction SilentlyContinue
    if ($null -ne $bwf) {
        $beforeWellFormed = $bwf.Count
        foreach ($b in $bwf) {
            $bp = ConvertFrom-PhaseContainmentYaml -Yaml $b
            if ($null -ne $bp['finding_key']) { [void]$beforeKeys.Add([string]$bp['finding_key']) }
        }
    }
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
    # PR #1006 review, M22: `@($null)` is a ONE-element array containing $null,
    # and the parser rejects it under the file's `$ErrorActionPreference =
    # 'Stop'` — terminating the whole run, so no report was written and the
    # RESULT line never printed, even though earlier targets may already have
    # been PATCHed. Preflight 1 has already recorded the failure; this target
    # should report and the run should continue.
    $blockList = if ($null -eq $blocks) { @() } else { @($blocks) }
    foreach ($blk in $blockList) {
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
        if ($beforeKeys.Contains($k)) {
            # A key already readable on THIS comment is the same entry, not a
            # collision -- it was in the enumerated corpus because it parsed.
            #
            # PR #1006 review, M4: this used to read `$beforeWellFormed -gt 0`,
            # a COUNT of blocks readable on this comment, which waived EVERY
            # collision against the whole corpus the moment the comment carried
            # one readable block — including a collision with a completely
            # different comment. The rationale sentence above said membership;
            # the predicate said "at least one". It is membership now.
            continue
        }
        if ($existingKeys.Contains($k)) {
            Write-Host "  FAIL: key '$k' already exists in the readable corpus; writing it would silently overwrite that entry."; $ok = $false
        }
        # PR #1006 review, M13/M32: $allNewKeys was appended to only AFTER this
        # loop, so two entries sharing a finding_id inside ONE comment both
        # received the same authored key and neither check saw it — dedup then
        # keeps one and drops the other silently. Comparison is ordinal on both
        # halves; `-contains` is case-insensitive and disagreed with the
        # ordinal corpus HashSet about what "the same key" means.
        if ($allNewKeys.Contains($k)) {
            Write-Host "  FAIL: key '$k' is authored twice by this repair run."; $ok = $false
        }
        [void]$allNewKeys.Add($k)
    }

    # ---- Preflight 4: the prose survives INTO THE BODY THAT GETS WRITTEN ----
    #
    # THIS CHECK USED TO BE A TAUTOLOGY (PR #1006 review, M3). It reassembled
    # the original from ProseSegments interleaved with ReplacedSpans — both
    # slices of $before recorded under `cursor := regionEnd`, so their
    # concatenation is $before BY CONSTRUCTION. It never inspected $after, the
    # string actually PATCHed. Mutation-proved: with the transform altered to
    # drop every prose segment from its output, the check still passed while
    # the prose was gone from the written body. Its own comment argued it
    # avoided circularity; it was circular the other way, comparing the input
    # to a partition of the input.
    #
    # Both halves now run, and the second is the one with teeth:
    #   (a) the partition still must reassemble into $before — that catches a
    #       misjudged region EXTENT, which $after alone cannot show;
    #   (b) every prose segment must appear in $after, in order, which is what
    #       "nothing outside the regions was consumed" actually claims.
    $reconstruction = [System.Text.StringBuilder]::new()
    for ($s = 0; $s -lt $repair.ProseSegments.Count; $s++) {
        [void]$reconstruction.Append($repair.ProseSegments[$s])
        if ($s -lt $repair.ReplacedSpans.Count) { [void]$reconstruction.Append($repair.ReplacedSpans[$s]) }
    }
    if ($reconstruction.ToString() -cne $before) {
        Write-Host '  FAIL: prose/region partition does not reassemble into the original body; the repair misjudged a region extent.'; $ok = $false
    }

    $cursorInAfter = 0
    foreach ($segment in $repair.ProseSegments) {
        if ($segment.Length -eq 0) { continue }
        $found = $after.IndexOf($segment, $cursorInAfter, [System.StringComparison]::Ordinal)
        if ($found -lt 0) {
            $preview = $segment.Trim()
            if ($preview.Length -gt 60) { $preview = $preview.Substring(0, 60) + '...' }
            Write-Host "  FAIL: a prose segment is missing from the body that would be written: '$preview'"; $ok = $false
            break
        }
        $cursorInAfter = $found + $segment.Length
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
