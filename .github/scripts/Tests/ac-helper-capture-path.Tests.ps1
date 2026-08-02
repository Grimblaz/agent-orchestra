#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Regression proof for issue #977 — AC extraction must read the acceptance-criteria
    section, not the second line of the issue body.

.DESCRIPTION
    Get-AcRefsFromIssue and Get-AcTermsFromIssue capture the issue body with
    `gh issue view N --json body --jq '.body'`. That command emits RAW MULTI-LINE
    TEXT, and PowerShell captures multi-line external-process stdout as
    [System.Object[]] — one element per line. `-split` over an array is vectorized,
    so the acceptance-criteria section was never isolated: `$parts[1]` was the
    SECOND LINE of the body, and the `Count -lt 2` guard (with its warning) never
    fired. The observable symptom was empty results, but the mechanism is a WRONG
    INPUT, which can also fabricate a match when line 2 happens to carry a token.

    WHY THIS FILE EXISTS SEPARATELY FROM Get-AcTermsFromIssue.Tests.ps1
    ------------------------------------------------------------------
    Every pre-existing test for these helpers substitutes `gh` with an IN-PROCESS
    PowerShell function. A function returns exactly one string object, so the
    captured body is a [String] with count 1 — which is what a CORRECTLY captured
    body looks like. Those tests therefore pass against the broken code and are
    structurally blind to this entire defect class. Measured at 18a28ba and again
    on this branch, against the same body:

        in-process function mock      -> System.String   count=1   (false green)
        script-file stand-in, one str -> System.String   count=1   (false green)
        native PATH shim (this file)  -> System.Object[] count=10  (reproduces)

    The second row matters: the established -GhCliPath injection pattern used
    elsewhere in this suite is a script file returning one string, so COPYING THE
    GOOD PATTERN is the second way to get a false green here.

    The discriminating property is that the body must reach the helper AS MULTIPLE
    OBJECTS — the shape every real external process produces. This file gets that
    with a native shim on PATH (gh.cmd on Windows, an executable gh script
    elsewhere). Test-HarnessShape below ASSERTS that property rather than assuming
    it, so a shim that silently stops being resolved fails loudly instead of
    reporting green.

    Do not rewrite these tests to use Mock gh or a local function named gh. That
    substitution is exactly how the defect shipped and survived a 27-test suite.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

    . (Join-Path $script:RepoRoot 'skills/review-judgment/scripts/Get-AcRefsFromIssue.ps1')
    . (Join-Path $script:RepoRoot 'skills/review-judgment/scripts/Get-AcTermsFromIssue.ps1')
    . (Join-Path $script:RepoRoot 'skills/review-judgment/scripts/Test-DeferralCriteria.ps1')

    # -----------------------------------------------------------------------
    # Fixtures. Line 2 of each body deliberately carries a backtick-quoted
    # identifier: that is the line the broken code read.
    # -----------------------------------------------------------------------

    # Populated: an identifier BEFORE the AC section (line 2), one INSIDE it,
    # and one AFTER it. Only the inside one may ever be returned.
    $script:BodyPopulated = @'
Parent: #709
Line two names `skills/portfolio-tracker/SKILL.md`, outside every section.

## Problem

The renderer drops `docs/problem-only.md` references.

## Acceptance criteria

- [ ] the renderer must fetch `triage`-labeled issues declared in `skills/review-judgment/SKILL.md`
- [ ] the `cost-walker` summary is recorded in the ledger

## Provenance

Found while reading `docs/provenance-only.md`.
'@

    # No acceptance-criteria section at all, but line 2 carries a backticked path.
    # A helper still reading line 2 returns that path here; a fixed helper returns
    # nothing. This is the case that discriminates.
    $script:BodyNoAcSection = @'
Parent: #709
Line two names `skills/portfolio-tracker/SKILL.md` and nothing declares criteria.

## Problem

