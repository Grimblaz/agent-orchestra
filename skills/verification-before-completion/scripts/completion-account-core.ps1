#Requires -Version 7.0
<#
.SYNOPSIS
    Reader for the completion account's required review assertion (issue #998,
    chunk 2 of #949).

.DESCRIPTION
    WHY THIS EXISTS. `CLAUDE.md` § What a finished run is true of states that a
    review which ran and found nothing must say so in words that would be false
    if it had not run. Property 1 -- every finding the review produced traces to
    an outcome that survived the judge -- is quantified over the findings a
    review produced, so a run that dispatched no review satisfies it vacuously
    over the empty set and can write a closed-looking account with no review
    behind it.

    The first draft of that rule was a single sentence forbidding the vacuous
    account, administered by the same run writing it. That is a hope, not a
    check. This file is the reader that is NOT the account's author.

    WARN-ONLY, AND STRUCTURALLY SO. Nothing here throws on a non-conforming
    account, returns a nonzero exit code, or refuses a write. It returns a
    verdict object. Two paths in this repository would quietly break that
    property and neither looks like it does:

      * A marker-family `ValidatorAdapter` is a HARD PRE-WRITE REFUSAL
        (`skills/review-judgment/SKILL.md`), not a warning -- wiring this
        reader there would make a non-conforming account unwritable rather
        than flagged, leaving the run with no durable account at all. The
        `completion-account` registry row's adapter is `$null` deliberately;
        its comment says so at the field.
      * `phase-containment-emission-check.ps1` carries a reserved `-Mode
        enforce` switch pre-wired to a nonzero exit. It is documented as
        unimplemented pending a separate decision and is not this file's to
        flip or to depend on.

    ABSENCE IS NOT A THIRD POLARITY. An account omitting the assertion reads
    as not-run, never as clean -- silence must not be readable as
    examined-and-clean. The verdict still distinguishes the two cases
    ('declared-not-run' vs 'unasserted') because they are different maintainer
    actions: one is an honest declaration, the other is an omission. This
    mirrors the brief-review surface's own `filter-not-run` /
    `filter-unasserted` split, which exists for the same reason.

.NOTES
    Dot-source this file to use the functions. No side effects on load.
#>

Set-StrictMode -Version Latest

# The one required assertion. Deliberately matched on its own line with an
# optional leading list marker or blockquote, so the account may carry it in a
# fenced YAML block, a bullet, or bare prose -- the payload format is the run's
# choice; only this field is fixed.
#
# Single-quoted so no PowerShell interpolation runs over the pattern: in a
# double-quoted string a backtick-dollar still reaches the regex engine as an
# end-of-line anchor, which is how this class of pattern usually breaks here.
$script:CompletionAccountAssertionPattern =
    '(?im)^[ \t]*(?:[-*>]\s*)*adversarial_review_ran[ \t]*:[ \t]*(?<value>\S+)[ \t]*$'

# Suite-state vocabulary, for the secondary signal only. A run may phrase its
# suite statement however it likes; this is a presence heuristic that feeds a
# warning, never a verdict.
$script:CompletionAccountSuitePattern =
    '(?im)\b(?:baseline[ _-]?commit|failures?[ \t]+at[ \t]+baseline|added[ \t]+failures?|failures?[ \t]+this[ \t]+change[ \t]+added|suite[ \t]+health)\b'

