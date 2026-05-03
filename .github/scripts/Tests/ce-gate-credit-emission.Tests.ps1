#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# TDD tests for Build-CeGateCreditRow builder (issue #442, Step 4a).
#
# Builder accepts -Surface [ValidateSet('cli','browser','canvas','api')].
# Status logic:
#   - -EnvironmentBlocked $true → status: inconclusive + block_kind
#   - -SurfaceTouchResult $false → status: not-applicable
#   - -EvidenceList populated → status: passed
#   - -EvidenceList empty (no results) → status: inconclusive

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

    $script:LedgerCoreLib = Join-Path $script:RepoRoot '.github/scripts/lib/frame-credit-ledger-core.ps1'
    if (Test-Path $script:LedgerCoreLib) {
        . $script:LedgerCoreLib
    }
}

# ---------------------------------------------------------------------------
# port naming
# ---------------------------------------------------------------------------

Describe 'Build-CeGateCreditRow port naming' {

    It 'emits port ce-gate-cli for Surface=cli' {
        $row = Build-CeGateCreditRow -Surface cli -EvidenceList @('S1: passed')
        $row.port | Should -Be 'ce-gate-cli'
    }

    It 'emits port ce-gate-browser for Surface=browser' {
        $row = Build-CeGateCreditRow -Surface browser -EvidenceList @('S1: passed')
        $row.port | Should -Be 'ce-gate-browser'
    }

    It 'emits port ce-gate-canvas for Surface=canvas' {
        $row = Build-CeGateCreditRow -Surface canvas -EvidenceList @('S1: passed')
        $row.port | Should -Be 'ce-gate-canvas'
    }

    It 'emits port ce-gate-api for Surface=api' {
        $row = Build-CeGateCreditRow -Surface api -EvidenceList @('S1: passed')
        $row.port | Should -Be 'ce-gate-api'
    }
}

# ---------------------------------------------------------------------------
# environment blocked → inconclusive + block_kind
# ---------------------------------------------------------------------------

Describe 'Build-CeGateCreditRow emits inconclusive when environment is blocked' {

    It 'emits status inconclusive when -EnvironmentBlocked is true' {
        $row = Build-CeGateCreditRow -Surface cli -EnvironmentBlocked $true -BlockKind 'environment'
        $row.status | Should -Be 'inconclusive'
    }

    It 'emits block_kind environment when -BlockKind is environment' {
        $row = Build-CeGateCreditRow -Surface cli -EnvironmentBlocked $true -BlockKind 'environment'
        $row.block_kind | Should -Be 'environment'
    }

    It 'emits block_kind tooling when -BlockKind is tooling' {
        $row = Build-CeGateCreditRow -Surface browser -EnvironmentBlocked $true -BlockKind 'tooling'
        $row.block_kind | Should -Be 'tooling'
    }

    It 'emits block_kind runtime when -BlockKind is runtime' {
        $row = Build-CeGateCreditRow -Surface canvas -EnvironmentBlocked $true -BlockKind 'runtime'
        $row.block_kind | Should -Be 'runtime'
    }

    It 'emits block_kind orchestration when -BlockKind is orchestration' {
        $row = Build-CeGateCreditRow -Surface api -EnvironmentBlocked $true -BlockKind 'orchestration'
        $row.block_kind | Should -Be 'orchestration'
    }
}

# ---------------------------------------------------------------------------
# surface not touched → not-applicable
# ---------------------------------------------------------------------------

Describe 'Build-CeGateCreditRow emits not-applicable when surface is not touched' {

    It 'emits status not-applicable when -SurfaceTouchResult is false' {
        $row = Build-CeGateCreditRow -Surface cli -SurfaceTouchResult $false
        $row.status | Should -Be 'not-applicable'
    }

    It 'does not emit block_kind on not-applicable rows' {
        $row = Build-CeGateCreditRow -Surface cli -SurfaceTouchResult $false
        $hasBk = $null -ne $row.PSObject.Properties['block_kind'] -and -not [string]::IsNullOrWhiteSpace([string]$row.block_kind)
        $hasBk | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
# evidence list populated → passed
# ---------------------------------------------------------------------------

Describe 'Build-CeGateCreditRow emits passed when evidence list is populated' {

    It 'emits status passed when -EvidenceList is non-empty' {
        $row = Build-CeGateCreditRow -Surface cli -EvidenceList @('S1: CLI help renders', 'S2: run completes')
        $row.status | Should -Be 'passed'
    }

    It 'includes evidence in the row' {
        $row = Build-CeGateCreditRow -Surface cli -EvidenceList @('S1: passed')
        $row.evidence | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# no results → inconclusive (no block_kind)
# ---------------------------------------------------------------------------

Describe 'Build-CeGateCreditRow emits inconclusive when EvidenceList is empty and not blocked' {

    It 'emits status inconclusive when -EvidenceList is empty and not blocked' {
        $row = Build-CeGateCreditRow -Surface cli -EvidenceList @()
        $row.status | Should -Be 'inconclusive'
    }

    It 'does not emit block_kind when inconclusive due to empty evidence (not environment-blocked)' {
        $row = Build-CeGateCreditRow -Surface cli -EvidenceList @()
        $hasBk = $null -ne $row.PSObject.Properties['block_kind'] -and -not [string]::IsNullOrWhiteSpace([string]$row.block_kind)
        $hasBk | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
# ValidateSet enforcement -- typoed surface rejected at parse time
# ---------------------------------------------------------------------------

Describe 'Build-CeGateCreditRow rejects invalid surface value' {

    It 'throws when -Surface is not in the ValidateSet' {
        { Build-CeGateCreditRow -Surface 'email' -EvidenceList @('x') } | Should -Throw
    }
}
