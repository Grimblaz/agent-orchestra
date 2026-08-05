#Requires -Version 7.0

# phase-containment-region-guard-core.ps1
# Issue #944 — the unattended half.
#
# WHY THIS IS SEPARATE FROM THE READER. Get-PhaseContainmentBlock answers
# "what did this body carry that I could not read", over a corpus of comments
# that were already posted. This answers a different question — "is the body
# somebody just wrote about to become another lost region" — and it answers it
# at a moment when a human can still fix it. The two now share their two
# load-bearing rules — a numeric id and an entry floor — and differ only in
# what each is FOR, which is stated at Find-MalformedPhaseContainmentRegion
# below. (An earlier revision of this line pointed at
# `Test-PhaseContainmentRegionIsReportable` for the rationale of a deliberate
# divergence; that function was never written, and the divergence it was meant
# to explain turned out to be the defect itself — the reader lacked the entry
# floor, so a prose mention flipped a clean surface to could-not-verify.
# PR #1006 review, M1 and M27.)
#
# SECURITY: no ConvertFrom-Yaml / powershell-yaml, same invariant as the
# reader it sits beside. Comment bodies are untrusted input.

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'phase-containment-core.ps1')

#region Find-MalformedPhaseContainmentRegion

function Find-MalformedPhaseContainmentRegion {
    <#
    .SYNOPSIS
        Reports every malformed-open phase-containment region in a body that a
        maintainer should act on.
    .DESCRIPTION
        Issue #944. The corpus reader is keyed to one ID at a time, because
        that is what its callers know. A guard watching a freshly-posted
        comment does not get to assume an ID: it has to find whatever region
        is there. So this scans for ANY numeric-id marker head and then
        decides, per occurrence, whether it is a lost emission or prose.

        THE THREE RULES, AND WHY EACH IS SEMANTIC RATHER THAN SYNTACTIC.
        Narrowing a guard by syntax rather than by meaning widens its
        exemption, usually in a direction nobody notices:

          1. NUMERIC ID ONLY. `<!-- phase-containment-{ID}` with a literal
             placeholder is a template, and templates are how this shape gets
             DOCUMENTED. No reader would ever match it, so it cannot be a lost
             emission. This single rule removes every quotation of the shape in
             this repository's own filing, brief and skills.
          2. IT MUST CARRY AT LEAST ONE ENTRY. A marker head followed by prose
             is discussion. A marker head followed by `finding_key:` and
             friends is an emission somebody meant to make. This is the rule
             that bounds the false-positive direction WITHOUT the fence-based
             exemption that would have blinded the guard to PR #810's real,
             fenced, lost regions.
          3. NOT INSIDE A YAML BLOCK SCALAR. The #863 M6 forgery class: text
             quoted inside a `rationale: |` scalar is string data. Reused from
             the reader rather than re-implemented, so the two cannot drift.

        WHAT IT DELIBERATELY DOES NOT DO. It does not check the id against the
        containing issue's number. A judge who posts a ledger region under the
        wrong id has made a different mistake, and one this guard has no
        standing to diagnose from the body alone; callers that DO know the
        container number can filter the result themselves.
    .PARAMETER Body
        The comment or file text to scan.
    .OUTPUTS
        Array of [PSCustomObject]@{ Id; Position; Line; EntryCount }.
        Empty array when the body is clean — which is the overwhelmingly
        common case and must stay cheap.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body
    )

    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()
    if ([string]::IsNullOrEmpty($Body)) { return , $findings.ToArray() }

    $blockScalarSpans = Get-BlockScalarSpans -Text $Body

    # Rule 1 lives in this pattern: `[0-9]+` accepts no placeholder. The
    # negative lookahead for '-->' is what makes this the MALFORMED half — a
    # self-closed head is the well-formed shape and is none of this guard's
    # business. `(?!ledger-)` keeps the sibling ledger sentinel family out.
    # The trailing exclusion accepts a hyphen ONLY when it opens the terminator
    # (PR #1006 review, M10): `[0-9A-Za-z_-]` treated the no-space shape as a
    # different id and skipped it silently, in a scanner whose entire job is to
    # stop that class from being silent.
    #
    # The well-formed exclusion is ONE SPACE, not `[ \t]*`. The reader matches
    # the literal `<!-- phase-containment-{id} -->` and nothing else, so any
    # other spacing — zero spaces, two spaces, a tab — is a head no reader can
    # match and therefore this guard's business. Writing it as `[ \t]*` excused
    # the zero-space shape, which is precisely the M10 variant.
    $pattern = '<!--[ \t]*phase-containment-(?!ledger-)(?<id>[0-9]+)(?![0-9A-Za-z_])(?!-(?!->))(?! -->)'

    foreach ($m in [regex]::Matches($Body, $pattern)) {
        if (Test-IndexInBlockScalarSpan -Index $m.Index -Spans $blockScalarSpans) { continue }

        $afterHead = $m.Index + $m.Length
        $terminator = $Body.IndexOf('-->', $afterHead, [System.StringComparison]::Ordinal)
        $regionEnd = if ($terminator -ge 0) { $terminator } else { $Body.Length }
        $regionText = $Body.Substring($afterHead, $regionEnd - $afterHead)

        # A head that closes immediately orphans its entries into the body
        # below; the extent is taken past that empty close so rule 2 can see
        # them. Mirrors Get-PhaseContainmentMalformedOpenRegion, which carries
        # the full rationale (PR #1006 review, M10).
        if ([string]::IsNullOrWhiteSpace($regionText) -and $terminator -ge 0) {
            $afterEmptyClose = $terminator + 3
            $nextTerminator = $Body.IndexOf('-->', $afterEmptyClose, [System.StringComparison]::Ordinal)
            $orphanEnd = if ($nextTerminator -ge 0) { $nextTerminator } else { $Body.Length }
            $regionText = $Body.Substring($afterEmptyClose, $orphanEnd - $afterEmptyClose)
        }

        $entryCount = Get-PhaseContainmentRegionEntryCount -RegionText $regionText
        if ($entryCount -lt 1) { continue }

        $line = 1 + @([regex]::Matches($Body.Substring(0, $m.Index), "`n")).Count

        # No excerpt field (PR #1006 review, M28). It carried 160 bytes of
        # untrusted body that nothing rendered -- dead weight that invites a
        # future edit to echo attacker-authored text into a posted comment.
        # The rendered advisory quotes nothing from the body: only the id
        # (digits), the line number, and the entry count.
        $findings.Add([PSCustomObject]@{
            Id         = $m.Groups['id'].Value
            Position   = $m.Index
            Line       = $line
            EntryCount = $entryCount
        })
    }

    return , $findings.ToArray()
}

