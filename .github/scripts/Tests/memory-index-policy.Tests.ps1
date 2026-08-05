#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Regression suite for skills/agent-memory-compaction/scripts/Test-MemoryIndexPolicy.ps1.

.DESCRIPTION
    The check's whole value is that each axis can FAIL on the defect it names. A one-time
    manual control run cannot hold that property across later edits, so every axis here is
    exercised against a modified copy, never against an expectation.

    Each defect case is paired with the conforming control that isolates it: the case and the
    control differ by exactly the planted defect, so a test that passes because the fixture is
    malformed in some other way fails its control.
#>

Describe 'Test-MemoryIndexPolicy' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:Core = Join-Path $script:RepoRoot 'skills/agent-memory-compaction/scripts/lib/memory-index-policy-core.ps1'
        $script:Skill = Join-Path $script:RepoRoot 'skills/agent-memory-compaction/SKILL.md'
        . $script:Core
        $script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ("mip-tests-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:Work -Force | Out-Null

        # The canonical policy text, read the same way the check reads it.
        $refLines = @([System.IO.File]::ReadAllLines($script:Skill))
        $b = -1; $e = -1
        for ($i = 0; $i -lt $refLines.Count; $i++) {
            if ($b -lt 0 -and $refLines[$i].Trim() -eq '<!-- policy-canonical-begin -->') { $b = $i; continue }
            if ($b -ge 0 -and $e -lt 0 -and $refLines[$i].Trim() -eq '<!-- policy-canonical-end -->') { $e = $i }
        }
        $script:CanonicalLines = @($refLines[($b + 1)..($e - 1)] | ForEach-Object { $_.TrimEnd() }) |
            Where-Object { $true }
        while ($script:CanonicalLines[0] -eq '') { $script:CanonicalLines = $script:CanonicalLines[1..($script:CanonicalLines.Count - 1)] }
        while ($script:CanonicalLines[-1] -eq '') { $script:CanonicalLines = $script:CanonicalLines[0..($script:CanonicalLines.Count - 2)] }

        # Build an index file: policy header, a section heading, then the supplied body lines.
        function script:New-Index {
            param([string[]]$Body, [string[]]$Header = $null, [string]$Name = $null)

            if ($null -eq $Header) { $Header = $script:CanonicalLines }
            if ([string]::IsNullOrEmpty($Name)) { $Name = ([guid]::NewGuid().ToString('N').Substring(0, 10) + '.md') }
            $path = Join-Path $script:Work $Name
            [System.IO.File]::WriteAllLines($path, (@($Header) + @('', '## Entries', '') + $Body))
            return $path
        }

        # In-process, per the repo's script-safety contract: dot-source the core and call it
        # directly rather than spawning a child shell per test.
        function script:Invoke-Check {
            param([string]$IndexPath, [string]$ReferencePath = $null, [switch]$AsJson)

            $report = Invoke-MemoryIndexPolicyCheck -IndexPath $IndexPath -PolicyReferencePath $ReferencePath
            $rendered = Format-MemoryIndexPolicyReport -Report $report -AsJson:$AsJson
            return [pscustomobject]@{ Text = ($rendered | Out-String); Code = $report.ExitCode; Report = $report }
        }

        # A body that conforms: two subjects, each with its own clause.
        $script:ConformingBody = @(
            '- [alpha](reference_alpha_lesson.md) — a stale read wins the race and silently drops the write',
            '- [beta](project_beta_thing.md) — the retry cap is three, not unlimited'
        )
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:Work) { Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Context 'the conforming control' {
        It 'reports clean and exits 0' {
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $script:ConformingBody)
            $r.Text | Should -Match 'RESULT: clean'
            $r.Code | Should -Be 0
        }
    }

    Context 'header axis' {
        It 'reports absent when the header is removed' {
            $path = script:New-Index -Body $script:ConformingBody -Header @('# Some other file')
            $r = script:Invoke-Check -IndexPath $path
            $r.Text | Should -Match 'header: absent'
            $r.Code | Should -Be 1
        }

        It 'reports INCOMPLETE for a case-only divergence rather than clean' {
            # Regression: -eq is case-insensitive in PowerShell, so this once reported complete.
            $header = @($script:CanonicalLines)
            $idx = [array]::IndexOf($header, ($header | Where-Object { $_ -match 'COMPACTION POLICY' } | Select-Object -First 1))
            $header[$idx] = $header[$idx].Replace('COMPACTION POLICY', 'compaction policy')
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $script:ConformingBody -Header $header)
            $r.Text | Should -Match 'header: present, INCOMPLETE'
            $r.Code | Should -Be 1
        }

        It 'reports a present-but-edited first line as INCOMPLETE with a divergence, not as absent' {
            $header = @($script:CanonicalLines)
            $header[0] = $header[0].Replace('—', '-')
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $script:ConformingBody -Header $header)
            $r.Text | Should -Match 'header: present, INCOMPLETE'
            $r.Text | Should -Match 'first divergence at header line'
        }

        It 'names a pointer line sitting inside the header region' {
            $header = @($script:CanonicalLines) + @('', '- [gamma](reference_gamma_lesson.md) — a clause')
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $script:ConformingBody -Header $header)
            $r.Text | Should -Match 'pointer line sits inside the header region'
            $r.Code | Should -Be 1
        }

        It 'refuses a reference copy whose canonical block carries a section heading' {
            # Regression: both surfaces were once delimited by the same '## ' token, so promoting
            # a heading inside the policy shrank the compared region on both sides at once and
            # still reported complete.
            $ref = Join-Path $script:Work 'ref-with-heading.md'
            $body = @('<!-- policy-canonical-begin -->', '**HEADER**', '', '## Promoted heading', 'text `project_` more',
                '<!-- policy-canonical-end -->', '', '## Adapting this to your store (not part of the compared text)', 'note')
            [System.IO.File]::WriteAllLines($ref, $body)
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $script:ConformingBody) -ReferencePath $ref
            $r.Text | Should -Match 'section heading'
            $r.Code | Should -Be 2
        }

        It 'refuses a reference copy with no canonical markers' {
            $ref = Join-Path $script:Work 'ref-no-markers.md'
            [System.IO.File]::WriteAllLines($ref, @('# Nothing here', 'no markers'))
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $script:ConformingBody) -ReferencePath $ref
            $r.Text | Should -Match 'malformed'
            $r.Code | Should -Be 2
        }
    }

    Context 'hook axis' {
        It 'counts a bare title whose every word is already in the filename' {
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body @('- [alpha lesson](reference_alpha_lesson.md)'))
            $r.Text | Should -Match 'subjects_without_hook: 1'
            $r.Text | Should -Match 'bare title'
            $r.Code | Should -Be 1
        }

        It 'rejects generic filler sitting in the LINK TEXT, not only in a clause' {
            # Regression: the filler set was applied only to trailing clauses, so a pointer whose
            # link text was literally "see body" reported clean.
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body @('- [see body](reference_alpha_lesson.md)'))
            $r.Text | Should -Match 'subjects_without_hook: 1'
            $r.Code | Should -Be 1
        }

        It 'rejects a generic-filler clause' {
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body @('- [alpha lesson](reference_alpha_lesson.md) — see body'))
            $r.Text | Should -Match 'subjects_without_hook: 1'
        }

        It 'rejects "N/A" as a clause, not only the bare spelling "na"' {
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body @('- [alpha lesson](reference_alpha_lesson.md) — N/A'))
            $r.Text | Should -Match 'subjects_without_hook: 1'
        }

        It 'does not accept a punctuation-only clause as a hook' {
            # Regression: emptiness was tested on the raw clause, so "**" and "." counted.
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body @('- **[alpha lesson](reference_alpha_lesson.md)**'))
            $r.Text | Should -Match 'subjects_without_hook: 1'
        }

        It 'still credits link text that states the lesson when a filler clause trails it' {
            # Regression: R1 is disjunctive, but the branches were exclusive, so a filler clause
            # suppressed the link-text path and flagged a conforming subject.
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body @('- [a stale read silently drops the write](reference_alpha_lesson.md) — see body'))
            $r.Text | Should -Match 'subjects_without_hook: 0'
        }

        It 'treats hyphen and apostrophe splits as the same words as the filename' {
            # Regression: "pre-existing" tokenized to pre+existing and never matched "preexisting",
            # so a textbook bare title passed.
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body @('- [pre-existing](reference_preexisting.md)'))
            $r.Text | Should -Match 'subjects_without_hook: 1'
            $r.Code | Should -Be 1
        }

        It 'credits a clause that sits BETWEEN two links to the link it follows' {
            # Regression: the clause was read only after the LAST link on a line, so the first
            # subject was reported bare and the second subject's own clause was reported as a
            # shared note.
            $body = @('- [alpha](reference_alpha_lesson.md) — a stale read drops the write, [beta](project_beta_thing.md) — the retry cap is three')
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $body)
            $r.Text | Should -Match 'subjects_without_hook: 0'
            $r.Text | Should -Match 'unattributed_shared_notes: 0'
            $r.Code | Should -Be 0
        }
    }

    Context 'shared-note axis' {
        It 'counts one trailing note over a run of bare subjects' {
            $body = @('- [reference alpha lesson](reference_alpha_lesson.md) [reference beta lesson](reference_beta_lesson.md) — one note covering both of them')
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $body)
            $r.Text | Should -Match 'unattributed_shared_notes: 1'
            $r.Code | Should -Be 1
        }

        It 'counts one LEADING note over a run of bare subjects' {
            $body = @('- These three runs all died on the same trigger-shaped mistake: [reference alpha lesson](reference_alpha_lesson.md), [reference beta lesson](reference_beta_lesson.md)')
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $body)
            $r.Text | Should -Match 'unattributed_shared_notes: 1'
        }

        It 'does NOT flag a grouped line whose subjects each carry their own hook' {
            # Regression: keyed on missing clauses rather than missing hooks, this fired on a
            # conforming grouped line - the shape the chunked-delivery brief carves out.
            $body = @('- Topic: [a stale read drops the write](reference_alpha_lesson.md) · [merge base predates both](reference_beta_lesson.md) · [the retry cap is three](project_beta_thing.md) — and that cap is not configurable')
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $body)
            $r.Text | Should -Match 'unattributed_shared_notes: 0'
        }

        It 'does not treat a short topic label as a note' {
            $body = @('- Git/CI truth: [reference alpha lesson](reference_alpha_lesson.md) [reference beta lesson](reference_beta_lesson.md)')
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $body)
            $r.Text | Should -Match 'unattributed_shared_notes: 0'
        }
    }

    Context 'scope: nothing is judged silently' {
        It 'judges pointers on * and + and numbered bullets, not only on -' {
            # Regression: the gate was '^\s*-\s', so eight bare '*' pointers reported clean.
            $body = @(
                '- [alpha](reference_alpha_lesson.md) — a stale read drops the write',
                '* [reference beta lesson](reference_beta_lesson.md)',
                '+ [reference gamma lesson](reference_gamma_lesson.md)',
                '1. [reference delta lesson](reference_delta_lesson.md)'
            )
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $body)
            $r.Text | Should -Match 'subjects_without_hook: 3'
            $r.Code | Should -Be 1
        }

        It 'parses and judges anchored, titled and uppercase-extension targets' {
            # Regression: the target pattern rejected these, and a rejected link was dropped
            # silently - not counted, not reported, not refused.
            $body = @(
                '- [alpha](reference_alpha_lesson.md) — a stale read drops the write',
                '- [reference beta lesson](reference_beta_lesson.md#top)',
                '- [reference gamma lesson](reference_gamma_lesson.md "a title")',
                '- [reference delta lesson](reference_delta_lesson.MD)'
            )
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $body)
            $r.Text | Should -Match 'subjects_without_hook: 3'
        }

        It 'refuses when a link-like construct cannot be parsed' {
            $body = @(
                '- [alpha](reference_alpha_lesson.md) — a stale read drops the write',
                '- [beta](my notes/reference_beta_lesson.md)'
            )
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $body)
            $r.Text | Should -Match 'could not be parsed'
            $r.Code | Should -Be 2
        }

        It 'refuses an index with no section heading' {
            $path = Join-Path $script:Work ('nosection-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.md')
            [System.IO.File]::WriteAllLines($path, @('- [alpha](reference_alpha_lesson.md) — a clause here'))
            $r = script:Invoke-Check -IndexPath $path
            $r.Text | Should -Match 'structure not recognized'
            $r.Code | Should -Be 2
        }

        It 'refuses an index with no pointer line' {
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body @('Just prose, no pointers.'))
            $r.Text | Should -Match 'structure not recognized'
            $r.Code | Should -Be 2
        }
    }

    Context 'entry-kind vocabulary' {
        It 'refuses when no entry matches any kind the policy names' {
            $body = @('- [note one](zz-note-one.md) — a clause', '- [note two](zz-note-two.md) — another clause')
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $body)
            $r.Text | Should -Match 'entry-kind vocabulary not recognized'
            $r.Code | Should -Be 2
        }

        It 'discloses how many subjects carry none of the named prefixes' {
            $body = @(
                '- [alpha](reference_alpha_lesson.md) — a stale read drops the write',
                '- [note one](zz-note-one.md) — a clause of its own'
            )
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $body)
            $r.Text | Should -Match 'matched 1 of 2 linked subjects'
            $r.Text | Should -Match 'carry none of those prefixes'
        }

        It 'reads the kind vocabulary from an adapted index header rather than the reference' {
            # Regression: the vocabulary came only from the reference, so a store that adapted
            # its policy text exactly as the adapt-note instructs was refused and told to adapt.
            $header = @($script:CanonicalLines) | ForEach-Object {
                $_ -replace '`reference_`', '`lesson_`' -replace '`feedback_`', '`howto_`' -replace '`project_`', '`task_`' -replace '`user_`', '`me_`'
            }
            $body = @('- [alpha](lesson_alpha_thing.md) — a stale read drops the write', '- [beta](task_beta_thing.md) — the retry cap is three')
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $body -Header $header)
            $r.Text | Should -Not -Match 'entry-kind vocabulary not recognized'
            $r.Text | Should -Match 'read from the index header'
        }
    }

    Context 'output contract' {
        It 'emits JSON on the clean path' {
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $script:ConformingBody) -AsJson
            { $r.Text | ConvertFrom-Json } | Should -Not -Throw
            ($r.Text | ConvertFrom-Json).result | Should -Be 'clean'
        }

        It 'emits JSON on the refusal path' {
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body @('Just prose, no pointers.')) -AsJson
            ($r.Text | ConvertFrom-Json).result | Should -Be 'refused'
            $r.Code | Should -Be 2
        }

        It 'emits JSON on the usage-error path' {
            # Regression: the exit-3 branch wrote plain text before -Json was consulted.
            $r = script:Invoke-Check -IndexPath (Join-Path $script:Work 'does-not-exist.md') -AsJson
            ($r.Text | ConvertFrom-Json).result | Should -Be 'usage-error'
            $r.Code | Should -Be 3
        }

        It 'returns the report as data, not only as host output' {
            # Regression: the report was written with Write-Host, so an in-process caller
            # captured an empty string.
            $r = script:Invoke-Check -IndexPath (script:New-Index -Body $script:ConformingBody)
            $r.Report.Result | Should -Be 'clean'
            $r.Report.SubjectsWithoutHook | Should -Be 0
            $r.Text | Should -Match 'RESULT: clean'
        }

        It 'refuses rather than reporting defects when the index cannot be read' -Skip:(-not $IsWindows) {
            # Regression: an IO failure fell through to exit 1, the code the contract documents
            # as "defects found". Windows-only: the lock is not advisory there.
            $path = script:New-Index -Body $script:ConformingBody
            $stream = [System.IO.File]::Open($path, 'Open', 'Read', 'None')
            try { $r = script:Invoke-Check -IndexPath $path } finally { $stream.Dispose() }
            $r.Code | Should -Be 2
            $r.Text | Should -Match 'could not be read'
        }
    }
}
