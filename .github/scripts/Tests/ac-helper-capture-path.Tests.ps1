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
    structurally blind to this entire defect class. Measured at 18a28ba against a
    10-line probe body, and re-measured on this branch against $script:BodyPopulated
    below, which is 15 lines:

        harness                        18a28ba probe        BodyPopulated (this file)
        in-process function mock       String   count=1     String    count=1   (false green)
        script-file stand-in, one str  String   count=1     String    count=1   (false green)
        native PATH shim (this file)   Object[] count=10    Object[]  count=15  (reproduces)

    The counts differ because the bodies differ; the TYPE is the invariant. The
    second row matters: the established -GhCliPath injection pattern used
    elsewhere in this suite is a script file returning one string, so COPYING THE
    GOOD PATTERN is the second way to get a false green here.

    The discriminating property is that the body must reach the helper AS MULTIPLE
    OBJECTS — the shape every real external process produces. This file gets that
    with a native shim on PATH (gh.cmd on Windows, an executable gh script
    elsewhere).

    Test-HarnessShape asserts BOTH halves — the multi-object shape AND a
    fixture-only sentinel string. The sentinel is load-bearing: the fixtures use a
    real issue number in this repository, and a real authenticated `gh` answering
    instead of the shim also returns Object[] with count > 1, so a shape-only check
    would report green on an unresolved shim (measured: real #977 -> Object[],
    count=145). Shape alone cannot tell "my shim ran" from "the real gh ran".

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
    #
    # Line 1 of every fixture carries $script:Sentinel. No real issue body
    # contains it, so its presence in a capture proves the SHIM answered rather
    # than a real `gh` — see Test-HarnessShape.
    # -----------------------------------------------------------------------

    $script:Sentinel = 'AC-HELPER-FIXTURE-SENTINEL-977'

    # Populated: an identifier BEFORE the AC section (line 2), one INSIDE it,
    # and one AFTER it. Only the inside one may ever be returned.
    $script:BodyPopulated = @'
Parent: #709 AC-HELPER-FIXTURE-SENTINEL-977
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
Parent: #709 AC-HELPER-FIXTURE-SENTINEL-977
Line two names `skills/portfolio-tracker/SKILL.md` and nothing declares criteria.

## Problem

Nothing here declares `docs/other.md` as a criterion.
'@

    $script:BodySingleLine = 'Parent: #709 AC-HELPER-FIXTURE-SENTINEL-977 with `docs/single.md` and no sections.'

    # Exactly ONE backticked path inside the acceptance-criteria section. This is
    # the newly COMMON shape after the fix (most issues declare one identifier),
    # and it is the shape where a one-element array unrolls to a bare scalar.
    $script:BodyOneResult = @'
Parent: #709 AC-HELPER-FIXTURE-SENTINEL-977
Line two names `skills/portfolio-tracker/SKILL.md`, outside every section.

## Acceptance criteria

