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
      EVERY FILE IN ANY skills/*/references/ DIRECTORY HAS A MANIFEST ROW (the reverse direction).

    Deliberately NOT a manifest-consistency check. A check that reads the manifest and asserts the
    manifest agrees with itself is green forever and never notices a lesson never promoted, a
    trigger deleted, or a roster truncated. Almost every assertion below names an artifact OUTSIDE
    the manifest and compares against it - a skill description, a body section, an agent body, a
    directory listing.

    THE MANIFEST IS ALSO THE SUBJECT (PR #1055 review, findings M1-M4/M9-M15). An earlier revision
    took every population and threshold from the manifest, so a one-token manifest edit - a zeroed
    floor, an emptied loader array, a `promoted` flipped to `pending`, an exhibit row deleted -
    left the whole suite green while the property this file exists to guarantee was false. Four
    defences now stand against that (the fourth added by PR #1061's review, which found that three
    were not enough):

      1. Every threshold the manifest supplies is itself floored here (a floor of zero is drift,
         not a disabled check), and every declared collection must be non-empty - with ONE stated
         exception, added by parent amendment A4.3 and named here rather than left for a reader to
         discover: `loading_surfaces` may legitimately be empty, because a tree in which no agent
         body mandates any receiving skill has no layer-4 reach to declare. What stops that being
         an escape is not a floor but defence 4 below.
      2. The counts that matter - the roster size and each chunk's promoted share - are passed in
         by the CALLER from a different artifact, never read from the manifest.
      3. The reverse scan's population is the tree (`skills/*/references/`), not the manifest's own
         list of receiving skills, so de-manifesting an exhibit cannot also de-scope the directory
         it sits in.
      4. THIS READER OWNS THE MANDATE MARKER. It is the string the whole consumer-type derivation
         keys off, and while the manifest supplied it there was a two-token escape: point it away
         from every real load and the derived set empties, every lens home reads main-session-only,
         and an emptied `loading_surfaces` then audits clean. Measured before this defence existed:
         43 drift findings to 0, suite still green. Requiring the marker to be merely FINDABLE does
         not close it - any real string in any agent body ("Read-Only Mode") is findable and derives
         zero loads - which is why the marker joins the roster states, the verdicts and the phase
         vocabulary as core-owned, with a manifest that disagrees reported as drift. Found by two
         prosecution passes; the findability fix was falsified by defense in one pass.

    What it deliberately does NOT reach, stated so nobody reads silence as coverage:

      - The roster's other side. The store is outside this repository and absent from every CI
        runner, so the caller-supplied roster count is the pinned anchor a standing check can hold.
        Whether the roster still matches the live store is a dated observation recorded at delivery.
      - Working-tree versus installed-plugin-cache divergence. The cache is user-local, absent
        from CI, and divergence is the normal state of any in-flight branch. That class is guarded
        by the version bump, not here.
      - Whether a lens's prose is any GOOD. The lens-body floor measures substance, not quality.
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

# Phrases that turn a mandated load into a permission. A load line carrying one of these is not
# unconditional however faithfully it quotes the skill path - the defect `pin_by_substring_is_not_a_pin`
# describes, applied to the layer this manifest calls "unconditional".
$script:LPLoadNegators = @(
    'optional', 'only when', 'only if', 'if it seems', 'if relevant', 'when relevant',
    'may load', 'can load', 'consider loading', 'as needed', 'where appropriate', 'at your discretion'
)

$script:LPDeclaredVerdicts = @('clean', 'cite', 'conflict')

# The phases a lens may declare it fires in, fixed HERE and not read from the manifest, for the same
# reason the roster states are (parent #1045 amendment A4.6). This field was called a declared enum
# by the design and had no assertion behind it anywhere, which is how the shipped rows diverged from
# the design's own list for a whole chunk and its review without anything noticing. The three words
# chunk 1 shipped govern - `plan` already agrees with the phase vocabulary in
# skills/calibration-pipeline/schemas/phase-containment.schema.json, and `completion` matches the
# receiving skill's own section name - so the declaration was corrected to them rather than 19 rows
# being rewritten against no validator.
$script:LPDeclaredFiresIn = @(
    'completion', 'plan', 'review', 'implementation', 'test-authoring',
    'tooling', 'compaction', 'design', 'release'
)

# Parent #1045 amendment A4.5. A promoted `conflict` was drift outright, while the contradiction
# procedure describes a state that has to be recordable: a shipped sentence the promoted lesson
# itself falsified, corrected in the same change. Every writable value failed - `conflict` red,
# an invented value red as out-of-vocabulary, `clean` forbidden by the procedure - and the cheap
# resolution was to widen the enum and delete the fixture, which removes a guard while looking like
# a passing build. So the model gains a companion instead: a contradiction CARRYING its resolution
# ships, a contradiction WITHOUT one stays red.
$script:LPResolutionFloor = 40

# The roster's three states, fixed HERE rather than taken from the manifest (parent #1045
# amendment A2.1). Reading the set from the artifact under audit is the manifest-authority defect
# one level up: only `promoted` gets meaningful handling, so adding a fourth string to BOTH an
# entry and `declared_states` - a typo, or an invented `half-done` - lets that entry bypass every
# promotion check while the declared-state assertion stays green. Raised by the #1055 external
# review (Codex P2).
$script:LPRosterStates = @('promoted', 'recall-loss', 'pending')

# The mandate marker, fixed HERE and not taken from the manifest - the fourth item in the same
# family as the roster states, the verdicts and the phase vocabulary above, and for exactly the
# same reason. PR #1061's review found the escape twice. The first fix required the manifest's
# marker to be FINDABLE in an agent body, and defense falsified that inside one pass: findability
# is not the property that matters. Any real string occurring in any agent body - "Read-Only Mode",
# "Core Principles" - satisfies findability while deriving ZERO mandated loads, so an emptied
# loading_surfaces audits clean again and the 43-finding escape reopens unchanged.
# The property that matters is that the derivation reads the SAME marker the layer-4 assertions do,
# and the only way the audited artifact cannot move that is for the reader to own it.
$script:LPMandateMarker = 'Mandated load, unconditional'

# The three remaining thresholds, for the same reason and closing the same shape one member wider
# (PR #1061 judge finding J1). Flooring them at >= 1 stopped a value of ZERO disabling a check, but
# not a value of ONE: setting all three to 1 audited the delivered tree clean, and the pointer-lens
# guard - the single mechanism between a promotion and the disguised demotion this whole umbrella
# exists to prevent - was silenced by a one-number manifest edit. Falsifier 2 of the brief predicts
# exactly that. The reader owns the numbers; a manifest that disagrees is drift.
$script:LPLensBodyFloor = 300
$script:LPSpecificityMinLength = 24
$script:LPSpecificityMinContentWords = 3

function Get-LPField {
    <#
        Reads a property that may be absent. Under StrictMode a bare `$o.x` on a ConvertFrom-Json
        object THROWS, which reports a crash where a finding belongs and - because the live audit
        runs in the suite's BeforeAll - takes every other assertion down with it. One hand-edited
        manifest row must produce one named drift detail, not a PropertyNotFoundException.
    #>
    param([Parameter(Mandatory)][AllowNull()]$Object, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -isnot [psobject]) { return $Default }
    # Enumerated one property at a time rather than as `.Properties.Name`. Member enumeration over
    # an EMPTY property collection throws under StrictMode 3.0 ("The property 'Name' cannot be found
    # on this object"), and an object with no properties became a lawful shape here the moment A4.3
    # allowed `loading_surfaces` to be empty - every home main-session-only. The guard against a
    # missing property was itself throwing on the emptiest object it could be handed.
    $names = @($Object.PSObject.Properties | ForEach-Object { $_.Name })
    if ($names -cnotcontains $Name) { return $Default }
    $v = $Object.$Name
    if ($null -eq $v) { return $Default }
    return $v
}

function Get-LPSkillDescription {
    <#
        Returns the `description:` scalar from a markdown file's YAML frontmatter, split into the
        part a reader is told to USE the skill for and the DO NOT USE FOR: exclusion clause.

        The split is load-bearing: a trigger condition relocated into the exclusion clause is
        present to a naive substring search and reads to a consumer as a reason NOT to load.

        Only a TOP-LEVEL, SINGLE-LINE scalar is accepted, and that constraint is enforced rather
        than assumed. An earlier revision matched `^\s*description:` anywhere in the frontmatter,
        so a nested `meta:`/`  description:` key won over the real one; and it silently accepted a
        block-scalar indicator (`>-`, `|`) as the value. Both now return a typed reason so the red
        names the right artifact.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $lines = @(Get-Content -LiteralPath $Path -Encoding utf8)
    if ($lines.Count -eq 0 -or $lines[0].Trim() -cne '---') { return $null }

    $end = -1
    for ($i = 1; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -ceq '---') { $end = $i; break } }
    if ($end -lt 0) { return $null }

    $raw = $null
    for ($i = 1; $i -lt $end; $i++) {
        # Top-level only: no leading whitespace. A nested key is a different key.
        if ($lines[$i] -cmatch '^description:\s*(.*)$') { $raw = $Matches[1]; break }
    }
    if ($null -eq $raw) { return $null }

    $value = $raw.Trim()
    if ($value -cmatch '^[>|][-+]?\d*$' -or $value -ceq '') {
        return [PSCustomObject]@{ Full = ''; UseClause = ''; Exclusion = ''; Unsupported = 'the description is a block or folded scalar; this audit reads only a single-line top-level scalar' }
    }
    if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
        $value = $value.Substring(1, $value.Length - 2) -replace '\\"', '"'
    }
    elseif ($value.StartsWith('"')) {
        return [PSCustomObject]@{ Full = ''; UseClause = ''; Exclusion = ''; Unsupported = 'the description opens a quoted scalar that does not close on the same line; this audit reads only a single-line top-level scalar' }
    }
    elseif ($value.Length -ge 2 -and $value.StartsWith("'") -and $value.EndsWith("'")) {
        $value = $value.Substring(1, $value.Length - 2) -replace "''", "'"
    }

    $marker = 'DO NOT USE FOR:'
    $idx = $value.IndexOf($marker, [System.StringComparison]::Ordinal)
    if ($idx -ge 0) {
        return [PSCustomObject]@{ Full = $value; UseClause = $value.Substring(0, $idx); Exclusion = $value.Substring($idx); Unsupported = $null }
    }
    return [PSCustomObject]@{ Full = $value; UseClause = $value; Exclusion = ''; Unsupported = $null }
}

function Get-LPFenceMask {
    <#
        Per-line flag: is this line inside a fenced code block? Markdown fences open and close on
        ``` or ~~~ at the start of a line (allowing up to three leading spaces), and a fence closes
        only on the same character it opened with.
    #>
    param([Parameter()][AllowNull()][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)
    $Lines = @($Lines)
    if ($Lines.Count -eq 0) { return , (New-Object 'bool[]' 0) }
    $mask = New-Object 'bool[]' $Lines.Count
    $fenceChar = $null
    $fenceLen = 0
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -cmatch '^ {0,3}(`{3,}|~{3,})') {
            $tok = $Matches[1]
            $ch = $tok[0]
            if ($null -eq $fenceChar) {
                $fenceChar = $ch; $fenceLen = $tok.Length
                $mask[$i] = $true
                continue
            }
            elseif ($ch -ceq $fenceChar -and $tok.Length -ge $fenceLen) {
                $mask[$i] = $true
                $fenceChar = $null; $fenceLen = 0
                continue
            }
        }
        $mask[$i] = ($null -ne $fenceChar)
    }
    return , $mask
}

