#Requires -Version 7.0

# brief-review-migration-core.ps1
# Issue #951 D5 — one-time corpus correction for the phase-containment ledger's
# falsely judge-attributed plan-surface rows.
#
# SCOPE, AND WHY IT IS A SANCTIONED EXCEPTION RATHER THAN A NEW WRITER.
# skills/plan-authoring/SKILL.md records persist-phase-ledger.ps1 as the only
# documented path into this corpus. That script has no relabel and no withdraw
# mode, and its Add-CommentBlocks only ever appends, so it structurally cannot
# express this correction. Amendment A1(f) decided to amend the doctrine and
# bless this script as the sole sanctioned exception, BOUNDED to the one-time
# correction of the two issues named in $script:BRMPlannedCorrections. It is
# not a general-purpose ledger writer and must not grow into one: it takes no
# arbitrary issue number, and a caller asking for anything outside that table
# is refused.
#
# SECURITY: no ConvertFrom-Yaml / powershell-yaml, matching the file-level
# invariant of every other module that touches these comment bodies.

Set-StrictMode -Version Latest

#region Planned corrections (the bound)

# The complete, closed set of corrections this script is sanctioned to make.
#
# Verdict-grain expectations, not count-grain. Amendment A1(c) recorded that
# D5's self-verification was count-grain and could therefore succeed while both
# issues rendered permanent false gaps forever — the script would report itself
# correct having made the corpus no more readable than it found it. Each row
# below therefore carries the emission verdict the corrected issue must RENDER,
# and the post-write verification re-parses and re-renders to check it.
#
# How each expected verdict is derived (they are forced by the mechanism, not
# chosen):
#   #939 — its own head records that the convergence filter ran and narrowed 37
#          findings to 29. That is a lawful brief-review authorization, so the
#          29 rows relabel and the issue renders clean.
#   #941 — its own head records that the convergence filter was SKIPPED. Under
#          D3 as restated by A1(d) an unfiltered run cannot authorize a count,
#          so its rows are withdrawn rather than relabelled: they are raw
#          prosecution output, and relabelling them would move an ungraded
#          population into the brief-review sub-arm — the same contamination
#          this work removes, one level down. The issue then renders
#          could-not-verify, which is the "unverified" end state AC4 describes
#          and the only intent-coherent one available to it.
$script:BRMPlannedCorrections = @(
    [PSCustomObject]@{
        Issue                = 939
        Action               = 'relabel'
        ExpectedRowCount     = 29
        FilteredCount        = 8
        ExpectedParseStatus  = 'ok'
        ExpectedReason       = 'ok'
        ExpectedSustained    = 29
        ExpectedBlockCount   = 29
        Note                 = 'Corrected by issue #951: this review had three prosecution lenses plus a convergence filter and NO judge stage. The rows below were originally written under `judge_ruling: sustained`, a vocabulary that had no value meaning "a prosecution panel sustained this and no judge reviewed it". They now carry `caught_stage: brief-review` with matching `finding_key` prefixes, authorized by the `brief_dispositions` head above. No finding changed; only the claim about how it was adjudicated.'
    },
    [PSCustomObject]@{
        Issue                = 941
        Action               = 'withdraw'
        ExpectedRowCount     = 27
        FilteredCount        = 0
        ExpectedParseStatus  = 'could-not-verify'
        ExpectedReason       = 'filter-not-run'
        ExpectedSustained    = 0
        ExpectedBlockCount   = 0
        Note                 = 'Withdrawn by issue #951: this review ran three prosecution lenses with the convergence filter SKIPPED, and no judge stage. Its 27 rows were raw, unnarrowed prosecution output written under `judge_ruling: sustained`. They are withdrawn rather than relabelled, because an unfiltered population is not a graded one and moving it under `brief-review` would carry the same contamination into the new sub-arm. The finding IDENTIFIERS the panel raised are listed below for the record, under a head that declares `convergence_filter_ran: false` and therefore authorizes no count at all. Their `disposition` values are NOT preserved and are not claimed to be: the original record carried a judge ruling per finding and no disposition field at all, so there is nothing to carry across. The uniform `incorporate` below is a placeholder required by the head shape, not a statement about what any panel decided.'
    }
)

