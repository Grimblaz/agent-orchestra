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

    WHAT THE FIRST DRAFT GOT WRONG (issue #998 review, findings M1/M2/M3/M14/
    M25/M27, all sustained). Every one of them made the mechanism report an
    HONEST run as not-run, or a DISHONEST one as examined -- i.e. each broke
    the one property this file exists to provide:

      * M2 (critical) -- the pattern ended `[ \t]*$` with no `\r?`, and nothing
        normalized line endings. The precedent it cited
        (`phase-containment-emission-check-core.ps1`) ends `[ \t]*\r?$`, and
        this repository defines `ConvertTo-MarkerLFBody` precisely so that
        `(?m)^...$` detection cannot miss a match because the source is CRLF.
        On Windows -- this repository's own platform -- the documented write
        path produces CRLF end to end, so the ONLY verdict that reads as
        examined was unreachable by a conforming account. Now normalized first.
      * M1 (high) -- `(?<value>\S+)[ \t]*$` admitted no trailing content, so
        the guidance's own example (`adversarial_review_ran: true    # or
        false`) read as `unasserted`. Trailing YAML comments are now parsed
        and discarded.
      * M3 (high) -- a bare `[regex]::Matches` with no decoy gating meant a
        fenced example, a YAML block scalar, or an HTML comment invisible in
        GitHub's render all read as `ran`. That hands the verdict back to the
        author, which is exactly what AC2 forbids. Those three spans are now
        masked before matching. A blockquoted assertion is still read: payload
        format is the run's choice and a `>` prefix is a legitimate one.
      * M14 (medium) -- the suite-state signal fired on a bare `Baseline
        commit:` label with no content and stayed silent on a substantive
        differential sentence. Both polarities were wrong. It is now a
        content-requiring heuristic, and its advisory status is stated.
      * M25/M27 (low) -- YAML 1.1 booleans (`yes`/`no`/`on`/`off`) read as
        unreadable, and agreeing assertions differing by a trailing period or
        markdown bold read as conflicting.

.NOTES
    Dot-source this file to use the functions. Note that it sets StrictMode at
    file scope, matching the house convention across the sibling libraries --
    dot-sourcing therefore turns StrictMode on in the caller's scope. That is a
    real side effect; the first draft's ".NOTES" claimed there were none.
#>

Set-StrictMode -Version Latest

# The one required assertion.
#
# Matched against an LF-normalized, span-masked copy (see Get-CAReadableText).
# Leading list markers and blockquote prefixes are tolerated because payload
# format is the run's choice; markdown emphasis around the key is tolerated
# because a run writing prose rather than YAML naturally bolds it. Trailing
# content after the value is parsed and discarded so an ordinary YAML inline
# comment -- including the one this skill's own documentation prints -- does
# not read as an absent field.
#
# Single-quoted so no PowerShell interpolation runs over the pattern: in a
# double-quoted string a backtick-dollar still reaches the regex engine as an
# end-of-line anchor, which is how this class of pattern usually breaks here.
$script:CompletionAccountAssertionPattern =
    '(?im)^[ \t]*(?:[-*>]\s*)*(?:\*\*|__)?adversarial_review_ran(?:\*\*|__)?[ \t]*:[ \t]*(?<value>[^\s#]+)[ \t]*(?:#[^\r\n]*)?[ \t]*\r?$'

# Accepted polarities. YAML 1.1 booleans are in scope because this skill
# documents the field inside a ```yaml fence, so they are the expected input
# class -- and every one of them landing on `value-unrecognized` put the
# warning on the honest run (M25).
$script:CompletionAccountTruthy = @('true', 'yes', 'on', 't', 'y')
$script:CompletionAccountFalsy = @('false', 'no', 'off', 'f', 'n')

# Suite-state heuristic (M14). ADVISORY ONLY -- it never changes the verdict.
# The RULE that an account must say something about the suite lives in
# SKILL.md; this is how a reader other than the author notices a likely
# omission. Requires a suite word AND some substance on the same line (a digit,
# or a commit-ish token, or an explicit "none"), because the first draft's
# bare-label match reported an empty `Baseline commit:` as a stated suite
# result while warning that a real differential sentence stated nothing.
$script:CompletionAccountSuiteWordPattern =
    '(?i)\b(?:suite|tests?|failures?|failing|passed|passing|baseline|pre-existing|preexisting|regression)\b'
$script:CompletionAccountSuiteSubstancePattern =
    '(?i)(?:\d|\bnone\b|\bzero\b|\bno\b|\bclean\b|\bgreen\b|\bred\b|[0-9a-f]{7,40})'

