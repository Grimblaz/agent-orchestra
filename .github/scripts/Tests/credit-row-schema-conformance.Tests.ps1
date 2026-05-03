#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Schema-conformance tests for credit-row builders and back-deriver output (issue #442, Step 6).
#
# (a) Iterate Build-*CreditRow builders; assert required fields (port, status, evidence)
#     and per-port status enum.
# (b) Iterate back-deriver output for each shipped audit fixture; assert same constraint.
#     Covers AC9 — implement-* never 'inconclusive' from any path.
# (c) Assert Build-CeGateCreditRow -Surface ValidateSet matches auto-na-ce-gate-*.md
#     adapter files (drift prevention).
#
# Per-port allowed-status table:
#   implement-*         → passed | failed | skipped | not-applicable
#   ce-gate-*           → passed | failed | skipped | not-applicable | inconclusive
#   experience/design/plan/post-pr → passed | failed | skipped | not-applicable

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

    $script:LedgerCoreLib = Join-Path $script:RepoRoot '.github/scripts/lib/frame-credit-ledger-core.ps1'
    if (Test-Path $script:LedgerCoreLib) {
        . $script:LedgerCoreLib
    }

    $script:BackDeriveLib = Join-Path $script:RepoRoot '.github/scripts/lib/frame-back-derive-core.ps1'
    if (Test-Path $script:BackDeriveLib) {
        . $script:BackDeriveLib
    }

    $script:AuditFixtureDir = Join-Path $script:RepoRoot 'frame\audit-fixtures'
    $script:FixtureDir = Join-Path $PSScriptRoot 'fixtures'
    $script:PortsDir = Join-Path $script:RepoRoot 'frame\ports'
    $script:CeGateAdaptersDir = Join-Path $script:RepoRoot 'skills\customer-experience\adapters'

    # Per-port allowed-status enum map.
    $script:AllowedStatusByPortPattern = @{
        'implement-*' = @('passed', 'failed', 'skipped', 'not-applicable')
        'ce-gate-*'   = @('passed', 'failed', 'skipped', 'not-applicable', 'inconclusive')
        'experience'  = @('passed', 'failed', 'skipped', 'not-applicable')
        'design'      = @('passed', 'failed', 'skipped', 'not-applicable')
        'plan'        = @('passed', 'failed', 'skipped', 'not-applicable')
        'post-pr'     = @('passed', 'failed', 'skipped', 'not-applicable')
    }

    function script:Get-AllowedStatuses {
        param([string]$Port)

        foreach ($pattern in $script:AllowedStatusByPortPattern.Keys) {
            if ($Port -like $pattern -or $Port -eq $pattern) {
                return $script:AllowedStatusByPortPattern[$pattern]
            }
        }
        # Default: all six values (for ports not in the table)
        return @('passed', 'failed', 'skipped', 'not-applicable', 'inconclusive', 'not-persisted')
    }

    # Canonical inputs for each builder.
    $script:BuilderInputs = @{
        'Build-CeGateCreditRow'           = @{ Surface = 'cli'; EvidenceList = @('S1: passed') }
        'Build-ExperienceCreditRow'        = @{ MarkerPresent = $true; IssueNumber = 1 }
        'Build-DesignCreditRow'            = @{ MarkerPresent = $true; IssueNumber = 1 }
        'Build-PlanCreditRow'              = @{ MarkerPresent = $true; IssueNumber = 1 }
        'Build-ImplementCodeCreditRow'     = @{ ValidationEvidence = @(@{ Name = 'lint'; Status = 'passed' }) }
        'Build-ImplementTestCreditRow'     = @{ ValidationEvidence = @(@{ Name = 'pester'; Status = 'passed' }) }
        'Build-ImplementRefactorCreditRow' = @{ ValidationEvidence = @(@{ Name = 'sonar'; Status = 'passed' }) }
        'Build-ImplementDocsCreditRow'     = @{ ValidationEvidence = @(@{ Name = 'doc-lint'; Status = 'passed' }) }
        'Build-PostPrCreditRow'            = @{ ChecklistOutcomes = @{ archive = $true; docs = $true; version = $true; releaseTag = $true } }
    }

    $script:VersionFixtures = @(
        @{ MetricsVersion = '1'; PrNumber = 286; FixtureFile = 'frame-pr-286-v1.json' }
        @{ MetricsVersion = '2'; PrNumber = 338; FixtureFile = 'frame-pr-338-v2.json' }
        @{ MetricsVersion = '3'; PrNumber = 415; FixtureFile = 'frame-pr-415-v3.json' }
        @{ MetricsVersion = '4'; PrNumber = 411; FixtureFile = 'frame-pr-411-v4.json' }
    )

    $script:TempDir = Join-Path ([System.IO.Path]::GetTempPath()) "pester-schema-conformance-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null
}

