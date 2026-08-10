#!/usr/bin/env pwsh
<#
.SYNOPSIS
    The audit behind the lesson-promotion manifest: does each promoted lesson actually reach a reader?

.DESCRIPTION
    A maintainer lesson living only in a private memory store fires unconditionally at session
    start. The same lesson moved into a repository file fires only if someone loads the gating
    skill AND reaches the lesson inside it. Promotion can therefore be a silent DEMOTION, and
    with nothing checking it, the demotion books as a success.

    This is the thing that makes that state red instead of invisible. Its central properties:

      A PROMOTED LESSON HAS A LENS IN A SURFACE THAT LOADS, AND A TRIGGER A READER CAN HIT.
      EVERY FILE IN A RECEIVING references/ DIRECTORY HAS A MANIFEST ROW (the reverse direction).

    Deliberately NOT a manifest-consistency check. A check that reads the manifest and asserts the
    manifest agrees with itself is green forever and never notices a lesson never promoted, a
    trigger deleted, or a roster truncated. Every assertion below names an artifact OUTSIDE the
    manifest and compares against it - a skill description, a body section, an agent body, a
    directory listing.

    What it deliberately does NOT reach, stated so nobody reads silence as coverage:

      - The roster's other side. The store is outside this repository and absent from every CI
        runner, so `roster_snapshot.count` is the pinned anchor a standing check can hold. Whether
        the roster still matches the live store is a dated observation recorded at delivery.
      - Working-tree versus installed-plugin-cache divergence. The cache is user-local, absent
        from CI, and divergence is the normal state of any in-flight branch. That class is guarded
        by the version bump, not here.
#>

Set-StrictMode -Version 3.0

# Words that carry no trigger specificity on their own. A condition phrase built only from these
# is present to a text search and absent to a reader.
$script:LPStopWords = @(
    'when', 'this', 'that', 'with', 'from', 'into', 'they', 'them', 'then', 'than', 'have', 'has',
    'been', 'were', 'will', 'your', 'you', 'the', 'and', 'for', 'are', 'use', 'used', 'uses',
    'about', 'after', 'before', 'while', 'which', 'what', 'where', 'their', 'there', 'these',
    'those', 'such', 'also', 'only', 'must', 'make', 'made', 'more', 'most', 'some', 'over',
    'under', 'each', 'both', 'same', 'other', 'being', 'does', 'done', 'its', 'not', 'any'
)

function Get-LPSkillDescription {
    <#
        Returns the `description:` scalar from a markdown file's YAML frontmatter, split into the
        part a reader is told to USE the skill for and the DO NOT USE FOR: exclusion clause.

        The split is load-bearing: a trigger condition relocated into the exclusion clause is
        present to a naive substring search and reads to a consumer as a reason NOT to load.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $lines = @(Get-Content -LiteralPath $Path -Encoding utf8)
    if ($lines.Count -eq 0 -or $lines[0].Trim() -ne '---') { return $null }

    $end = -1
    for ($i = 1; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -eq '---') { $end = $i; break } }
    if ($end -lt 0) { return $null }

    $raw = $null
    for ($i = 1; $i -lt $end; $i++) {
        if ($lines[$i] -match '^\s*description:\s*(.*)$') { $raw = $Matches[1]; break }
    }
    if ($null -eq $raw) { return $null }

    $value = $raw.Trim()
    if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
        $value = $value.Substring(1, $value.Length - 2) -replace '\\"', '"'
    }
    elseif ($value.Length -ge 2 -and $value.StartsWith("'") -and $value.EndsWith("'")) {
        $value = $value.Substring(1, $value.Length - 2) -replace "''", "'"
    }

    $marker = 'DO NOT USE FOR:'
    $idx = $value.IndexOf($marker, [System.StringComparison]::Ordinal)
    if ($idx -ge 0) {
        return [PSCustomObject]@{
            Full      = $value
            UseClause = $value.Substring(0, $idx)
            Exclusion = $value.Substring($idx)
        }
    }
    return [PSCustomObject]@{ Full = $value; UseClause = $value; Exclusion = '' }
}

function Get-LPSection {
    <#
        Returns the body of the section a heading owns: from the heading line to the next heading
        of the SAME OR HIGHER level. Returns $null when the heading is absent, which is what makes
        an anchor rename distinguishable from a text deletion.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Anchor
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $lines = @(Get-Content -LiteralPath $Path -Encoding utf8)
    $wanted = $Anchor.Trim()
    if ($wanted -notmatch '^(#+)\s') { return $null }
    $level = $Matches[1].Length

    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].TrimEnd() -eq $wanted) { $start = $i; break }
    }
    if ($start -lt 0) { return $null }

    $stop = $lines.Count
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^(#+)\s' -and $Matches[1].Length -le $level) { $stop = $i; break }
    }
    return (($lines[$start..($stop - 1)]) -join "`n")
}

