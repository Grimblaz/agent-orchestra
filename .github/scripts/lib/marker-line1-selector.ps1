#Requires -Version 7.0
<#
.SYNOPSIS
    The line-1-exact comment-selection predicate shared by Find-OrUpsertComment
    and by every selector that must reach the SAME comment it reaches.

.DESCRIPTION
    Issue #1031 (chunk 1 of #1011), parent AC2 -- the "close the path" arm.

    NOTE (apostrophe hygiene): comment prose in this file avoids possessive
    apostrophes. audit-hub-artifact-paths.ps1 scans every .github/scripts/lib
    PowerShell file and extracts path references with a naive single-quote
    pairing regex that treats EVERY apostrophe as a string delimiter, so an
    odd number of them re-pairs every quoted span later in the file. Same
    convention as lib/cost-session-render.ps1 and lib/cost-telemetry-budgets.ps1.

    THE HAZARD THIS CLOSES. Find-OrUpsertComment used to select its PATCH
    target with `$_.body -like "*$Marker*"` -- unanchored, over the whole body,
    backticks not stripped -- and then REPLACED that body verbatim. A marker
    quoted anywhere in ordinary prose was therefore enough to make an
    unrelated comment be chosen as some other family write target and
    destroyed. Not a timestamp advance: destruction. The earliest-REST-id
    tie-break made it worse, because a prose mention posted BEFORE the real
    target was actively preferred over it.

    This was not theoretical. A live corpus probe over every issue and pull
    request 1..1037 found exactly one such comment, and it is the worst shape
    available: comment 4861653613 on issue #782 is the approved PLAN comment
    for that issue (a plan-issue marker on line 1) which quotes the
    pc-emission-check-report marker mid-line in backticked prose on line 37.
    It was the ONLY comment on #782 containing that string, so a
    phase-containment-emission-check.ps1 -PostTo 782 run would have matched it
    uniquely and overwritten the whole plan with an emission-check report.

    WHY LINE-1-EXACT AND NOT A LINE ANCHOR. A start-of-line anchor and a
    whole-line anchor both still select a marker sitting ALONE ON ITS OWN LINE
    inside a fenced code block or an indented example -- the shape the plan
    bodies, design documents and handoff prose in this repository produce by
    construction. This tree has already ruled on exactly that once, in a
    different reader:
    skills/verification-before-completion/scripts/completion-account-core.ps1
    (:553-570) rejected a multiline start-of-line anchor because "a marker on
    line 3, an indented marker, or a marker inside a fenced code block still
    read as a candidate -- the exact shadowing defect this anchor exists to
    close", and settled on line-1-exact. This predicate is the same rule, for
    the write side.

    IT DOES NOT CONVERGE ON THE WHOLE-LINE READERS -- IT GOES STRICTLY
    NARROWER, AND THAT DIRECTION IS DELIBERATE. Two readers had already
    diverged from the old substring rule for markers this writer writes, and
    both noted that the writer-side selector was the real fix:
    goal-run-stage-core.ps1:244-286 (used at :503, :1738, :1971) and
    migrate-brief-review-corpus.ps1:170-177 (and the same whole-line finder
    reached through persist-phase-ledger-core.ps1:138). They match
    `(?m)^\s*ESC\s*$` -- whole line, ANY line -- so they still accept a marker
    alone on its own line inside a fenced block, which the section above
    argues is exactly the shape that must not select. This predicate rejects
    it. So the accept set of the WRITER is now a strict SUBSET of the accept
    set of those READERS, where before this change it was a superset.

    Why that inversion is the safe direction, and why no reader was narrowed
    with it: an over-selecting READER refuses or reuses, loudly. An
    over-selecting WRITER destroys. Concretely -- Clear-GoalRunStageMarker
    (goal-run-stage-core.ps1:1971) reports `marker-ambiguous` and deletes
    nothing when it sees more than one match, and Invoke-GoalRunRestart
    surfaces that as `restarted-partial-marker-clear-failed`; before this
    change the same quotation-only state ended in a silent PATCH over the
    quoting comment instead. For the phase-containment-ledger family the
    reader GATES the writer (persist-phase-ledger-core.ps1:777-783 only calls
    the upserter when its own whole-line lookup found nothing), so a reader
    that accepts more than the writer can only over-reuse an existing
    comment, never route a write onto one the writer would have refused.
    Narrowing those readers is therefore not required by this change, and is
    not attempted by it. Recorded here rather than left implicit because the
    divergence is real and a later reader must not conclude the two sides
    agree (#1031, review finding M1).

    WHY ITS OWN FILE. It has exactly one job and no side effects at
    dot-source time, so any selector can import it without importing anything
    else. Two neighbours could not import this equivalence from where it
    previously lived:
      * find-or-upsert-comment.ps1 also defines Find-OrUpsertComment, and
        pulling that name into the dot-source scope of a file silently
        shadows Pester per-test Find-OrUpsertComment mocks -- the documented
        reason cost-baseline-harvest.ps1 mirrored Get-RestCommentId by hand
        instead (see the .NOTES at the top of that file, issue #824 M6).
      * marker-transport-core.ps1, which owns the whole-line finder
        Get-MarkerWholeLinePattern, sets [Console]::OutputEncoding
        PROCESS-WIDE as its first top-level statement (:96-101);
        goal-run-stage-core.ps1:266-279 declines to dot-source it for exactly
        that reason. find-or-upsert-comment.ps1 is dot-sourced by all fifteen
        production call sites and their suites, so importing that mutation
        here would push it into every one of them.
    A shared file removes the drift that AC-c would otherwise have to police
    by comment cross-reference: the mirrors do not agree with this selector by
    convention, they agree with it by construction.
#>

function Test-CommentBodyMarkerLine1 {
    <#
    .SYNOPSIS
        True iff the FIRST LINE of Body -- trailing whitespace stripped -- is
        EXACTLY Marker, ordinally.
    .DESCRIPTION
        Deliberately TrimEnd, not Trim: leading whitespace on line 1 is
        SIGNIFICANT and disqualifies a candidate, because an indented marker
        is one of the shapes this anchor exists to reject. Trailing
        whitespace is immaterial to which line-1 payload was posted, so it
        alone is stripped -- the same asymmetry that the trailing `\s*$` in
        Get-MarkerWholeLinePattern applies at end-of-line.

        Deliberately [StringComparison]::Ordinal, not the PowerShell -eq
        operator: -eq on strings is CULTURE-AWARE, which ignores case and
        treats a leading BOM (U+FEFF) or ZWSP (U+200B) as ignorable -- so a
        BOM-prefixed marker line would match here while the finder belonging
        to the marker-write primitive (whose \s excludes those two Unicode
        format characters) would not find it. Ordinal keeps the accept set of
        this selector a SUBSET of the accept set of that primitive, never
        wider. Same reasoning, same conclusion as PF1/PF6 in
        completion-account-core.ps1.

        The marker is TrimEnd-ed too, not only the body line, so the
        comparison is reflexive: a marker carrying a stray trailing space or
        CR still matches the comment that carries it. Trimming only one side
        made the predicate return false for Body == Marker, and since zero
        matches is the POST branch in Find-OrUpsertComment, such a caller
        would have posted a fresh comment on every run -- the unbounded
        duplicate accretion class persist-marker-core.ps1:681-696 records.
        No current caller could reach it (all interpolate literals), which is
        why it was a latent defect rather than a live one (#1031, review
        finding M4).

        Fails closed on a null, empty or WHITESPACE-ONLY body or marker.
        Whitespace-only is checked, not merely empty, because TrimEnd can
        never leave a line ending in whitespace: a whitespace-only marker
        would pass an IsNullOrEmpty guard and then match nothing, forever,
        silently -- and silently-matches-nothing becomes POST-a-new-comment
        one layer up. Find-OrUpsertComment binds Marker as a mandatory
        [string], which rejects the empty string but NOT a whitespace-only
        one, and the two mirrors bind nothing at all (#1031, finding M16).
    .PARAMETER Body
        The comment body to test. Null and empty are accepted and return
        false rather than throwing, because the shapes returned by
        `gh ... --json comments` include comments with no body.
    .PARAMETER Marker
        The full marker token, for example the delimited frame-credit-ledger
        head for a PR. This is an EXACT line-1 payload, not a substring and
        not a prefix.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowNull()][AllowEmptyString()][string]$Body,
        [Parameter(Mandatory, Position = 1)][AllowNull()][AllowEmptyString()][string]$Marker
    )

    if ([string]::IsNullOrWhiteSpace($Body)) { return $false }
    if ([string]::IsNullOrWhiteSpace($Marker)) { return $false }

    # Slice on either terminator: GitHub returns CRLF in comment bodies often
    # enough that IndexOf on LF alone would leave a trailing CR on line 1.
    # TrimEnd below removes it anyway, but slicing on both keeps the notion of
    # "first line" honest for CR-only text too.
    $firstBreak = $Body.IndexOfAny([char[]]@("`n", "`r"))
    $firstLine = if ($firstBreak -lt 0) { $Body } else { $Body.Substring(0, $firstBreak) }

    return $firstLine.TrimEnd().Equals($Marker.TrimEnd(), [System.StringComparison]::Ordinal)
}