Nothing here declares `docs/other.md` as a criterion.
'@

    $script:BodySingleLine = 'Parent: #709 with `docs/single.md` and no sections.'

    # -----------------------------------------------------------------------
    # Native gh shim. Emits the fixture body from a real external process, so
    # PowerShell captures it the same way it captures the real gh.
    # -----------------------------------------------------------------------
    function script:New-GhShim {
        param(
            [string]$Body,
            [string]$Dir,
            [switch]$FailExit
        )

        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $bodyPath = Join-Path $Dir 'issue-body.md'
        Set-Content -LiteralPath $bodyPath -Value $Body -Encoding utf8NoBOM -NoNewline

        $cmdPath = Join-Path $Dir 'gh.cmd'
        $shPath = Join-Path $Dir 'gh'

        # Windows resolves gh.cmd through PATHEXT. Linux resolves only an
        # extensionless executable named gh, so BOTH are written and the execute
        # bit is set on the POSIX one. Same shape as the gh shim in
        # post-merge-cleanup-squash-merge.Tests.ps1, which is registered in
        # pester.yml and green on the Linux runner. Issue #922 records what
        # happens when only the Windows half is written: Get-Command gh fails on
        # Linux and the fixture silently means something else there.
        if ($FailExit) {
            # gh unavailable or gh error: no stdout, non-zero exit.
            $cmdText = "@echo off`r`nexit /b 1`r`n"
            $shText = "#!/bin/sh`nexit 1`n"
        }
        else {
            $cmdText = "@echo off`r`ntype `"$($bodyPath -replace '/', '\')`"`r`n"
            $shText = "#!/bin/sh`ncat `"$bodyPath`"`n"
        }

        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($cmdPath, $cmdText, $utf8NoBom)
        [System.IO.File]::WriteAllText($shPath, $shText, $utf8NoBom)
        if (-not $IsWindows) { & chmod +x $shPath 2>&1 | Out-Null }

        return $Dir
    }

    # Run a scriptblock with the shim directory first on PATH.
    function script:Invoke-WithGhShim {
        param([string]$ShimDir, [scriptblock]$Body)

        $saved = $env:PATH
        $env:PATH = $ShimDir + [System.IO.Path]::PathSeparator + $saved
        try { & $Body }
        finally { $env:PATH = $saved }
    }

    # C2 self-check: report what the harness actually hands the helper.
    function script:Test-HarnessShape {
        param([string]$ShimDir)

        return script:Invoke-WithGhShim -ShimDir $ShimDir -Body {
            $captured = gh issue view 977 --json body --jq '.body' 2>$null
            [PSCustomObject]@{
                TypeName = if ($null -eq $captured) { '<null>' } else { $captured.GetType().FullName }
                Count    = @($captured).Count
            }
        }
    }

    $script:ShimPopulated = script:New-GhShim -Body $script:BodyPopulated -Dir (Join-Path $TestDrive 'shim-populated')
    $script:ShimNoAc = script:New-GhShim -Body $script:BodyNoAcSection -Dir (Join-Path $TestDrive 'shim-noac')

    # Keyed so the degenerate-input cases below can select one by name.
    $script:Shims = @{
        'empty'      = script:New-GhShim -Body '' -Dir (Join-Path $TestDrive 'shim-empty')
        'single'     = script:New-GhShim -Body $script:BodySingleLine -Dir (Join-Path $TestDrive 'shim-single')
        'gh-failure' = script:New-GhShim -Body '' -Dir (Join-Path $TestDrive 'shim-failed') -FailExit
    }
}

