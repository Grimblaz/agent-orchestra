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
            try { $proc.Kill($true) } catch {}

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
}