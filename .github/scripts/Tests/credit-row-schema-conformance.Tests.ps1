#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Schema-conformance tests for credit-row builders and back-deriver output (issue #442, Step 6).
#
# (a) Iterate Build-*CreditRow builders; assert required fields (port, status, evidence)
#     and per-port status enum.
# (b) Iterate back-deriver output for each shipped audit fixture; assert same constraint.
#     Covers AC9 — implement-* never 'inconclusive' from any path.
# (c) Assert Build-CeGateCreditRow -Surface ValidateSet matches ce-gate-*-auto-na-adapter.md
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

    $ledgerCoreTokens = $null
    $ledgerCoreParseErrors = $null
    $script:LedgerCoreAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:LedgerCoreLib,
        [ref]$ledgerCoreTokens,
        [ref]$ledgerCoreParseErrors
    )
    $script:LedgerCoreParseErrors = @($ledgerCoreParseErrors)

    $script:BackDeriveLib = Join-Path $script:RepoRoot '.github/scripts/lib/frame-back-derive-core.ps1'
    if (Test-Path $script:BackDeriveLib) {
        . $script:BackDeriveLib
    }

    $script:AuditFixtureDir = Join-Path $script:RepoRoot 'frame/audit-fixtures'
    $script:FixtureDir = Join-Path $PSScriptRoot 'fixtures'
    $script:PortsDir = Join-Path $script:RepoRoot 'frame/ports'
    $script:CeGateAdaptersDir = Join-Path $script:RepoRoot 'skills/customer-experience/adapters'

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
        # Default: all seven values (for ports not in the table)
        return @('passed', 'failed', 'skipped', 'not-applicable', 'inconclusive', 'not-persisted', 'overridden')
    }

    function script:Get-CreditBuilderFunctionAst {
        param([Parameter(Mandatory)][string]$Name)

        return $script:LedgerCoreAst.Find({
            $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $args[0].Name -eq $Name
        }, $true)
    }

    function script:Copy-BuilderInputs {
        param([Parameter(Mandatory)][hashtable]$InputMap)

        $copy = @{}
        foreach ($key in $InputMap.Keys) {
            $copy[$key] = $InputMap[$key]
        }
        return $copy
    }

    function script:Get-CreditField {
        param(
            [Parameter(Mandatory)]$LedgerRow,
            [Parameter(Mandatory)][string]$Name
        )

        if ($LedgerRow -is [System.Collections.IDictionary]) {
            return $LedgerRow[$Name]
        }

        $property = $LedgerRow.PSObject.Properties[$Name]
        if ($null -eq $property) {
            return $null
        }
        return $property.Value
    }

    # Canonical inputs for each builder.
    $script:BuilderInputs = @{
        'Build-ReviewCreditRow'           = @{
            JudgeRulingsComment = @'
<!-- judge-rulings
- id: F1
  judge_ruling: defense-sustained
  judge_confidence: high
  points_awarded: D+1
-->
'@
        }
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
    @{ Name = 'Build-ReviewCreditRow' }
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
# (a2) Cycle-aware credit-row builder contract (issue #512 Step 3 / AC7)
# ---------------------------------------------------------------------------

Describe 'Cycle-aware credit-row builder contract (issue #512 Step 3 / AC7)' -ForEach @(
    @{ Name = 'Build-ReviewCreditRow' }
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

    It "$Name exposes appended optional [int]`$Step = 0" {
        $script:LedgerCoreParseErrors | Should -BeNullOrEmpty -Because 'credit-row builder source must parse before AST contract checks can run'

        $functionAst = script:Get-CreditBuilderFunctionAst -Name $Name
        $functionAst | Should -Not -BeNullOrEmpty -Because "$Name must exist in frame-credit-ledger-core.ps1"
        if ($null -eq $functionAst) { return }

        $parameters = @($functionAst.Body.ParamBlock.Parameters)
        $stepParam = @($parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Step' })
        $stepParam.Count | Should -Be 1 -Because "$Name must expose exactly one Step parameter"
        if ($stepParam.Count -ne 1) { return }

        $parameters[-1].Name.VariablePath.UserPath | Should -Be 'Step' -Because '-Step is appended so existing call sites keep their parameter order contract'
        $stepParam[0].StaticType.Name | Should -Be 'Int32' -Because '-Step is an integer commit-index/sentinel value'
        $stepParam[0].DefaultValue.Extent.Text | Should -Be '0' -Because 'omitted -Step must preserve legacy/spine-omitted behavior'
    }

    It "$Name omits terminal-step-id when -Step is omitted" {
        $inputs = script:Copy-BuilderInputs -InputMap $script:BuilderInputs[$Name]
        $row = & $Name @inputs

        $row | Should -Not -BeNullOrEmpty
        $row.PSObject.Properties.Name | Should -Not -Contain 'terminal-step-id' -Because 'omitting -Step must preserve the existing row shape for legacy emitters'
    }

    It "$Name treats -Step 0 as the legacy sentinel identity" {
        $legacyInputs = script:Copy-BuilderInputs -InputMap $script:BuilderInputs[$Name]
        $legacyRow = & $Name @legacyInputs

        $stepZeroInputs = script:Copy-BuilderInputs -InputMap $script:BuilderInputs[$Name]
        $stepZeroInputs['Step'] = 0
        $stepZeroRow = & $Name @stepZeroInputs

        ($stepZeroRow | ConvertTo-Json -Depth 20) | Should -Be ($legacyRow | ConvertTo-Json -Depth 20) -Because 'Step 0 is the spine-omitted any-step sentinel and must not split legacy row identity'
    }

    It "$Name records positive -Step as terminal-step-id" {
        $inputs = script:Copy-BuilderInputs -InputMap $script:BuilderInputs[$Name]
        $inputs['Step'] = 3

        $row = & $Name @inputs

        $row.PSObject.Properties.Name | Should -Contain 'terminal-step-id' -Because 'cycle-aware additive merge needs a terminal step identifier on positive Step rows'
        $row.'terminal-step-id' | Should -Be 3
    }
}

Describe 'Pipeline metrics v4 schema documentation (issue #512 fallback metrics)' {

    BeforeAll {
        $script:PipelineMetricsSchemaPath = Join-Path $script:RepoRoot 'frame/pipeline-metrics-v4-schema.md'
        $script:PipelineMetricsSchema = (Get-Content -Path $script:PipelineMetricsSchemaPath -Raw -ErrorAction Stop) -replace "`r`n?", "`n"
    }

    It 'documents optional dispatch fallback metrics and stale-spine count semantics' {
        $script:PipelineMetricsSchema | Should -Match 'dispatch-fallback-events' `
            -Because 'v4 schema must name the fallback event container'
        $script:PipelineMetricsSchema | Should -Match 'spine-stale-fallback-count' `
            -Because 'v4 schema must name the derived stale-spine counter'
        $script:PipelineMetricsSchema | Should -Match '(?is)dispatch-fallback-events.{0,220}optional.{0,220}absent when no dispatch fallback' `
            -Because 'absence is the default when no fallback occurred'
        $script:PipelineMetricsSchema | Should -Match 'legacy-plan-shape:\s*true' `
            -Because 'legacy plan fallback event key must be documented'
        $script:PipelineMetricsSchema | Should -Match 'pre-load-budget-exceeded:\s*true' `
            -Because 'budget fallback event key must be documented'
        $script:PipelineMetricsSchema | Should -Match '(?is)stale-spine\[\].{0,260}step.{0,180}reason.{0,220}(generated_at-mismatch|missing-step-id)' `
            -Because 'stale-spine events must document their event keys and allowed reasons'
        $script:PipelineMetricsSchema | Should -Match '(?is)spine-stale-fallback-count.{0,420}max\(existing count, observed stale-spine event count\)' `
            -Because 'the derived count must preserve higher existing values during additive updates'
        $script:PipelineMetricsSchema | Should -Match '(?is)Dispatch fallback metrics follow the same preservation rule.{0,260}preserve unrelated metrics' `
            -Because 'fallback metrics must document additive preservation behavior'
    }
}

Describe 'Cycle-aware additive merge identity (issue #512 Step 3 / AC7)' {
    It 'preserves separate positive terminal-step rows for the same port' {
        $metricsBlock = @'
metrics_version: 4
credits:
  - port: implement-code
    terminal-step-id: 1
    status: passed
    evidence: "step 1 implementation credit"
  - port: implement-code
    terminal-step-id: 2
    status: passed
    evidence: "step 2 implementation credit"
'@

        $existingCredits = Get-FBDExistingCredits -MetricsBlock $metricsBlock
        $implementCodeRows = @($existingCredits.Values | Where-Object { [string](script:Get-CreditField -LedgerRow $_ -Name 'port') -eq 'implement-code' })

        $implementCodeRows.Count | Should -Be 2 -Because 'additive merge identity is (port, terminal-step-id) for positive Step rows'
        [int[]]$terminalStepIds = @($implementCodeRows | ForEach-Object { script:Get-CreditField -LedgerRow $_ -Name 'terminal-step-id' })
        @($terminalStepIds | Sort-Object) | Should -Be @(1, 2)
    }

    It 'collapses omitted and zero terminal-step rows to the legacy first-write identity' {
        $metricsBlock = @'
metrics_version: 4
credits:
  - port: implement-test
    status: passed
    evidence: "legacy first write"
  - port: implement-test
    terminal-step-id: 0
    status: failed
    evidence: "duplicate zero-step write"
'@

        $existingCredits = Get-FBDExistingCredits -MetricsBlock $metricsBlock
        $implementTestRows = @($existingCredits.Values | Where-Object { [string](script:Get-CreditField -LedgerRow $_ -Name 'port') -eq 'implement-test' })

        $implementTestRows.Count | Should -Be 1 -Because 'omitted Step and Step 0 share the legacy (port, 0) identity'
        script:Get-CreditField -LedgerRow $implementTestRows[0] -Name 'evidence' | Should -Be 'legacy first write' -Because 'legacy/Step 0 additive merge keeps the first writer and does not double-write the port'
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

Describe 'Build-CeGateCreditRow ValidateSet matches ce-gate-*-auto-na-adapter files (Step 6e)' {

    It 'each ce-gate-*-auto-na-adapter.md adapter has a matching surface value in the ValidateSet' {
        $adapterFiles = @(Get-ChildItem -Path $script:CeGateAdaptersDir -Filter 'ce-gate-*-auto-na-adapter.md' -ErrorAction SilentlyContinue)

        if ($adapterFiles.Count -eq 0) {
            Set-ItResult -Skipped -Because 'No ce-gate-*-auto-na-adapter.md adapter files found'
            return
        }

        # Extract surface names from file names: ce-gate-{surface}-auto-na-adapter.md
        $adapterSurfaces = @($adapterFiles | ForEach-Object {
            if ($_.Name -match '^ce-gate-(.+)-auto-na-adapter\.md$') { $Matches[1] }
        })

        $validSetSurfaces = @('cli', 'browser', 'canvas', 'api')

        foreach ($surface in $adapterSurfaces) {
            $validSetSurfaces | Should -Contain $surface -Because "adapter ce-gate-$surface-auto-na-adapter.md must match a ValidateSet value in Build-CeGateCreditRow"
        }
    }

    It 'Build-CeGateCreditRow has a ValidateSet surface for each ce-gate-*-auto-na-adapter.md adapter' {
        $adapterFiles = @(Get-ChildItem -Path $script:CeGateAdaptersDir -Filter 'ce-gate-*-auto-na-adapter.md' -ErrorAction SilentlyContinue)

        $adapterSurfaces = @($adapterFiles | ForEach-Object {
            if ($_.Name -match '^ce-gate-(.+)-auto-na-adapter\.md$') { $Matches[1] }
        })

        $validSetSurfaces = @('cli', 'browser', 'canvas', 'api')

        foreach ($surface in $validSetSurfaces) {
            $adapterSurfaces | Should -Contain $surface -Because "ValidateSet surface '$surface' must have a matching ce-gate-$surface-auto-na-adapter.md adapter file"
        }
    }
}