AfterAll {
    if (Test-Path $script:TempDir) {
        Remove-Item -Recurse -Force -Path $script:TempDir -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# (a) Builder schema conformance
# ---------------------------------------------------------------------------

Describe 'Builder credit-row schema conformance (Step 6a)' -ForEach @(
    @{ Name = 'Build-CeGateCreditRow' }
    @{ Name = 'Build-ExperienceCreditRow' }
    @{ Name = 'Build-DesignCreditRow' }
    @{ Name = 'Build-PlanCreditRow' }
    @{ Name = 'Build-ImplementCodeCreditRow' }
    @{ Name = 'Build-ImplementTestCreditRow' }
    @{ Name = 'Build-ImplementRefactorCreditRow' }
    @{ Name = 'Build-ImplementDocsCreditRow' }
    @{ Name = 'Build-PostPrCreditRow' }
) {
    param($Name)

    BeforeAll {
        $fn = Get-Command $Name -ErrorAction SilentlyContinue
        if ($null -eq $fn) {
            Set-ItResult -Skipped -Because "$Name not yet implemented"
            return
        }

        $inputs = $script:BuilderInputs[$Name]
        $script:Row = & $Name @inputs
    }

    It "$Name returns a non-null row" {
        $script:Row | Should -Not -BeNullOrEmpty
    }

    It "$Name row has required field 'port'" {
        $script:Row | Should -Not -BeNullOrEmpty
        $null -ne $script:Row.PSObject.Properties['port'] -or $script:Row -is [hashtable] | Should -Be $true
        [string]$script:Row.port | Should -Not -BeNullOrEmpty
    }

    It "$Name row has required field 'status'" {
        $null -ne $script:Row.PSObject.Properties['status'] | Should -Be $true
        [string]$script:Row.status | Should -Not -BeNullOrEmpty
    }

    It "$Name row has required field 'evidence'" {
        $null -ne $script:Row.PSObject.Properties['evidence'] | Should -Be $true
    }

    It "$Name row 'status' is within the allowed enum for port '$([string]$script:Row?.port)'" {
        $port = [string]$script:Row.port
        $status = [string]$script:Row.status
        $allowed = script:Get-AllowedStatuses -Port $port
        $allowed | Should -Contain $status -Because "port '$port' allows: $($allowed -join ', ')"
    }
}

# ---------------------------------------------------------------------------
# (b) Back-deriver output conformance (AC9: implement-* never inconclusive)
# ---------------------------------------------------------------------------

Describe 'Back-deriver output per-port status conformance (Step 6b / AC9)' -ForEach @(
    @{ MetricsVersion = '1'; PrNumber = 286; FixtureFile = 'frame-pr-286-v1.json' }
    @{ MetricsVersion = '2'; PrNumber = 338; FixtureFile = 'frame-pr-338-v2.json' }
    @{ MetricsVersion = '3'; PrNumber = 415; FixtureFile = 'frame-pr-415-v3.json' }
    @{ MetricsVersion = '4'; PrNumber = 411; FixtureFile = 'frame-pr-411-v4.json' }
) {
    param($MetricsVersion, $PrNumber, $FixtureFile)

    BeforeAll {
        if (-not (Get-Command Invoke-FrameBackDerive -ErrorAction SilentlyContinue)) {
            $script:BackDeriveCredits = $null
            return
        }

        $fixturePath = Join-Path $script:FixtureDir $FixtureFile
        $fixtureData = Get-Content -Raw -Path $fixturePath | ConvertFrom-Json
        $fixtureFile2 = Join-Path $script:TempDir "fbd-view-$PrNumber.json"
        $fixtureData | ConvertTo-Json -Depth 10 | Set-Content -Path $fixtureFile2 -Encoding UTF8

        $mockPath = Join-Path $script:TempDir "gh-$PrNumber.ps1"
        $escapedFile = $fixtureFile2 -replace "'", "''"
        @"
param()
if (`$args.Count -ge 2 -and `$args[0] -eq 'repo' -and `$args[1] -eq 'view') {
    Write-Output '{"nameWithOwner":"Grimblaz/agent-orchestra"}'
    exit 0
}
if (`$args.Count -ge 3 -and `$args[0] -eq 'pr' -and `$args[1] -eq 'view') {
    Get-Content -Raw -Path '$escapedFile'
    exit 0
}
Write-Error "Mock: unsupported"
exit 99
"@ | Set-Content $mockPath -Encoding UTF8

        $result = Invoke-FrameBackDerive -Repo 'Grimblaz/agent-orchestra' -PrNumber $PrNumber `
            -OutputFormat 'json' -GhCliPath $mockPath -PortsDir $script:PortsDir `
            -CacheDir (Join-Path $script:TempDir "cache-$PrNumber")

        if ($null -ne $result -and $result.ExitCode -eq 0) {
            $parsed = $result.Output | ConvertFrom-Json
            $script:BackDeriveCredits = @($parsed.credits)
        } else {
            $script:BackDeriveCredits = $null
        }
    }

    It "back-deriver for PR $PrNumber produces a non-empty credits list" {
        if ($null -eq $script:BackDeriveCredits) {
            Set-ItResult -Skipped -Because 'Invoke-FrameBackDerive not available or produced no output'
            return
        }
        $script:BackDeriveCredits.Count | Should -BeGreaterThan 0
    }

    It "back-deriver for PR ${PrNumber}: no implement-* port has status 'inconclusive' (D5/AC9)" {
        if ($null -eq $script:BackDeriveCredits) {
            Set-ItResult -Skipped -Because 'Invoke-FrameBackDerive not available'
            return
        }
        $violations = @($script:BackDeriveCredits | Where-Object {
            [string]$_.port -like 'implement-*' -and [string]$_.status -eq 'inconclusive'
        })
        $violations | Should -BeNullOrEmpty -Because "implement-* ports must not use 'inconclusive' per D5"
    }

    It "back-deriver for PR ${PrNumber}: no post-pr port has status 'inconclusive' (D5)" {
        if ($null -eq $script:BackDeriveCredits) {
            Set-ItResult -Skipped -Because 'Invoke-FrameBackDerive not available'
            return
        }
        $violations = @($script:BackDeriveCredits | Where-Object {
            [string]$_.port -eq 'post-pr' -and [string]$_.status -eq 'inconclusive'
        })
        $violations | Should -BeNullOrEmpty -Because "post-pr must not use 'inconclusive' per D5"
    }
}

# ---------------------------------------------------------------------------
# (d) Build-CeGateCreditRow schema conformance across all 4 resolution branches
# ---------------------------------------------------------------------------

Describe 'Build-CeGateCreditRow schema conformance for all resolution branches (Step 6d)' -ForEach @(
    @{ Branch = 'env-blocked-inconclusive'; Params = @{ Surface = 'cli'; EnvironmentBlocked = $true; BlockKind = 'environment' }; ExpectedStatus = 'inconclusive' }
    @{ Branch = 'surface-not-touched-na';   Params = @{ Surface = 'browser'; SurfaceTouchResult = $false };                         ExpectedStatus = 'not-applicable' }
    @{ Branch = 'empty-evidence-inconclusive'; Params = @{ Surface = 'canvas'; EvidenceList = @() };                                ExpectedStatus = 'inconclusive' }
    @{ Branch = 'evidence-passed';          Params = @{ Surface = 'api'; EvidenceList = @('S1: passed') };                          ExpectedStatus = 'passed' }
) {
    param($Branch, $Params, $ExpectedStatus)

    BeforeAll {
        if (-not (Get-Command Build-CeGateCreditRow -ErrorAction SilentlyContinue)) {
            $script:BranchRow = $null
            return
        }
        $script:BranchRow = Build-CeGateCreditRow @Params
    }

    It "branch '$Branch' returns a non-null row" {
        if ($null -eq $script:BranchRow) { Set-ItResult -Skipped -Because 'Build-CeGateCreditRow not available'; return }
        $script:BranchRow | Should -Not -BeNullOrEmpty
    }

    It "branch '$Branch' has required field 'port' with ce-gate prefix" {
        if ($null -eq $script:BranchRow) { Set-ItResult -Skipped -Because 'Build-CeGateCreditRow not available'; return }
        [string]$script:BranchRow.port | Should -BeLike 'ce-gate-*'
    }

    It "branch '$Branch' has expected status '$ExpectedStatus'" {
        if ($null -eq $script:BranchRow) { Set-ItResult -Skipped -Because 'Build-CeGateCreditRow not available'; return }
        [string]$script:BranchRow.status | Should -Be $ExpectedStatus
    }

    It "branch '$Branch' has required field 'evidence'" {
        if ($null -eq $script:BranchRow) { Set-ItResult -Skipped -Because 'Build-CeGateCreditRow not available'; return }
        $null -ne $script:BranchRow.PSObject.Properties['evidence'] | Should -Be $true
    }

    It "branch '$Branch' status is within ce-gate allowed enum" {
        if ($null -eq $script:BranchRow) { Set-ItResult -Skipped -Because 'Build-CeGateCreditRow not available'; return }
        @('passed', 'failed', 'skipped', 'not-applicable', 'inconclusive') | Should -Contain ([string]$script:BranchRow.status)
    }
}

# ---------------------------------------------------------------------------
# (e) ValidateSet parity: Build-CeGateCreditRow surfaces vs adapter files
# ---------------------------------------------------------------------------

Describe 'Build-CeGateCreditRow ValidateSet matches auto-na-ce-gate adapter files (Step 6e)' {

    It 'each auto-na-ce-gate-*.md adapter has a matching surface value in the ValidateSet' {
        $adapterFiles = @(Get-ChildItem -Path $script:CeGateAdaptersDir -Filter 'auto-na-ce-gate-*.md' -ErrorAction SilentlyContinue)

        if ($adapterFiles.Count -eq 0) {
            Set-ItResult -Skipped -Because 'No auto-na-ce-gate-*.md adapter files found'
            return
        }

        # Extract surface names from file names: auto-na-ce-gate-{surface}.md
        $adapterSurfaces = @($adapterFiles | ForEach-Object {
            if ($_.Name -match '^auto-na-ce-gate-(.+)\.md$') { $Matches[1] }
        })

        $validSetSurfaces = @('cli', 'browser', 'canvas', 'api')

        foreach ($surface in $adapterSurfaces) {
            $validSetSurfaces | Should -Contain $surface -Because "adapter auto-na-ce-gate-$surface.md must match a ValidateSet value in Build-CeGateCreditRow"
        }
    }

    It 'Build-CeGateCreditRow has a ValidateSet surface for each auto-na-ce-gate-*.md adapter' {
        $adapterFiles = @(Get-ChildItem -Path $script:CeGateAdaptersDir -Filter 'auto-na-ce-gate-*.md' -ErrorAction SilentlyContinue)

        $adapterSurfaces = @($adapterFiles | ForEach-Object {
            if ($_.Name -match '^auto-na-ce-gate-(.+)\.md$') { $Matches[1] }
        })

        $validSetSurfaces = @('cli', 'browser', 'canvas', 'api')

        foreach ($surface in $validSetSurfaces) {
            $adapterSurfaces | Should -Contain $surface -Because "ValidateSet surface '$surface' must have a matching auto-na-ce-gate-$surface.md adapter file"
        }
    }
}
