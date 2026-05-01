#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Get-CostTranscriptSlug' {
    BeforeAll {
        $script:LibPath = Join-Path $PSScriptRoot '..\lib\cost-walker.ps1'
        if (Test-Path $script:LibPath) {
            . $script:LibPath
            . (Join-Path $PSScriptRoot '..\lib\path-normalize.ps1')
        }
    }

    Context 'slug derivation' {
        It 'derives slug from Windows backslash path' {
            Get-CostTranscriptSlug -CwdPath 'C:\Users\Micah\Code 2\copilot-orchestra' |
                Should -Be 'c--Users-Micah-Code-2-copilot-orchestra'
        }
        It 'derives slug from git-bash /c/ path' {
            Get-CostTranscriptSlug -CwdPath '/c/Users/Micah/Code 2/copilot-orchestra' |
                Should -Be 'c--Users-Micah-Code-2-copilot-orchestra'
        }
        It 'replaces spaces with dashes' {
            Get-CostTranscriptSlug -CwdPath '/c/Users/Micah/My Project' |
                Should -Be 'c--Users-Micah-My-Project'
        }
        It 'preserves case in path segments' {
            Get-CostTranscriptSlug -CwdPath '/c/Users/Micah/MyRepo' |
                Should -Be 'c--Users-Micah-MyRepo'
        }
        It 'drops leading drive-letter colon' {
            Get-CostTranscriptSlug -CwdPath 'D:\repos\project' |
                Should -Be 'd--repos-project'
        }
    }
}