- [ ] the loader must read `skills/review-judgment/SKILL.md`
'@

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
        # post-merge-cleanup-squash-merge.Tests.ps1, which is selected by
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
        if (-not $IsWindows) {
            & chmod +x $shPath 2>&1 | Out-Null
            # A silent chmod failure leaves the POSIX shim unexecutable, `gh`
            # falls through to whatever is next on PATH, and the fixture quietly
            # means something else. CI (ubuntu-latest) is the branch that runs
            # this, so fail here rather than three assertions later.
            if ($LASTEXITCODE -ne 0) {
                throw "New-GhShim: chmod +x failed (exit $LASTEXITCODE) on $shPath — the POSIX shim would not be executable and the real gh would answer instead."
            }
        }

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

    # Run a scriptblock with NO gh resolvable anywhere on PATH. This is the
    # genuinely-UNAVAILABLE case, which is NOT the same as a gh that exists and
    # exits non-zero: an unresolvable command throws CommandNotFoundException
    # from PowerShell's own lookup, before any process starts, and `2>$null`
    # cannot suppress it.
    function script:Invoke-WithNoGh {
        param([scriptblock]$Body)

        $emptyDir = Join-Path $TestDrive 'no-gh-here'
        New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null

        $saved = $env:PATH
        $env:PATH = $emptyDir
        try { & $Body }
        finally { $env:PATH = $saved }
    }

    # C2 self-check: report what the harness actually hands the helper, AND
    # whether the answer came from the shim rather than a real gh.
    function script:Test-HarnessShape {
        param([string]$ShimDir)

        return script:Invoke-WithGhShim -ShimDir $ShimDir -Body {
            $captured = gh issue view 977 --json body --jq '.body' 2>$null
            [PSCustomObject]@{
                TypeName    = if ($null -eq $captured) { '<null>' } else { $captured.GetType().FullName }
                Count       = @($captured).Count
                HasSentinel = (@($captured) -join "`n").Contains($script:Sentinel)
            }
        }
    }

    $script:ShimPopulated = script:New-GhShim -Body $script:BodyPopulated -Dir (Join-Path $TestDrive 'shim-populated')
    $script:ShimNoAc = script:New-GhShim -Body $script:BodyNoAcSection -Dir (Join-Path $TestDrive 'shim-noac')
    $script:ShimOneResult = script:New-GhShim -Body $script:BodyOneResult -Dir (Join-Path $TestDrive 'shim-oneresult')

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

    It 'proves the SHIM answered, not a real gh, via a fixture-only sentinel' {
        $shape = script:Test-HarnessShape -ShimDir $script:ShimPopulated

        # Shape alone cannot discriminate. The fixtures use issue number 977,
        # which exists in this repository: a real authenticated gh returns
        # Object[] with count=145 for it, passing both assertions above on a
        # shim that never resolved. Only the sentinel distinguishes them.
        $shape.HasSentinel | Should -BeTrue `
            -Because 'no real issue body contains this string, so its absence means the PATH shim was bypassed and the assertions in this file are measuring the wrong thing'
    }

    It 'hands the no-AC-section body to the helper as multiple objects too, and from the shim' {
        $shape = script:Test-HarnessShape -ShimDir $script:ShimNoAc
        $shape.TypeName | Should -BeExactly 'System.Object[]'
        $shape.Count | Should -BeGreaterThan 1
        $shape.HasSentinel | Should -BeTrue
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

        # The third term on the SAME line as `triage`. `is_behavioral` is decided
        # ONCE PER LINE and applied to every token on it, so this path-shaped
        # term inherits high confidence purely because the word "must" appears
        # elsewhere on its line — and high confidence alone reaches force-accept.
        # Pinning it here so the escalation is visible rather than incidental:
        # an earlier revision of this suite asserted two of the three terms and
        # left the over-escalated one unasserted. Whether per-line escalation is
        # the RIGHT semantics is out of scope for issue #977 and is carried by
        # the AC-term precision follow-up; this assertion only makes a change to
        # it break loudly here.
        ($terms | Where-Object { $_.term -ceq 'skills/review-judgment/SKILL.md' }).is_behavioral |
            Should -BeTrue -Because 'per-line escalation marks every token on a behavioral line, including this one'
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
    # input is exercised for both value and type.
    #
    # Read the type assertion honestly. `Should -Not -BeOfType [string]` FAILS on
    # a bare string, a one-element array, AND a two-element array, and PASSES only
    # on the AutomationNull that an empty `return @()` produces — measured, all
    # four shapes. So it does not distinguish "bare string" from "one-element
    # array" the way an earlier revision of this comment claimed. What it does is
    # pin that these three inputs produce the empty shape and nothing else, which
    # is the property C6 needs. The one-result shape, where a scalar genuinely
    # can come back, is covered separately below.

    $degenerate = @(
        @{ Name = 'a genuinely empty body'; Shim = 'empty' }
        @{ Name = 'a single-line body'; Shim = 'single' }
        # A gh that EXISTS and exits non-zero. Deliberately not called
        # "unavailable" — that is a different failure mode with a different
        # mechanism, and it gets its own tests below.
        @{ Name = 'a failing gh (exists, exits 1)'; Shim = 'gh-failure' }
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

    It 'a failing gh is distinguishable from a genuinely empty body via -Verbose' {
        # The return value is identical either way (@()) by contract — this
        # asserts the diagnostic that lets a maintainer tell them apart without
        # changing that contract.
        $vRefsFail = script:Invoke-WithGhShim -ShimDir $script:Shims['gh-failure'] -Body {
            Get-AcRefsFromIssue -IssueNumber '977' -Verbose 4>&1 | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] }
        }
        $vRefsEmpty = script:Invoke-WithGhShim -ShimDir $script:Shims['empty'] -Body {
            Get-AcRefsFromIssue -IssueNumber '977' -Verbose 4>&1 | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] }
        }

        (@($vRefsFail) -join ' ') | Should -Match 'exited' -Because 'a failing gh sets $LASTEXITCODE and should say so'
        @($vRefsEmpty).Count | Should -Be 0 -Because 'gh succeeding with a genuinely empty body is not a failure and should not claim to be one'

        # Get-AcTermsFromIssue carries the identical branch — pinned separately
        # since the two helpers' preambles are known-duplicated (issue #977's
        # own audit records this) and could drift independently.
        $vTermsFail = script:Invoke-WithGhShim -ShimDir $script:Shims['gh-failure'] -Body {
            Get-AcTermsFromIssue -IssueNumber '977' -Verbose 4>&1 | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] }
        }
        (@($vTermsFail) -join ' ') | Should -Match 'exited'
    }

    It 'the $LASTEXITCODE diagnostic tolerates an unset variable under StrictMode (in-process mock, no native process ran)' {
        # Every pre-existing test for these helpers substitutes gh as an
        # in-process PowerShell function — no native process runs, so
        # $LASTEXITCODE is never set. A bare reference to it under
        # Set-StrictMode -Version Latest throws, which the surrounding
        # try/catch silently converts to an empty return — turning a CORRECT
        # result into a false negative. That is the exact defect class #977
        # exists to close, self-inflicted by the diagnostic added in review.
        #
        # $LASTEXITCODE is process-global: once ANY native command runs
        # anywhere in this process, it stays set for the rest of the run —
        # every earlier It in this file has already run a native gh/chmod
        # shim, so a bare reference here would read that STALE leftover
        # value instead of throwing, and this test would pass whether or not
        # the bug is present. Reproduced live: 33/33 green with the
        # unguarded bare-reference version restored, in-process, before this
        # fix.
        #
        # Do NOT reach for a child `pwsh -File` process to dodge that —
        # script-safety-contract.Tests.ps1 forbids spawning child pwsh
        # processes in test files (issue #257: dot-source + in-process call
        # pattern only). `Remove-Variable -Scope Global` instead forces
        # $LASTEXITCODE back to a genuinely unset state in THIS process,
        # which reproduces the same condition without violating that
        # contract or paying its overhead.
        Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
        (Test-Path variable:global:LASTEXITCODE) | Should -BeFalse `
            -Because 'the removal must actually succeed, or this test silently reverts to probing a set variable and proves nothing'

        function global:gh {
            return "## Acceptance Criteria`n- must use ``skills/foo/bar.md``"
        }
        $result = $null
        $caught = $null
        try {
            try {
                Set-StrictMode -Version Latest
                $result = @(Get-AcRefsFromIssue -IssueNumber '1')
            }
            catch {
                $caught = $_
            }
            finally {
                Set-StrictMode -Off
            }
        }
        finally {
            Remove-Item Function:\gh -Force -ErrorAction SilentlyContinue
        }

        $caught | Should -BeNullOrEmpty -Because 'StrictMode + an in-process mock, with no prior native command in this process, must not throw'
        $result.Count | Should -Be 1 -Because 'and must not silently swallow a real result either'
        $result | Should -Contain 'skills/foo/bar.md'
    }

    Context 'gh genuinely UNAVAILABLE — a different mechanism from a failing gh' {

        # `2>$null` redirects the NATIVE PROCESS stderr. It cannot suppress
        # CommandNotFoundException, which PowerShell raises from its own command
        # lookup before any process starts. Both helpers document "empty on any
        # failure, so callers can pass the result straight to -AcRefs without
        # null checks", and no caller wraps them in try/catch — so an
        # unresolvable gh must not escape as a throw.
        #
        # The shim fixture above cannot cover this: it writes a gh that EXISTS
        # and exits 1. This context removes gh from PATH entirely.

        It 'the harness really does make gh unresolvable' {
            $found = script:Invoke-WithNoGh -Body {
                [bool](Get-Command gh -ErrorAction SilentlyContinue)
            }
            $found | Should -BeFalse `
                -Because 'if gh is still resolvable, the two tests below prove nothing'
        }

        It 'Get-AcRefsFromIssue returns empty instead of throwing when gh is unresolvable' {
            $raw = $null
            $caught = $null
            try {
                $raw = script:Invoke-WithNoGh -Body { Get-AcRefsFromIssue -IssueNumber '977' }
            }
            catch { $caught = $_ }

            $caught | Should -BeNullOrEmpty -Because 'the documented contract is empty-on-any-failure, and callers have no try/catch'
            @($raw).Count | Should -Be 0
        }

        It 'Get-AcTermsFromIssue returns empty instead of throwing when gh is unresolvable' {
            $raw = $null
            $caught = $null
            try {
                $raw = script:Invoke-WithNoGh -Body { Get-AcTermsFromIssue -IssueNumber '977' -WarningAction SilentlyContinue }
            }
            catch { $caught = $_ }

            $caught | Should -BeNullOrEmpty
            @($raw).Count | Should -Be 0
        }

        It 'the statement AFTER the helper call still executes' {
            # The observable that actually matters to a caller. Before the fix
            # this never ran: the throw took out the whole statement sequence.
            $reached = script:Invoke-WithNoGh -Body {
                $null = Get-AcRefsFromIssue -IssueNumber '977'
                'reached'
            }
            $reached | Should -BeExactly 'reached'
        }
    }

    Context 'the ONE-RESULT shape — newly the common case after the fix' {

        # An AC section declaring exactly one backticked identifier returns a
        # BARE SCALAR, not a one-element array, because PowerShell unrolls
        # `return @($x)`. Pre-fix this shape was unreachable (every real issue
        # returned empty); post-fix it is what most issues produce. The
        # degenerate-input assertions above cannot see it — they only ever run
        # against the empty shape.

        It 'Get-AcRefsFromIssue returns a bare string for a single result' {
            $raw = script:Invoke-WithGhShim -ShimDir $script:ShimOneResult -Body {
                Get-AcRefsFromIssue -IssueNumber '977'
            }
            $raw | Should -BeOfType [string] `
                -Because 'the docstring records this exactly: one result unrolls to a scalar, so callers that index or type-check must wrap in @()'
            @($raw).Count | Should -Be 1
            @($raw)[0] | Should -BeExactly 'skills/review-judgment/SKILL.md'
        }

        It 'the single-result shape still binds correctly through Get-StructuralVerdict' {
            # The property that makes the scalar harmless: the consumer declares
            # [string[]] and coerces. Asserted through the consumer, not by
            # inspecting the helper, because the consumer is where it matters.
            $refs = script:Invoke-WithGhShim -ShimDir $script:ShimOneResult -Body {
                Get-AcRefsFromIssue -IssueNumber '977'
            }

            $result = Get-StructuralVerdict `
                -Finding @{ id = 'F7'; text = 'Loader change.'; files = @('skills/review-judgment/SKILL.md') } `
                -PrFileSet @() `
                -AcRefs $refs `
                -AcTerms @() `
                -RepoRoot $script:RepoRoot

            $result.ac_cross_check.file_arm | Should -BeTrue
            $result.ac_cross_check.routed | Should -BeExactly 'force-accept'
        }

        It 'a single result does NOT include the line-2 token' {
            $raw = script:Invoke-WithGhShim -ShimDir $script:ShimOneResult -Body {
                @(Get-AcRefsFromIssue -IssueNumber '977')
            }
            $raw | Should -Not -Contain 'skills/portfolio-tracker/SKILL.md'
            @($raw).Count | Should -Be 1
        }
    }
}