function Read-CompletionAccount {
    <#
    .SYNOPSIS
        Reads a completion account's required review assertion and returns a
        warn-only verdict. Never throws, never blocks a write.
    .DESCRIPTION
        The account's author writes the assertion; this function is the reader
        that is not the author. It is the whole of what makes "the review ran
        and returned nothing" distinguishable from "no review ran" without
        reading the transcript.

        Verdict values and what each means to a maintainer:

          'ran'                the account asserts a review ran. This is the
                               only value that reads as examined.
          'declared-not-run'   the account asserts, in words, that no review
                               ran. Honest, and actionable: run the review.
          'unasserted'         the field is absent. Reads as NOT RUN. Kept
                               distinct from the above because the maintainer
                               action differs -- here the account itself is
                               incomplete.
          'value-unrecognized' the field is present and its value is neither
                               polarity. Reported as its own verdict rather
                               than folded into 'unasserted', because telling
                               a maintainer the field is missing when it is
                               right in front of them points at the wrong edit.
          'duplicate-assertion' two or more assertions disagree. No statement
                               either makes can be trusted, so naming one of
                               them would send the maintainer to the wrong
                               line. (Repeated assertions that AGREE are not
                               a conflict and resolve to their shared value.)

        A run reaching completion is never prevented by any of these.
    .PARAMETER Text
        Raw completion-account body. Empty, whitespace, and $null are all
        legitimate inputs and all read as 'unasserted' -- an account that does
        not exist has not asserted a review any more than one that omits the
        field.
    .OUTPUTS
        [PSCustomObject] Verdict [string], ReviewRan [bool] (true ONLY for
        'ran'), AssertionPresent [bool], AssertionValue [string or $null],
        AssertionCount [int], SuiteStateStated [bool], Warnings [string[]],
        Blocking [bool] (always $false -- present so a caller reading this
        field cannot accidentally build a gate on the verdict alone).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()][AllowEmptyString()]
        [string]$Text
    )

    process {
        $warnings = [System.Collections.Generic.List[string]]::new()

        $body = if ($null -eq $Text) { '' } else { $Text }

        $matchesFound = @([regex]::Matches($body, $script:CompletionAccountAssertionPattern))

        # Distinct VALUES, not distinct matches: an account that states the
        # same polarity twice (a fenced block plus a prose restatement, say) is
        # consistent, and reporting it as a conflict would train a reader to
        # ignore the conflict verdict for the case that matters.
        $rawValues = @(
            $matchesFound | ForEach-Object { $_.Groups['value'].Value.Trim().Trim('"', "'", ',').ToLowerInvariant() }
        )
        $distinctValues = @($rawValues | Sort-Object -Unique)

        $suiteStated = [regex]::IsMatch($body, $script:CompletionAccountSuitePattern)

        $assertionPresent = $matchesFound.Count -gt 0
        $assertionValue = if ($distinctValues.Count -eq 1) { $distinctValues[0] } else { $null }

        $verdict =
            if (-not $assertionPresent) {
                $warnings.Add('The account carries no `adversarial_review_ran` assertion. An account omitting the field reads as NOT RUN, never as examined-and-clean.')
                'unasserted'
            }
            elseif ($distinctValues.Count -gt 1) {
                $warnings.Add("The account carries disagreeing ``adversarial_review_ran`` assertions ($($distinctValues -join ', ')). No statement either makes can be trusted; resolve to one before reading the account.")
                'duplicate-assertion'
            }
            elseif ($assertionValue -eq 'true') {
                'ran'
            }
            elseif ($assertionValue -eq 'false') {
                $warnings.Add('The account asserts `adversarial_review_ran: false`. The run has not met property 1: no review is accounted for.')
                'declared-not-run'
            }
            else {
                $warnings.Add("The ``adversarial_review_ran`` assertion is present but its value '$assertionValue' is neither ``true`` nor ``false``. The field is there and unreadable -- this is a different edit from a missing field.")
                'value-unrecognized'
            }

        if (-not $suiteStated) {
            # AC16's secondary signal. The rejection itself is a guidance
            # clause in SKILL.md; this warning is how a reader other than the
            # author notices it, and it never changes the verdict.
            $warnings.Add('The account states nothing about suite health. A finished run states its suite state differentially -- what this change added, against a named baseline commit.')
        }

        return [PSCustomObject]@{
            Verdict          = $verdict
            # True ONLY for 'ran'. Every other verdict -- including the two
            # that merely fail to say -- is a not-run reading, which is the
            # whole false-polarity property.
            ReviewRan        = ($verdict -eq 'ran')
            AssertionPresent = $assertionPresent
            AssertionValue   = $assertionValue
            AssertionCount   = $matchesFound.Count
            SuiteStateStated = $suiteStated
            Warnings         = @($warnings)
            # Constant. A caller that wants to gate on completion is building
            # the fail-the-run detector #949 rejected; this field says so at
            # the point where that caller would read the verdict.
            Blocking         = $false
        }
    }
}