Describe 'C2 — the harness reproduces the input shape of the defect' {

    It 'hands the populated body to the helper as MULTIPLE OBJECTS, not one string' {
        $shape = script:Test-HarnessShape -ShimDir $script:ShimPopulated

        # This is the whole reason the file exists. A [String] here means the
        # harness has degraded into the shape that reports green against the
        # broken code, and every assertion below is worthless.
        $shape.TypeName | Should -BeExactly 'System.Object[]' `
            -Because 'a real external process yields one array element per line; a function or single-string stand-in yields System.String and cannot reproduce the defect'
        $shape.Count | Should -BeGreaterThan 1 `
            -Because 'the vectorized -split that is this defect only happens on a multi-element capture'
    }

    It 'hands the no-AC-section body to the helper as multiple objects too' {
        $shape = script:Test-HarnessShape -ShimDir $script:ShimNoAc
        $shape.TypeName | Should -BeExactly 'System.Object[]'
        $shape.Count | Should -BeGreaterThan 1
    }
}

Describe 'C1 — Get-AcRefsFromIssue is scoped to the acceptance-criteria section' {

    It 'POSITIVE: returns the path declared inside the AC section' {
        $refs = script:Invoke-WithGhShim -ShimDir $script:ShimPopulated -Body {
            @(Get-AcRefsFromIssue -IssueNumber '977')
        }
        $refs | Should -Contain 'skills/review-judgment/SKILL.md'
    }

    It 'POSITIVE: returns NO path that appears only outside the AC section' {
        $refs = script:Invoke-WithGhShim -ShimDir $script:ShimPopulated -Body {
            @(Get-AcRefsFromIssue -IssueNumber '977')
        }
        # Line 2 — what the broken helper returned.
        $refs | Should -Not -Contain 'skills/portfolio-tracker/SKILL.md'
        # An earlier H2 section.
        $refs | Should -Not -Contain 'docs/problem-only.md'
        # A later H2 section, past the section terminator.
        $refs | Should -Not -Contain 'docs/provenance-only.md'
        $refs.Count | Should -Be 1 -Because 'exactly one backticked path occurs inside the AC section'
    }

    It 'NEGATIVE: returns empty for a body with no AC section whose line 2 carries a backticked path' {
        $refs = script:Invoke-WithGhShim -ShimDir $script:ShimNoAc -Body {
            @(Get-AcRefsFromIssue -IssueNumber '977')
        }
        # Pre-fix this returned skills/portfolio-tracker/SKILL.md — a fabricated
        # AC reference that routes force-accept and overrides a deferral verdict.
        $refs.Count | Should -Be 0
    }
}

Describe 'C1 — Get-AcTermsFromIssue is scoped to the acceptance-criteria section' {

    It 'POSITIVE: returns the identifiers declared inside the AC section' {
        $terms = script:Invoke-WithGhShim -ShimDir $script:ShimPopulated -Body {
            @(Get-AcTermsFromIssue -IssueNumber '977')
        }
        $names = @($terms | ForEach-Object { $_.term })
        $names | Should -Contain 'triage'
        $names | Should -Contain 'cost-walker'
        $names | Should -Contain 'skills/review-judgment/SKILL.md'
    }

    It 'POSITIVE: returns NO identifier that appears only outside the AC section' {
        $terms = script:Invoke-WithGhShim -ShimDir $script:ShimPopulated -Body {
            @(Get-AcTermsFromIssue -IssueNumber '977')
        }
        $names = @($terms | ForEach-Object { $_.term })
        $names | Should -Not -Contain 'skills/portfolio-tracker/SKILL.md'
        $names | Should -Not -Contain 'docs/problem-only.md'
        $names | Should -Not -Contain 'docs/provenance-only.md'
        $names.Count | Should -Be 3
    }

    It 'POSITIVE: annotates the behavioral flag from the AC line the term was read from' {
        $terms = script:Invoke-WithGhShim -ShimDir $script:ShimPopulated -Body {
            @(Get-AcTermsFromIssue -IssueNumber '977')
        }
        ($terms | Where-Object { $_.term -ceq 'triage' }).is_behavioral | Should -BeTrue
        ($terms | Where-Object { $_.term -ceq 'cost-walker' }).is_behavioral | Should -BeFalse
    }

    It 'NEGATIVE: returns empty for a body with no AC section whose line 2 carries a backticked path' {
        $terms = script:Invoke-WithGhShim -ShimDir $script:ShimNoAc -Body {
            @(Get-AcTermsFromIssue -IssueNumber '977' -WarningAction SilentlyContinue)
        }
        $terms.Count | Should -Be 0
    }
}