function Test-LPSpecificityFloor {
    <#
        Two independently-reported components. Enforcing only one lets a trigger clear the floor
        on length while saying nothing ("when you are working with the thing"), or clear it on
        content words while being too short to locate anything.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][int]$MinLength,
        [Parameter(Mandatory)][int]$MinContentWords
    )

    $failures = @()
    $t = [string]$Text
    if ($t.Trim().Length -lt $MinLength) {
        $failures += "below the specificity floor on length ($($t.Trim().Length) < $MinLength)"
    }
    $words = @([regex]::Matches($t.ToLowerInvariant(), '[a-z][a-z''-]{3,}') | ForEach-Object { $_.Value })
    $content = @($words | Where-Object { $script:LPStopWords -notcontains $_ } | Select-Object -Unique)
    if ($content.Count -lt $MinContentWords) {
        $failures += "below the specificity floor on content words ($($content.Count) < $MinContentWords)"
    }
    return , $failures
}

function Get-LessonPromotionAudit {
    <#
        Audits one manifest against the live tree it describes.

        Returns HasDrift plus DriftDetails, one human-readable string per escape found. Every
        detail names the entry or surface it belongs to, so a red is actionable without opening
        the suite.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ManifestPath
    )

    $drift = [System.Collections.Generic.List[string]]::new()
    $resolve = { param($rel) Join-Path $RepoRoot ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar) }

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        $drift.Add("manifest not found at '$ManifestPath' - an absent manifest must not read as nothing to check")
        return [PSCustomObject]@{ HasDrift = $true; DriftDetails = @($drift); Entries = @(); PromotedCount = 0; PendingCount = 0 }
    }

    try { $m = Get-Content -LiteralPath $ManifestPath -Raw -Encoding utf8 | ConvertFrom-Json }
    catch {
        $drift.Add("manifest did not parse as JSON: $($_.Exception.Message)")
        return [PSCustomObject]@{ HasDrift = $true; DriftDetails = @($drift); Entries = @(); PromotedCount = 0; PendingCount = 0 }
    }

    $entries = @($m.entries)
    $declared = @($m.declared_states)
    $minLen = [int]$m.specificity_floor.min_length
    $minWords = [int]$m.specificity_floor.min_content_words
    $minLensBody = [int]$m.lens_body_floor.min_chars

    # --- The count anchor. Removing a roster entry has to be visible from the repository alone.
    $anchorCount = [int]$m.roster_snapshot.count
    if ($entries.Count -ne $anchorCount) {
        $drift.Add("roster count anchor says $anchorCount, the manifest carries $($entries.Count) entries")
    }

    $seen = @{}
    foreach ($e in $entries) {
        $name = [string]$e.lesson
        if ([string]::IsNullOrWhiteSpace($name)) { $drift.Add('an entry carries no lesson name'); continue }
        if ($seen.ContainsKey($name)) { $drift.Add("lesson '$name' appears more than once in the roster") }
        $seen[$name] = $true

        $state = if ($e.PSObject.Properties.Name -contains 'state') { [string]$e.state } else { '' }
        if ($declared -notcontains $state) {
            $drift.Add("lesson '$name' is in no declared state (found '$state'; declared states are $($declared -join ', '))")
            continue
        }
        if ($state -ne 'promoted') { continue }

        # --- Promoted entries carry a home, an anchor, and triggers.
        foreach ($required in @('kind', 'home', 'anchor')) {
            if (-not ($e.PSObject.Properties.Name -contains $required) -or [string]::IsNullOrWhiteSpace([string]$e.$required)) {
                $drift.Add("promoted lesson '$name' carries no $required")
            }
        }
        if (-not ($e.PSObject.Properties.Name -contains 'home')) { continue }

        $homeRel = [string]$e.home
        $kind = [string]$e.kind

        # --- The lens floor, read from BOTH directions. The clause below catches an exhibit
        #     wearing a lens's label; this one catches the reverse, which every kind-conditional
        #     assertion is blind to. A roster entry IS a lesson, and exhibit-only promotion states
        #     do not exist - a lesson booked as promoted with kind 'exhibit' has been recorded as
        #     non-firing content while still counting toward the promoted set. Exhibits live in the
        #     manifest's own `exhibits` array, never as a roster state.
        if ($kind -ne 'lens') {
            $drift.Add("promoted lesson '$name' is recorded with kind '$kind'; a roster entry's only promoted kind is 'lens', because an exhibit-only promotion is accepted recall loss wearing a promotion's label")
        }

        if ($kind -eq 'lens') {
            if ($homeRel -like '*/references/*') {
                $drift.Add("lesson '$name' is recorded as a lens but its home '$homeRel' is a references file, which is not a loading surface")
            }
            elseif ($homeRel -notmatch '^skills/[^/]+/SKILL\.md$' -and $homeRel -notmatch '^agents/[^/]+\.agent\.md$') {
                $drift.Add("lesson '$name' is recorded as a lens but its home '$homeRel' is not a loading surface (a skill body or an agent body)")
            }
            elseif ($homeRel -match '^skills/' -and -not ($m.loading_surfaces.PSObject.Properties.Name -contains $homeRel)) {
                $drift.Add("lesson '$name' is a lens in '$homeRel', which the manifest records no unconditional loader for")
            }
        }

        $homeAbs = & $resolve $homeRel
        if (-not (Test-Path -LiteralPath $homeAbs)) {
            $drift.Add("lesson '$name' names home '$homeRel', which does not exist")
            continue
        }
        $lensSection = Get-LPSection -Path $homeAbs -Anchor ([string]$e.anchor)
        if ($null -eq $lensSection) {
            $drift.Add("lesson '$name' names anchor '$($e.anchor)' in '$homeRel', which that file does not carry")
        }
        elseif ($kind -eq 'lens' -and $minLensBody -gt 0) {
            # The pointer lens. "See the promotion manifest" satisfies a naive reachability read
            # while moving the lesson's content nowhere a session reads - the disguised demotion
            # the lens floor exists to forbid. A trigger-text assertion alone cannot see it,
            # because the trigger sentence survives inside the gutted section.
            #
            # Stated limit: this measures SUBSTANCE, not quality. A section of 300 characters of
            # prose passes whether or not it carries the lesson's actionable core; what it cannot
            # be is a pointer.
            # A heading with nothing under it splits into one part, not two. Index it directly and
            # StrictMode throws - which would report a crash where a finding belongs, and a lens of
            # exactly nothing is the most extreme member of the class this floor exists to catch.
            $parts = @($lensSection -split "`n", 2)
            $bodyLen = if ($parts.Count -lt 2) { 0 } else { $parts[1].Trim().Length }
            if ($bodyLen -lt $minLensBody) {
                $drift.Add("lens '$name' has a body of $bodyLen characters under '$($e.anchor)', below the lens-body floor of $minLensBody - a lens that short is a pointer, not the lesson's core")
            }
        }

        $triggers = @($e.triggers)
        if (@($triggers | Where-Object { $_.surface_kind -eq 'description' }).Count -lt 1) {
            $drift.Add("promoted lesson '$name' carries no description trigger, so no main session is told when it bites")
        }
        if (@($triggers | Where-Object { $_.surface_kind -in @('body', 'agent-body') }).Count -lt 1) {
            $drift.Add("promoted lesson '$name' carries no body trigger")
        }

        foreach ($t in $triggers) {
            $tSurfaceRel = [string]$t.surface
            $tKind = [string]$t.surface_kind
            $tText = [string]$t.text
            $label = "lesson '$name' trigger on '$tSurfaceRel'"

            foreach ($f in (Test-LPSpecificityFloor -Text $tText -MinLength $minLen -MinContentWords $minWords)) {
                $drift.Add("$label is $f")
            }

            $tAbs = & $resolve $tSurfaceRel
            if (-not (Test-Path -LiteralPath $tAbs)) { $drift.Add("$label names a surface that does not exist"); continue }

            if ($tKind -eq 'description') {
                $desc = Get-LPSkillDescription -Path $tAbs
                if ($null -eq $desc) { $drift.Add("$label is a description trigger but that file carries no parseable description"); continue }
                if ($desc.UseClause.IndexOf($tText, [System.StringComparison]::Ordinal) -lt 0) {
                    if ($desc.Exclusion.IndexOf($tText, [System.StringComparison]::Ordinal) -ge 0) {
                        $drift.Add("$label is present only inside the DO NOT USE FOR clause, where it reads as a reason not to load the skill")
                    }
                    else {
                        $drift.Add("$label names condition text absent from that skill's description")
                    }
                }
            }
            elseif ($tKind -in @('body', 'agent-body')) {
                $tAnchor = if ($t.PSObject.Properties.Name -contains 'anchor') { [string]$t.anchor } else { '' }
                if ([string]::IsNullOrWhiteSpace($tAnchor)) {
                    $drift.Add("$label is a $tKind trigger scoped to the whole file rather than to a named anchor")
                    continue
                }
                $section = Get-LPSection -Path $tAbs -Anchor $tAnchor
                if ($null -eq $section) { $drift.Add("$label names anchor '$tAnchor', which that surface does not carry"); continue }
                if ($section.IndexOf($tText, [System.StringComparison]::Ordinal) -lt 0) {
                    $drift.Add("$label names text absent from the section anchored at '$tAnchor'")
                }
            }
            else {
                $drift.Add("$label declares surface_kind '$tKind', which is not one of description, body, agent-body")
            }
        }
    }

    # --- Layer 4. A skill with no unconditional loader reaches a subagent through nothing at all.
    foreach ($p in $m.loading_surfaces.PSObject.Properties) {
        $skillRel = $p.Name
        foreach ($load in @($p.Value.loads_unconditionally_from)) {
            $sRel = [string]$load.surface
            $sAbs = & $resolve $sRel
            $label = "mandated load of '$skillRel' from '$sRel'"
            if (-not (Test-Path -LiteralPath $sAbs)) { $drift.Add("$label names a surface that does not exist"); continue }
            $sAnchor = [string]$load.anchor
            if ([string]::IsNullOrWhiteSpace($sAnchor)) { $drift.Add("$label is scoped to the whole file rather than to a named anchor"); continue }
            $section = Get-LPSection -Path $sAbs -Anchor $sAnchor
            if ($null -eq $section) { $drift.Add("$label names anchor '$sAnchor', which that surface does not carry"); continue }
            $text = [string]$load.text
            if ($section.IndexOf($text, [System.StringComparison]::Ordinal) -lt 0) {
                $drift.Add("$label names text absent from the section anchored at '$sAnchor'")
            }
            elseif ($text.IndexOf($skillRel, [System.StringComparison]::Ordinal) -lt 0) {
                $drift.Add("$label carries text that never names '$skillRel', so it cannot be the load it claims to be")
            }
        }
    }

    # --- In-file pins. An editor who hits a red needs the local explanation - what authorises the
    #     constraint, and how to tell a migration from a regression - in the file they are editing,
    #     not in a suite they have to go and find. Without this assertion the pins are prose
    #     nothing holds, which is the delivery-demo failure one chunk-1 lesson describes.
    foreach ($pin in @($m.in_file_pins)) {
        $pRel = [string]$pin.surface
        $pAbs = & $resolve $pRel
        $label = "in-file pin on '$pRel'"
        if (-not (Test-Path -LiteralPath $pAbs)) { $drift.Add("$label names a surface that does not exist"); continue }

        $scope = [string]$pin.scope
        $text = $null
        if ($scope -eq 'section') {
            $text = Get-LPSection -Path $pAbs -Anchor ([string]$pin.anchor)
            if ($null -eq $text) { $drift.Add("$label names anchor '$($pin.anchor)', which that surface does not carry"); continue }
        }
        elseif ($scope -eq 'file') {
            # Whole-file scope is a DECLARED choice here, not an omission: the suite is PowerShell
            # and carries no markdown headings to anchor to.
            $text = Get-Content -LiteralPath $pAbs -Raw -Encoding utf8
        }
        else {
            $drift.Add("$label declares scope '$scope', which is not one of section, file")
            continue
        }

        foreach ($needle in @($pin.must_contain)) {
            if ($text.IndexOf([string]$needle, [System.StringComparison]::Ordinal) -lt 0) {
                $drift.Add("$label is missing its required text '$needle'")
            }
        }
    }

    # --- Exhibits, forward and reverse.
    $exhibits = @($m.exhibits)
    $exhibitFiles = @($exhibits | ForEach-Object { [string]$_.file })

    foreach ($x in $exhibits) {
        $xRel = [string]$x.file
        $xAbs = & $resolve $xRel
        if (-not (Test-Path -LiteralPath $xAbs)) { $drift.Add("exhibit row names '$xRel', which does not exist"); continue }

        $citations = @($x.cited_by)
        if ($citations.Count -lt 1) {
            $drift.Add("exhibit '$xRel' is cited by nothing - an exhibit no lens reaches is unreachable content")
        }
        $leaf = Split-Path -Leaf $xRel
        foreach ($c in $citations) {
            $cRel = [string]$c.surface
            $cAbs = & $resolve $cRel
            $label = "exhibit '$xRel' citation from '$cRel'"
            if (-not (Test-Path -LiteralPath $cAbs)) { $drift.Add("$label names a surface that does not exist"); continue }
            $section = Get-LPSection -Path $cAbs -Anchor ([string]$c.anchor)
            if ($null -eq $section) { $drift.Add("$label names anchor '$($c.anchor)', which that surface does not carry"); continue }
            if ($section.IndexOf($leaf, [System.StringComparison]::Ordinal) -lt 0) {
                $drift.Add("$label points at a section that never mentions '$leaf'")
            }
        }

        foreach ($t in @($x.triggers)) {
            $label = "exhibit '$xRel' trigger on '$($t.surface)'"
            foreach ($f in (Test-LPSpecificityFloor -Text ([string]$t.text) -MinLength $minLen -MinContentWords $minWords)) {
                $drift.Add("$label is $f")
            }
            $tAbs = & $resolve ([string]$t.surface)
            if (-not (Test-Path -LiteralPath $tAbs)) { $drift.Add("$label names a surface that does not exist"); continue }
            $desc = Get-LPSkillDescription -Path $tAbs
            if ($null -eq $desc) { $drift.Add("$label names a file with no parseable description"); continue }
            if ($desc.UseClause.IndexOf([string]$t.text, [System.StringComparison]::Ordinal) -lt 0) {
                if ($desc.Exclusion.IndexOf([string]$t.text, [System.StringComparison]::Ordinal) -ge 0) {
                    $drift.Add("$label is present only inside the DO NOT USE FOR clause, where it reads as a reason not to load the skill")
                }
                else {
                    $drift.Add("$label names condition text absent from that skill's description")
                }
            }
        }
    }

    # --- The reverse scan. Without it the manifest only ever grows, and a references file added
    #     beside a promoted lesson is unaccounted content nobody notices.
    $receivingSkills = @(
        @($entries | Where-Object { $_.state -eq 'promoted' } | ForEach-Object { [string]$_.home }) +
        @($exhibits | ForEach-Object { [string]$_.gating_skill })
    ) | Where-Object { $_ -match '^skills/' } | ForEach-Object { Split-Path -Parent ($_ -replace '/', [System.IO.Path]::DirectorySeparatorChar) } | Select-Object -Unique

    foreach ($skillDir in $receivingSkills) {
        $refDir = Join-Path (Join-Path $RepoRoot $skillDir) 'references'
        if (-not (Test-Path -LiteralPath $refDir)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $refDir -File)) {
            $rel = ((Join-Path $skillDir 'references') + [System.IO.Path]::DirectorySeparatorChar + $f.Name) -replace '\\', '/'
            if ($exhibitFiles -notcontains $rel) {
                $drift.Add("'$rel' sits in a receiving references directory with no manifest row")
            }
        }
    }

    # --- Forward guard: a lens may not cite an exhibit this manifest does not carry. Written for
    #     the cross-chunk case, where exhibits arrive a chunk later and the citation is a dead end
    #     for as long as that chunk is deferred.
    foreach ($e in @($entries | Where-Object { $_.state -eq 'promoted' -and $_.kind -eq 'lens' })) {
        $homeAbs = & $resolve ([string]$e.home)
        if (-not (Test-Path -LiteralPath $homeAbs)) { continue }
        $section = Get-LPSection -Path $homeAbs -Anchor ([string]$e.anchor)
        if ($null -eq $section) { continue }
        # Assembled from parts rather than written as one literal. Written whole it reads to the
        # hub-artifact path extractor as a path family in its own right, and the path-inventory
        # drift gate then reports an uncategorized family that is a regex, not an artifact.
        $refPattern = '[A-Za-z0-9._' + [regex]::Escape('/') + '-]*' + 'references' + '/' + '[A-Za-z0-9._-]+\.md'
        foreach ($mm in [regex]::Matches($section, $refPattern)) {
            $cited = $mm.Value
            if (-not @($exhibitFiles | Where-Object { $_.EndsWith($cited, [System.StringComparison]::Ordinal) })) {
                $drift.Add("lens '$($e.lesson)' cites '$cited', which no manifest exhibit row carries")
            }
        }
    }

    return [PSCustomObject]@{
        HasDrift      = ($drift.Count -gt 0)
        DriftDetails  = @($drift)
        Entries       = $entries
        PromotedCount = @($entries | Where-Object { $_.state -eq 'promoted' }).Count
        PendingCount  = @($entries | Where-Object { $_.state -eq 'pending' }).Count
    }
}