function Get-BRMPlannedCorrection {
    <#
    .SYNOPSIS
        The sanctioned correction for an issue, or $null when the issue is
        outside this one-time migration's bound.
    #>
    param([Parameter(Mandatory)][int]$Issue)
    foreach ($c in $script:BRMPlannedCorrections) {
        if ($c.Issue -eq $Issue) { return $c }
    }
    return $null
}

#endregion

#region Body transforms (pure — no network, no filesystem)

function Get-BRMJudgeRulingsFindingIds {
    <#
    .SYNOPSIS
        The finding_id values inside a body's `<!-- judge-rulings ... -->`
        block, in document order.
    .DESCRIPTION
        Read from the judge-rulings block specifically, never from the whole
        body: a phase-containment row also carries a finding_key, and a stray
        prose mention of an id must not be promoted into the rewritten head.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Body)
    $ids = [System.Collections.Generic.List[object]]::new()
    # Returned WITHOUT a leading comma. `return ,$array` wraps the array in an
    # outer one-element array; every call site here wraps the result in @(),
    # and @() does not flatten that nesting — the whole id list arrives as a
    # single element whose string form is "N1 N2 N3 …". That produced a head
    # with one finding_id line holding 29 space-joined ids, which parsed
    # cleanly as ONE upheld finding against 29 blocks.
    $headMatch = [regex]::Match($Body, '(?ms)<!--\s*judge-rulings\b.*?-->')
    if (-not $headMatch.Success) { return $ids.ToArray() }
    # Each id is paired with the ruling recorded against it, so the rewritten
    # head can carry what the record actually said rather than a uniform
    # placeholder (#963 review, finding X). An id whose ruling cannot be read
    # is returned with a null ruling and fails loud downstream — the one thing
    # this migration must never do is invent a disposition, since inventing
    # provenance is the defect it exists to remove.
    #
    # Item-28 fix (#963 review), CORRECTED by the post-fix review (finding M1).
    #
    # The original single combined regex required BOTH lines to match as one
    # unit, so a malformed or missing judge_ruling line silently dropped the
    # finding_id too — the id never reached the caller, contradicting this
    # function's own "returned with a null ruling" contract above. That is a
    # real defect and is still fixed here.
    #
    # The FIRST attempt at the fix ran two separate `[regex]::Matches`
    # enumerations and joined them on `.Index`, on the stated premise that
    # "both regexes start matching at the same `^\s*-\s+finding_id` position".
    # That premise is FALSE, and the post-fix panel measured it: the coupled
    # pattern's greedy trailing `\s*$` consumes into the whitespace run
    # BETWEEN entries, so `Matches` resumes its next scan one character past
    # where the id-only pattern starts its next match. The `.Index` keys never
    # collide and every id after the first reads back `Ruling = $null` —
    # which `New-BRMBriefHead` then throws on. Measured: two blank lines
    # between LF entries, or one blank line in a CRLF body, was enough
    # (`N1=sustained N2=NULL N3=NULL`). Do NOT reintroduce an index join and
    # try to correct the arithmetic; any such join stays hostage to that
    # trailing `\s*`.
    #
    # ONE regex, with the judge_ruling half as an OPTIONAL non-capturing
    # group. `Groups[2].Success` distinguishes "ruling read" from "ruling
    # absent or malformed" without a second enumeration to reconcile. Safe
    # against an id borrowing the NEXT entry's ruling because the inner `\s*`
    # cannot cross the `-` list marker that opens the next entry.
    $entryPattern = '(?m)^\s*-\s+finding_id\s*:\s*(\S+)\s*$(?:\s*^\s*judge_ruling\s*:\s*(\S+)\s*$)?'
    foreach ($m in [regex]::Matches($headMatch.Value, $entryPattern)) {
        $ruling = if ($m.Groups[2].Success) { $m.Groups[2].Value } else { $null }
        $ids.Add([PSCustomObject]@{ Id = $m.Groups[1].Value; Ruling = $ruling })
    }
    return $ids.ToArray()
}