function Get-LPSection {
    <#
        Returns the body of the section a heading owns: from the heading line to the next heading
        of the SAME OR HIGHER level. Returns $null when the heading is absent, which is what makes
        an anchor rename distinguishable from a text deletion.

        FENCE-AWARE, and that is not cosmetic (PR #1055 review, finding M8). An earlier revision
        treated any `#`-prefixed line as a heading. A shell comment inside a fenced block therefore
        ended the section early - blinding the forward-citation guard to everything after it - and,
        worse in the other direction, a lens deleted from the tree with only a copy left inside a
        fenced "illustrative example" satisfied every assertion, which is exactly the disguised
        demotion this file exists to forbid.

        Returns an object carrying the section text, the text with fenced lines blanked, and the
        section's line span, so callers can ask where inside it a match landed.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Anchor
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    if ([string]::IsNullOrWhiteSpace($Anchor)) { return $null }
    $lines = @(Get-Content -LiteralPath $Path -Encoding utf8)
    if ($lines.Count -eq 0) { return $null }
    $wanted = $Anchor.Trim()
    if ($wanted -cnotmatch '^(#+)\s') { return $null }
    $level = $Matches[1].Length

    $mask = Get-LPFenceMask -Lines $lines

    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if (-not $mask[$i] -and $lines[$i].TrimEnd() -ceq $wanted) { $start = $i; break }
    }
    if ($start -lt 0) { return $null }

    $stop = $lines.Count
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        if (-not $mask[$i] -and $lines[$i] -cmatch '^(#+)\s' -and $Matches[1].Length -le $level) { $stop = $i; break }
    }

    $span = $lines[$start..($stop - 1)]
    $unfenced = for ($i = $start; $i -lt $stop; $i++) { if ($mask[$i]) { '' } else { $lines[$i] } }
    $bodyLines = if ($span.Count -gt 1) { $span[1..($span.Count - 1)] } else { @() }

    return [PSCustomObject]@{
        Text         = ($span -join "`n")
        UnfencedText = (@($unfenced) -join "`n")
        BodyText     = (@($bodyLines) -join "`n")
        Lines        = @($span)
        StartLine    = $start + 1
    }
}

function Test-LPContains {
    <#
        Ordinal containment that tolerates a source line break inside the needle. `Get-LPSection`
        joins with LF and a manifest string cannot express one, so a trigger phrase that happens to
        wrap in the source could never match however correct it was.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Haystack, [Parameter(Mandatory)][AllowEmptyString()][string]$Needle)
    if ([string]::IsNullOrEmpty($Needle)) { return $false }
    if ($Haystack.IndexOf($Needle, [System.StringComparison]::Ordinal) -ge 0) { return $true }
    $flat = [regex]::Replace($Haystack, '\s+', ' ')
    $needleFlat = [regex]::Replace($Needle, '\s+', ' ')
    return ($flat.IndexOf($needleFlat, [System.StringComparison]::Ordinal) -ge 0)
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