#endregion

#region Format-MalformedRegionReport

function Format-MalformedRegionReport {
    <#
    .SYNOPSIS
        Renders the maintainer-facing message for a set of findings.
    .DESCRIPTION
        Names the shape, the count, and the remedy. A signal that only says
        "something is wrong here" costs the reader the same investigation the
        silence did — issue #944's own filing observed that the one advisory
        which DID fire went unread, so being loud is necessary and not
        sufficient. The remedy line names the documented write path, because
        every affected region in the corpus was hand-authored around it.
    .PARAMETER Findings
        Find-MalformedPhaseContainmentRegion output.
    .PARAMETER SourceLabel
        Where the body came from, for the message header.
    .OUTPUTS
        [string] the rendered report; empty string when there is nothing to say.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings,
        [Parameter(Mandatory)][string]$SourceLabel
    )

    if ($Findings.Count -eq 0) { return '' }

    $totalEntries = ($Findings | Measure-Object EntryCount -Sum).Sum
    $regionWord = if ($Findings.Count -eq 1) { 'region' } else { 'regions' }
    $entryWord = if ($totalEntries -eq 1) { 'entry' } else { 'entries' }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("**Unreadable phase-containment $regionWord detected** in $SourceLabel.")
    $lines.Add('')
    $regionVerb = if ($Findings.Count -eq 1) { 'opens' } else { 'open' }
    $regionPronoun = if ($Findings.Count -eq 1) { 'it' } else { 'them' }
    $lines.Add("$($Findings.Count) $regionWord here $regionVerb with a marker head that is **not** the self-closed form, so no reader will ever match $regionPronoun. $totalEntries ledger $entryWord would be silently invisible: not parsed, not counted, and not warned about, because the parser's malformed-block warnings only fire after an open tag has matched.")
    $lines.Add('')
    foreach ($f in $Findings) {
        # Single-quoted concatenation, not interpolation: in a double-quoted
        # PowerShell string the backtick is the ESCAPE character, so the
        # intended inline-code rendering was silently eaten and the suite's
        # -Match assertion could not see it (PR #1006 review, M26).
        $entryNoun = if ($f.EntryCount -eq 1) { 'entry' } else { 'entries' }
        $lines.Add('- line ' + $f.Line + ': a `phase-containment-' + $f.Id + '` region carrying ' + $f.EntryCount + ' ' + $entryNoun)
    }
    $lines.Add('')
    # THE EXEMPLARS USE A PLACEHOLDER ID, NOT A NUMBER (PR #1006 review, M2).
    # An earlier revision wrote a literal `123`, which made this advisory a
    # real malformed region for issue/PR #123 -- so the remedy manufactured the
    # defect class it detects, on any thread where the guard fired. A `{ID}`
    # placeholder is inert to both scanners by their shared numeric-id rule,
    # and it is the same hygiene the sibling report already applies through
    # Format-InertMarkerLabel.
    #
    # The `wrong:` exemplar is also rendered across LINES (M34). A single-line
    # version is a complete, well-formed HTML comment -- so the one example a
    # maintainer copies did not show the defect being described.
    $lines.Add('**The shape.** An open tag must be self-closed and paired with a closing tag:')
    $lines.Add('')
    $lines.Add('```text')
    $lines.Add('  wrong:                          right:')
    $lines.Add('    <!-- phase-containment-{ID}      <!-- phase-containment-{ID} -->')
    $lines.Add('    ...entries...                    ...one entry...')
    $lines.Add('    -->                              <!-- /phase-containment-{ID} -->')
    $lines.Add('```')
    $lines.Add('')
    $lines.Add('(`{ID}` stands in for the issue or PR number. It is written as a placeholder here on purpose: a real number would make this very comment another unreadable region.)')
    $lines.Add('')
    $lines.Add('One entry per block — the parser builds one flat mapping per block and has no YAML-sequence handling, so a multi-entry sequence in a single block parses as one last-wins entry with a null `finding_key`.')
    $lines.Add('')
    $lines.Add('**The fix.** Write through `skills/session-memory-contract/scripts/persist-phase-ledger.ps1`, the documented write path, which emits the paired form and refuses a malformed payload. Every region this guard exists for was hand-authored around it (issue #944).')

    return ($lines -join "`n")
}

#endregion
