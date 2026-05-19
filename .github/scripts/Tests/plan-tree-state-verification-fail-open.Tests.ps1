#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#!
.SYNOPSIS
    Behavioral fail-open tests for issue #579 plan tree-state verification.

.DESCRIPTION
    Locks the warn-only contract for the future plan-tree-state-verification orchestrator.
    The orchestrator must accept inline plan markdown content or a plan path, emit warnings
    for malformed Verification Evidence blocks, and exit 0 for all parseable warn-mode cases.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:OrchestratorPath = Join-Path $script:RepoRoot '.github/scripts/plan-tree-state-verification.ps1'

    $script:InvokeOrchestrator = {
        param(
            [Parameter(Mandatory = $true)]
            [string]$PlanContent,

            [switch]$UsePlanPath,

            [int]$TimeoutSeconds = 30
        )

        $planPath = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N') + '.plan.md')
        Set-Content -Path $planPath -Value $PlanContent -Encoding UTF8

        $harnessPath = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N') + '.harness.ps1')
        $usePlanPathLiteral = if ($UsePlanPath) { '$true' } else { '$false' }

        $harness = @"
`$ErrorActionPreference = 'Continue'
`$WarningPreference = 'Continue'
`$orchestratorPath = '$($script:OrchestratorPath -replace "'", "''")'
`$planPath = '$($planPath -replace "'", "''")'
`$usePlanPath = $usePlanPathLiteral

if (-not (Test-Path -LiteralPath `$orchestratorPath -PathType Leaf)) {
    [Console]::Error.WriteLine("ORCHESTRATOR_NOT_FOUND: `$orchestratorPath")
    exit 127
}

if (`$usePlanPath) {
    & `$orchestratorPath -PlanPath `$planPath
} else {
    `$planContent = Get-Content -LiteralPath `$planPath -Raw
    & `$orchestratorPath -PlanContent `$planContent
}

if (`$null -eq `$global:LASTEXITCODE) {
    exit 0
}

exit `$global:LASTEXITCODE
"@
        Set-Content -Path $harnessPath -Value $harness -Encoding UTF8

        $stdoutPath = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N') + '.stdout.txt')
        $stderrPath = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N') + '.stderr.txt')

        $proc = Start-Process -FilePath 'pwsh' `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $harnessPath) `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -PassThru `
            -WindowStyle Hidden

        $waited = $proc.WaitForExit($TimeoutSeconds * 1000)
        if (-not $waited) {
            try { $proc.Kill($true) } catch { Write-Warning "Failed to kill timed-out orchestrator process: $($_.Exception.Message)" }

            return [pscustomobject]@{
                ExitCode = -1
                Stdout   = (Test-Path $stdoutPath) ? (Get-Content $stdoutPath -Raw) : ''
                Stderr   = (Test-Path $stderrPath) ? (Get-Content $stderrPath -Raw) : ''
                TimedOut = $true
            }
        }

        return [pscustomobject]@{
            ExitCode = $proc.ExitCode
            Stdout   = (Test-Path $stdoutPath) ? (Get-Content $stdoutPath -Raw) : ''
            Stderr   = (Test-Path $stderrPath) ? (Get-Content $stderrPath -Raw) : ''
            TimedOut = $false
        }
    }

    $script:AssertWarnOnlyExit = {
        param(
            [Parameter(Mandatory = $true)]
            [pscustomobject]$Result,

            [Parameter(Mandatory = $true)]
            [string]$Because
        )

        $combined = "$($Result.Stdout)`n$($Result.Stderr)"
        $Result.TimedOut | Should -Be $false -Because "the child orchestrator should complete promptly. Output: $combined"
        $Result.ExitCode | Should -Be 0 -Because "$Because Output: $combined"
    }

    $script:AssertWarningContains = {
        param(
            [Parameter(Mandatory = $true)]
            [pscustomobject]$Result,

            [Parameter(Mandatory = $true)]
            [string]$ExpectedWarning
        )

        $combined = "$($Result.Stdout)`n$($Result.Stderr)"
        $combined | Should -Match ([regex]::Escape($ExpectedWarning)) -Because "the warning stream should contain the expected plan verification warning. Output: $combined"
    }

    $script:AssertNoWarnings = {
        param(
            [Parameter(Mandatory = $true)]
            [pscustomobject]$Result
        )

        $combined = "$($Result.Stdout)`n$($Result.Stderr)"
        $combined | Should -Not -Match '(?im)^\s*WARNING:' -Because "category-shape-compliant evidence should not produce warnings. Output: $combined"
    }
}