function script:Get-CAReadableText {
    <#
    .SYNOPSIS
        Returns an LF-normalized copy of the account with the CONTENTS of
        fenced code blocks, HTML comments, and YAML block scalars blanked out,
        so the assertion scan sees only text the account actually asserts.
    .DESCRIPTION
        M3's failure mode: an account can quote the assertion -- in a fenced
        example, in a `notes: |` block scalar, or inside an HTML comment that
        GitHub does not render at all -- and the bare scan reads it as a live
        assertion. That returns control of the verdict to the account's author,
        which is precisely the property AC2 exists to remove.

        This is the same class the sibling instrument already closed for the
        judge-rulings surface (`Get-BlockScalarSpans` / `Test-IndexInBlockScalarSpan`,
        the CM4 fix). It is reimplemented compactly here rather than imported,
        because this skill ships to consumer repositories that do not receive
        `.github/scripts/lib`.

        Length and newline positions are preserved so offsets index the
        normalized text exactly. A blockquote prefix is deliberately NOT
        masked: `> adversarial_review_ran: true` is a legitimate payload shape.
    .OUTPUTS
        [string] the LF-normalized, masked copy.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }

    # M2: normalize FIRST. Everything below, and the caller's own matching,
    # then operates on LF regardless of how the body reached us -- a body file
    # authored on Windows, a comment GitHub returns CRLF-encoded, or a here-
    # string in a test.
    $lf = $Text -replace "`r`n", "`n" -replace "`r", "`n"

    $sb = [System.Text.StringBuilder]::new($lf)
    $blankSpan = {
        param([int]$Start, [int]$End)
        for ($i = $Start; $i -lt $End -and $i -lt $lf.Length; $i++) {
            if ($lf[$i] -ne "`n") { $sb[$i] = ' ' }
        }
    }

    # 1. HTML comments. Masked whole, including the delimiters: an assertion
    #    inside one is invisible to every human reading the comment on GitHub,
    #    so treating it as asserted is strictly worse than ignoring it.
    foreach ($m in [regex]::Matches($lf, '(?s)<!--.*?-->')) {
        & $blankSpan $m.Index ($m.Index + $m.Length)
    }

    # 2. Fenced code blocks (``` or ~~~), including an unterminated final
    #    fence -- an account that opens a fence and never closes it has put
    #    everything after it inside an example.
    foreach ($m in [regex]::Matches($lf, '(?m)^[ \t]*(?<f>`{3,}|~{3,})[^\n]*\n(?<body>.*?)(?:^[ \t]*\k<f>[^\n]*$|\z)', 'Singleline')) {
        & $blankSpan $m.Index ($m.Index + $m.Length)
    }

    # 3. YAML block scalars (`key: |`, `key: >`, with optional chomping /
    #    indent indicators). The block is every following line indented
    #    deeper than the key, plus blank lines.
    foreach ($m in [regex]::Matches($lf, '(?m)^(?<indent>[ \t]*)[^\s:#][^:\n]*:[ \t]*[|>][+-]?\d?[ \t]*$')) {
        $keyIndent = $m.Groups['indent'].Value.Length
        $pos = $m.Index + $m.Length
        while ($pos -lt $lf.Length) {
            $nl = $lf.IndexOf("`n", $pos)
            $lineStart = if ($lf[$pos] -eq "`n") { $pos + 1 } else { $pos }
            if ($lineStart -ge $lf.Length) { break }
            $nl = $lf.IndexOf("`n", $lineStart)
            $lineEnd = if ($nl -lt 0) { $lf.Length } else { $nl }
            $line = $lf.Substring($lineStart, $lineEnd - $lineStart)
            if ($line.Trim().Length -gt 0) {
                $ind = ($line.Length - $line.TrimStart(' ', "`t").Length)
                if ($ind -le $keyIndent) { break }
            }
            & $blankSpan $lineStart $lineEnd
            $pos = $lineEnd
            if ($nl -lt 0) { break }
        }
    }

    return $sb.ToString()
}

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
          'unasserted'         the field is absent -- or present only inside a
                               fenced example, a block scalar, or an HTML
                               comment, which is not an assertion. Reads as
                               NOT RUN. Kept distinct from the above because
                               the maintainer action differs: here the account
                               itself is incomplete.
          'value-unrecognized' the field is present and its value is neither
                               polarity. Reported as its own verdict rather
                               than folded into 'unasserted', because telling
                               a maintainer the field is missing when it is
                               right in front of them points at the wrong edit.
          'duplicate-assertion' two or more assertions disagree. No statement
                               either makes can be trusted, so naming one of
                               them would send the maintainer to the wrong
                               line. Repeated assertions that AGREE -- after
                               punctuation and case normalization -- are not a
                               conflict and resolve to their shared value.

        A run reaching completion is never prevented by any of these.
    .PARAMETER Text
        Raw completion-account body, in any line-ending convention. Empty,
        whitespace, and $null are all legitimate inputs and all read as
        'unasserted' -- an account that does not exist has not asserted a
        review any more than one that omits the field.
    .PARAMETER PostedBy
        Optional login of the account comment's author, for disclosure.
        Issue-comment records in this repository are recognised by SHAPE
        alone, so anyone who can comment on the issue can post something that
        reads as a completion account. The settled mitigation (#957 amendments
        11/13, shipped by #995) is that every surface which resumes or routes
        on such a record STATES WHO POSTED IT rather than pretending the
        record authenticates itself. This reader is such a surface, so it
        carries the field through and says so when it is absent. It is
        advisory: nothing here authenticates, and an undisclosed account is
        reported, not rejected.
    .OUTPUTS
        [PSCustomObject] Verdict [string], ReviewRan [bool] (true ONLY for
        'ran'), AssertionPresent [bool], AssertionValue [string or $null],
        AssertionCount [int], SuiteStateStated [bool], PostedBy [string or
        $null], AuthorDisclosed [bool], Warnings [string[]], Blocking [bool]
        (always $false -- present so a caller reading this field cannot
        accidentally build a gate on the verdict alone).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()][AllowEmptyString()]
        [string]$Text,

        [Parameter()]
        [AllowNull()][AllowEmptyString()]
        [string]$PostedBy
    )

    process {
        $warnings = [System.Collections.Generic.List[string]]::new()

        $body = if ($null -eq $Text) { '' } else { $Text }
        $readable = script:Get-CAReadableText -Text $body

        $matchesFound = @([regex]::Matches($readable, $script:CompletionAccountAssertionPattern))

        # Distinct NORMALIZED values, not distinct matches: an account that
        # states the same polarity twice -- once as YAML and once restated in
        # prose with a full stop -- is consistent, and reporting it as a
        # conflict would train a reader to ignore the conflict verdict for the
        # case that matters (M27).
        $rawValues = @(
            $matchesFound | ForEach-Object {
                $_.Groups['value'].Value.Trim().Trim('"', "'", ',', '.', ';', '*', '`').ToLowerInvariant()
            }
        )
        $distinctValues = @($rawValues | Where-Object { $_ -ne '' } | Sort-Object -Unique)

        # M14: a suite word alone is not a suite statement. Evaluated per line
        # so a label on one line and a number three paragraphs away do not
        # combine into a false positive.
        $suiteStated = $false
        foreach ($line in ($readable -split "`n")) {
            if ($line -match $script:CompletionAccountSuiteWordPattern -and
                $line -match $script:CompletionAccountSuiteSubstancePattern) {
                $suiteStated = $true
                break
            }
        }

        $assertionPresent = $matchesFound.Count -gt 0
        $assertionValue = if ($distinctValues.Count -eq 1) { $distinctValues[0] } else { $null }

        $verdict =
            if (-not $assertionPresent) {
                $warnings.Add('The account carries no live `adversarial_review_ran` assertion. An account omitting the field -- or carrying it only inside a fenced example, a block scalar, or an HTML comment -- reads as NOT RUN, never as examined-and-clean.')
                'unasserted'
            }
            elseif ($distinctValues.Count -gt 1) {
                $warnings.Add("The account carries disagreeing ``adversarial_review_ran`` assertions ($($distinctValues -join ', ')). No statement either makes can be trusted; resolve to one before reading the account.")
                'duplicate-assertion'
            }
            elseif ($script:CompletionAccountTruthy -contains $assertionValue) {
                'ran'
            }
            elseif ($script:CompletionAccountFalsy -contains $assertionValue) {
                $warnings.Add('The account asserts that no adversarial review ran. The run has not met property 1: no review is accounted for.')
                'declared-not-run'
            }
            else {
                $warnings.Add("The ``adversarial_review_ran`` assertion is present but its value '$assertionValue' is neither polarity. The field is there and unreadable -- this is a different edit from a missing field.")
                'value-unrecognized'
            }

        if (-not $suiteStated) {
            # AC16's secondary signal, and ADVISORY: the rejection itself is a
            # guidance clause in SKILL.md, and this heuristic never changes the
            # verdict above. It exists so a reader other than the author
            # notices the omission.
            $warnings.Add('The account states nothing substantive about suite health. A finished run states its suite state differentially -- what this change added, against a named baseline commit that predates the change.')
        }

        $authorDisclosed = -not [string]::IsNullOrWhiteSpace($PostedBy)
        if (-not $authorDisclosed) {
            $warnings.Add('No author was supplied for this account. A completion account is recognised by shape alone, so anyone who can comment on the issue can post one; a reader that routes on it should state who posted it (issue #957 amendments 11/13, shipped by #995) rather than treat the record as self-authenticating.')
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
            PostedBy         = if ($authorDisclosed) { $PostedBy } else { $null }
            AuthorDisclosed  = $authorDisclosed
            Warnings         = @($warnings)
            # Constant. A caller that wants to gate on completion is building
            # the fail-the-run detector #949 rejected; this field says so at
            # the point where that caller would read the verdict.
            Blocking         = $false
        }
    }
}