Describe 'C3 — both cross-check arms are reachable through the production capture path' {

    BeforeAll {
        $script:AcRefsLive = script:Invoke-WithGhShim -ShimDir $script:ShimPopulated -Body {
            @(Get-AcRefsFromIssue -IssueNumber '977')
        }
        $script:AcTermsLive = script:Invoke-WithGhShim -ShimDir $script:ShimPopulated -Body {
            @(Get-AcTermsFromIssue -IssueNumber '977')
        }
    }

    It 'FILE ARM POSITIVE: a finding on an AC-declared file reaches force-accept on the file route alone' {
        $result = Get-StructuralVerdict `
            -Finding @{ id = 'F1'; text = 'The renderer drops labels.'; files = @('skills/review-judgment/SKILL.md') } `
            -PrFileSet @() `
            -AcRefs $script:AcRefsLive `
            -AcTerms @() `
            -RepoRoot $script:RepoRoot

        $result.ac_cross_check.file_arm | Should -BeTrue
        $result.ac_cross_check.routed | Should -BeExactly 'force-accept'
        $result.ac_cross_check.source | Should -Not -BeExactly 'no-ac-section'
    }

    It 'FILE ARM NEGATIVE: a finding on a file named only OUTSIDE the AC section does not reach force-accept' {
        $result = Get-StructuralVerdict `
            -Finding @{ id = 'F2'; text = 'The renderer drops labels.'; files = @('skills/portfolio-tracker/SKILL.md') } `
            -PrFileSet @() `
            -AcRefs $script:AcRefsLive `
            -AcTerms @() `
            -RepoRoot $script:RepoRoot

        $result.ac_cross_check.file_arm | Should -BeFalse
        $result.ac_cross_check.routed | Should -Not -BeExactly 'force-accept'
    }

    It 'TERM ARM POSITIVE: a finding naming a behavioral AC term reaches force-accept on the term route alone' {
        $result = Get-StructuralVerdict `
            -Finding @{ id = 'F3'; text = 'The triage fetch is not wired in the renderer.'; files = @() } `
            -PrFileSet @() `
            -AcRefs @() `
            -AcTerms $script:AcTermsLive `
            -RepoRoot $script:RepoRoot

        $result.ac_cross_check.term_arm | Should -BeTrue
        $result.ac_cross_check.routed | Should -BeExactly 'force-accept'
    }

    It 'TERM ARM NEGATIVE: a finding naming only text outside the AC section does not reach force-accept' {
        $result = Get-StructuralVerdict `
            -Finding @{ id = 'F4'; text = 'The portfolio-tracker renderer drops labels.'; files = @() } `
            -PrFileSet @() `
            -AcRefs @() `
            -AcTerms $script:AcTermsLive `
            -RepoRoot $script:RepoRoot

        $result.ac_cross_check.term_arm | Should -BeFalse
        $result.ac_cross_check.routed | Should -Not -BeExactly 'force-accept'
    }

    It 'the ambiguous arm is reachable: a non-behavioral AC term routes to disposition-gate' {
        $result = Get-StructuralVerdict `
            -Finding @{ id = 'F5'; text = 'The cost-walker summary is missing.'; files = @() } `
            -PrFileSet @() `
            -AcRefs @() `
            -AcTerms $script:AcTermsLive `
            -RepoRoot $script:RepoRoot

        $result.ac_cross_check.result | Should -BeExactly 'matched-ambiguous'
        $result.ac_cross_check.routed | Should -BeExactly 'disposition-gate'
    }
}

Describe 'C4 — the absent-section self-report is emitted again' {

    # Scoped to Get-AcTermsFromIssue on purpose. The two helpers are NOT
    # symmetric: Get-AcRefsFromIssue has never carried a warning of any kind,
    # and adding one is out of scope for issue #977.

    It 'WARNS when a non-empty body genuinely has no acceptance-criteria section' {
        $warnings = script:Invoke-WithGhShim -ShimDir $script:ShimNoAc -Body {
            $null = Get-AcTermsFromIssue -IssueNumber '977' -WarningVariable w -WarningAction SilentlyContinue
            @($w)
        }
        # Pre-fix this warning was unreachable for any multi-line body, because
        # the guard it sits behind never fired.
        @($warnings).Count | Should -BeGreaterThan 0
        ($warnings -join ' ') | Should -Match "No '## Acceptance Criteria' section found"
    }

    It 'stays SILENT when the acceptance-criteria section is present' {
        $warnings = script:Invoke-WithGhShim -ShimDir $script:ShimPopulated -Body {
            $null = Get-AcTermsFromIssue -IssueNumber '977' -WarningVariable w -WarningAction SilentlyContinue
            @($w)
        }
        @($warnings).Count | Should -Be 0 `
            -Because 'a warning that now fires unconditionally is not a repaired self-report'
    }
}

