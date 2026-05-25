#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Add-FollowUpIssue' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ScriptFile = Join-Path $script:RepoRoot 'skills/safe-operations/scripts/Add-FollowUpIssue.ps1'
        
        # Load the script
        if (Test-Path $script:ScriptFile) {
            . $script:ScriptFile
        }

        # Create temporary directory for physical logs
        $script:TempDir = Join-Path ([System.IO.Path]::GetTempPath()) "gh-mock-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null
        
        $script:LogFile = Join-Path $script:TempDir 'gh-call.log'
        $script:ControlFile = Join-Path $script:TempDir 'gh-graphql-control.txt'
        
        # Define a global gh function mock that intercepts all gh calls
        function global:gh {
            param([Parameter(ValueFromRemainingArguments=$true)]$RemainingArgs)
            $joined = $RemainingArgs -join ' '
            $joined | Out-File -FilePath $script:LogFile -Append -Encoding UTF8

            if ($joined -match 'issue\s+create') {
                return "https://github.com/Grimblaz/agent-orchestra/issues/999"
            }
            if ($joined -match 'issue\s+view\s+\d+\s+--json\s+id\s+--jq\s+\.id') {
                if ($joined -match 'view\s+610') {
                    return "I_parent_610"
                }
                return "I_child_999"
            }
            if ($joined -match 'api\s+graphql') {
                if (Test-Path $script:ControlFile) {
                    $control = Get-Content -Raw -Path $script:ControlFile
                    if ($control -match 'fail') {
                        $global:LASTEXITCODE = 1
                        return $null
                    }
                }
                $global:LASTEXITCODE = 0
                return '{"data":{"addSubIssue":{"issue":{"title":"Child"}}}}'
            }
            return ""
        }
    }

    BeforeEach {
        if (Test-Path $script:LogFile) { Remove-Item $script:LogFile -Force }
        if (Test-Path $script:ControlFile) { Remove-Item $script:ControlFile -Force }
        $global:LASTEXITCODE = 0
    }

    AfterAll {
        # Remove global gh function
        if (Get-Command gh -ErrorAction SilentlyContinue) {
            Remove-Item Function:\gh -ErrorAction SilentlyContinue
        }
        if (Test-Path $script:TempDir) {
            Remove-Item -Recurse -Force $script:TempDir -ErrorAction SilentlyContinue
        }
    }

    Context 'Happy Path' {
        It 'successfully creates a follow-up issue with GraphQL parent linkage' {
            $Result = Add-FollowUpIssue -ParentIssue 610 -Title "Test Title" -Body "Test Body" -Labels @("priority: medium", "filed-by: code-conductor")
            
            $Result | Should -Be "https://github.com/Grimblaz/agent-orchestra/issues/999"
            
            # Verify issue create command carried both labels
            $log = Get-Content $script:LogFile -Raw
            $log | Should -Match 'issue create'
            $log | Should -Match 'priority: medium'
            $log | Should -Match 'filed-by: code-conductor'
        }
    }

    Context 'Retry & Fallback' {
        It 'retries once on GraphQL failure and succeeds if the second attempt passes' {
            "fail" | Set-Content -Path $script:ControlFile -Encoding UTF8
            
            $Result = Add-FollowUpIssue -ParentIssue 610 -Title "Test Title" -Body "Test Body" -Labels @("priority: medium")
            
            $Result | Should -Be "https://github.com/Grimblaz/agent-orchestra/issues/999"
            
            $logLines = Get-Content $script:LogFile
            $graphqlCalls = $logLines | Where-Object { $_ -match 'api graphql' }
            $graphqlCalls.Count | Should -Be 2
        }
    }

    Context 'Title Canonicalization' {
        It 'produces a deterministic title format' {
            $Title = ConvertTo-CanonicalFollowupTitle -FindingSubject "Refactor locales" -CriterionIds @("S-cross-cutting")
            $Title | Should -Be "[Structural] S-cross-cutting: Refactor locales"
        }

        It 'trims spaces and trailing periods/colons' {
            $Title = ConvertTo-CanonicalFollowupTitle -FindingSubject "  Refactor locales. : " -CriterionIds @("S-design-decision")
            $Title | Should -Be "[Structural] S-design-decision: Refactor locales"
        }
    }
}
