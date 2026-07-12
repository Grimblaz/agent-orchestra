#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester 5 tests for Invoke-CreateImprovementIssue (create-improvement-issue-core.ps1).

.DESCRIPTION
    Gate ordering under test: §2d consolidation → calibration dedup → GitHub search
    dedup → D10 ceiling advisory → D-259-7 classification → create → linkage.

    All tests use mock gh CLI via -GhCliPath parameter and are tagged 'no-gh'.
#>

Describe 'Invoke-CreateImprovementIssue' -Tag 'no-gh' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:CorePath = Join-Path $script:RepoRoot 'skills/calibration-pipeline/scripts/create-improvement-issue-core.ps1'
        $script:WrapperPath = Join-Path $script:RepoRoot 'skills/calibration-pipeline/scripts/create-improvement-issue.ps1'
        . $script:CorePath

        # ── temp root for all test data ──────────────────────────────
        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "cii-tests-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null

        # ── #837 R1 / #849 G1: filing routes through Add-FollowUpIssue.
        # Add-FollowUpIssue now accepts -GhCliPath and Invoke-CreateImprovementIssue
        # forwards its own -GhCliPath value through to it (#849 G1), so filing
        # travels through the SAME per-test mock script the Gates 1-3 dedup
        # calls use, rather than always hitting the literal `gh` binary. This
        # global:gh function remains as the shadow for the *default*
        # -GhCliPath = 'gh' path only (used if a test ever omits -GhCliPath):
        # Add-FollowUpIssue.ps1 is dot-sourced into this Describe's own scope
        # (via create-improvement-issue-core.ps1's own dot-source), so a bare
        # `gh` call from inside it resolves to this function with no scope
        # boundary in between. The per-test mock .ps1 files below are a
        # SEPARATE script file invoked via `&`, which creates a fresh script
        # scope — `$script:` inside a function called from that new scope
        # resolves to the mock's own (empty) scope, not this one, so those
        # mocks must answer 'issue create'/'issue edit' with baked-in values
        # instead of delegating back here.
        $script:NextCreateIssueUrl = ''
        $script:CapturedCreateArgsFile = $null

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$RemainingArgs)
            $joined = $RemainingArgs -join ' '

            if ($joined -match 'issue\s+create') {
                if ($script:CapturedCreateArgsFile) {
                    $RemainingArgs | Out-File -FilePath $script:CapturedCreateArgsFile -Encoding UTF8
                }
                $global:LASTEXITCODE = 0
                return $script:NextCreateIssueUrl
            }
            if ($joined -match 'issue\s+edit') {
                $global:LASTEXITCODE = 0
                return ''
            }
            if ($joined -match 'issue\s+view\s+\d+\s+--json\s+id\s+--jq\s+\.id') {
                $global:LASTEXITCODE = 0
                return 'I_node_id'
            }
            if ($joined -match 'api\s+graphql') {
                $global:LASTEXITCODE = 0
                return '{"data":{"addSubIssue":{"issue":{"title":"Child"}}}}'
            }
            $global:LASTEXITCODE = 0
            return ''
        }

        # ── helper: create an isolated work directory per test ────────
        $script:NewWorkDir = {
            $dir = Join-Path $script:TempRoot ([System.Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            return $dir
        }

        # ── helper: write mock gh CLI with argument routing ──────────
        # #849 G1: filing now travels through this SAME mock (Add-FollowUpIssue
        # forwards -GhCliPath), so it must answer 'issue create' (filing) and
        # 'issue edit' (M13 marker append) itself with baked-in values, rather
        # than delegating to the global:gh shadow -- a standalone .ps1 invoked
        # via `&` gets its own fresh script scope, so `$script:` inside a
        # function called back from there can't reach this Describe's state
        # (see the BeforeAll note above this helper's Describe block).
        $script:WriteMockGh = {
            param(
                [string]$WorkDir,
                [string]$IssueListOutput = '[]',
                [string]$IssueCreateOutput = '',
                [int]$IssueListExitCode = 0,
                [int]$IssueCreateExitCode = 0
            )
            $listFile = Join-Path $WorkDir 'gh-list-response.json'
            $mockPath = Join-Path $WorkDir 'gh.ps1'
            $IssueListOutput | Set-Content -Path $listFile -Encoding UTF8
            $createOutputEscaped = $IssueCreateOutput -replace "'", "''"
            @"
# Mock gh CLI — routes 'issue list' (Gates 1-3), 'issue create' (filing,
# #849 G1), and 'issue edit' (M13 marker append) with baked-in responses.
`$joined = `$args -join ' '
if (`$joined -match 'issue\s+list') {
    Get-Content -Raw -Path '$($listFile -replace "'", "''")'
    exit $IssueListExitCode
}
if (`$joined -match 'issue\s+create') {
    Write-Output '$createOutputEscaped'
    exit $IssueCreateExitCode
}
if (`$joined -match 'issue\s+edit') {
    exit 0
}
exit 0
"@ | Set-Content -Path $mockPath -Encoding UTF8
            return $mockPath
        }

        # ── helper: mock gh with §2d / search-dedup routing ─────────
        # §2d list has NO --search flag; GitHub dedup uses --search
        $script:WriteMockGhDualList = {
            param(
                [string]$WorkDir,
                [string]$Section2dOutput = '[]',
                [string]$SearchDedupOutput = '[]',
                [string]$IssueCreateOutput = '',
                [int]$IssueCreateExitCode = 0
            )
            $s2dFile = Join-Path $WorkDir 'gh-s2d-response.json'
            $dedupFile = Join-Path $WorkDir 'gh-dedup-response.json'
            $mockPath = Join-Path $WorkDir 'gh.ps1'
            $Section2dOutput   | Set-Content -Path $s2dFile    -Encoding UTF8
            $SearchDedupOutput | Set-Content -Path $dedupFile  -Encoding UTF8
            $createOutputEscaped = $IssueCreateOutput -replace "'", "''"
            @"
# Mock gh CLI — routes §2d list vs search-dedup list (Gates 1-3), plus
# 'issue create'/'issue edit' with baked-in responses (#849 G1: filing now
# travels through this same mock; see WriteMockGh's note on why it can't
# delegate to the global:gh shadow).
`$joined = `$args -join ' '
if (`$joined -match 'issue\s+list' -and `$joined -match '--search') {
    Get-Content -Raw -Path '$($dedupFile -replace "'", "''")'
    exit 0
}
if (`$joined -match 'issue\s+list') {
    Get-Content -Raw -Path '$($s2dFile -replace "'", "''")'
    exit 0
}
if (`$joined -match 'issue\s+create') {
    Write-Output '$createOutputEscaped'
    exit $IssueCreateExitCode
}
if (`$joined -match 'issue\s+edit') {
    exit 0
}
exit 0
"@ | Set-Content -Path $mockPath -Encoding UTF8
            return $mockPath
        }

        # ── helper: mock gh with arg-capture for issue create ────────
        # #849 G1: filing travels through this same mock now, so 'issue
        # create' captures its own args directly to $argsFile and returns
        # the baked-in $CreateOutput, instead of delegating to the
        # global:gh shadow (see WriteMockGh's note on why that delegation
        # doesn't work from a standalone .ps1 invoked via `&`).
        $script:WriteMockGhWithArgCapture = {
            param(
                [string]$WorkDir,
                [string]$CreateOutput = '',
                [int]$CreateExitCode = 0
            )
            $argsFile = Join-Path $WorkDir 'gh-captured-args.txt'
            $mockPath = Join-Path $WorkDir 'gh.ps1'
            $createOutputEscaped = $CreateOutput -replace "'", "''"
            @"
# Mock gh CLI — routes 'issue list' (Gates 1-3); 'issue create' captures its
# args to '$($argsFile -replace "'", "''")' for assertion (#849 G1) and
# returns a baked-in URL; 'issue edit' is a no-op success.
`$joined = `$args -join ' '
if (`$joined -match 'issue\s+list') {
    Write-Output '[]'
    exit 0
}
if (`$joined -match 'issue\s+create') {
    `$args | Out-File -FilePath '$($argsFile -replace "'", "''")' -Encoding UTF8
    Write-Output '$createOutputEscaped'
    exit $CreateExitCode
}
if (`$joined -match 'issue\s+edit') {
    exit 0
}
exit 0
"@ | Set-Content -Path $mockPath -Encoding UTF8
            return @{ MockPath = $mockPath; ArgsFile = $argsFile }
        }

        # ── helper: write calibration JSON file ──────────────────────
        $script:WriteCalibrationFile = {
            param([string]$Path, [object]$Data)
            $dir = Split-Path $Path -Parent
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $Data | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding UTF8
        }

        # ── helper: write complexity JSON file ───────────────────────
        $script:WriteComplexityJson = {
            param([string]$Path, [string[]]$AgentsOverCeiling = @())
            $dir = Split-Path $Path -Parent
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            @{
                agents_over_ceiling = $AgentsOverCeiling
                agents              = @()
            } | ConvertTo-Json -Depth 5 | Set-Content -Path $Path -Encoding UTF8
        }

        # ── standard base params for splatting ───────────────────────
        $script:BaseParams = @{
            PatternKey              = 'agent-prompt:implementation-clarity'
            EvidencePrs             = @(245, 248, 252)
            FirstEmittedAt          = '2026-04-03T10:00:00Z'
            FixTypeLevel            = 5
            TargetFile              = 'agents/Code-Critic.agent.md'
            ProposedChange          = 'Add defensive validation for empty input arrays'
            SystemicFixType         = 'agent-prompt'
            Repo                    = 'Grimblaz/agent-orchestra'
            UpstreamPreflightPassed = $true
        }
    }

    BeforeEach {
        $script:NextCreateIssueUrl = ''
        $script:CapturedCreateArgsFile = $null
        $global:LASTEXITCODE = 0
    }

    AfterAll {
        if (Test-Path $script:TempRoot) {
            Remove-Item -Recurse -Force -Path $script:TempRoot -ErrorAction SilentlyContinue
        }
        Remove-Item -Path Function:\gh -ErrorAction SilentlyContinue
    }

    # ═══════════════════════════════════════════════════════════════════
    # CLI wrapper structural checks
    # ═══════════════════════════════════════════════════════════════════
    Context 'CLI wrapper (create-improvement-issue.ps1)' -Tag 'no-gh' {
        It 'wrapper script exists, dot-sources lib, and has matching params' {
            $wrapperPath = $script:WrapperPath
            $wrapperPath | Should -Exist

            $wrapperContent = Get-Content -Raw -Path $wrapperPath
            $wrapperContent | Should -Match 'create-improvement-issue-core\.ps1'

            $wrapperAst = [System.Management.Automation.Language.Parser]::ParseInput(
                $wrapperContent, [ref]$null, [ref]$null)
            $wrapperParams = $wrapperAst.ParamBlock.Parameters |
                ForEach-Object { $_.Name.VariablePath.UserPath }

            $commonParams = @(
                'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction',
                'ErrorVariable', 'WarningVariable', 'InformationVariable',
                'OutVariable', 'OutBuffer', 'PipelineVariable', 'ProgressAction')
            $libParams = (Get-Command Invoke-CreateImprovementIssue).Parameters.Keys |
                Where-Object { $_ -notin $commonParams }

            $wrapperParams | Should -Be $libParams
        }
    }

    # ═══════════════════════════════════════════════════════════════════
    # Gate 1 — §2d consolidation
    # ═══════════════════════════════════════════════════════════════════
    Context '§2d consolidation gate' {

        It '§2d consolidation — candidate found → returns consolidation-candidate' {
            # Arrange
            $wd = & $script:NewWorkDir
            $mock = & $script:WriteMockGh -WorkDir $wd `
                -IssueListOutput '[{"number":100,"title":"[Systemic Fix] agent-prompt in agents/"}]'
            $params = $script:BaseParams.Clone()
            $params.GhCliPath = $mock

            # Act
            $result = Invoke-CreateImprovementIssue @params

            # Assert
            $result.Action              | Should -Be 'consolidation-candidate'
            $result.ConsolidationTarget | Should -Be 100
            $result.IssueNumber         | Should -BeNullOrEmpty
            $result.ExitCode            | Should -Be 0
        }

        It '§2d consolidation — no candidate → proceeds to Gate 2' {
            # Arrange
            $wd = & $script:NewWorkDir
            $mock = & $script:WriteMockGh -WorkDir $wd `
                -IssueListOutput '[]' `
                -IssueCreateOutput 'https://github.com/Grimblaz/agent-orchestra/issues/201'
            $params = $script:BaseParams.Clone()
            $params.GhCliPath = $mock

            # Act
            $result = Invoke-CreateImprovementIssue @params

            # Assert — proves it passed Gate 1 and reached creation
            $result.Action | Should -Be 'created'
        }
    }

    # ═══════════════════════════════════════════════════════════════════
    # Gate 2 — calibration dedup
    # ═══════════════════════════════════════════════════════════════════
    Context 'calibration dedup gate' {

        It 'calibration dedup — pattern_key match with fix_issue_number → skipped-dedup' {
            # Arrange
            $wd = & $script:NewWorkDir
            $calPath = Join-Path $wd 'calibration.json'
            & $script:WriteCalibrationFile -Path $calPath -Data @{
                proposals_emitted = @(
                    @{
                        pattern_key      = 'agent-prompt:implementation-clarity'
                        evidence_prs     = @(245, 248, 252)
                        first_emitted_at = '2026-04-03T10:00:00Z'
                        fix_issue_number = 270
                    }
                )
            }
            $mock = & $script:WriteMockGh -WorkDir $wd -IssueListOutput '[]'
            $params = $script:BaseParams.Clone()
            $params.GhCliPath = $mock
            $params.CalibrationPath = $calPath

            # Act
            $result = Invoke-CreateImprovementIssue @params

            # Assert
            $result.Action   | Should -Be 'skipped-dedup'
            $result.ExitCode | Should -Be 0
        }

        It 'calibration dedup — pattern_key match without fix_issue_number (backward compat) → proceeds to Gate 3' {
            # Arrange — entry has matching pattern_key but NO fix_issue_number field
            $wd = & $script:NewWorkDir
            $calPath = Join-Path $wd 'calibration.json'
            & $script:WriteCalibrationFile -Path $calPath -Data @{
                proposals_emitted = @(
                    @{
                        pattern_key      = 'agent-prompt:implementation-clarity'
                        evidence_prs     = @(245, 248, 252)
                        first_emitted_at = '2026-04-03T10:00:00Z'
                    }
                )
            }
            $mock = & $script:WriteMockGh -WorkDir $wd `
                -IssueListOutput '[]' `
                -IssueCreateOutput 'https://github.com/Grimblaz/agent-orchestra/issues/202'
            $params = $script:BaseParams.Clone()
            $params.GhCliPath = $mock
            $params.CalibrationPath = $calPath

            # Act
            $result = Invoke-CreateImprovementIssue @params

            # Assert — proves it tolerated missing fix_issue_number and reached creation
            $result.Action | Should -Be 'created'
        }

        It 'calibration dedup — no matching pattern_key → proceeds to Gate 3' {
            # Arrange — calibration has a DIFFERENT pattern_key
            $wd = & $script:NewWorkDir
            $calPath = Join-Path $wd 'calibration.json'
            & $script:WriteCalibrationFile -Path $calPath -Data @{
                proposals_emitted = @(
                    @{
                        pattern_key      = 'skill:something-else'
                        evidence_prs     = @(100)
                        first_emitted_at = '2026-01-01T00:00:00Z'
                        fix_issue_number = 50
                    }
                )
            }
            $mock = & $script:WriteMockGh -WorkDir $wd `
                -IssueListOutput '[]' `
                -IssueCreateOutput 'https://github.com/Grimblaz/agent-orchestra/issues/203'
            $params = $script:BaseParams.Clone()
            $params.GhCliPath = $mock
            $params.CalibrationPath = $calPath

            # Act
            $result = Invoke-CreateImprovementIssue @params

            # Assert
            $result.Action | Should -Be 'created'
        }
    }

    # ═══════════════════════════════════════════════════════════════════
    # Gate 3 — GitHub search dedup
    # ═══════════════════════════════════════════════════════════════════
    Context 'GitHub search dedup gate' {

        It 'GitHub search dedup — match found → skipped-dedup' {
            # Arrange — §2d returns empty, GitHub search returns a match
            $wd = & $script:NewWorkDir
            $mock = & $script:WriteMockGhDualList -WorkDir $wd `
                -Section2dOutput '[]' `
                -SearchDedupOutput '[{"number":150,"title":"[Systemic Fix] agent-prompt implementation-clarity"}]'
            $params = $script:BaseParams.Clone()
            $params.GhCliPath = $mock

            # Act
            $result = Invoke-CreateImprovementIssue @params

            # Assert
            $result.Action | Should -Be 'skipped-dedup'
        }

        It 'GitHub search dedup — no match → proceeds to creation' {
            # Arrange — both list calls return empty
            $wd = & $script:NewWorkDir
            $mock = & $script:WriteMockGhDualList -WorkDir $wd `
                -Section2dOutput '[]' `
                -SearchDedupOutput '[]' `
                -IssueCreateOutput 'https://github.com/Grimblaz/agent-orchestra/issues/204'
            $params = $script:BaseParams.Clone()
            $params.GhCliPath = $mock

            # Act
            $result = Invoke-CreateImprovementIssue @params

            # Assert
            $result.Action | Should -Be 'created'
        }
    }

    # ═══════════════════════════════════════════════════════════════════
    # D10 ceiling advisory
    # ═══════════════════════════════════════════════════════════════════
    Context 'D10 ceiling advisory' {

        It 'D10 ceiling — over ceiling + L5 → advisory populated' {
            # Arrange
            $wd = & $script:NewWorkDir
            $complexityPath = Join-Path $wd 'complexity.json'
            & $script:WriteComplexityJson -Path $complexityPath `
                -AgentsOverCeiling @('Code-Critic.agent.md')
            $mock = & $script:WriteMockGh -WorkDir $wd `
                -IssueListOutput '[]' `
                -IssueCreateOutput 'https://github.com/Grimblaz/agent-orchestra/issues/205'
            $params = $script:BaseParams.Clone()
            $params.GhCliPath = $mock
            $params.FixTypeLevel = 5
            $params.TargetFile = 'agents/Code-Critic.agent.md'
            $params.ComplexityJsonPath = $complexityPath

            # Act
            $result = Invoke-CreateImprovementIssue @params

            # Assert
            $result.Action         | Should -Be 'created'
            $result.CeilingAdvisory | Should -Not -BeNullOrEmpty
        }

        It 'D10 ceiling — over ceiling + L2 → advisory null (structural fixes exempt)' {
            # Arrange
            $wd = & $script:NewWorkDir
            $complexityPath = Join-Path $wd 'complexity.json'
            & $script:WriteComplexityJson -Path $complexityPath `
                -AgentsOverCeiling @('Code-Critic.agent.md')
            $mock = & $script:WriteMockGh -WorkDir $wd `
                -IssueListOutput '[]' `
                -IssueCreateOutput 'https://github.com/Grimblaz/agent-orchestra/issues/206'
            $params = $script:BaseParams.Clone()
            $params.GhCliPath = $mock
            $params.FixTypeLevel = 2
            $params.TargetFile = 'agents/Code-Critic.agent.md'
            $params.ComplexityJsonPath = $complexityPath

            # Act
            $result = Invoke-CreateImprovementIssue @params

            # Assert
            $result.CeilingAdvisory | Should -BeNullOrEmpty
        }

        It 'D10 ceiling — non-agent target → ceiling check skipped' {
            # Arrange — target is an instruction file, not an agent
            $wd = & $script:NewWorkDir
            $complexityPath = Join-Path $wd 'complexity.json'
            & $script:WriteComplexityJson -Path $complexityPath `
                -AgentsOverCeiling @('Code-Critic.agent.md')
            $mock = & $script:WriteMockGh -WorkDir $wd `
                -IssueListOutput '[]' `
                -IssueCreateOutput 'https://github.com/Grimblaz/agent-orchestra/issues/207'
            $params = $script:BaseParams.Clone()
            $params.GhCliPath = $mock
            $params.TargetFile = 'skills/safe-operations/SKILL.md'
            $params.ComplexityJsonPath = $complexityPath

            # Act
            $result = Invoke-CreateImprovementIssue @params

            # Assert
            $result.CeilingAdvisory | Should -BeNullOrEmpty
        }

        It 'D10 ceiling — basename extraction matches agents_over_ceiling' {
            # Arrange — full path target, basename-only in agents_over_ceiling
            $wd = & $script:NewWorkDir
            $complexityPath = Join-Path $wd 'complexity.json'
            & $script:WriteComplexityJson -Path $complexityPath `
                -AgentsOverCeiling @('Code-Critic.agent.md')
            $mock = & $script:WriteMockGh -WorkDir $wd `
                -IssueListOutput '[]' `
                -IssueCreateOutput 'https://github.com/Grimblaz/agent-orchestra/issues/208'
            $params = $script:BaseParams.Clone()
            $params.GhCliPath = $mock
            $params.FixTypeLevel = 5
            $params.TargetFile = 'agents/Code-Critic.agent.md'
            $params.ComplexityJsonPath = $complexityPath

            # Act
            $result = Invoke-CreateImprovementIssue @params

            # Assert
            $result.Action          | Should -Be 'created'
            $result.CeilingAdvisory | Should -Not -BeNullOrEmpty
        }
    }

    # ═══════════════════════════════════════════════════════════════════
    # D-259-7 classification
    # ═══════════════════════════════════════════════════════════════════
    Context 'D-259-7 classification' {

        It 'classification — default levels for each systemic_fix_type' -ForEach @(
            @{ FixType = 'plan-template'; ExpectedLevel = 3; FixTypeLevel = 99 }
            @{ FixType = 'instruction'; ExpectedLevel = 4; FixTypeLevel = 99 }
            @{ FixType = 'skill'; ExpectedLevel = 4; FixTypeLevel = 99 }
            @{ FixType = 'agent-prompt'; ExpectedLevel = 5; FixTypeLevel = 99 }
        ) {
            # Arrange — FixTypeLevel=99 (sentinel) proves lookup table overrides input
            $wd = & $script:NewWorkDir
            $mock = & $script:WriteMockGh -WorkDir $wd `
                -IssueListOutput '[]' `
                -IssueCreateOutput 'https://github.com/Grimblaz/agent-orchestra/issues/210'
            $params = $script:BaseParams.Clone()
            $params.GhCliPath = $mock
            $params.SystemicFixType = $FixType
            $params.FixTypeLevel = $FixTypeLevel

            # Act
            $result = Invoke-CreateImprovementIssue @params

            # Assert — lookup table returns ExpectedLevel, not the sentinel 99
            $result.ClassifiedLevel | Should -Be $ExpectedLevel
        }

        It 'classification — ProposedChange keyword "contract test" → SuggestedLevel 1' {
            # Arrange
            $wd = & $script:NewWorkDir
            $mock = & $script:WriteMockGh -WorkDir $wd `
                -IssueListOutput '[]' `
                -IssueCreateOutput 'https://github.com/Grimblaz/agent-orchestra/issues/211'
            $params = $script:BaseParams.Clone()
            $params.GhCliPath = $mock
            $params.ProposedChange = 'Add contract test for pattern detection'

            # Act
            $result = Invoke-CreateImprovementIssue @params

            # Assert
            $result.SuggestedLevel  | Should -Be 1
            $result.ClassifiedLevel | Should -Be 5   # default for agent-prompt
        }

        It 'classification — ProposedChange keyword "pre-flight" → SuggestedLevel 2' {
            # Arrange
            $wd = & $script:NewWorkDir
            $mock = & $script:WriteMockGh -WorkDir $wd `
                -IssueListOutput '[]' `
                -IssueCreateOutput 'https://github.com/Grimblaz/agent-orchestra/issues/213'
            $params = $script:BaseParams.Clone()
            $params.GhCliPath = $mock
            $params.ProposedChange = 'Add pre-flight validation for detection'

            # Act
            $result = Invoke-CreateImprovementIssue @params

            # Assert
            $result.SuggestedLevel  | Should -Be 2
            $result.ClassifiedLevel | Should -Be 5   # default for agent-prompt
        }

        It 'classification — ProposedChange keyword "template field" → SuggestedLevel 3' {
            # Arrange
            $wd = & $script:NewWorkDir
            $mock = & $script:WriteMockGh -WorkDir $wd `
                -IssueListOutput '[]' `
                -IssueCreateOutput 'https://github.com/Grimblaz/agent-orchestra/issues/214'
            $params = $script:BaseParams.Clone()
            $params.GhCliPath = $mock
            $params.ProposedChange = 'Add template field for pattern detection'

            # Act
            $result = Invoke-CreateImprovementIssue @params

            # Assert
            $result.SuggestedLevel  | Should -Be 3
            $result.ClassifiedLevel | Should -Be 5   # default for agent-prompt
        }

        It 'classification — FixTypeOverride wins over default and heuristic' {
            # Arrange — SystemicFixType=agent-prompt (default=5), but FixTypeOverride forces level 2
            $wd = & $script:NewWorkDir
            $mock = & $script:WriteMockGh -WorkDir $wd `
                -IssueListOutput '[]' `
                -IssueCreateOutput 'https://github.com/Grimblaz/agent-orchestra/issues/212'
            $params = $script:BaseParams.Clone()
            $params.GhCliPath = $mock
            $params.SystemicFixType = 'agent-prompt'
            $params.FixTypeLevel = 2
            $params.FixTypeOverride = 'Structural wording-lock required per contract'

            # Act
            $result = Invoke-CreateImprovementIssue @params

            # Assert — override wins: ClassifiedLevel = FixTypeLevel (2), not default 5
            $result.ClassifiedLevel | Should -Be 2
        }
    }

    # ═══════════════════════════════════════════════════════════════════
    # New-ImprovementIssueProposal (#837 R1 assemble-only half of the split)
    # ═══════════════════════════════════════════════════════════════════
    Context 'New-ImprovementIssueProposal (assemble-only)' {

        It 'gates passed → returns a would-create proposal with Title/Body/Labels and never files' {
            # Arrange
            $wd = & $script:NewWorkDir
            $mock = & $script:WriteMockGh -WorkDir $wd -IssueListOutput '[]'
            $params = $script:BaseParams.Clone()
            $params.GhCliPath = $mock

            # Act
            $result = New-ImprovementIssueProposal @params

            # Assert
            $result.Action | Should -Be 'would-create'
            $result.Title   | Should -Match '\[Systemic Fix\] agent-prompt — implementation-clarity'
            $result.Body    | Should -Match 'defensive validation'
            $result.Labels  | Should -Be @('priority: medium')
            $result.ClassifiedLevel | Should -Be 5
            # #849 post-fix: New-ImprovementIssueProposal contains zero filing
            # code — 'Action' can only ever be 'would-create' here (filing and
            # the 'created' action value live exclusively in the separate
            # Invoke-CreateImprovementIssue wrapper, after Add-FollowUpIssue
            # succeeds). The Action assertion above is the real regression
            # guard: it would fail if filing logic were ever moved into this
            # assemble-only function, independent of what the gh mock does.
        }

        It 'consolidation-candidate short-circuits before assembling a proposal (no Title/Body)' {
            # Arrange
            $wd = & $script:NewWorkDir
            $mock = & $script:WriteMockGh -WorkDir $wd `
                -IssueListOutput '[{"number":100,"title":"[Systemic Fix] agent-prompt in agents/"}]'
            $params = $script:BaseParams.Clone()
            $params.GhCliPath = $mock

            # Act
            $result = New-ImprovementIssueProposal @params

            # Assert
            $result.Action | Should -Be 'consolidation-candidate'
            $result.Title  | Should -BeNullOrEmpty
            $result.Body   | Should -BeNullOrEmpty
        }

        It 'Invoke-CreateImprovementIssue delegates gate logic to New-ImprovementIssueProposal (same ClassifiedLevel)' {
            # Arrange — same params through both entry points should agree
            # on classification, proving the wrapper doesn't duplicate gates.
            $wd1 = & $script:NewWorkDir
            $mock1 = & $script:WriteMockGh -WorkDir $wd1 -IssueListOutput '[]'
            $params1 = $script:BaseParams.Clone()
            $params1.GhCliPath = $mock1

            $wd2 = & $script:NewWorkDir
            $mock2 = & $script:WriteMockGh -WorkDir $wd2 -IssueListOutput '[]' `
                -IssueCreateOutput 'https://github.com/Grimblaz/agent-orchestra/issues/299'
            $params2 = $script:BaseParams.Clone()
            $params2.GhCliPath = $mock2

            # Act
            $proposeOnly = New-ImprovementIssueProposal @params1
            $filed = Invoke-CreateImprovementIssue @params2

            # Assert
            $proposeOnly.Action          | Should -Be 'would-create'
            $filed.Action                | Should -Be 'created'
            $filed.ClassifiedLevel       | Should -Be $proposeOnly.ClassifiedLevel
        }
    }

    # ═══════════════════════════════════════════════════════════════════
    # Issue creation
    # ═══════════════════════════════════════════════════════════════════
    Context 'issue creation' {

        It 'issue creation — happy path → created with IssueNumber' {
            # Arrange
            $wd = & $script:NewWorkDir
            $mock = & $script:WriteMockGh -WorkDir $wd `
                -IssueListOutput '[]' `
                -IssueCreateOutput 'https://github.com/Grimblaz/agent-orchestra/issues/270'
            $params = $script:BaseParams.Clone()
            $params.GhCliPath = $mock

            # Act
            $result = Invoke-CreateImprovementIssue @params

            # Assert
            $result.Action      | Should -Be 'created'
            $result.IssueNumber | Should -Be 270
            $result.ExitCode    | Should -Be 0
            $result.Output      | Should -Match '270'
        }

        It 'issue body — contains D-259-7 classification fields' {
            # Arrange — use arg-capturing mock
            $wd = & $script:NewWorkDir
            $capture = & $script:WriteMockGhWithArgCapture -WorkDir $wd `
                -CreateOutput 'https://github.com/Grimblaz/agent-orchestra/issues/271'
            $params = $script:BaseParams.Clone()
            $params.GhCliPath = $capture.MockPath

            # Act
            $result = Invoke-CreateImprovementIssue @params

            # Assert — read captured args and verify body contents
            $result.Action | Should -Be 'created'
            $capturedText = Get-Content -Raw -Path $capture.ArgsFile
            $capturedText | Should -Match 'implementation-clarity'          # pattern / level info
            $capturedText | Should -Match '(?s)--title\s+\[Systemic Fix\] agent-prompt — implementation-clarity' # title uses extracted category with em-dash
            $capturedText | Should -Not -Match '(?s)--title\s+\[Systemic Fix\] agent-prompt:implementation-clarity' # must NOT leak full pattern_key into title
            $capturedText | Should -Match '245'                             # evidence PR
            $capturedText | Should -Match 'Code-Critic\.agent\.md'          # target file
            $capturedText | Should -Match 'defensive validation'            # proposed change
            $capturedText | Should -Match 'Fix-type level'                   # classification field
            $capturedText | Should -Match 'Upstream pre-flight'              # pre-flight field
        }

        It '#837 R1 — filing routes through Add-FollowUpIssue and stamps -FilingProvenance ''pre-gate-legacy''' {
            # Arrange — use arg-capturing mock; the captured args are the
            # literal arguments Add-FollowUpIssue's internal `gh issue
            # create` call received, proving the filing primitive (not a
            # bare `gh issue create`) produced the provenance marker.
            $wd = & $script:NewWorkDir
            $capture = & $script:WriteMockGhWithArgCapture -WorkDir $wd `
                -CreateOutput 'https://github.com/Grimblaz/agent-orchestra/issues/273'
            $params = $script:BaseParams.Clone()
            $params.GhCliPath = $capture.MockPath

            # Act
            $result = Invoke-CreateImprovementIssue @params

            # Assert
            $result.Action | Should -Be 'created'
            $capturedText = Get-Content -Raw -Path $capture.ArgsFile
            $capturedText | Should -Match '<!-- filing-provenance: pre-gate-legacy -->'
            $capturedText | Should -Match '<!-- code-conductor-filed-followup'   # Add-FollowUpIssue's own sentinel (M1), proving the shared primitive ran
        }

        It 'issue body — L5 includes "Why not structural?" section' {
            # Arrange
            $wd = & $script:NewWorkDir
            $capture = & $script:WriteMockGhWithArgCapture -WorkDir $wd `
                -CreateOutput 'https://github.com/Grimblaz/agent-orchestra/issues/272'
            $params = $script:BaseParams.Clone()
            $params.GhCliPath = $capture.MockPath
            $params.FixTypeLevel = 5

            # Act
            $result = Invoke-CreateImprovementIssue @params

            # Assert
            $result.Action | Should -Be 'created'
            $capturedText = Get-Content -Raw -Path $capture.ArgsFile
            $capturedText | Should -Match 'Why not structural\?'
        }
    }

    # ═══════════════════════════════════════════════════════════════════
    # Calibration linkage
    # ═══════════════════════════════════════════════════════════════════
    Context 'calibration linkage' {

        It 'calibration linkage — fix_issue_number written after creation' {
            # Arrange — calibration entry exists but has no fix_issue_number
            $wd = & $script:NewWorkDir
            $calPath = Join-Path $wd 'calibration.json'
            & $script:WriteCalibrationFile -Path $calPath -Data @{
                proposals_emitted = @(
                    @{
                        pattern_key      = 'agent-prompt:implementation-clarity'
                        evidence_prs     = @(245, 248, 252)
                        first_emitted_at = '2026-04-03T10:00:00Z'
                    }
                )
            }
            $mock = & $script:WriteMockGh -WorkDir $wd `
                -IssueListOutput '[]' `
                -IssueCreateOutput 'https://github.com/Grimblaz/agent-orchestra/issues/270'
            $params = $script:BaseParams.Clone()
            $params.GhCliPath = $mock
            $params.CalibrationPath = $calPath

            # Act
            $result = Invoke-CreateImprovementIssue @params

            # Assert — read back the calibration file and verify linkage
            $result.Action | Should -Be 'created'
            $updatedCal = Get-Content -Raw -Path $calPath | ConvertFrom-Json
            $matchedEntry = $updatedCal.proposals_emitted |
                Where-Object { $_.pattern_key -eq 'agent-prompt:implementation-clarity' }
            $matchedEntry.fix_issue_number | Should -Be 270
        }
    }

    # ═══════════════════════════════════════════════════════════════════
    # Error handling
    # ═══════════════════════════════════════════════════════════════════
    Context 'error handling' {

        It 'error — gh CLI failure → Action=error, ExitCode=1' {
            # Arrange — gh issue create exits non-zero
            $wd = & $script:NewWorkDir
            $mock = & $script:WriteMockGh -WorkDir $wd `
                -IssueListOutput '[]' `
                -IssueCreateOutput '' `
                -IssueCreateExitCode 1
            $params = $script:BaseParams.Clone()
            $params.GhCliPath = $mock

            # Act
            $result = Invoke-CreateImprovementIssue @params

            # Assert
            $result.Action   | Should -Be 'error'
            $result.ExitCode | Should -Be 1
        }

        It 'error — PatternKey is declared Mandatory' {
            # Verify via AST introspection (no interactive prompt risk)
            $fn = Get-Command Invoke-CreateImprovementIssue -ErrorAction SilentlyContinue
            $fn | Should -Not -BeNullOrEmpty
            $paramMeta = $fn.Parameters['PatternKey']
            $paramMeta | Should -Not -BeNullOrEmpty -Because 'PatternKey parameter must exist'
            $mandatory = $paramMeta.Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
                ForEach-Object { $_.Mandatory }
            $mandatory | Should -Contain $true -Because 'PatternKey must be declared [Parameter(Mandatory)]'
        }
    }
}