function New-BRMBriefHead {
    <#
    .SYNOPSIS
        Renders a conformant brief-review authorizing head.
    .DESCRIPTION
        Shape and required fields are the emission check's, not this script's:
        `brief_dispositions:` with `convergence_filter_ran` over the full value
        domain and a `filtered_count` the brief-review dismiss-rate arm
        consumes. Written here rather than delegated because
        persist-phase-ledger.ps1 has no mode that rewrites an existing head —
        see this file's header for why that is a sanctioned exception.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings,
        [Parameter(Mandatory)][bool]$ConvergenceFilterRan,
        [Parameter(Mandatory)][int]$FilteredCount
    )
    # The ONLY ruling→disposition mapping this migration will make. A
    # judge-rulings `sustained` and a brief `incorporate` both mean "this
    # finding was upheld and is being acted on", so the translation is
    # faithful. `defense-sustained` has NO brief equivalent — the brief surface
    # has no defense pass, which is the whole reason it exists — so it is not
    # mapped and not guessed at.
    # Emitted UNFENCED. A ```yaml fence around the head is cosmetic for the
    # reader — Get-BriefReviewSustainedCountInternal isolates its region from
    # the head to the next fence, so a fence merely bounds it — but it puts a
    # fence pair upstream of every phase-containment block in the comment, and
    # Get-PhaseContainmentBlock strips fences during extraction. That
    # interaction was observed to drop block extraction to zero on a
    # 29-block body, which would silently zero the very BlockCount the
    # verdict guard checks. Not worth the decoration.
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('brief_dispositions:')
    $lines.Add("  convergence_filter_ran: $($ConvergenceFilterRan.ToString().ToLowerInvariant())")
    $lines.Add("  filtered_count: $FilteredCount")
    $lines.Add('  findings:')
    foreach ($f in $Findings) {
        if ($f.Ruling -ne 'sustained') {
            throw "New-BRMBriefHead: finding '$($f.Id)' carries judge_ruling '$($f.Ruling)', which has no faithful brief-review disposition. Refusing to guess — writing a disposition the record does not support is the false provenance this migration exists to remove."
        }
        $lines.Add("    - finding_id: $($f.Id)")
        $lines.Add('      disposition: incorporate')
    }
    return ($lines -join "`n")
}

