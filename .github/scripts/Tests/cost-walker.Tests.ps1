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
        $script:TestCwd = '/c/test/repo'
        $script:TestBranch = 'feature/test-branch'

        # Inline event builders
        function script:New-AssistantEvent {
            param(
                [string]$Uuid = [System.Guid]::NewGuid().ToString(),
                [string]$Cwd = $script:TestCwd,
                [string]$Branch = $script:TestBranch,
                [hashtable]$Usage = @{ input_tokens = 10; output_tokens = 5 },
                [object[]]$Content = @()
            )
            return @{
                type      = 'assistant'
                uuid      = $Uuid
                timestamp = '2026-01-01T00:00:00Z'
                cwd       = $Cwd
                gitBranch = $Branch
                message   = @{ usage = $Usage; content = $Content }
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

            $outputAndWarnings = @(Invoke-CostTranscriptWalk -Slug $slug -Branch $script:TestBranch -ParentCwd $script:TestCwd -ProjectsRoot $tmp -WarningAction Continue 3>&1)
            @($outputAndWarnings | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] }).Count | Should -Be 0
            # Verify a warning was emitted for the unknown type
            $warningRecords = @($outputAndWarnings | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            ($warningRecords | Where-Object { $_ -match 'unknown' -or $_ -match 'unknown-future-type' }) | Should -Not -BeNullOrEmpty
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
            $primaryDir = Join-Path $tmp $slug
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
            $slugDir = Join-Path $tmp $slug
            $subagDir = Join-Path $slugDir 'subagents'
            $null = New-Item -ItemType Directory -Path $subagDir -Force

            $toolUseId = [System.Guid]::NewGuid().ToString()
            $agentContent = script:New-AgentToolUseContent -ToolUseId $toolUseId
            $parentEvent = script:New-AssistantEvent -Content @($agentContent)

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
            $slugDir = Join-Path $tmp $slug
            $subagDir = Join-Path $slugDir 'subagents'
            $null = New-Item -ItemType Directory -Path $subagDir -Force

            $toolUseId = [System.Guid]::NewGuid().ToString()
            $agentContent = script:New-AgentToolUseContent -ToolUseId $toolUseId
            # Parent has wrong branch — should be excluded
            $parentEvent = script:New-AssistantEvent -Branch 'wrong/branch' -Content @($agentContent)

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

            $toolUseId = [System.Guid]::NewGuid().ToString()
            $agentContent = script:New-AgentToolUseContent -ToolUseId $toolUseId
            $parentEvent = script:New-AssistantEvent -Content @($agentContent)

            script:Write-TestJsonl -Path (Join-Path $slugDir 'session.jsonl') -Events @($parentEvent)
            # Note: no subagents/ dir and no subagent transcript file created

            # Only the parent assistant event; no subagent events
            @(Invoke-CostTranscriptWalk -Slug $slug -Branch $script:TestBranch -ParentCwd $script:TestCwd -ProjectsRoot $tmp).Count | Should -Be 1
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

            $toolUseId = [System.Guid]::NewGuid().ToString()
            $agentContent = script:New-AgentToolUseContent -ToolUseId $toolUseId
            $parentEvent = script:New-AssistantEvent -Content @($agentContent)
            script:Write-TestJsonl -Path (Join-Path $slugDir 'session.jsonl') -Events @($parentEvent)
            # subagents/ dir deliberately absent

            @(Invoke-CostTranscriptWalk -Slug $slug -Branch $script:TestBranch -ParentCwd $script:TestCwd -ProjectsRoot $tmp).Count | Should -Be 1
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

        Context 'phase-marker windowing' {
            It 'admits only assistant events inside a phase-marker /plan 529 window (fixture-driven)' {
                $tmp = Join-Path ([IO.Path]::GetTempPath()) "cost-walker-test-$([System.Guid]::NewGuid())"
                $slug = 'phase-marker-test'
                $slugDir = Join-Path $tmp $slug
                $null = New-Item -ItemType Directory -Path $slugDir -Force

                # Copy committed fixtures into the temp slug dir
                $fixtureDir = Join-Path $PSScriptRoot 'fixtures\phase-marker-sessions'
                Copy-Item -Path (Join-Path $fixtureDir 'phase-marker-529.jsonl') -Destination (Join-Path $slugDir 'session.jsonl')
                Copy-Item -Path (Join-Path $fixtureDir 'phase-marker-529b.jsonl') -Destination (Join-Path $slugDir 'session2.jsonl')

                $result = @(Invoke-CostTranscriptWalk -Slug $slug -Branch $script:TestBranch -ParentCwd $script:TestCwd -ProjectsRoot $tmp -IssueNumber 529)

                # Expected: only assistant events admitted by target phase-marker windows
                $uuids = $result | ForEach-Object { $_.uuid } | Where-Object { $_ -ne $null }
                $uuids | Should -BeExactly @(
                    '11111111-1111-1111-1111-111111111111',
                    '22222222-2222-2222-2222-222222222222',
                    '44444444-4444-4444-4444-444444444444',
                    '55555555-5555-5555-5555-555555555555',
                    '66666666-6666-6666-6666-666666666666'
                )
                @($result | Where-Object { $_.uuid -eq '11111111-1111-1111-1111-111111111111' })[0]['_phase_marker_port'] | Should -Be 'plan'
                @($result | Where-Object { $_.uuid -eq '44444444-4444-4444-4444-444444444444' })[0]['_phase_marker_port'] | Should -Be 'experience'
                @($result | Where-Object { $_.uuid -eq '55555555-5555-5555-5555-555555555555' })[0]['_phase_marker_port'] | Should -Be 'design'

                # Command markers live on user events; assert marker parsing there, not on assistant content.
                $acceptedCommands = @(
                    '/experience', '/design', '/plan', '/orchestrate', '/code-conductor',
                    '/agent-orchestra:experience', '/agent-orchestra:design', '/agent-orchestra:plan',
                    '/agent-orchestra:orchestrate', '/agent-orchestra:code-conductor'
                )
                $acceptedArgs = @('529', '#529', 'issue 529')
                foreach ($command in $acceptedCommands) {
                    foreach ($argument in $acceptedArgs) {
                        $markerEvent = @{
                            type    = 'user'
                            message = @{ content = "<command-name>$command</command-name>`n<command-args>$argument</command-args>" }
                        }
                        $phaseMarker = script:Get-CostWalkerPhaseMarker -TranscriptEvent $markerEvent
                        $phaseMarker.IssueId | Should -Be 529
                        $phaseMarker.PortHint | Should -Be $command.Replace('/agent-orchestra:', '').Replace('/', '')
                    }
                }

                $rejectedMarkers = @(
                    @{ type = 'user'; message = @{ content = '<command-name>experience</command-name><command-args>529</command-args>' } }
                    @{ type = 'user'; message = @{ content = '<command-name>/Experience</command-name><command-args>529</command-args>' } }
                    @{ type = 'user'; message = @{ content = '<command>/plan</command><command-args>529</command-args>' } }
                    @{ type = 'user'; message = @{ content = '<command-name>/plan</command-name><command-args>plan-#529</command-args>' } }
                    @{ type = 'user'; message = @{ content = 'debug: <command-name>/plan</command-name><command-args>529</command-args>' } }
                    @{ type = 'user'; message = @{ content = 'please run /plan for issue 529' } }
                    @{ type = 'user'; message = @{ content = @(@{ some = 'object' }) } }
                )
                foreach ($markerEvent in $rejectedMarkers) {
                    script:Get-CostWalkerPhaseMarker -TranscriptEvent $markerEvent | Should -BeNullOrEmpty
                }

                # Object[] user content must be rejected — ensure no user-content arrays appear
                ($result | Where-Object { $_.type -eq 'user' -and $_.message -and ($_.message.content -is [System.Array]) }).Count | Should -Be 0

                # Non-phase-marker user events should not emit 'unknown event type' warnings
                $warnings = $null
                $null = @(Invoke-CostTranscriptWalk -Slug $slug -Branch $script:TestBranch -ParentCwd $script:TestCwd -ProjectsRoot $tmp -IssueNumber 529 -WarningVariable warnings)
                ($warnings | Where-Object { $_ -match 'unknown event type' }).Count | Should -Be 0

                Remove-Item -Recurse -Force $tmp
            }

            It 'does not bleed window state across multiple JSONL files in same slug dir' {
                $tmp = Join-Path ([IO.Path]::GetTempPath()) "cost-walker-test-$([System.Guid]::NewGuid())"
                $slug = 'phase-marker-test'
                $slugDir = Join-Path $tmp $slug
                $null = New-Item -ItemType Directory -Path $slugDir -Force

                $events1 = @(
                    @{
                        type      = 'user'
                        message   = @{ role = 'user'; content = '<command-name>/plan</command-name><command-args>529</command-args>' }
                        cwd       = $script:TestCwd
                        gitBranch = 'main'
                        timestamp = '2026-01-03T00:00:00Z'
                    }
                    script:New-AssistantEvent -Uuid '77777777-7777-7777-7777-777777777777' -Branch 'main'
                )
                $events2 = @(
                    script:New-AssistantEvent -Uuid '88888888-8888-8888-8888-888888888888' -Branch 'main'
                )
                script:Write-TestJsonl -Path (Join-Path $slugDir 'session.jsonl') -Events $events1
                script:Write-TestJsonl -Path (Join-Path $slugDir 'session2.jsonl') -Events $events2

                $result = @(Invoke-CostTranscriptWalk -Slug $slug -Branch $script:TestBranch -ParentCwd $script:TestCwd -ProjectsRoot $tmp -IssueNumber 529)

                # Expectation: windows are per-file; session2 has no marker and must not inherit session1's open window.
                @($result | Where-Object { $_.uuid -eq '77777777-7777-7777-7777-777777777777' }).Count | Should -Be 1
                @($result | Where-Object { $_.uuid -eq '88888888-8888-8888-8888-888888888888' }).Count | Should -Be 0

                Remove-Item -Recurse -Force $tmp
            }

            It 'loads subagent transcript for admitted Agent tool_use once admitted by phase-marker' {
                $tmp = Join-Path ([IO.Path]::GetTempPath()) "cost-walker-test-$([System.Guid]::NewGuid())"
                $slug = 'phase-marker-test'
                $slugDir = Join-Path $tmp $slug
                $subagDir = Join-Path $slugDir 'subagents'
                $null = New-Item -ItemType Directory -Path $subagDir -Force

                $fixtureDir = Join-Path $PSScriptRoot 'fixtures\phase-marker-sessions'
                Copy-Item -Path (Join-Path $fixtureDir 'phase-marker-529.jsonl') -Destination (Join-Path $slugDir 'session.jsonl')
                Copy-Item -Path (Join-Path $fixtureDir 'phase-marker-529b.jsonl') -Destination (Join-Path $slugDir 'session2.jsonl')

                # Create a subagent transcript for the Agent tool_use id in fixture b
                $subEvent = @{
                    type = 'assistant'
                    uuid = 'subagent-0000-0000-0000-000000000000'
                    timestamp = '2026-01-02T00:10:00Z'
                    message = @{ usage = @{ input_tokens = 1; output_tokens = 1 }; content = @() }
                }
                script:Write-TestJsonl -Path (Join-Path $subagDir 'agent-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.jsonl') -Events @($subEvent)

                $result = @(Invoke-CostTranscriptWalk -Slug $slug -Branch $script:TestBranch -ParentCwd $script:TestCwd -ProjectsRoot $tmp -IssueNumber 529)

                # Expectation: subagent event appears in results when its parent assistant is admitted by the phase-marker
                @($result | Where-Object { $_.uuid -eq 'subagent-0000-0000-0000-000000000000' }).Count | Should -Be 1

                Remove-Item -Recurse -Force $tmp
            }

            It 'omitting -IssueNumber preserves strict branch behavior' {
                $tmp = Join-Path ([IO.Path]::GetTempPath()) "cost-walker-test-$([System.Guid]::NewGuid())"
                $slug = 'phase-marker-test'
                $slugDir = Join-Path $tmp $slug
                $null = New-Item -ItemType Directory -Path $slugDir -Force

                $fixtureDir = Join-Path $PSScriptRoot 'fixtures\phase-marker-sessions'
                Copy-Item -Path (Join-Path $fixtureDir 'phase-marker-529.jsonl') -Destination (Join-Path $slugDir 'session.jsonl')
                Copy-Item -Path (Join-Path $fixtureDir 'phase-marker-529b.jsonl') -Destination (Join-Path $slugDir 'session2.jsonl')

                # Call without -IssueNumber but target the feature branch in fixture
                $result = @(Invoke-CostTranscriptWalk -Slug $slug -Branch 'feature/issue-529' -ParentCwd $script:TestCwd -ProjectsRoot $tmp)

                # Strict branch behavior: no assistant events on feature/issue-529 exist (admitted ones are on main), expect zero
                $result.Count | Should -Be 0

                Remove-Item -Recurse -Force $tmp
            }

            It 'supplying -IssueNumber preserves strict feature-branch assistant events without phase-marker tag' {
                $tmp = Join-Path ([IO.Path]::GetTempPath()) "cost-walker-test-$([System.Guid]::NewGuid())"
                $slug = 'phase-marker-test'
                $slugDir = Join-Path $tmp $slug
                $null = New-Item -ItemType Directory -Path $slugDir -Force

                $strictUuid = '99999999-9999-9999-9999-999999999999'
                $events = @(
                    @{
                        type      = 'user'
                        message   = @{ role = 'user'; content = '<command-name>/plan</command-name><command-args>529</command-args>' }
                        cwd       = $script:TestCwd
                        gitBranch = 'main'
                        timestamp = '2026-01-04T00:00:00Z'
                    }
                    script:New-AssistantEvent -Uuid $strictUuid -Branch 'feature/issue-529'
                    script:New-AssistantEvent -Uuid 'aaaaaaaa-0000-0000-0000-000000000000' -Branch 'main'
                )
                script:Write-TestJsonl -Path (Join-Path $slugDir 'session.jsonl') -Events $events

                $result = @(Invoke-CostTranscriptWalk -Slug $slug -Branch 'feature/issue-529' -ParentCwd $script:TestCwd -ProjectsRoot $tmp -IssueNumber 529)
                $strictEvent = @($result | Where-Object { $_.uuid -eq $strictUuid })

                $strictEvent.Count | Should -Be 1
                $strictEvent[0]['gitBranch'] | Should -Be 'feature/issue-529'
                $strictEvent[0].ContainsKey('_phase_marker_port') | Should -BeFalse

                Remove-Item -Recurse -Force $tmp
            }
        }
}