Describe 'plan tree-state verification fail-open behavior (issue #579 AC5)' {

    It 'Complete Verification Evidence block with all rows category-shape-compliant emits no warnings and exits 0' {
        $plan = @'
## Plan

## Acceptance Criteria

- **AC1** (text-presence): load-bearing literal text exists.
- **AC2** (structure-presence): load-bearing heading exists.
- **AC3** (downstream-consumer): load-bearing consumer wiring exists.
- **AC4** (numeric-or-structural): load-bearing threshold is respected.
- **AC5** (named-standard): load-bearing named standard is cited.

<!-- verification-evidence -->
**Verification Evidence**

- **AC1** (text-presence): `rg "foo" target.md` -> found. **verified** - evidence: `target.md:12`.
- **AC2** (structure-presence): `grep "^## Heading" target.md` -> found. **verified** - evidence: `line 34`.
- **AC3** (downstream-consumer): consumer calls `Invoke-PlanThing()`. **verified** - evidence: `scripts/consumer.ps1:42`.
- **AC4** (numeric-or-structural): design D2 requires 5 items. **verified** - evidence: `#579` and `5 items`.
- **AC5** (named-standard): SMC-01 defines the durable marker standard. **verified** - evidence: `SMC-01`.
'@

        $result = & $script:InvokeOrchestrator -PlanContent $plan -UsePlanPath

        & $script:AssertWarnOnlyExit -Result $result -Because 'warn-only invariant: complete evidence must exit 0'
        & $script:AssertNoWarnings -Result $result
    }

    It 'Missing verification-evidence anchor warns that the Verification Evidence block is missing and exits 0' {
        $plan = @'
## Plan

## Acceptance Criteria

- **AC1** (text-presence): load-bearing literal text exists.

### Notes

This plan intentionally has no verification evidence anchor.
'@

        $result = & $script:InvokeOrchestrator -PlanContent $plan

        & $script:AssertWarnOnlyExit -Result $result -Because 'warn-only invariant: missing evidence block must exit 0'
        & $script:AssertWarningContains -Result $result -ExpectedWarning 'Verification Evidence block missing'
    }

    It 'Anchor present but Verification Evidence heading missing warns distinctly and exits 0' {
        $plan = @'
## Plan

## Acceptance Criteria

- **AC1** (text-presence): load-bearing literal text exists.

<!-- verification-evidence -->

- **AC1** (text-presence): `rg "foo" target.md` -> found. **verified** - evidence: `target.md:12`.
'@

        $result = & $script:InvokeOrchestrator -PlanContent $plan

        $combined = "$($result.Stdout)`n$($result.Stderr)"
        & $script:AssertWarnOnlyExit -Result $result -Because 'warn-only invariant: missing Verification Evidence heading must exit 0'
        & $script:AssertWarningContains -Result $result -ExpectedWarning 'Verification Evidence block anchor present but heading missing'
        $combined | Should -Not -Match ([regex]::Escape('Verification Evidence block missing')) -Because "the heading-specific failure should not collapse into the generic missing-block warning. Output: $combined"
    }

    It 'Block present but missing row for a load-bearing-flagged AC warns for the missing AC row and exits 0' {
        $plan = @'
## Plan

## Acceptance Criteria

- **AC1** (text-presence): load-bearing literal text exists.
- **AC2** (structure-presence): load-bearing heading exists.

<!-- verification-evidence -->
**Verification Evidence**

- **AC1** (text-presence): `rg "foo" target.md` -> found. **verified** - evidence: `target.md:12`.
'@

        $result = & $script:InvokeOrchestrator -PlanContent $plan

        & $script:AssertWarnOnlyExit -Result $result -Because 'warn-only invariant: missing load-bearing row must exit 0'
        & $script:AssertWarningContains -Result $result -ExpectedWarning 'AC2 marked load-bearing has no evidence row'
    }

    It 'Final-plan-shaped valid evidence with one category row per AC and non-AC audit groups emits no warnings and exits 0' {
        $plan = @'
## Plan

## Acceptance Criteria

- **AC1** (text-presence + structure-presence): `skills/plan-authoring/SKILL.md` contains the discipline section and category subsections.
- **AC3** (text-presence + structure-presence): `skills/plan-authoring/SKILL.md` contains the plan-template Verification Evidence block.

<!-- verification-evidence -->
**Verification Evidence**

- **AC1** (text-presence): `grep -n '^## Stress-Test Preparation' skills/plan-authoring/SKILL.md` -> line 87. **verified** - evidence: `skills/plan-authoring/SKILL.md:87`.
- **AC3** (text-presence): `grep -n '^\*\*Verification\*\*$' skills/plan-authoring/SKILL.md` -> line 198. **verified** - evidence: `skills/plan-authoring/SKILL.md:198`.
- **Adapter-path verification** (per judge finding F4) - text-presence for each slice's adapter field:
    - s1 adapter `agents/Test-Writer.agent.md`: `Glob agents/Test-Writer.agent.md` -> exists. **verified** - evidence: live tree at HEAD.
    - s5 adapter `skills/implementation-discipline/adapters/implement-code-adapter.md`: `Glob` -> exists. **verified** - evidence: live tree at HEAD.
- **Executor verification** (per judge finding F4) - downstream-consumer for each slice's executor field:
    - s1 executor `agents/Test-Writer.agent.md`: same path as adapter - verified above.
    - s5 executor `agents/Code-Smith.agent.md`: `Glob agents/Code-Smith.agent.md` -> exists. **verified** - evidence: live tree at HEAD.
'@

            $result = & $script:InvokeOrchestrator -PlanContent $plan

            & $script:AssertWarnOnlyExit -Result $result -Because 'warn-only invariant: final-plan-shaped valid evidence must exit 0'
            & $script:AssertNoWarnings -Result $result
            }

    It 'Evidence block parser stops before a following bold heading with trailing text and does not consume later AC-like rows' {
        $plan = @'
## Plan

## Acceptance Criteria

- **AC1** (text-presence): load-bearing literal text exists.
- **AC4** (text-presence): load-bearing literal text also exists.

<!-- verification-evidence -->
**Verification Evidence**

- **AC1** (text-presence): `rg "foo" target.md` -> found. **verified** - evidence: `target.md:12`.

**Decisions** (if applicable)

- **AC4** (text-presence): decision-like row after the evidence block. **verified** - evidence: `target.md:13`.
'@

        $result = & $script:InvokeOrchestrator -PlanContent $plan

        & $script:AssertWarnOnlyExit -Result $result -Because 'warn-only invariant: AC-like rows after a following bold heading must exit 0'
        & $script:AssertWarningContains -Result $result -ExpectedWarning 'AC4 marked load-bearing has no evidence row'
    }

    It 'AC discovery treats a dash-prefixed AC with a load-bearing continuation line as needing evidence and exits 0' {
        $plan = @'
## Plan

## Acceptance Criteria

- **AC1**: add the new planner discipline.
  `skills/plan-authoring/SKILL.md` must contain the heading.
- **AC2** (text-presence): load-bearing literal text exists.

<!-- verification-evidence -->
**Verification Evidence**

- **AC2** (text-presence): `rg "foo" target.md` -> found. **verified** - evidence: `target.md:12`.
'@

        $result = & $script:InvokeOrchestrator -PlanContent $plan

        & $script:AssertWarnOnlyExit -Result $result -Because 'warn-only invariant: omitted continuation-line load-bearing AC must exit 0'
        & $script:AssertWarningContains -Result $result -ExpectedWarning 'AC1 marked load-bearing has no evidence row'
    }

    It 'Duplicate evidence rows for the same AC across different categories warn and exit 0' {
        $plan = @'
## Plan

## Acceptance Criteria

- **AC1** (text-presence + structure-presence): load-bearing literal text and heading exist.

<!-- verification-evidence -->
**Verification Evidence**

- **AC1** (text-presence): `rg "foo" target.md` -> found. **verified** - evidence: `target.md:12`.
- **AC1** (structure-presence): `grep "^## Foo" target.md` -> found. **verified** - evidence: `line 13`.
'@

        $result = & $script:InvokeOrchestrator -PlanContent $plan

        & $script:AssertWarnOnlyExit -Result $result -Because 'warn-only invariant: duplicate evidence rows must exit 0'
        & $script:AssertWarningContains -Result $result -ExpectedWarning 'duplicate evidence row for AC1'
    }

    It 'Row marked revised without rationale warns for the revised disposition and exits 0' {
        $plan = @'
## Plan

## Acceptance Criteria

- **AC1** (text-presence): load-bearing literal text exists.

<!-- verification-evidence -->
**Verification Evidence**

- **AC1** (text-presence): `rg "foo" target.md` -> found changed text. **revised** - evidence: `target.md:12`.
'@

        $result = & $script:InvokeOrchestrator -PlanContent $plan

        & $script:AssertWarnOnlyExit -Result $result -Because 'warn-only invariant: revised row without rationale must exit 0'
        & $script:AssertWarningContains -Result $result -ExpectedWarning 'AC1 revised disposition has no rationale'
    }

    It "Verified text-presence row whose evidence lacks accepted forms warns for category shape and exits 0" {
        $plan = @'
## Plan

## Acceptance Criteria

- **AC1** (text-presence): load-bearing literal text exists.

<!-- verification-evidence -->
**Verification Evidence**

- **AC1** (text-presence): manual inspection confirmed the text is present. **verified** - evidence: obvious in the target file.
'@

        $result = & $script:InvokeOrchestrator -PlanContent $plan

        & $script:AssertWarnOnlyExit -Result $result -Because 'warn-only invariant: malformed text-presence evidence must exit 0'
        & $script:AssertWarningContains -Result $result -ExpectedWarning "AC1 text-presence evidence doesn't match category shape"
    }

    It 'Planned row without an sN slice anchor warns for missing slice anchor and exits 0' {
        $plan = @'
## Plan

## Acceptance Criteria

- **AC1** (text-presence): load-bearing literal text will be authored.

<!-- verification-evidence -->
**Verification Evidence**

- **AC1** (text-presence): new artifact will be authored later. **planned** - category: text-presence.
'@

        $result = & $script:InvokeOrchestrator -PlanContent $plan

        & $script:AssertWarnOnlyExit -Result $result -Because 'warn-only invariant: planned row without slice anchor must exit 0'
        & $script:AssertWarningContains -Result $result -ExpectedWarning 'AC1 planned disposition lacks slice anchor'
    }

    It 'Planned row without future category detail warns for missing future category and exits 0' {
        $plan = @'
## Plan

## Acceptance Criteria

- **AC1** (text-presence): load-bearing literal text will be authored.

<!-- verification-evidence -->
**Verification Evidence**

- **AC1** (text-presence): new artifact will be authored in the implementation slice. **planned (s5)** - evidence will be produced later.
'@

        $result = & $script:InvokeOrchestrator -PlanContent $plan

        & $script:AssertWarnOnlyExit -Result $result -Because 'warn-only invariant: planned row without future category detail must exit 0'
        & $script:AssertWarningContains -Result $result -ExpectedWarning 'AC1 planned disposition lacks future category'
    }

    It 'Planned row with a valid sN slice anchor emits no warnings and exits 0' {
        $plan = @'
## Plan

## Acceptance Criteria

- **AC1** (text-presence): load-bearing literal text will be authored.

<!-- verification-evidence -->
**Verification Evidence**

- **AC1** (text-presence): new artifact will be authored in the implementation slice. **planned (s5)** - category: text-presence.
'@

        $result = & $script:InvokeOrchestrator -PlanContent $plan

        & $script:AssertWarnOnlyExit -Result $result -Because 'warn-only invariant: planned row with a valid slice anchor must exit 0'
        & $script:AssertNoWarnings -Result $result
    }

    It 'Untagged artifact-referencing AC omitted from non-empty evidence block warns as load-bearing and exits 0' {
        $plan = @'
## Plan

## Acceptance Criteria

- **AC1**: add `skills/plan-authoring/SKILL.md` section.
- **AC2** (text-presence): load-bearing literal text exists.

<!-- verification-evidence -->
**Verification Evidence**

- **AC2** (text-presence): `rg "foo" target.md` -> found. **verified** - evidence: `target.md:12`.
'@

        $result = & $script:InvokeOrchestrator -PlanContent $plan

        & $script:AssertWarnOnlyExit -Result $result -Because 'warn-only invariant: omitted untagged artifact-referencing AC must exit 0'
        & $script:AssertWarningContains -Result $result -ExpectedWarning 'AC1 marked load-bearing has no evidence row'
    }

    It 'Untagged artifact-referencing AC omitted from non-empty evidence block warns for <Name> and exits 0' -ForEach @(
        @{ Name = 'root-level file path README.md'; AcLine = '- **AC1**: update README.md.' }
        @{ Name = 'root-level manifest plugin.json'; AcLine = '- **AC1**: update plugin.json.' }
        @{ Name = 'directory path skills/plan-authoring/'; AcLine = '- **AC1**: update skills/plan-authoring/ directory.' }
        @{ Name = 'root dotfile .gitignore'; AcLine = '- **AC1**: update `.gitignore`.' }
        @{ Name = 'root dotfile .editorconfig'; AcLine = '- **AC1**: update `.editorconfig`.' }
        @{ Name = 'dotless root file LICENSE'; AcLine = '- **AC1**: update `LICENSE`.' }
    ) {
        $plan = @"
## Plan

## Acceptance Criteria

$AcLine
- **AC2** (text-presence): load-bearing literal text exists.

<!-- verification-evidence -->
**Verification Evidence**

- **AC2** (text-presence): ``rg "foo" target.md`` -> found. **verified** - evidence: ``target.md:12``.
"@

        $result = & $script:InvokeOrchestrator -PlanContent $plan

        & $script:AssertWarnOnlyExit -Result $result -Because 'warn-only invariant: omitted untagged artifact-referencing AC must exit 0'
        & $script:AssertWarningContains -Result $result -ExpectedWarning 'AC1 marked load-bearing has no evidence row'
    }

    It 'Dotted technology prose token omitted from non-empty evidence block does not warn as load-bearing and exits 0' {
        $plan = @'
## Plan

## Acceptance Criteria

- **AC1**: Support .NET SDK users without extra setup.
- **AC2** (text-presence): load-bearing literal text exists.

<!-- verification-evidence -->
**Verification Evidence**

- **AC2** (text-presence): `rg "foo" target.md` -> found. **verified** - evidence: `target.md:12`.
'@

        $result = & $script:InvokeOrchestrator -PlanContent $plan
        $combined = "$($result.Stdout)`n$($result.Stderr)"

        & $script:AssertWarnOnlyExit -Result $result -Because 'warn-only invariant: dotted technology prose should not require evidence'
        & $script:AssertNoWarnings -Result $result
        $combined | Should -Not -Match ([regex]::Escape('AC1 marked load-bearing has no evidence row')) -Because "dotted technology prose such as .NET should not be classified as a root dotfile artifact. Output: $combined"
    }

    It 'Untagged named-standard AC omitted from non-empty evidence block warns for <Name> and exits 0' -ForEach @(
        @{ Name = 'issue standard #527'; AcLine = '- **AC1**: comply with #527.' }
        @{ Name = 'session-memory standard SMC-01'; AcLine = '- **AC1**: comply with SMC-01.' }
        @{ Name = 'design decision D2'; AcLine = '- **AC1**: comply with D2.' }
    ) {
        $plan = @"
## Plan

## Acceptance Criteria

$AcLine
- **AC2** (text-presence): load-bearing literal text exists.

<!-- verification-evidence -->
**Verification Evidence**

- **AC2** (text-presence): ``rg "foo" target.md`` -> found. **verified** - evidence: ``target.md:12``.
"@

        $result = & $script:InvokeOrchestrator -PlanContent $plan

        & $script:AssertWarnOnlyExit -Result $result -Because 'warn-only invariant: omitted untagged artifact-referencing AC must exit 0'
        & $script:AssertWarningContains -Result $result -ExpectedWarning 'AC1 marked load-bearing has no evidence row'
    }
}