function Test-LPMandateIsUnconditional {
    <#
        Does the line that names the skill actually MANDATE the load, or merely permit it?

        A substring assertion cannot tell "load X before writing any claim" from "you may load X
        before writing any claim" - the manifest string survives both. That is the finding
        `pin_by_substring_is_not_a_pin` describes, reproduced inside the layer whose whole name is
        "unconditional" (PR #1055 review, finding M4).

        Two conditions, both on the line carrying the skill path: it must carry the manifest's
        declared mandate marker, and it must carry no permission phrasing.
    #>
    param(
        [Parameter()][AllowNull()][AllowEmptyCollection()][AllowEmptyString()][string[]]$SectionLines,
        [Parameter(Mandatory)][string]$SkillPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$MandateMarker
    )

    $carrier = @(@($SectionLines) | Where-Object { $_ -and $_.IndexOf($SkillPath, [System.StringComparison]::Ordinal) -ge 0 })
    if ($carrier.Count -eq 0) { return , @("no line in that section names '$SkillPath'") }

    $problems = @()
    $anyMandating = $false
    foreach ($line in $carrier) {
        # A negator preceded by "not"/"never" is a STRENGTHENING, not a permission: "load it, not
        # only when validating" mandates harder than the bare imperative. Strip those first, or the
        # check reads the negation of a negation as the thing it negates.
        $lower = [regex]::Replace($line.ToLowerInvariant(), '\b(?:not|never)\s+(?:only|optional|merely|just|solely)\b', '')
        $hasMarker = $line.IndexOf($MandateMarker, [System.StringComparison]::Ordinal) -ge 0
        $negators = @($script:LPLoadNegators | Where-Object { $lower.Contains($_) })
        if ($hasMarker -and $negators.Count -eq 0) { $anyMandating = $true; break }
        if (-not $hasMarker) { $problems += "the line naming '$SkillPath' does not carry the mandate marker '$MandateMarker'" }
        if ($negators.Count -gt 0) { $problems += "the line naming '$SkillPath' reads as permission, not a mandate (found: $($negators -join ', '))" }
    }
    if ($anyMandating) { return , @() }
    return , @($problems | Select-Object -Unique)
}

function Get-LPMandatedSkillSet {
    <#
        The set of skills that some agent body actually mandates a load of, DERIVED FROM THE TREE.

        Parent #1045 amendment A4.3. The design states reachability per consumer type and scopes the
        layer-4 mandated load to lenses whose consumers are SUBAGENTS; the check chunk 1 shipped
        required a loader of every skill home unconditionally, which is stricter than the design and
        leaves two receiving skills with no executing agent body at all only two moves: re-home away
        from the phase they name, or add a mandated load to a body that does not do the work - which
        the drift text elsewhere in this file calls booking reach without providing it.

        DERIVED, never declared. The first proposal had the manifest carry the consumer type, and
        all three review lenses independently found the same two defects: it asserts nothing the
        check does not already require of every entry, and it hands the audited artifact control of
        its own audit.

        Reads the MANDATE-MARKER-BEARING load set, not a bare name search: an agent body can name a
        skill path illustratively - an example adapter path, a cross-reference - and a name grep
        would read that as a consumer. The marker is what distinguishes a load this file is willing
        to call unconditional.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][AllowEmptyString()][string]$MandateMarker
    )

    $set = @{}
    $problems = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($MandateMarker)) {
        return [PSCustomObject]@{ Skills = $set; Problems = @('no mandate_marker declared, so no mandated load can be recognised at all') }
    }
    $agentDir = Join-Path $RepoRoot 'agents'
    if (-not (Test-Path -LiteralPath $agentDir -PathType Container)) {
        # An absent population is not "nothing to derive" - it is the derivation losing its only
        # input. Silence here reads every lens home as main-session-only (PR #1061 review, F5).
        return [PSCustomObject]@{ Skills = $set; Problems = @("no 'agents' directory at '$RepoRoot', so the consumer-type derivation has no population and would read every lens home as main-session-only") }
    }

    # BOTH shapes. `*.agent.md` are the shared bodies; `agents/*.md` are the Claude-native shells,
    # which CLAUDE.md documents as first-class and which can carry a mandate of their own (F5).
    $markerSeen = $false
    foreach ($f in @(Get-ChildItem -LiteralPath $agentDir -File -Filter '*.md')) {
        $lines = @(Get-Content -LiteralPath $f.FullName -Encoding utf8)
        # FENCE-AWARE, like every other reader in this file. A mandate quoted inside a fenced
        # example is an illustration, not a load - and reading it as one produced a home with NO
        # writable green state, since layer 4 matches against unfenced text (F3).
        $mask = Get-LPFenceMask -Lines $lines
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($mask[$i]) { continue }
            if ($lines[$i].IndexOf($MandateMarker, [System.StringComparison]::Ordinal) -lt 0) { continue }
            $markerSeen = $true
            # A negator makes it a permission, not a mandate - the same test the layer-4 assertions
            # apply. Read over the same window as the path search below, so the two agree.
            $window = $lines[$i]
            for ($j = $i + 1; $j -lt [Math]::Min($i + 3, $lines.Count); $j++) {
                if ($mask[$j] -or $lines[$j].Trim() -ceq '') { break }
                $window += "`n" + $lines[$j]
            }
            $lower = [regex]::Replace($window.ToLowerInvariant(), '\b(?:not|never)\s+(?:only|optional|merely|just|solely)\b', '')
            if (@($script:LPLoadNegators | Where-Object { $lower.Contains($_) }).Count -gt 0) { continue }
            # Windowed, because a markdown list-continuation splits the marker from the path it
            # mandates and a single-line search reads that as no mandate at all (F4).
            foreach ($mm in [regex]::Matches($window, 'skills/[A-Za-z0-9._-]+/SKILL\.md')) {
                if (-not $set.ContainsKey($mm.Value)) { $set[$mm.Value] = @() }
                $rel = 'agents/' + $f.Name
                if ($set[$mm.Value] -cnotcontains $rel) { $set[$mm.Value] = @($set[$mm.Value]) + $rel }
            }
        }
    }

    # THE MARKER MUST BE FINDABLE, not merely non-blank (F1, the one high finding of PR #1061's
    # review). `mandate_marker` is a manifest field, and the whole unconditional-load layer keys off
    # it: point it at a string that appears nowhere and the derived set empties, every home reads
    # main-session-only, and an emptied `loading_surfaces` then audits clean. Reproduced live -
    # two tokens took the audit from 43 findings to none. Non-blankness was never the property that
    # mattered; reaching the tree is.
    if (-not $markerSeen) {
        $problems.Add("manifest declares mandate_marker '$MandateMarker', which appears in no agent body - a marker that reaches nothing derives an empty consumer-type set and reads every lens home as main-session-only")
    }
    return [PSCustomObject]@{ Skills = $set; Problems = @($problems) }
}