function Convert-BRMLedgerBody {
    <#
    .SYNOPSIS
        Applies one planned correction to a ledger sibling body. Idempotent.
    .OUTPUTS
        [PSCustomObject] Body [string], Changed [bool], Reason [string].
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body,
        [Parameter(Mandatory)][int]$Issue
    )

    $plan = Get-BRMPlannedCorrection -Issue $Issue
    if ($null -eq $plan) {
        throw "Convert-BRMLedgerBody: issue #$Issue is outside this one-time migration's sanctioned bound. This script corrects only $(($script:BRMPlannedCorrections | ForEach-Object { "#$($_.Issue)" }) -join ' and '); it is not a general-purpose ledger writer."
    }

    $ledgerMarker = "<!-- phase-containment-ledger-$Issue -->"
    if (-not $Body.Contains($ledgerMarker, [System.StringComparison]::Ordinal)) {
        throw "Convert-BRMLedgerBody: body does not carry $ledgerMarker — refusing to write. A correction applied to the wrong comment is exactly the failure that cost #922 sixteen rows."
    }

    # Idempotency gate, checked BEFORE any transform. An interrupted run is
    # resolved by re-running, never by diagnosis.
    $hasJudgeHead  = [regex]::IsMatch($Body, '(?m)^[ \t]*<!--\s*judge-rulings(?:\s|-->|$)')
    $hasBriefHead  = [regex]::IsMatch($Body, '(?m)^brief_dispositions[ \t]*:[ \t]*\r?$')
    # Item-8 fix (#963 review): `[ \t]*` before the field name, matching
    # Get-PhaseContainmentBlock's own tolerant field parser
    # (phase-containment-core.ps1's `'^\s*finding_key\s*:...'` /
    # `'^\s*caught_stage\s*:...'`). A column-0-only anchor here would leave a
    # row the production reader accepts as indented silently undetected as
    # "old" by this idempotency gate, which is the same class of bug the
    # comment below already warns about for CRLF.
    $hasOldPrefix  = [regex]::IsMatch($Body, '(?m)^[ \t]*finding_key[ \t]*:[ \t]*plan-stress-test:')
    $hasOldStage   = [regex]::IsMatch($Body, '(?m)^[ \t]*caught_stage[ \t]*:[ \t]*plan-stress-test[ \t]*\r?$')
    if ((-not $hasJudgeHead) -and $hasBriefHead -and (-not $hasOldPrefix) -and (-not $hasOldStage)) {
        return [PSCustomObject]@{ Body = $Body; Changed = $false; Reason = 'already-corrected' }
    }

    $findings = @(Get-BRMJudgeRulingsFindingIds -Body $Body)
    $new = $Body

    if ($plan.Action -eq 'relabel') {
        # THE TWO REWRITES ARE COUPLED AND MUST HAPPEN TOGETHER. Rule 12
        # validates the finding_key pattern only; it never cross-checks the
        # prefix against caught_stage. A caught_stage-only relabel therefore
        # validates perfectly cleanly and leaves every row invisible to the
        # emission check's finding_key prefix gate — 29 rows that parse, pass
        # schema validation, and are silently discarded by every reader.
        # `[ \t]*\r?$` — never a bare `[ \t]*$`. In multiline mode `$` matches
        # before the `\n` of a CRLF pair, and `\r` is not in `[ \t]`, so a bare
        # anchor silently fails to relabel a CRLF-bodied comment. GitHub
        # returns CRLF bodies, and the failure is silent in the worst possible
        # way: the finding_key rewrite below has no `$` anchor and DOES apply,
        # so the coupled pair comes apart and the rows land with a brief-review
        # prefix over a plan-stress-test stage. Both halves still validate
        # (Rule 12 never cross-checks prefix against stage) and the blocks
        # still COUNT, so a verdict check that only reads BlockCount reports
        # success on a corpus that was never relabelled.
        # Item-8 fix (#963 review): capture and PRESERVE leading indentation
        # rather than requiring column 0. Same rationale as the idempotency
        # checks above — the production reader tolerates an indented field,
        # so the rewrite must too, and stripping the indentation in the
        # replacement would itself reshape a row the reader was already
        # parsing correctly.
        $new = [regex]::Replace($new, '(?m)^([ \t]*)caught_stage[ \t]*:[ \t]*plan-stress-test[ \t]*\r?$', '${1}caught_stage: brief-review')
        $new = [regex]::Replace($new, '(?m)^([ \t]*)finding_key[ \t]*:[ \t]*plan-stress-test:', '${1}finding_key: brief-review:')
    }
    elseif ($plan.Action -eq 'withdraw') {
        # Archive before deleting (#963 review, finding AB). The rows carry
        # introduced_phase, catchable_phase, severity, systemic_fix_type and
        # category — real analytical content that the withdrawal decision was
        # never about. Withdrawing them from the COUNT is the decision;
        # destroying them is not, and an instrument whose repair silently
        # deletes evidence is a poor advertisement for itself.
        #
        # The archive is deliberately INERT: markers are rendered as text
        # inside a fence with the HTML-comment delimiters stripped, so no
        # sweep can ever re-parse it as live blocks. Same hygiene the emission
        # check's own Format-InertMarkerLabel applies to its reports.
        $blockPattern = "(?ms)^<!--\s*phase-containment-$Issue\s*-->.*?^<!--\s*/phase-containment-$Issue\s*-->[ \t]*\r?\n?"
        $withdrawn = @([regex]::Matches($new, $blockPattern) | ForEach-Object { $_.Value })
        $new = [regex]::Replace($new, $blockPattern, '')
        if ($withdrawn.Count -gt 0) {
            $inert = ($withdrawn -join "`n") -replace '<!--\s*', '' -replace '\s*-->', ''
            $archive = "`n`n<details><summary>Withdrawn rows ($($withdrawn.Count)), archived inert for the record</summary>`n`n" +
                       "These are the phase-containment blocks withdrawn from the count by the issue #951 correction. " +
                       "The marker delimiters are stripped so no reader can parse them as live ledger rows; they are kept " +
                       "because the withdrawal decision was about whether an unfiltered population may be COUNTED, not about " +
                       "destroying the phase attribution the panel recorded.`n`n" +
                       "``````text`n$inert`n```````n`n</details>"
            $new = $new.TrimEnd() + $archive
        }
    }
    else {
        throw "Convert-BRMLedgerBody: unknown action '$($plan.Action)' for issue #$Issue."
    }

    # Replace the judge-rulings head with the brief head. Done last so the
    # finding ids were read from the head while it still existed.
    $briefHead = New-BRMBriefHead -Findings $findings -ConvergenceFilterRan ($plan.Action -eq 'relabel') -FilteredCount $plan.FilteredCount
    $replacement = $briefHead + "`n`n" + $plan.Note
    if ($hasJudgeHead) {
        # Instance Regex with an explicit count of 1, and a MatchEvaluator
        # rather than a replacement string. Both matter:
        #   - [regex]::Replace's STATIC overloads have no count parameter, so
        #     passing 1 there binds to RegexOptions (IgnoreCase) instead of a
        #     replacement limit — a silent, wrong-behaviour trap.
        #   - a replacement STRING would interpret `$` sequences in the note
        #     as capture-group references.
        $rx = [regex]::new('<!--\s*judge-rulings\b.*?-->', [System.Text.RegularExpressions.RegexOptions]::Singleline)
        $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $replacement }
        $new = $rx.Replace($new, $evaluator, 1)
    }
    elseif (-not $hasBriefHead) {
        # No head of either kind: insert one immediately after the ledger
        # marker. Plain string surgery, never -replace: the note is arbitrary
        # prose and -replace would treat `$` in it as a substitution token.
        $idx = $new.IndexOf($ledgerMarker, [System.StringComparison]::Ordinal)
        $insertAt = $idx + $ledgerMarker.Length
        $new = $new.Substring(0, $insertAt) + "`n`n" + $replacement + $new.Substring($insertAt)
    }

    return [PSCustomObject]@{ Body = $new; Changed = ($new -ne $Body); Reason = 'corrected' }
}