function Get-CompletionAccountFromComments {
    <#
    .SYNOPSIS
        Selects the completion account from an issue's comments and reads it,
        carrying the comment author through for disclosure. This is the
        invocation point the first draft did not have (M6).
    .DESCRIPTION
        WHY THIS EXISTS. The first draft shipped `Read-CompletionAccount` with
        no caller anywhere in the tree and no guidance naming when or by whom
        it runs. That is the shape this repository has already measured
        failing: a stated-once obligation shipped into three skills emitted
        zero across three consecutive reviews, and the recorded remedy was a
        warn-only reader-side SWEEP. A reader with no sweep caller is that
        remedy minus the sweep.

        WHICH COMMENT IS THE ACCOUNT. The family marker
        `<!-- completion-account-{ID} -->`, required on line 1 by the
        marker-write primitive's payload hygiene. Selecting by marker rather
        than by concatenating every comment matters: a concatenated read would
        let any unrelated comment on the issue supply the assertion.

        WHEN TWO CANDIDATES EXIST. The family is `upsert`, so exactly one
        should. If more than one is present the newest is returned and the
        collision is reported -- because the primitive's canonical selection
        is the EARLIEST comment id, a record planted before the run would
        otherwise be the one a reader retrieves and the one the run PATCHes.
        Disclosure is the settled mitigation, so both the winner's author and
        the collision are surfaced rather than silently resolved.
    .PARAMETER Comments
        Objects carrying at least `body`; `user.login` (or `author.login`) and
        `id` are used when present. The shape `gh issue view --json comments`
        returns.
    .PARAMETER Id
        Issue number, used to build the family marker.
    .OUTPUTS
        [PSCustomObject] the Read-CompletionAccount verdict, plus Found [bool],
        CandidateCount [int], and CommentId. Returns a Found=$false verdict
        rather than throwing when no account exists -- an issue with no
        completion account has not asserted a review.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Comments,
        [Parameter(Mandatory)][int]$Id
    )

    $marker = "<!-- completion-account-$Id -->"
    $candidates = @(
        $Comments | Where-Object {
            $null -ne $_ -and
            $_.PSObject.Properties.Match('body').Count -gt 0 -and
            ([string]$_.body) -like "*$marker*"
        }
    )

    if ($candidates.Count -eq 0) {
        $verdict = Read-CompletionAccount -Text ''
        return $verdict |
            Add-Member -NotePropertyName Found -NotePropertyValue $false -PassThru |
            Add-Member -NotePropertyName CandidateCount -NotePropertyValue 0 -PassThru |
            Add-Member -NotePropertyName CommentId -NotePropertyValue $null -PassThru
    }

    $chosen = $candidates[-1]
    $login = $null
    foreach ($path in @('user', 'author')) {
        if ($chosen.PSObject.Properties.Match($path).Count -gt 0 -and $null -ne $chosen.$path) {
            $u = $chosen.$path
            if ($u.PSObject.Properties.Match('login').Count -gt 0) { $login = [string]$u.login; break }
        }
    }

    $verdict = Read-CompletionAccount -Text ([string]$chosen.body) -PostedBy $login
    if ($candidates.Count -gt 1) {
        $verdict.Warnings = @($verdict.Warnings) + @(
            "This issue carries $($candidates.Count) comments bearing the completion-account marker, but the family is upsert and should carry one. The newest was read. A record planted before the run would be the primitive's canonical (earliest) match, so verify who posted each."
        )
    }

    $commentId = if ($chosen.PSObject.Properties.Match('id').Count -gt 0) { $chosen.id } else { $null }
    return $verdict |
        Add-Member -NotePropertyName Found -NotePropertyValue $true -PassThru |
        Add-Member -NotePropertyName CandidateCount -NotePropertyValue $candidates.Count -PassThru |
        Add-Member -NotePropertyName CommentId -NotePropertyValue $commentId -PassThru
}