Describe 'Invoke-CostTranscriptWalk' {
    BeforeAll {
        $script:LibPath = Join-Path $PSScriptRoot '..\lib\cost-walker.ps1'
        if (Test-Path $script:LibPath) {
            . $script:LibPath
            . (Join-Path $PSScriptRoot '..\lib\path-normalize.ps1')
        }

        # Helper: write a JSONL file from an array of event hashtables
        function script:Write-TestJsonl {
            param([string]$Path, [hashtable[]]$Events)
            $dir = Split-Path -Parent $Path
            if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
            $Events | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 10 } | Set-Content -Path $Path -Encoding utf8NoBOM
        }

        # Standard CWD and branch used by most tests
        $script:TestCwd    = '/c/test/repo'
        $script:TestBranch = 'feature/test-branch'

        # Inline event builders
        function script:New-AssistantEvent {
            param(
                [string]$Uuid = [System.Guid]::NewGuid().ToString(),
                [string]$Cwd   = $script:TestCwd,
                [string]$Branch = $script:TestBranch,
                [hashtable]$Usage = @{ input_tokens = 10; output_tokens = 5 },
                [object[]]$Content = @()
            )
            return @{
                type       = 'assistant'
                uuid       = $Uuid
                timestamp  = '2026-01-01T00:00:00Z'
                cwd        = $Cwd
                gitBranch  = $Branch
                message    = @{ usage = $Usage; content = $Content }
            }
        }

        function script:New-AgentToolUseContent {
            param([string]$ToolUseId = [System.Guid]::NewGuid().ToString())
            return @{
                type  = 'tool_use'
                id    = $ToolUseId
                name  = 'Agent'
                input = @{ prompt = 'do something' }
            }
        }
    }

    Context 'event-type filtering' {
        It 'includes assistant events matching cwd+branch' {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) "cost-walker-test-$([System.Guid]::NewGuid())"
            $slug = 'test--repo'
            $slugDir = Join-Path $tmp $slug
            $null = New-Item -ItemType Directory -Path $slugDir -Force

            $events = @(
                script:New-AssistantEvent -Cwd $script:TestCwd -Branch $script:TestBranch
            )
            script:Write-TestJsonl -Path (Join-Path $slugDir 'session.jsonl') -Events $events

            $result = @(Invoke-CostTranscriptWalk -Slug $slug -Branch $script:TestBranch -ParentCwd $script:TestCwd -ProjectsRoot $tmp)
            $result.Count | Should -Be 1
            $result[0].type | Should -Be 'assistant'
            Remove-Item -Recurse -Force $tmp
        }

        It 'excludes assistant events with non-matching branch' {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) "cost-walker-test-$([System.Guid]::NewGuid())"
            $slug = 'test--repo'
            $slugDir = Join-Path $tmp $slug
            $null = New-Item -ItemType Directory -Path $slugDir -Force

            $events = @(
                script:New-AssistantEvent -Cwd $script:TestCwd -Branch 'other/branch'
            )
            script:Write-TestJsonl -Path (Join-Path $slugDir 'session.jsonl') -Events $events

            $result = @(Invoke-CostTranscriptWalk -Slug $slug -Branch $script:TestBranch -ParentCwd $script:TestCwd -ProjectsRoot $tmp)
            $result.Count | Should -Be 0
            Remove-Item -Recurse -Force $tmp
        }

        It 'excludes assistant events with non-matching cwd' {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) "cost-walker-test-$([System.Guid]::NewGuid())"
            $slug = 'test--repo'
            $slugDir = Join-Path $tmp $slug
            $null = New-Item -ItemType Directory -Path $slugDir -Force

            $events = @(
                script:New-AssistantEvent -Cwd '/c/other/repo' -Branch $script:TestBranch
            )
            script:Write-TestJsonl -Path (Join-Path $slugDir 'session.jsonl') -Events $events

            $result = @(Invoke-CostTranscriptWalk -Slug $slug -Branch $script:TestBranch -ParentCwd $script:TestCwd -ProjectsRoot $tmp)
            $result.Count | Should -Be 0
            Remove-Item -Recurse -Force $tmp
        }

        It 'excludes user events silently' {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) "cost-walker-test-$([System.Guid]::NewGuid())"
            $slug = 'test--repo'
            $slugDir = Join-Path $tmp $slug
            $null = New-Item -ItemType Directory -Path $slugDir -Force

            $events = @(
                @{ type = 'user'; uuid = [System.Guid]::NewGuid().ToString(); timestamp = '2026-01-01T00:00:00Z'; content = 'hello' }
                script:New-AssistantEvent
            )
            script:Write-TestJsonl -Path (Join-Path $slugDir 'session.jsonl') -Events $events

            $result = @(Invoke-CostTranscriptWalk -Slug $slug -Branch $script:TestBranch -ParentCwd $script:TestCwd -ProjectsRoot $tmp)
            $result.Count | Should -Be 1
            $result[0].type | Should -Be 'assistant'
            Remove-Item -Recurse -Force $tmp
        }

        It 'excludes system events silently' {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) "cost-walker-test-$([System.Guid]::NewGuid())"
            $slug = 'test--repo'
            $slugDir = Join-Path $tmp $slug
            $null = New-Item -ItemType Directory -Path $slugDir -Force

            $events = @(
                @{ type = 'system'; uuid = [System.Guid]::NewGuid().ToString(); timestamp = '2026-01-01T00:00:00Z' }
                script:New-AssistantEvent
            )
            script:Write-TestJsonl -Path (Join-Path $slugDir 'session.jsonl') -Events $events

            $result = @(Invoke-CostTranscriptWalk -Slug $slug -Branch $script:TestBranch -ParentCwd $script:TestCwd -ProjectsRoot $tmp)
            $result.Count | Should -Be 1
            Remove-Item -Recurse -Force $tmp
        }

        It 'logs warning for unknown event type' {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) "cost-walker-test-$([System.Guid]::NewGuid())"
            $slug = 'test--repo'
            $slugDir = Join-Path $tmp $slug
            $null = New-Item -ItemType Directory -Path $slugDir -Force

            $events = @(
                @{ type = 'unknown-future-type'; uuid = [System.Guid]::NewGuid().ToString(); timestamp = '2026-01-01T00:00:00Z' }
            )
            script:Write-TestJsonl -Path (Join-Path $slugDir 'session.jsonl') -Events $events

            $warnings = [System.Collections.Generic.List[string]]::new()
            $result = @(Invoke-CostTranscriptWalk -Slug $slug -Branch $script:TestBranch -ParentCwd $script:TestCwd -ProjectsRoot $tmp -WarningVariable wv)
            $result.Count | Should -Be 0
            # Verify a warning was emitted for the unknown type
            ($wv | Where-Object { $_ -match 'unknown' -or $_ -match 'unknown-future-type' }) | Should -Not -BeNullOrEmpty
            Remove-Item -Recurse -Force $tmp
        }
    }

    Context 'multi-session aggregation' {
        It 'collects events from multiple JSONL files in same slug dir' {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) "cost-walker-test-$([System.Guid]::NewGuid())"
            $slug = 'test--repo'
            $slugDir = Join-Path $tmp $slug
            $null = New-Item -ItemType Directory -Path $slugDir -Force

            script:Write-TestJsonl -Path (Join-Path $slugDir 'session1.jsonl') -Events @(script:New-AssistantEvent)
            script:Write-TestJsonl -Path (Join-Path $slugDir 'session2.jsonl') -Events @(script:New-AssistantEvent)

            $result = @(Invoke-CostTranscriptWalk -Slug $slug -Branch $script:TestBranch -ParentCwd $script:TestCwd -ProjectsRoot $tmp)
            $result.Count | Should -Be 2
            Remove-Item -Recurse -Force $tmp
        }

        It 'collects events from worktree slug directories' {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) "cost-walker-test-$([System.Guid]::NewGuid())"
            $slug = 'test--repo'
            $primaryDir  = Join-Path $tmp $slug
            $worktreeDir = Join-Path $tmp "$slug--claude-worktrees-main"
            $null = New-Item -ItemType Directory -Path $primaryDir  -Force
            $null = New-Item -ItemType Directory -Path $worktreeDir -Force

            script:Write-TestJsonl -Path (Join-Path $primaryDir  'session1.jsonl') -Events @(script:New-AssistantEvent)
            script:Write-TestJsonl -Path (Join-Path $worktreeDir 'session2.jsonl') -Events @(script:New-AssistantEvent)

            $result = @(Invoke-CostTranscriptWalk -Slug $slug -Branch $script:TestBranch -ParentCwd $script:TestCwd -ProjectsRoot $tmp)
            $result.Count | Should -Be 2
            Remove-Item -Recurse -Force $tmp
        }
    }

    Context 'subagent traversal' {
        It 'loads subagent transcript for included Agent tool_use' {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) "cost-walker-test-$([System.Guid]::NewGuid())"
            $slug = 'test--repo'
            $slugDir  = Join-Path $tmp $slug
            $subagDir = Join-Path $slugDir 'subagents'
            $null = New-Item -ItemType Directory -Path $subagDir -Force

            $toolUseId = [System.Guid]::NewGuid().ToString()
            $agentContent = script:New-AgentToolUseContent -ToolUseId $toolUseId
            $parentEvent  = script:New-AssistantEvent -Content @($agentContent)

            script:Write-TestJsonl -Path (Join-Path $slugDir 'session.jsonl') -Events @($parentEvent)

            # Subagent transcript contains one assistant event
            $subEvent = @{
                type      = 'assistant'
                uuid      = [System.Guid]::NewGuid().ToString()
                timestamp = '2026-01-01T00:01:00Z'
                message   = @{ usage = @{ input_tokens = 20; output_tokens = 10 }; content = @() }
            }
            script:Write-TestJsonl -Path (Join-Path $subagDir "agent-$toolUseId.jsonl") -Events @($subEvent)

            $result = @(Invoke-CostTranscriptWalk -Slug $slug -Branch $script:TestBranch -ParentCwd $script:TestCwd -ProjectsRoot $tmp)
            # Expect: parent assistant + 1 subagent event = 2 total
            $result.Count | Should -Be 2
            Remove-Item -Recurse -Force $tmp
        }

        It 'does not load subagent transcript for excluded parent' {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) "cost-walker-test-$([System.Guid]::NewGuid())"
            $slug = 'test--repo'
            $slugDir  = Join-Path $tmp $slug
            $subagDir = Join-Path $slugDir 'subagents'
            $null = New-Item -ItemType Directory -Path $subagDir -Force

            $toolUseId = [System.Guid]::NewGuid().ToString()
            $agentContent = script:New-AgentToolUseContent -ToolUseId $toolUseId
            # Parent has wrong branch — should be excluded
            $parentEvent  = script:New-AssistantEvent -Branch 'wrong/branch' -Content @($agentContent)

            script:Write-TestJsonl -Path (Join-Path $slugDir 'session.jsonl') -Events @($parentEvent)

            $subEvent = @{
                type      = 'assistant'
                uuid      = [System.Guid]::NewGuid().ToString()
                timestamp = '2026-01-01T00:01:00Z'
                message   = @{ usage = @{ input_tokens = 5; output_tokens = 2 }; content = @() }
            }
            script:Write-TestJsonl -Path (Join-Path $subagDir "agent-$toolUseId.jsonl") -Events @($subEvent)

            $result = @(Invoke-CostTranscriptWalk -Slug $slug -Branch $script:TestBranch -ParentCwd $script:TestCwd -ProjectsRoot $tmp)
            $result.Count | Should -Be 0
            Remove-Item -Recurse -Force $tmp
        }

        It 'tolerates missing subagent transcript file' {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) "cost-walker-test-$([System.Guid]::NewGuid())"
            $slug = 'test--repo'
            $slugDir = Join-Path $tmp $slug
            $null = New-Item -ItemType Directory -Path $slugDir -Force

            $toolUseId    = [System.Guid]::NewGuid().ToString()
            $agentContent = script:New-AgentToolUseContent -ToolUseId $toolUseId
            $parentEvent  = script:New-AssistantEvent -Content @($agentContent)

            script:Write-TestJsonl -Path (Join-Path $slugDir 'session.jsonl') -Events @($parentEvent)
            # Note: no subagents/ dir and no subagent transcript file created

            { $result = @(Invoke-CostTranscriptWalk -Slug $slug -Branch $script:TestBranch -ParentCwd $script:TestCwd -ProjectsRoot $tmp) } | Should -Not -Throw
            $result = @(Invoke-CostTranscriptWalk -Slug $slug -Branch $script:TestBranch -ParentCwd $script:TestCwd -ProjectsRoot $tmp)
            # Only the parent assistant event; no subagent events
            $result.Count | Should -Be 1
            Remove-Item -Recurse -Force $tmp
        }
    }

    Context 'resilience' {
        It 'returns empty result when slug directory does not exist' {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) "cost-walker-test-$([System.Guid]::NewGuid())"
            $null = New-Item -ItemType Directory -Path $tmp -Force
            # No slug subdirectory created

            $result = @(Invoke-CostTranscriptWalk -Slug 'nonexistent-slug' -Branch $script:TestBranch -ParentCwd $script:TestCwd -ProjectsRoot $tmp)
            $result.Count | Should -Be 0
            Remove-Item -Recurse -Force $tmp
        }

        It 'tolerates absent subagents/ subdirectory' {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) "cost-walker-test-$([System.Guid]::NewGuid())"
            $slug = 'test--repo'
            $slugDir = Join-Path $tmp $slug
            $null = New-Item -ItemType Directory -Path $slugDir -Force

            $toolUseId    = [System.Guid]::NewGuid().ToString()
            $agentContent = script:New-AgentToolUseContent -ToolUseId $toolUseId
            $parentEvent  = script:New-AssistantEvent -Content @($agentContent)
            script:Write-TestJsonl -Path (Join-Path $slugDir 'session.jsonl') -Events @($parentEvent)
            # subagents/ dir deliberately absent

            { $result = @(Invoke-CostTranscriptWalk -Slug $slug -Branch $script:TestBranch -ParentCwd $script:TestCwd -ProjectsRoot $tmp) } | Should -Not -Throw
            Remove-Item -Recurse -Force $tmp
        }

        It 'handles event with absent cwd field as non-matching' {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) "cost-walker-test-$([System.Guid]::NewGuid())"
            $slug = 'test--repo'
            $slugDir = Join-Path $tmp $slug
            $null = New-Item -ItemType Directory -Path $slugDir -Force

            # Event with no cwd field
            $events = @(
                @{
                    type      = 'assistant'
                    uuid      = [System.Guid]::NewGuid().ToString()
                    timestamp = '2026-01-01T00:00:00Z'
                    gitBranch = $script:TestBranch
                    message   = @{ usage = @{ input_tokens = 1; output_tokens = 1 }; content = @() }
                }
            )
            script:Write-TestJsonl -Path (Join-Path $slugDir 'session.jsonl') -Events $events

            $result = @(Invoke-CostTranscriptWalk -Slug $slug -Branch $script:TestBranch -ParentCwd $script:TestCwd -ProjectsRoot $tmp)
            $result.Count | Should -Be 0
            Remove-Item -Recurse -Force $tmp
        }

        It 'handles event with absent gitBranch field as non-matching' {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) "cost-walker-test-$([System.Guid]::NewGuid())"
            $slug = 'test--repo'
            $slugDir = Join-Path $tmp $slug
            $null = New-Item -ItemType Directory -Path $slugDir -Force

            # Event with no gitBranch field
            $events = @(
                @{
                    type      = 'assistant'
                    uuid      = [System.Guid]::NewGuid().ToString()
                    timestamp = '2026-01-01T00:00:00Z'
                    cwd       = $script:TestCwd
                    message   = @{ usage = @{ input_tokens = 1; output_tokens = 1 }; content = @() }
                }
            )
            script:Write-TestJsonl -Path (Join-Path $slugDir 'session.jsonl') -Events $events

            $result = @(Invoke-CostTranscriptWalk -Slug $slug -Branch $script:TestBranch -ParentCwd $script:TestCwd -ProjectsRoot $tmp)
            $result.Count | Should -Be 0
            Remove-Item -Recurse -Force $tmp
        }
    }

    Context 'mixed-branch session' {
        It 'includes only events matching the target branch in a multi-branch JSONL' {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) "cost-walker-test-$([System.Guid]::NewGuid())"
            $slug = 'test--repo'
            $slugDir = Join-Path $tmp $slug
            $null = New-Item -ItemType Directory -Path $slugDir -Force

            $targetId = [System.Guid]::NewGuid().ToString()
            $events = @(
                script:New-AssistantEvent -Uuid $targetId    -Branch $script:TestBranch
                script:New-AssistantEvent                    -Branch 'other/branch'
                script:New-AssistantEvent                    -Branch 'main'
            )
            script:Write-TestJsonl -Path (Join-Path $slugDir 'session.jsonl') -Events $events

            $result = @(Invoke-CostTranscriptWalk -Slug $slug -Branch $script:TestBranch -ParentCwd $script:TestCwd -ProjectsRoot $tmp)
            $result.Count | Should -Be 1
            $result[0].uuid | Should -Be $targetId
            Remove-Item -Recurse -Force $tmp
        }
    }
}