#endregion

#region Verdict-grain verification

function Test-BRMCorrectedVerdict {
    <#
    .SYNOPSIS
        Re-PARSES a corrected issue's comment corpus and checks the emission
        verdict it now renders against the planned terminal verdict.
    .DESCRIPTION
        This is the guard amendment A1(c) requires, and it is deliberately not
        a recount. A count-grain check ("29 blocks written, 29 blocks read
        back") passes on a corpus whose rows are all present, all parseable,
        and all invisible to every reader — the exact end state a
        caught_stage-only relabel produces. Re-rendering the verdict is the
        only check that fails in that case.
    .OUTPUTS
        [PSCustomObject] Ok [bool], Failures [string[]], Surfaces [string[]],
        Gap [PSCustomObject].
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Bodies,
        [Parameter(Mandatory)][int]$Issue
    )

    $plan = Get-BRMPlannedCorrection -Issue $Issue
    if ($null -eq $plan) { throw "Test-BRMCorrectedVerdict: issue #$Issue is outside this migration's bound." }

    $failures = [System.Collections.Generic.List[string]]::new()
    $surfaces = @(Get-IssueEmissionSurfaces -Bodies $Bodies -Id $Issue)

    if ($surfaces -notcontains 'brief-review') {
        $failures.Add("#${Issue}: the issue does not route to the brief-review surface after correction (surfaces: $($surfaces -join ', ')). The rows moved and the routing did not follow them.")
    }
    if ($surfaces -contains 'plan-stress-test') {
        $failures.Add("#${Issue}: plan-stress-test is still probed after correction, so the corrected rows will render as a permanent false gap on a surface that no longer owns them — the failure amendment A1(a) named.")
    }

    $gap = Get-EmissionGap -Bodies $Bodies -Id $Issue -Surface 'brief-review'
    if ($gap.ParseStatus -ne $plan.ExpectedParseStatus) {
        $failures.Add("#${Issue}: expected ParseStatus '$($plan.ExpectedParseStatus)', rendered '$($gap.ParseStatus)'.")
    }
    if ($gap.Reason -ne $plan.ExpectedReason) {
        $failures.Add("#${Issue}: expected Reason '$($plan.ExpectedReason)', rendered '$($gap.Reason)'.")
    }
    if ($gap.SustainedCount -ne $plan.ExpectedSustained) {
        $failures.Add("#${Issue}: expected SustainedCount $($plan.ExpectedSustained), rendered $($gap.SustainedCount).")
    }
    if ($gap.BlockCount -ne $plan.ExpectedBlockCount) {
        $failures.Add("#${Issue}: expected BlockCount $($plan.ExpectedBlockCount), rendered $($gap.BlockCount). A block that was written but is not counted is a block no reader can see.")
    }

    # No judge vocabulary may survive anywhere in the corrected authorizing
    # record. This is the property the whole issue exists to establish, so it
    # is checked directly rather than inferred from the verdict.
    foreach ($b in $Bodies) {
        if ([string]::IsNullOrWhiteSpace($b)) { continue }
        if (-not $b.Contains("<!-- phase-containment-ledger-$Issue -->", [System.StringComparison]::Ordinal)) { continue }
        if ([regex]::IsMatch($b, '(?m)^\s*(?:-\s+)?judge_ruling\s*:')) {
            $failures.Add("#${Issue}: a judge_ruling field survives on the ledger sibling after correction.")
        }
        if ([regex]::IsMatch($b, '(?m)^[ \t]*<!--\s*judge-rulings(?:\s|-->|$)')) {
            $failures.Add("#${Issue}: a judge-rulings head survives on the ledger sibling after correction.")
        }
        # BOTH HALVES OF THE COUPLED REWRITE ARE CHECKED SEPARATELY, and this
        # half is the one a verdict alone cannot see. A stage-that-did-not-move
        # under a prefix-that-did still validates (Rule 12 never cross-checks
        # the two) and still COUNTS, so BlockCount reads correct while every
        # row asserts the wrong adjudication standard and the rollup partition
        # files them under the wrong sub-arm. A CRLF-anchoring slip in the
        # relabel regex produced exactly this state.
        #
        # Checked through the PRODUCTION PARSER, not a third copy of the
        # rewrite's own literal regex (#963 review, finding O). The parser
        # accepts leading indentation and quoted values; the literal regexes
        # do not. A guard whose discriminating power is narrower than the
        # parser's acceptance reports success on precisely the inputs the
        # rewrite silently skipped — the guard added to catch the decoupling
        # was blind to the shapes most likely to cause it.
        # DIRECT ASSIGNMENT, no @() and no pipeline. Get-PhaseContainmentBlock
        # returns its result through the `return ,$array` idiom, which
        # preserves the array for a direct assignment and collapses under
        # `@(... | ...)` into a single element holding the whole array. Piping
        # it through a `$_ -is [string]` filter therefore discarded all 29
        # blocks and left this guard scanning nothing — it reported success on
        # a corpus it had not looked at, which is the failure mode it exists to
        # prevent. Get-EmissionGap assigns directly for the same reason.
        $rawBlocks = Get-PhaseContainmentBlock -Text $b -Id $Issue
        if ($null -eq $rawBlocks) { continue }
        foreach ($raw in $rawBlocks) {
            if ([string]::IsNullOrWhiteSpace($raw)) { continue }
            $entry = ConvertFrom-PhaseContainmentYaml -Yaml $raw
            $stage = [string]$entry['caught_stage']
            $key = [string]$entry['finding_key']
            if ($stage -eq 'plan-stress-test') {
                $failures.Add("#${Issue}: a row still parses as caught_stage 'plan-stress-test' after correction. The finding_key prefix and the stage must move together; a prefix-only rewrite counts correctly and grades wrongly.")
            }
            if ($key.StartsWith('plan-stress-test:', [System.StringComparison]::Ordinal)) {
                $failures.Add("#${Issue}: a row still parses with a 'plan-stress-test:' finding_key prefix after correction.")
            }
            if ($stage -eq 'brief-review' -and -not $key.StartsWith('brief-review:', [System.StringComparison]::Ordinal)) {
                $failures.Add("#${Issue}: a row carries caught_stage 'brief-review' under a finding_key prefix of '$key' — schema-valid, parseable, and invisible to every reader.")
            }
        }
    }

    return [PSCustomObject]@{
        Ok       = ($failures.Count -eq 0)
        Failures = $failures.ToArray()
        Surfaces = $surfaces
        Gap      = $gap
    }
}

#endregion