Describe 'C6 — the degenerate-input contract survives the join' {

    # Callers pass these results straight into Get-StructuralVerdict without null
    # checks. Joining changed what reaches the empty-guard, so each degenerate
    # input is exercised for TYPE as well as value: a bare string and a
    # one-element array read alike in most assertions and behave differently at
    # the call site.

    $degenerate = @(
        @{ Name = 'a genuinely empty body'; Shim = 'empty' }
        @{ Name = 'a single-line body'; Shim = 'single' }
        @{ Name = 'a failed or unavailable gh'; Shim = 'gh-failure' }
    )

    It 'Get-AcRefsFromIssue yields an empty array and does not throw for <Name>' -ForEach $degenerate {
        $shimDir = $script:Shims[$Shim]

        $raw = $null
        $caught = $null
        try {
            $raw = script:Invoke-WithGhShim -ShimDir $shimDir -Body {
                Get-AcRefsFromIssue -IssueNumber '977'
            }
        }
        catch { $caught = $_ }

        $caught | Should -BeNullOrEmpty -Because 'callers have no try/catch around this helper'
        $raw | Should -Not -BeOfType [string] -Because 'a bare string at the call site is silently treated as a one-element AcRefs list'
        @($raw).Count | Should -Be 0
    }

    It 'Get-AcTermsFromIssue yields an empty array and does not throw for <Name>' -ForEach $degenerate {
        $shimDir = $script:Shims[$Shim]

        $raw = $null
        $caught = $null
        try {
            $raw = script:Invoke-WithGhShim -ShimDir $shimDir -Body {
                Get-AcTermsFromIssue -IssueNumber '977' -WarningAction SilentlyContinue
            }
        }
        catch { $caught = $_ }

        $caught | Should -BeNullOrEmpty
        $raw | Should -Not -BeOfType [string]
        @($raw).Count | Should -Be 0
    }

    It 'a degenerate result is still accepted by Get-StructuralVerdict without a null check' {
        $refs = script:Invoke-WithGhShim -ShimDir $script:Shims['empty'] -Body {
            Get-AcRefsFromIssue -IssueNumber '977'
        }
        $terms = script:Invoke-WithGhShim -ShimDir $script:Shims['empty'] -Body {
            Get-AcTermsFromIssue -IssueNumber '977' -WarningAction SilentlyContinue
        }

        $result = Get-StructuralVerdict `
            -Finding @{ id = 'F6'; text = 'Anything.'; files = @('some/file.ps1') } `
            -PrFileSet @() `
            -AcRefs $refs `
            -AcTerms $terms `
            -RepoRoot $script:RepoRoot

        $result.ac_cross_check.source | Should -BeExactly 'no-ac-section'
        $result.ac_cross_check.routed | Should -BeExactly 'defer'
    }
}
