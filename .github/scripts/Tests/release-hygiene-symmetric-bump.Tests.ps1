#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Tests for symmetric-bump verifier (issue #441, Step 7a — D-new-5).
#
# Three result paths:
#   passed         — all manifest files carry the same version
#   failed         — at least one manifest file lags (drift evidence)
#   not-applicable — no manifest file appears in the touched-files set
#
# Manifest set (5 files, matching bump-version.ps1):
#   plugin.json, .claude-plugin/plugin.json, .claude-plugin/marketplace.json,
#   .github/plugin/marketplace.json, README.md

BeforeAll {
    $script:RepoRoot    = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:VerifierPath = Join-Path $script:RepoRoot 'skills/plugin-release-hygiene/scripts/symmetric-bump-verifier.ps1'

    if (Test-Path $script:VerifierPath) {
        . $script:VerifierPath
    }

    # ---- fixture helpers ----

    # Write a minimal plugin.json with the given version.
    function script:Write-PluginJson {
        param([string]$Dir, [string]$Version)
        $content = "{`"name`": `"test-plugin`", `"version`": `"$Version`"}"
        Set-Content -Path (Join-Path $Dir 'plugin.json') -Value $content -Encoding UTF8
    }

    # Write a minimal marketplace.json with TWO version occurrences.
    function script:Write-MarketplaceJson {
        param([string]$Dir, [string]$RelPath, [string]$Version)
        $fullDir = Join-Path $Dir (Split-Path $RelPath -Parent)
        if (-not (Test-Path $fullDir)) { New-Item -ItemType Directory -Path $fullDir -Force | Out-Null }
        $content = "{`"metadata`": {`"version`": `"$Version`"}, `"plugin`": {`"version`": `"$Version`"}}"
        Set-Content -Path (Join-Path $Dir $RelPath) -Value $content -Encoding UTF8
    }

    # Write a README.md badge with the given version.
    function script:Write-ReadmeMd {
        param([string]$Dir, [string]$Version)
        $content = "# My Plugin`n`n![version](https://img.shields.io/badge/version-v$Version-blue)`n"
        Set-Content -Path (Join-Path $Dir 'README.md') -Value $content -Encoding UTF8
    }

    # Create a fully consistent fixture tree at $Root with all 5 manifests at $Version.
    function script:New-ManifestFixture {
        param([string]$Root, [string]$Version = '2.7.0')
        script:Write-PluginJson         -Dir $Root -Version $Version
        $claudePluginDir = Join-Path $Root '.claude-plugin'
        if (-not (Test-Path $claudePluginDir)) { New-Item -ItemType Directory -Path $claudePluginDir -Force | Out-Null }
        script:Write-PluginJson         -Dir $claudePluginDir -Version $Version
        script:Write-MarketplaceJson    -Dir $Root -RelPath '.claude-plugin/marketplace.json' -Version $Version
        script:Write-MarketplaceJson    -Dir $Root -RelPath '.github/plugin/marketplace.json' -Version $Version
        script:Write-ReadmeMd           -Dir $Root -Version $Version
    }

    # Manifest relative paths that count as "touched" for the not-applicable test.
    $script:ManifestPaths = @(
        'plugin.json',
        '.claude-plugin/plugin.json',
        '.claude-plugin/marketplace.json',
        '.github/plugin/marketplace.json',
        'README.md'
    )
}

# ---------------------------------------------------------------------------
# Section 1 — Result paths
# ---------------------------------------------------------------------------

Describe 'Invoke-SymmetricBumpVerifier — result paths (Step 7a)' {

    It 'returns status=passed when all five manifests carry the same version' {
        $root = $TestDrive
        script:New-ManifestFixture -Root $root -Version '2.8.0'

        $result = Invoke-SymmetricBumpVerifier -RepoRoot $root `
            -TouchedFiles @('plugin.json', '.claude-plugin/plugin.json')

        $result.status   | Should -Be 'passed'
        $result.port     | Should -Be 'release-hygiene'
        $result.adapter  | Should -Be 'symmetric-bump'
        $result.evidence | Should -Match '2\.8\.0'
    }

    It 'returns status=failed when plugin.json lags behind the others' {
        $root = $TestDrive
        script:New-ManifestFixture -Root $root -Version '2.8.0'
        # Overwrite plugin.json with an older version to simulate drift.
        script:Write-PluginJson -Dir $root -Version '2.7.0'

        $result = Invoke-SymmetricBumpVerifier -RepoRoot $root `
            -TouchedFiles @('plugin.json', '.claude-plugin/plugin.json')

        $result.status   | Should -Be 'failed'
        $result.port     | Should -Be 'release-hygiene'
        $result.adapter  | Should -Be 'symmetric-bump'
        $result.evidence | Should -Match 'drift'
    }

    It 'failed evidence names the drifting file(s)' {
        $root = $TestDrive
        script:New-ManifestFixture -Root $root -Version '2.8.0'
        # README.md lags.
        script:Write-ReadmeMd -Dir $root -Version '2.7.0'

        $result = Invoke-SymmetricBumpVerifier -RepoRoot $root `
            -TouchedFiles @('README.md')

        $result.evidence | Should -Match 'README'
    }

    It 'returns status=not-applicable when no manifest file is in the touched-files set' {
        $root = $TestDrive
        script:New-ManifestFixture -Root $root -Version '2.8.0'

        $result = Invoke-SymmetricBumpVerifier -RepoRoot $root `
            -TouchedFiles @('agents/Code-Conductor.agent.md', 'skills/some/SKILL.md')

        $result.status  | Should -Be 'not-applicable'
        $result.evidence | Should -Match 'no manifest change'
    }

    It 'returns status=not-applicable when touched-files list is empty' {
        $root = $TestDrive
        script:New-ManifestFixture -Root $root -Version '2.8.0'

        $result = Invoke-SymmetricBumpVerifier -RepoRoot $root -TouchedFiles @()
        $result.status | Should -Be 'not-applicable'
    }

    It 'result object always carries port, adapter, status, evidence, and verified_at' {
        $root = $TestDrive
        script:New-ManifestFixture -Root $root -Version '2.8.0'

        $result = Invoke-SymmetricBumpVerifier -RepoRoot $root `
            -TouchedFiles @('plugin.json')

        $result.PSObject.Properties.Name | Should -Contain 'port'
        $result.PSObject.Properties.Name | Should -Contain 'adapter'
        $result.PSObject.Properties.Name | Should -Contain 'status'
        $result.PSObject.Properties.Name | Should -Contain 'evidence'
        $result.PSObject.Properties.Name | Should -Contain 'verified_at'
    }

    It 'verified_at is an ISO-8601 UTC timestamp' {
        $root = $TestDrive
        script:New-ManifestFixture -Root $root -Version '2.8.0'

        $result = Invoke-SymmetricBumpVerifier -RepoRoot $root `
            -TouchedFiles @('plugin.json')

        # ISO-8601 UTC pattern: 2026-05-01T12:34:56Z or with fractional seconds
        $result.verified_at | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'
    }
}

# ---------------------------------------------------------------------------
# Section 2 — State file persistence
# ---------------------------------------------------------------------------

Describe 'Invoke-SymmetricBumpVerifier — state file persistence (Step 7a)' {

    It 'writes symmetric_bump_credit to state file when StatePath is provided (passed)' {
        $root      = $TestDrive
        $statePath = Join-Path $TestDrive 'release-hygiene-test.json'
        script:New-ManifestFixture -Root $root -Version '2.8.0'

        Invoke-SymmetricBumpVerifier -RepoRoot $root `
            -TouchedFiles @('plugin.json') -StatePath $statePath | Out-Null

        Test-Path $statePath | Should -Be $true
        $state = Get-Content $statePath -Raw | ConvertFrom-Json
        $state.symmetric_bump_credit           | Should -Not -BeNullOrEmpty
        $state.symmetric_bump_credit.status    | Should -Be 'passed'
        $state.symmetric_bump_credit.port      | Should -Be 'release-hygiene'
        $state.symmetric_bump_credit.adapter   | Should -Be 'symmetric-bump'
    }

    It 'writes symmetric_bump_credit with status=failed to state file' {
        $root      = $TestDrive
        $statePath = Join-Path $TestDrive 'release-hygiene-fail.json'
        script:New-ManifestFixture -Root $root -Version '2.8.0'
        script:Write-PluginJson -Dir $root -Version '2.7.0'

        Invoke-SymmetricBumpVerifier -RepoRoot $root `
            -TouchedFiles @('plugin.json') -StatePath $statePath | Out-Null

        $state = Get-Content $statePath -Raw | ConvertFrom-Json
        $state.symmetric_bump_credit.status | Should -Be 'failed'
    }

    It 'writes symmetric_bump_credit with status=not-applicable to state file' {
        $root      = $TestDrive
        $statePath = Join-Path $TestDrive 'release-hygiene-na.json'
        script:New-ManifestFixture -Root $root -Version '2.8.0'

        Invoke-SymmetricBumpVerifier -RepoRoot $root `
            -TouchedFiles @('agents/some.md') -StatePath $statePath | Out-Null

        $state = Get-Content $statePath -Raw | ConvertFrom-Json
        $state.symmetric_bump_credit.status | Should -Be 'not-applicable'
    }

    It 'merges symmetric_bump_credit into an existing state file without clobbering other fields' {
        $root      = $TestDrive
        $statePath = Join-Path $TestDrive 'release-hygiene-merge.json'
        script:New-ManifestFixture -Root $root -Version '2.8.0'

        # Seed an existing state file with the old fields.
        $existing = [pscustomobject]@{
            proposed_level  = 'minor'
            chosen_level    = 'minor'
            keying_strategy = 'branch_slug'
            touched_files   = @('plugin.json')
        }
        $existing | ConvertTo-Json -Depth 5 | Set-Content $statePath -Encoding UTF8

        Invoke-SymmetricBumpVerifier -RepoRoot $root `
            -TouchedFiles @('plugin.json') -StatePath $statePath | Out-Null

        $state = Get-Content $statePath -Raw | ConvertFrom-Json
        $state.proposed_level              | Should -Be 'minor'
        $state.chosen_level                | Should -Be 'minor'
        $state.symmetric_bump_credit       | Should -Not -BeNullOrEmpty
        $state.symmetric_bump_credit.port  | Should -Be 'release-hygiene'
    }

    It 'second invocation overwrites symmetric_bump_credit (idempotent write)' {
        $root      = $TestDrive
        $statePath = Join-Path $TestDrive 'release-hygiene-idempotent.json'
        script:New-ManifestFixture -Root $root -Version '2.8.0'

        # First run — all good.
        Invoke-SymmetricBumpVerifier -RepoRoot $root `
            -TouchedFiles @('plugin.json') -StatePath $statePath | Out-Null

        $first = (Get-Content $statePath -Raw | ConvertFrom-Json).symmetric_bump_credit.status

        # Introduce drift and re-run.
        script:Write-PluginJson -Dir $root -Version '2.7.0'
        Invoke-SymmetricBumpVerifier -RepoRoot $root `
            -TouchedFiles @('plugin.json') -StatePath $statePath | Out-Null

        $second = (Get-Content $statePath -Raw | ConvertFrom-Json).symmetric_bump_credit.status

        $first  | Should -Be 'passed'
        $second | Should -Be 'failed'
    }

    It 'does not write state file when StatePath is not provided' {
        $root          = $TestDrive
        $uniqueMarker  = "release-hygiene-no-path-$(New-Guid).json"
        $unexpectedPath = Join-Path $TestDrive $uniqueMarker
        script:New-ManifestFixture -Root $root -Version '2.8.0'

        # No -StatePath argument.
        $result = Invoke-SymmetricBumpVerifier -RepoRoot $root -TouchedFiles @('plugin.json')

        # Verify the result is still returned correctly.
        $result.status | Should -Be 'passed'

        # The specific unique file name should NOT exist because we did not pass -StatePath.
        Test-Path $unexpectedPath | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
# Section 3 — Merge-SymmetricBumpCreditToStateFile standalone
# ---------------------------------------------------------------------------

Describe 'Merge-SymmetricBumpCreditToStateFile (Step 7a — direct)' {

    It 'creates a new state file with credit when path does not exist' {
        $statePath = Join-Path $TestDrive 'new-state.json'
        $credit = [pscustomobject]@{
            port        = 'release-hygiene'
            adapter     = 'symmetric-bump'
            status      = 'passed'
            evidence    = 'all manifests at 2.8.0'
            verified_at = (Get-Date -Format 'o')
        }

        Merge-SymmetricBumpCreditToStateFile -StatePath $statePath -Credit $credit

        Test-Path $statePath | Should -Be $true
        $state = Get-Content $statePath -Raw | ConvertFrom-Json
        $state.symmetric_bump_credit.status | Should -Be 'passed'
    }

    It 'preserves existing state file fields while adding symmetric_bump_credit' {
        $statePath = Join-Path $TestDrive 'existing-state.json'
        $existing = [pscustomobject]@{ proposed_level = 'patch'; touched_files = @('plugin.json') }
        $existing | ConvertTo-Json | Set-Content $statePath -Encoding UTF8

        $credit = [pscustomobject]@{
            port = 'release-hygiene'; adapter = 'symmetric-bump'; status = 'passed'
            evidence = 'ok'; verified_at = (Get-Date -Format 'o')
        }

        Merge-SymmetricBumpCreditToStateFile -StatePath $statePath -Credit $credit

        $state = Get-Content $statePath -Raw | ConvertFrom-Json
        $state.proposed_level             | Should -Be 'patch'
        $state.symmetric_bump_credit.port | Should -Be 'release-hygiene'
    }
}