function Get-LessonPromotionAudit {
    <#
        Audits one manifest against the live tree it describes.

        Returns HasDrift plus DriftDetails, one human-readable string per escape found. Every
        detail names the entry or surface it belongs to, so a red is actionable without opening
        the suite.

    .PARAMETER ExpectedRosterCount
        The roster size, supplied by the CALLER from an artifact other than the manifest. Omitted,
        the audit falls back to the manifest's own count anchor and says so - an intra-manifest
        comparison cannot catch an entry removed and the count decremented in one edit.

    .PARAMETER ExpectedPromotedByChunk
        Hashtable of chunk number -> expected promoted count, again caller-supplied. Without it,
        relabelling every promoted entry `pending` is invisible: the roster still totals, and each
        surviving row still checks out.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ManifestPath,
        [int]$ExpectedRosterCount = 0,
        [hashtable]$ExpectedPromotedByChunk,
        [string[]]$ReceivingSkillDirs
    )

    $drift = [System.Collections.Generic.List[string]]::new()
    $resolve = { param($rel) Join-Path $RepoRoot ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar) }

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        $drift.Add("manifest not found at '$ManifestPath' - an absent manifest must not read as nothing to check")
        return [PSCustomObject]@{ HasDrift = $true; DriftDetails = @($drift); Entries = @(); PromotedCount = 0; PendingCount = 0 }
    }

    try { $m = Get-Content -LiteralPath $ManifestPath -Raw -Encoding utf8 | ConvertFrom-Json }
    catch {
        $drift.Add("manifest did not parse as JSON: $($_.Exception.Message)")
        return [PSCustomObject]@{ HasDrift = $true; DriftDetails = @($drift); Entries = @(); PromotedCount = 0; PendingCount = 0 }
    }

    # --- Shape. A well-formed JSON document of the wrong shape must produce findings, not a crash.
    $entries = @(Get-LPField $m 'entries' @())
    $exhibits = @(Get-LPField $m 'exhibits' @())
    $declared = @(Get-LPField $m 'declared_states' @())
    $snapshot = Get-LPField $m 'roster_snapshot'
    $floor = Get-LPField $m 'specificity_floor'
    $lensFloor = Get-LPField $m 'lens_body_floor'
    $loadingSurfaces = Get-LPField $m 'loading_surfaces'
    $pins = @(Get-LPField $m 'in_file_pins' @())

    foreach ($req in @('entries', 'declared_states', 'roster_snapshot', 'specificity_floor', 'lens_body_floor', 'loading_surfaces', 'in_file_pins', 'exhibits', 'schema_version')) {
        if ($null -eq (Get-LPField $m $req)) { $drift.Add("manifest carries no '$req'; a manifest missing a top-level key must read as drift, not as nothing to check") }
    }
    $schemaVersion = [int](Get-LPField $m 'schema_version' 0)
    if ($schemaVersion -lt 1) { $drift.Add("manifest declares schema_version '$schemaVersion'; a version this reader does not know how to read is drift") }
    # The declared set is validated against the fixed three, not merely used. Otherwise a state the
    # manifest invents is a state every promotion check skips.
    if ($declared.Count -lt 1) { $drift.Add('manifest declares no states, so every entry would be in an undeclared state') }
    foreach ($s in $declared) {
        if ($script:LPRosterStates -cnotcontains [string]$s) {
            $drift.Add("manifest declares state '$s', which is not one of $($script:LPRosterStates -join ', ') - an invented state is one every promotion check skips")
        }
    }
    foreach ($s in $script:LPRosterStates) {
        if ($declared -cnotcontains $s) { $drift.Add("manifest does not declare the state '$s', which the roster's state model requires") }
    }

    $minLen = [int](Get-LPField $floor 'min_length' 0)
    $useMinLen = $script:LPSpecificityMinLength; $useMinWords = $script:LPSpecificityMinContentWords; $useLensFloor = $script:LPLensBodyFloor
    $minWords = [int](Get-LPField $floor 'min_content_words' 0)
    $minLensBody = [int](Get-LPField $lensFloor 'min_chars' 0)
    $mandateMarker = [string](Get-LPField $m 'mandate_marker' '')

    # --- Every threshold the manifest supplies is itself floored. A floor of zero is a DISABLED
    #     check, and disabling a check is the cheapest way to silence a red.
    # J1: the reader owns these numbers. A floor is only a floor while the artifact under audit
    # cannot lower it, and >= 1 admitted the whole useful range of evasions.
    foreach ($f in @(
            @{ Name = 'specificity_floor.min_length'; Got = $minLen; Want = $script:LPSpecificityMinLength },
            @{ Name = 'specificity_floor.min_content_words'; Got = $minWords; Want = $script:LPSpecificityMinContentWords },
            @{ Name = 'lens_body_floor.min_chars'; Got = $minLensBody; Want = $script:LPLensBodyFloor })) {
        if ([int]$f.Got -ne [int]$f.Want) {
            $drift.Add("manifest declares $($f.Name) as $($f.Got); this reader owns that threshold and uses $($f.Want). A floor the audited artifact can lower is not a floor - lowering all three to 1 audits a gutted lens clean.")
        }
    }
    if ([string]::IsNullOrWhiteSpace($mandateMarker)) { $drift.Add('manifest declares no mandate_marker, so a mandated load cannot be told from a permission') }
    if ($pins.Count -lt 1) { $drift.Add('manifest declares no in_file_pins, so no amended surface is required to carry its authoritative-source pin') }
    if ($entries.Count -lt 1) { $drift.Add('manifest carries no roster entries; a guard over an empty roster passes vacuously') }

    # --- The count anchor. Prefer the caller's number: two numbers in one file cannot catch an
    #     entry removed and the count decremented in the same edit.
    $anchorCount = [int](Get-LPField $snapshot 'count' 0)
    if ($ExpectedRosterCount -gt 0) {
        if ($entries.Count -ne $ExpectedRosterCount) { $drift.Add("the caller expects a roster of $ExpectedRosterCount entries, the manifest carries $($entries.Count)") }
        if ($anchorCount -ne $ExpectedRosterCount) { $drift.Add("the caller expects a roster of $ExpectedRosterCount entries, the manifest's own count anchor says $anchorCount") }
    }
    elseif ($entries.Count -ne $anchorCount) {
        $drift.Add("roster count anchor says $anchorCount, the manifest carries $($entries.Count) entries (no caller-supplied expected count; this comparison is intra-manifest and cannot catch a consistent edit)")
    }

    # Derived once, from the tree, before any entry is judged (A4.3). Its own problems are drift:
    # a derivation that lost its population must not read as "no subagent consumers anywhere".
    if ($mandateMarker -cne $script:LPMandateMarker) {
        $drift.Add("manifest declares mandate_marker '$mandateMarker'; this reader owns that vocabulary and uses '$($script:LPMandateMarker)'. A marker the audited artifact can move is a marker that can be pointed away from every real load - which empties the consumer-type derivation and makes an emptied loading_surfaces audit clean.")
    }
    # DERIVED WITH THE READER'S OWN MARKER, never the manifest's.
    $derived = Get-LPMandatedSkillSet -RepoRoot $RepoRoot -MandateMarker $script:LPMandateMarker
    $mandatedSkills = $derived.Skills
    foreach ($p in @($derived.Problems)) { $drift.Add($p) }

    $seen = @{}
    $promotedByChunk = @{}
    foreach ($e in $entries) {
        $name = [string](Get-LPField $e 'lesson' '')
        if ([string]::IsNullOrWhiteSpace($name)) { $drift.Add('an entry carries no lesson name'); continue }
        # Case-SENSITIVE: on a case-sensitive runner two names differing only in case are two
        # different lessons and two different files.
        if ($seen.Keys -ccontains $name) { $drift.Add("lesson '$name' appears more than once in the roster") }
        $seen[$name] = $true

        $state = [string](Get-LPField $e 'state' '')
        if ($declared -cnotcontains $state) {
            $drift.Add("lesson '$name' is in no declared state (found '$state'; declared states are $($declared -join ', '))")
            continue
        }

        $chunk = Get-LPField $e 'chunk'
        $issue = Get-LPField $e 'issue'

        if ($state -ceq 'pending') {
            # Parent amendment A2.1: `pending` carries the chunk sub-issue that owns it and is
            # machine-distinguishable from an entry in no state at all. A bare `pending` row is
            # unowned work no chunk claims.
            if ($null -eq $chunk) { $drift.Add("pending lesson '$name' names no owning chunk") }
            if ($null -eq $issue) { $drift.Add("pending lesson '$name' names no owning sub-issue") }
            continue
        }
        if ($state -ceq 'recall-loss') {
            # Parent's own two-state rule: recall-loss carries a one-line reason. Without it,
            # relabelling a promoted lesson is a silent, unbooked loss.
            $reason = [string](Get-LPField $e 'recall_loss_reason' '')
            if ([string]::IsNullOrWhiteSpace($reason)) { $drift.Add("recall-loss lesson '$name' carries no recall_loss_reason; an unbooked loss is what the lens floor forbids") }
            if ($null -eq $chunk) { $drift.Add("recall-loss lesson '$name' names no owning chunk") }
            continue
        }
        if ($state -cne 'promoted') { continue }

        if ($null -ne $chunk) {
            $k = [string]$chunk
            if (-not $promotedByChunk.ContainsKey($k)) { $promotedByChunk[$k] = 0 }
            $promotedByChunk[$k] = $promotedByChunk[$k] + 1
        }
        else { $drift.Add("promoted lesson '$name' names no owning chunk") }

        # --- Promoted entries carry a home, an anchor, and triggers.
        $kind = [string](Get-LPField $e 'kind' '')
        $homeRel = [string](Get-LPField $e 'home' '')
        $anchor = [string](Get-LPField $e 'anchor' '')
        if ([string]::IsNullOrWhiteSpace($kind)) { $drift.Add("promoted lesson '$name' carries no kind") }

        # A4.6. The field the design calls a declared enum, actually asserted. Without this a value
        # outside the declaration passes unremarked, which is exactly how the shipped vocabulary and
        # the declared one diverged for a whole chunk.
        $firesIn = [string](Get-LPField $e 'fires_in' '')
        if ($script:LPDeclaredFiresIn -cnotcontains $firesIn) {
            $drift.Add("promoted lesson '$name' declares fires_in '$firesIn', which is not one of $($script:LPDeclaredFiresIn -join ', ')")
        }
        if ([string]::IsNullOrWhiteSpace($homeRel)) { $drift.Add("promoted lesson '$name' carries no home"); continue }
        if ([string]::IsNullOrWhiteSpace($anchor)) { $drift.Add("promoted lesson '$name' carries no anchor") }

        # --- The lens floor, read from BOTH directions. The clause below catches an exhibit
        #     wearing a lens's label; this one catches the reverse, which every kind-conditional
        #     assertion is blind to. A roster entry IS a lesson, and exhibit-only promotion states
        #     do not exist - a lesson booked as promoted with kind 'exhibit' has been recorded as
        #     non-firing content while still counting toward the promoted set.
        if ($kind -cne 'lens') {
            $drift.Add("promoted lesson '$name' is recorded with kind '$kind'; a roster entry's only promoted kind is 'lens', because an exhibit-only promotion is accepted recall loss wearing a promotion's label")
        }
        else {
            if ($homeRel -like '*/references/*') {
                $drift.Add("lesson '$name' is recorded as a lens but its home '$homeRel' is a references file, which is not a loading surface")
            }
            elseif ($homeRel -cnotmatch '^skills/[^/]+/SKILL\.md$' -and $homeRel -cnotmatch '^agents/[^/]+\.agent\.md$') {
                $drift.Add("lesson '$name' is recorded as a lens but its home '$homeRel' is not a loading surface (a skill body or an agent body)")
            }
            elseif ($homeRel -clike 'skills/*') {
                # A4.3: the consumer-type limb is DERIVED. A home is main-session-only exactly when
                # no agent body mandates a load of that skill; when one does, the check refuses the
                # main-session-only reading and requires the manifest to record the loader. The
                # relaxation is real but SMALL, and the size is stated because the first draft of
                # this comment claimed five. As of chunk 3 the true number is TWO of nine promoted
                # homes - `agent-memory-compaction`, whose single lens has no executing agent body
                # at all, and `plugin-release-hygiene`, which chunk 3 added and which is loaded by a
                # PostToolUse hook rather than by any agent body. The other seven carry a loader and
                # would pass under the pre-A4.3 rule unchanged. A comment that inflates what removing
                # a guard buys is the wrong kind of justification (PR #1061, F10) - and one that
                # DEFLATES it is the same defect mirrored, which is what this comment did between
                # chunk 3's delivery and its review (#1065 review, M19). Recount when a home is added.
                # It is not a hole: adding a mandated load to that body turns this red until the
                # manifest records it, and a mandate_marker that reaches no agent body is itself
                # drift, so the derivation cannot be emptied from the manifest side.
                $ls = Get-LPField $loadingSurfaces $homeRel
                $mandatingBodies = @(if ($mandatedSkills.ContainsKey($homeRel)) { $mandatedSkills[$homeRel] } else { @() })
                if ($null -eq $ls) {
                    if ($mandatingBodies.Count -gt 0) {
                        $drift.Add("lesson '$name' is a lens in '$homeRel', which the manifest records no unconditional loader for, while the tree carries a mandated load of it from $($mandatingBodies -join ', ') - a home with a subagent consumer is not main-session-only")
                    }
                }
                elseif (@(Get-LPField $ls 'loads_unconditionally_from' @()).Count -lt 1) {
                    $drift.Add("lesson '$name' is a lens in '$homeRel', whose loads_unconditionally_from list is empty - declaring the skill with no loader books layer-4 reach without providing it")
                }
                if (-not @($pins | Where-Object { [string](Get-LPField $_ 'surface' '') -ceq $homeRel })) {
                    $drift.Add("lesson '$name' is a lens in '$homeRel', which carries no in_file_pins row - an editor who hits a red there has no local explanation")
                }
            }
        }

        $homeAbs = & $resolve $homeRel
        if (-not (Test-Path -LiteralPath $homeAbs -PathType Leaf)) {
            $drift.Add("lesson '$name' names home '$homeRel', which does not exist")
            continue
        }
        $lensSection = Get-LPSection -Path $homeAbs -Anchor $anchor
        if ($null -eq $lensSection) {
            $drift.Add("lesson '$name' names anchor '$anchor' in '$homeRel', which that file does not carry")
        }
        elseif ($kind -ceq 'lens') {
            # The pointer lens. "See the promotion manifest" satisfies a naive reachability read
            # while moving the lesson's content nowhere a session reads. A trigger-text assertion
            # alone cannot see it, because the trigger sentence survives inside the gutted section.
            # Measured on the UNFENCED body: a fenced example is not the lesson's core.
            $bodyLen = ([regex]::Replace($lensSection.BodyText, '^ {0,3}(`{3,}|~{3,}).*$', '', 'Multiline')).Trim().Length
            if ($bodyLen -lt $useLensFloor) {
                $drift.Add("lens '$name' has a body of $bodyLen characters under '$anchor', below the lens-body floor of $useLensFloor - a lens that short is a pointer, not the lesson's core")
            }
        }

        $triggers = @(Get-LPField $e 'triggers' @())
        if (@($triggers | Where-Object { [string](Get-LPField $_ 'surface_kind' '') -ceq 'description' }).Count -lt 1) {
            $drift.Add("promoted lesson '$name' carries no description trigger, so no main session is told when it bites")
        }
        if (@($triggers | Where-Object { [string](Get-LPField $_ 'surface_kind' '') -ceq 'body' }).Count -lt 1) {
            $drift.Add("promoted lesson '$name' carries no body trigger")
        }

        foreach ($t in $triggers) {
            $tSurfaceRel = [string](Get-LPField $t 'surface' '')
            $tKind = [string](Get-LPField $t 'surface_kind' '')
            $tText = [string](Get-LPField $t 'text' '')
            $label = "lesson '$name' trigger on '$tSurfaceRel'"

            foreach ($f in (Test-LPSpecificityFloor -Text $tText -MinLength $useMinLen -MinContentWords $useMinWords)) {
                $drift.Add("$label is $f")
            }

            # --- The chain. Validating each clause independently never checks that they describe
            #     ONE walk: a trigger recorded on a skill that does not carry the lens tells a
            #     reader to load the wrong thing, and an anchor pointing at a section this
            #     promotion never wrote certifies a lesson that was never written.
            if ($tSurfaceRel -cne $homeRel) {
                $drift.Add("$label names a surface other than the lesson's home '$homeRel'; a trigger a reader follows must lead to the skill that carries the lens")
            }

            $tAbs = & $resolve $tSurfaceRel
            if (-not (Test-Path -LiteralPath $tAbs -PathType Leaf)) { $drift.Add("$label names a surface that does not exist"); continue }

            if ($tKind -ceq 'description') {
                $desc = Get-LPSkillDescription -Path $tAbs
                if ($null -eq $desc) { $drift.Add("$label is a description trigger but that file carries no parseable top-level description"); continue }
                if ($null -ne $desc.Unsupported) { $drift.Add("$label cannot be checked: $($desc.Unsupported)"); continue }
                if (-not (Test-LPContains -Haystack $desc.UseClause -Needle $tText)) {
                    if (Test-LPContains -Haystack $desc.Exclusion -Needle $tText) {
                        $drift.Add("$label is present only inside the DO NOT USE FOR clause, where it reads as a reason not to load the skill")
                    }
                    else {
                        $drift.Add("$label names condition text absent from that skill's description")
                    }
                }
            }
            elseif ($tKind -ceq 'body') {
                $tAnchor = [string](Get-LPField $t 'anchor' '')
                if ([string]::IsNullOrWhiteSpace($tAnchor)) {
                    $drift.Add("$label is a body trigger scoped to the whole file rather than to a named anchor")
                    continue
                }
                if ($tAnchor -cne $anchor) {
                    $drift.Add("$label names anchor '$tAnchor', which is not the lesson's own anchor '$anchor'")
                    continue
                }
                $section = Get-LPSection -Path $tAbs -Anchor $tAnchor
                if ($null -eq $section) { $drift.Add("$label names anchor '$tAnchor', which that surface does not carry"); continue }
                # Matched against the UNFENCED text: a trigger sentence demoted into a fenced
                # "bad example" block is present to a search and absent to a reader.
                if (-not (Test-LPContains -Haystack $section.UnfencedText -Needle $tText)) {
                    if (Test-LPContains -Haystack $section.Text -Needle $tText) {
                        $drift.Add("$label names text that survives only inside a fenced block, where it reads as an example rather than as guidance")
                    }
                    else {
                        $drift.Add("$label names text absent from the section anchored at '$tAnchor'")
                    }
                }
            }
            else {
                $drift.Add("$label declares surface_kind '$tKind', which is not one of description, body")
            }
        }
    }

    if ($ExpectedPromotedByChunk) {
        foreach ($k in $ExpectedPromotedByChunk.Keys) {
            $want = [int]$ExpectedPromotedByChunk[$k]
            $got = if ($promotedByChunk.ContainsKey([string]$k)) { [int]$promotedByChunk[[string]$k] } else { 0 }
            if ($got -ne $want) {
                $drift.Add("chunk $k is expected to have promoted $want lessons, the manifest records $got - a promoted share cannot be reduced by relabelling its entries")
            }
        }
        # Both directions. Iterating only the caller's keys leaves the quietest escape in this file
        # open: a chunk that promotes N lessons under a key NOBODY DECLARED is counted by nothing,
        # while the roster still totals and every surviving row still checks out. An absent key is
        # not a mismatched one, so the loop above cannot see it - the mutation that removes a chunk
        # key entirely came back green until this clause existed.
        foreach ($k in $promotedByChunk.Keys) {
            if (-not $ExpectedPromotedByChunk.ContainsKey([string]$k)) {
                $drift.Add("the manifest records $($promotedByChunk[$k]) promoted lessons under chunk $k, which the caller's expected-share map does not declare - a chunk with no count anchor is a promoted share nothing counts")
            }
        }
    }

    # --- Layer 4. A skill with no unconditional loader reaches a subagent through nothing at all,
    #     and a loader sentence rewritten into a permission reaches it no better.
    if ($null -ne $loadingSurfaces -and $loadingSurfaces -is [psobject]) {
        foreach ($p in $loadingSurfaces.PSObject.Properties) {
            $skillRel = $p.Name
            $loads = @(Get-LPField $p.Value 'loads_unconditionally_from' @())
            if ($loads.Count -lt 1) {
                $drift.Add("loading surface '$skillRel' declares an empty loads_unconditionally_from list")
                continue
            }
            foreach ($load in $loads) {
                $sRel = [string](Get-LPField $load 'surface' '')
                $sAbs = & $resolve $sRel
                $label = "mandated load of '$skillRel' from '$sRel'"
                if (-not (Test-Path -LiteralPath $sAbs -PathType Leaf)) { $drift.Add("$label names a surface that does not exist"); continue }
                $sAnchor = [string](Get-LPField $load 'anchor' '')
                if ([string]::IsNullOrWhiteSpace($sAnchor)) { $drift.Add("$label is scoped to the whole file rather than to a named anchor"); continue }
                $section = Get-LPSection -Path $sAbs -Anchor $sAnchor
                if ($null -eq $section) { $drift.Add("$label names anchor '$sAnchor', which that surface does not carry"); continue }
                $text = [string](Get-LPField $load 'text' '')
                if (-not (Test-LPContains -Haystack $section.UnfencedText -Needle $text)) {
                    $drift.Add("$label names text absent from the section anchored at '$sAnchor'")
                    continue
                }
                if ($text.IndexOf($skillRel, [System.StringComparison]::Ordinal) -lt 0) {
                    $drift.Add("$label carries text that never names '$skillRel', so it cannot be the load it claims to be")
                    continue
                }
                foreach ($problem in (Test-LPMandateIsUnconditional -SectionLines $section.Lines -SkillPath $skillRel -MandateMarker $mandateMarker)) {
                    $drift.Add("$label is not unconditional: $problem")
                }
            }
        }
    }

    # --- In-file pins. An editor who hits a red needs the local explanation - what authorises the
    #     constraint, and how to tell a migration from a regression - in the file they are editing.
    foreach ($pin in $pins) {
        $pRel = [string](Get-LPField $pin 'surface' '')
        $pAbs = & $resolve $pRel
        $label = "in-file pin on '$pRel'"
        if (-not (Test-Path -LiteralPath $pAbs -PathType Leaf)) { $drift.Add("$label names a surface that does not exist"); continue }

        $scope = [string](Get-LPField $pin 'scope' '')
        $text = $null
        if ($scope -ceq 'section') {
            $sec = Get-LPSection -Path $pAbs -Anchor ([string](Get-LPField $pin 'anchor' ''))
            if ($null -eq $sec) { $drift.Add("$label names anchor '$(Get-LPField $pin 'anchor' '')', which that surface does not carry"); continue }
            $text = $sec.UnfencedText
        }
        elseif ($scope -ceq 'file') {
            # Whole-file scope is a DECLARED choice here, not an omission: the suite is PowerShell
            # and carries no markdown headings to anchor to.
            $text = Get-Content -LiteralPath $pAbs -Raw -Encoding utf8
            if ($null -eq $text) { $drift.Add("$label names a file with no content, so its pins cannot be present"); continue }
        }
        else {
            $drift.Add("$label declares scope '$scope', which is not one of section, file")
            continue
        }

        foreach ($needle in @(Get-LPField $pin 'must_contain' @())) {
            if (-not (Test-LPContains -Haystack $text -Needle ([string]$needle))) {
                $drift.Add("$label is missing its required text '$needle'")
            }
        }
    }

    # --- Exhibits, forward and reverse.
    $exhibitFiles = @($exhibits | ForEach-Object { [string](Get-LPField $_ 'file' '') } | Where-Object { $_ })

    foreach ($x in $exhibits) {
        $xRel = [string](Get-LPField $x 'file' '')
        if ([string]::IsNullOrWhiteSpace($xRel)) { $drift.Add('an exhibit row names no file'); continue }
        $xAbs = & $resolve $xRel
        if (-not (Test-Path -LiteralPath $xAbs -PathType Leaf)) { $drift.Add("exhibit row names '$xRel', which does not exist"); continue }

        $citations = @(Get-LPField $x 'cited_by' @())
        if ($citations.Count -lt 1) {
            $drift.Add("exhibit '$xRel' is cited by nothing - an exhibit no lens reaches is unreachable content")
        }
        $leaf = Split-Path -Leaf $xRel
        foreach ($c in $citations) {
            $cRel = [string](Get-LPField $c 'surface' '')
            $cAbs = & $resolve $cRel
            $label = "exhibit '$xRel' citation from '$cRel'"
            if (-not (Test-Path -LiteralPath $cAbs -PathType Leaf)) { $drift.Add("$label names a surface that does not exist"); continue }
            $sec = Get-LPSection -Path $cAbs -Anchor ([string](Get-LPField $c 'anchor' ''))
            if ($null -eq $sec) { $drift.Add("$label names anchor '$(Get-LPField $c 'anchor' '')', which that surface does not carry"); continue }
            if (-not (Test-LPContains -Haystack $sec.UnfencedText -Needle $leaf)) {
                $drift.Add("$label points at a section that never mentions '$leaf'")
            }
        }

        foreach ($t in @(Get-LPField $x 'triggers' @())) {
            $tSurface = [string](Get-LPField $t 'surface' '')
            $tText = [string](Get-LPField $t 'text' '')
            $label = "exhibit '$xRel' trigger on '$tSurface'"
            foreach ($f in (Test-LPSpecificityFloor -Text $tText -MinLength $useMinLen -MinContentWords $useMinWords)) {
                $drift.Add("$label is $f")
            }
            $tAbs = & $resolve $tSurface
            if (-not (Test-Path -LiteralPath $tAbs -PathType Leaf)) { $drift.Add("$label names a surface that does not exist"); continue }
            $desc = Get-LPSkillDescription -Path $tAbs
            if ($null -eq $desc) { $drift.Add("$label names a file with no parseable top-level description"); continue }
            if ($null -ne $desc.Unsupported) { $drift.Add("$label cannot be checked: $($desc.Unsupported)"); continue }
            if (-not (Test-LPContains -Haystack $desc.UseClause -Needle $tText)) {
                if (Test-LPContains -Haystack $desc.Exclusion -Needle $tText) {
                    $drift.Add("$label is present only inside the DO NOT USE FOR clause, where it reads as a reason not to load the skill")
                }
                else {
                    $drift.Add("$label names condition text absent from that skill's description")
                }
            }
        }
    }

    # --- The reverse scan. Its population is CALLER-SUPPLIED, for the same reason the roster count
    #     is: an earlier revision derived the scanned directories from promoted homes plus exhibit
    #     `gating_skill` values, so deleting an exhibit row also deleted the directory that
    #     deletion would have been detected in - a "nothing was lost" check assembled from a
    #     partition of its own input (PR #1055 review, finding M9).
    #
    #     Not "every skills/*/references/ directory in the repository": this manifest is the
    #     registry for PROMOTED LESSONS, not for the ~30 pre-existing reference files that predate
    #     it and belong to other skills. Claiming those would be a scope expansion asserted rather
    #     than designed. The honest population is the receiving set, pinned by the caller from a
    #     different artifact so the manifest cannot shrink it.
    #
    #     Recursive, because unaccounted content parks one directory deeper than a flat scan reaches.
    # @($null) has a Count of 1, so an omitted parameter would silently look like a supplied
    # population of one blank directory - the fallback would never announce itself.
    #
    # Caller entries are normalized to the separator and trailing-slash form the manifest uses.
    # Without it the containment clause below compares a normalized left side against a raw right
    # side, so `skills\demo-skill` reds as uncovered while the scan below visits that directory
    # perfectly well - and the scan builds its `## Composite References` needle from the same raw
    # string, so one backslash entry breaks TWO checks rather than one (#1065 review, M4).
    $receiving = @(
        $ReceivingSkillDirs |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { ($_ -replace '\\', '/').TrimEnd('/') })

    # Derived ONCE and shared by the fallback and the containment clause below. The first draft
    # carried two byte-identical copies of this expression with nothing pinning them together, so a
    # future edit to what counts as a needed home would have desynchronized the two populations
    # silently (#1065 review, M3 - reported by all five prosecution passes).
    #
    # The outer @() is load-bearing, not decoration: `Select-Object -Unique` returns a SCALAR at
    # exactly one distinct home and $null at zero, and `.Count` on either throws under this file's
    # `Set-StrictMode -Version 3.0`. Unwrapped, this assignment crashed the audit on every
    # small-manifest tree - which is the shape every induced fixture builds (#1065 review, M1).
    # `file` is read alongside `gating_skill` deliberately, and it is the half that cannot be turned
    # off. `gating_skill` is free text no check validates, and for a skill reached ONLY through it -
    # the cross-chunk shape the forward guard below is written for, where an exhibit lands a chunk
    # before its lens - blanking that one field removed the containment requirement and produced
    # zero drift of any kind: not "gating_skill missing", nothing. Demonstrated by mutation against
    # the live tree on `skills/terminal-hygiene`, the one skill currently in that position
    # (#1065 review, M5). `file` is existence-checked further down, so deriving the home from it
    # too means the requirement survives a blanked sibling field.
    $manifestHomes = @(
        @(
            @($entries | Where-Object { [string](Get-LPField $_ 'state' '') -ceq 'promoted' } | ForEach-Object { [string](Get-LPField $_ 'home' '') }) +
            @($exhibits | ForEach-Object { [string](Get-LPField $_ 'gating_skill' '') }) +
            @($exhibits | ForEach-Object { [string](Get-LPField $_ 'file' '') })
        ) | Where-Object { $_ -clike 'skills/*' } | ForEach-Object { ($_ -split '/')[0..1] -join '/' } | Select-Object -Unique)

    # And say so out loud rather than only routing around it: a blank or non-`skills/` gating_skill
    # is a malformed row, not a lawful one. Without this the field could be emptied and the only
    # symptom would be a check quietly covering less than it did yesterday.
    foreach ($x in $exhibits) {
        $gs = [string](Get-LPField $x 'gating_skill' '')
        $xf = [string](Get-LPField $x 'file' '')
        if ([string]::IsNullOrWhiteSpace($gs)) {
            $drift.Add("exhibit '$xf' carries a blank 'gating_skill' - the field gates which skill's references directory is scanned, and nothing else validates it")
        }
        elseif (-not ($gs -clike 'skills/*')) {
            $drift.Add("exhibit '$xf' declares gating_skill '$gs', which is not a 'skills/*' path - the containment derivation reads only 'skills/*' values, so this row gates nothing")
        }
    }

    if ($receiving.Count -lt 1) {
        $receiving = $manifestHomes
        $drift.Add('no caller-supplied receiving-skill set; the reverse scan fell back to a manifest-derived population, which cannot detect a directory removed from the manifest')
    }

    # Containment - the pin's other direction, and the half that was missing. Pinning the set in the
    # caller stops the MANIFEST shrinking the population. Nothing stopped the CALLER's set from
    # failing to cover the manifest, and that omission is silent in the worst way: the loop below
    # simply never visits an uncovered skill, so both its orphan-file scan and its
    # `## Composite References` completeness arm are skipped while the audit reports zero drift.
    # Demonstrated on the chunk-3 delivery (#1051) - the audit returned HasDrift=False both with and
    # without the receiving entry that delivery had to hand-add, so the edit was unenforceable and
    # forgetting it would have looked identical to doing it. This is the same shape as the absent-key
    # escape closed for chunk counts above, pointing in the direction future promotions travel.
    #
    # Guarded on the caller-supplied set alone. The first draft also required `$receiving.Count -ge 1`,
    # which protected nothing - by that point an all-blank set has already been replaced by the
    # manifest-derived fallback, against which containment is satisfied by construction - while being
    # the sole cause of the M1 crash. Removing it was proved behaviour-identical on every case that
    # already worked (#1065 review, M2).
    #
    # Lawful removal direction, since the two registers now constrain each other and nothing else
    # says this: an entry leaves the caller's set only when that skill's `references/` directory is
    # gone from the tree. Dropping it because the manifest no longer names the skill inverts the
    # older and more load-bearing half of the pin - the manifest must not be able to shrink the
    # scanned population (#1065 review, M20).
    if ($ReceivingSkillDirs) {
        foreach ($needed in $manifestHomes) {
            if ($receiving -cnotcontains $needed) {
                $drift.Add("'$needed' is a skill this manifest promotes into or gates an exhibit on, but the caller's receiving-skill set does not cover it - an uncovered skill is one the reverse scan never visits, so its unmanifested references files and its 'Composite References' completeness both go unchecked")
            }
        }
    }

    foreach ($skillRel in $receiving) {
        $refDir = Join-Path (Join-Path $RepoRoot ($skillRel -replace '/', [System.IO.Path]::DirectorySeparatorChar)) 'references'
        if (-not (Test-Path -LiteralPath $refDir -PathType Container)) { continue }

        # A4.4 / parent A3, the deferral arm. Where a receiving skill carries the repository's
        # `## Composite References` convention, THAT section is the citation surface the design named
        # and the check reads it: every file in the directory has to be listed there, so a reader
        # arriving at the skill sees the whole set rather than whichever files a lens happened to
        # cite. Where the convention is absent the manifest-carried registry governs alone, exactly
        # as A3 provides - reading an absent convention would be a check with no population.
        $skillMd = Join-Path (Join-Path $RepoRoot ($skillRel -replace '/', [System.IO.Path]::DirectorySeparatorChar)) 'SKILL.md'
        $composite = Get-LPSection -Path $skillMd -Anchor '## Composite References'

        foreach ($f in @(Get-ChildItem -LiteralPath $refDir -File -Recurse)) {
            $rel = ($skillRel + '/references/' + $f.FullName.Substring($refDir.Length).TrimStart('\', '/')) -replace '\\', '/'
            if ($exhibitFiles -cnotcontains $rel) {
                $drift.Add("'$rel' sits in a receiving references directory with no manifest row")
            }
            if ($null -ne $composite -and -not (Test-LPContains -Haystack $composite.UnfencedText -Needle ($rel -replace "^$([regex]::Escape($skillRel))/", ''))) {
                $drift.Add("'$rel' is not named in '$skillRel/SKILL.md' section 'Composite References', which that skill carries - a skill that adopts the convention lists every file in its references directory there")
            }
        }
    }

    # --- Forward guard: a lens may not cite an exhibit this manifest does not carry. Written for
    #     the cross-chunk case, where exhibits arrive a chunk later and the citation is a dead end
    #     for as long as that chunk is deferred.
    #
    #     Assembled from parts rather than written as one literal: written whole it reads to the
    #     hub-artifact path extractor as a path family in its own right. The leading boundary is
    #     required - without it a segment merely ENDING in "references" (project-references/) matches.
    $refPattern = '(?<![A-Za-z0-9._-])(?:[A-Za-z0-9._-]+/)*' + 'references' + '/' + '[A-Za-z0-9._-]+\.md'
    foreach ($e in @($entries | Where-Object { [string](Get-LPField $_ 'state' '') -ceq 'promoted' -and [string](Get-LPField $_ 'kind' '') -ceq 'lens' })) {
        $homeRel = [string](Get-LPField $e 'home' '')
        if ([string]::IsNullOrWhiteSpace($homeRel)) { continue }
        $homeAbs = & $resolve $homeRel
        if (-not (Test-Path -LiteralPath $homeAbs -PathType Leaf)) { continue }
        $sec = Get-LPSection -Path $homeAbs -Anchor ([string](Get-LPField $e 'anchor' ''))
        if ($null -eq $sec) { continue }
        $homeDir = (Split-Path -Parent $homeRel) -replace '\\', '/'
        foreach ($mm in [regex]::Matches($sec.UnfencedText, $refPattern)) {
            $cited = $mm.Value
            # Resolve against the LENS HOME's directory, then compare full repo-relative paths. A
            # suffix match certifies a link that is dead for the reader of the citing skill
            # whenever any other skill happens to carry a same-named exhibit.
            $resolved = if ($cited -clike 'references/*') { "$homeDir/$cited" } else { $cited }
            if ($exhibitFiles -cnotcontains $resolved) {
                $drift.Add("lens '$(Get-LPField $e 'lesson' '')' cites '$cited' (resolving to '$resolved'), which no manifest exhibit row carries")
            }
        }
    }

    # --- Contradiction verdicts. Asserted here, not only in the suite, so a fixture can exercise
    #     the red state - an assertion with no induced-failure case is a branch that can rot.
    foreach ($e in @($entries | Where-Object { [string](Get-LPField $_ 'state' '') -ceq 'promoted' })) {
        $name = [string](Get-LPField $e 'lesson' '')
        $ca = Get-LPField $e 'checked_against'
        if ($null -eq $ca) { $drift.Add("promoted lesson '$name' records no checked_against verdict"); continue }
        $verdict = [string](Get-LPField $ca 'verdict' '')
        if ($script:LPDeclaredVerdicts -cnotcontains $verdict) {
            $drift.Add("promoted lesson '$name' records verdict '$verdict', which is not one of $($script:LPDeclaredVerdicts -join ', ')")
        }
        if ($verdict -ceq 'conflict') {
            # A4.5: the contradiction is expressible, its resolution is not optional. A `resolution`
            # that is absent, blank, or too short to name what was corrected leaves this red - which
            # is the state the pre-amendment check reached for EVERY conflict, now narrowed to the
            # unresolved one rather than deleted.
            $resolution = [string](Get-LPField $ca 'resolution' '')
            if ([string]::IsNullOrWhiteSpace($resolution)) {
                $drift.Add("promoted lesson '$name' records a 'conflict' verdict with no resolution; a lesson contradicting shipped doctrine ships only when it carries the correction it made, otherwise it routes up")
            }
            elseif ($resolution.Trim().Length -lt $script:LPResolutionFloor) {
                $drift.Add("promoted lesson '$name' records a 'conflict' resolution of $($resolution.Trim().Length) characters, below the floor of $script:LPResolutionFloor - a resolution that does not name the surface corrected is a label, not a resolution")
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string](Get-LPField $ca 'resolution' ''))) {
            $drift.Add("promoted lesson '$name' records a resolution under a '$verdict' verdict; a resolution is what makes a contradiction shippable and means nothing beside any other verdict")
        }
        $surfaces = @(Get-LPField $ca 'surfaces' @())
        if ($surfaces.Count -lt 1) { $drift.Add("promoted lesson '$name' records no searched surfaces for its verdict") }
        foreach ($s in $surfaces) {
            # A surface has to be something a later reader can re-search. An absolute local path is
            # not reproducible by another reviewer or by CI.
            if ([string]$s -cmatch '^[A-Za-z]:[\\/]' -or [string]$s -clike '/*' -or [string]$s -clike '~*') {
                $drift.Add("promoted lesson '$name' records searched surface '$s', which is a machine-local path rather than a repository-relative surface")
            }
        }
        if ([string]::IsNullOrWhiteSpace([string](Get-LPField $ca 'note' ''))) { $drift.Add("promoted lesson '$name' records no note for its verdict") }
    }

    return [PSCustomObject]@{
        HasDrift      = ($drift.Count -gt 0)
        DriftDetails  = @($drift)
        Entries       = $entries
        PromotedCount = @($entries | Where-Object { [string](Get-LPField $_ 'state' '') -ceq 'promoted' }).Count
        PendingCount  = @($entries | Where-Object { [string](Get-LPField $_ 'state' '') -ceq 'pending' }).Count
    }
}
