#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Get-CostTranscriptSlug' {
    BeforeAll {
        $script:LibPath = Join-Path $PSScriptRoot '../lib/cost-walker.ps1'
        if (Test-Path $script:LibPath) {
            . $script:LibPath
            . (Join-Path $PSScriptRoot '../lib/path-normalize.ps1')
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
        $script:LibPath = Join-Path $PSScriptRoot '../lib/cost-walker.ps1'
        if (Test-Path $script:LibPath) {
            . $script:LibPath
            . (Join-Path $PSScriptRoot '../lib/path-normalize.ps1')
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

        It 'discovers uppercase primary slug directory when lowercase slug exact path is absent' {
            $tmp = Join-Path ([IO.Path]::GetTempPath()) "cost-walker-test-$([System.Guid]::NewGuid())"
            $slug = 'c--Users-Micah-Code-Copilot-Orchestra'
            $upperSlugDirName = 'C--Users-Micah-Code-Copilot-Orchestra'
            $slugDir = Join-Path $tmp $upperSlugDirName
            $null = New-Item -ItemType Directory -Path $slugDir -Force

            $eventId = [System.Guid]::NewGuid().ToString()
            script:Write-TestJsonl -Path (Join-Path $slugDir 'session.jsonl') -Events @(
                script:New-AssistantEvent -Uuid $eventId -Cwd $script:TestCwd -Branch $script:TestBranch
            )

            $exactLowercasePath = Join-Path $tmp $slug
            Mock Test-Path { return $false } -ParameterFilter { $LiteralPath -eq $exactLowercasePath }

            $result = @(Invoke-CostTranscriptWalk -Slug $slug -Branch $script:TestBranch -ParentCwd $script:TestCwd -ProjectsRoot $tmp)
            $result.Count | Should -Be 1
            $result[0].uuid | Should -Be $eventId
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

        It 'admits assistant events whose branch matches even when cwd differs from ParentCwd' {
            # D2: cwd-equality check was removed in s3; slug-dir identity is the admission gate.
            $tmp = Join-Path ([IO.Path]::GetTempPath()) "cost-walker-test-$([System.Guid]::NewGuid())"
            $slug = 'test--repo'
            $slugDir = Join-Path $tmp $slug
            $null = New-Item -ItemType Directory -Path $slugDir -Force

            $events = @(
                script:New-AssistantEvent -Cwd '/c/other/repo' -Branch $script:TestBranch
            )
            script:Write-TestJsonl -Path (Join-Path $slugDir 'session.jsonl') -Events $events

            $result = @(Invoke-CostTranscriptWalk -Slug $slug -Branch $script:TestBranch -ParentCwd $script:TestCwd -ProjectsRoot $tmp)
            $result.Count | Should -Be 1
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

        It 'admits event with absent cwd field when branch matches (cwd check removed in s3)' {
            # D2: Test-CostWalkerAssistantMatchesStrictFilter checks only gitBranch after s3.
            # An event with no cwd field is admitted as long as branch matches.
            $tmp = Join-Path ([IO.Path]::GetTempPath()) "cost-walker-test-$([System.Guid]::NewGuid())"
            $slug = 'test--repo'
            $slugDir = Join-Path $tmp $slug
            $null = New-Item -ItemType Directory -Path $slugDir -Force

            # Event with no cwd field but with matching branch
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
            $result.Count | Should -Be 1
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

    Context 'Copilot OTel sentinel cwd bypass' {
        It 'treats sentinel cwd <Cwd> as matching before path normalization' -TestCases @(
            @{ Cwd = 'copilot-otel://copilot-orchestra' }
            @{ Cwd = 'copilot-otel://copilot-orchestra/' }
        ) {
            param([string]$Cwd)

            Mock Get-NormalizedPath { throw 'Get-NormalizedPath must not run for Copilot OTel sentinel cwd values' } `
                -ParameterFilter { $Path -like 'copilot-otel://*' }

            $matchesParent = script:Test-CostWalkerEventCwdMatchesParent `
                -TranscriptEvent @{ cwd = $Cwd } `
                -NormalizedParentCwd '/c/test/repo'

            $matchesParent | Should -BeTrue
            Should -Invoke Get-NormalizedPath -Exactly -Times 0 -ParameterFilter { $Path -like 'copilot-otel://*' }
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
                $fixtureDir = Join-Path $PSScriptRoot 'fixtures/phase-marker-sessions'
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

                $fixtureDir = Join-Path $PSScriptRoot 'fixtures/phase-marker-sessions'
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

                $fixtureDir = Join-Path $PSScriptRoot 'fixtures/phase-marker-sessions'
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

    Context 'D2 — cross-clone attribution (identity matching)' {
        BeforeAll {
            # Resolve the actual repo root so identity resolution (git remote get-url origin)
            # succeeds in tests. Tests that use RepoRoot use the real repo; tests that omit
            # RepoRoot and provide only Slug rely on the backward-compat path.
            $script:TestRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        }

        It 'admits events from two slug dirs with different cwd paths that resolve to the same git remote identity (AC3)' {
            # Get the target remote URL from the real repo
            $targetRemote = @(& git -C $script:TestRepoRoot remote get-url origin 2>&1) | Select-Object -First 1
            if ($global:LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($targetRemote)) {
                Set-ItResult -Skipped -Because 'cannot resolve test repo remote (no git remote configured)'
                return
            }
            $targetRemote = $targetRemote.Trim()

            $tmpProj = Join-Path ([IO.Path]::GetTempPath()) "cost-walker-ac3-$([System.Guid]::NewGuid())"
            $tmpProjects = Join-Path $tmpProj 'projects'
            $null = New-Item -ItemType Directory -Path $tmpProjects -Force

            # Primary slug — events cwd is the actual repo root
            $primarySlug = Get-CostTranscriptSlug -CwdPath $script:TestRepoRoot
            $primaryDir = Join-Path $tmpProjects $primarySlug
            $null = New-Item -ItemType Directory -Path $primaryDir -Force

            # Sibling clone — a DIFFERENT cwd path, but same remote URL (simulates sibling clone)
            $siblingCwdPath = Join-Path $tmpProj 'sibling-clone'
            $null = New-Item -ItemType Directory -Path $siblingCwdPath -Force
            $null = & git init $siblingCwdPath 2>&1
            $null = & git -C $siblingCwdPath remote add origin $targetRemote  # same remote as TestRepoRoot

            $siblingSlug = Get-CostTranscriptSlug -CwdPath $siblingCwdPath
            $siblingDir = Join-Path $tmpProjects $siblingSlug
            $null = New-Item -ItemType Directory -Path $siblingDir -Force

            $branch = 'feature/ac3-test'

            # Primary event — cwd = real repo root
            @(@{
                type = 'assistant'; uuid = 'ac3-primary-01'; timestamp = '2026-01-01T00:00:00Z'
                cwd = $script:TestRepoRoot; gitBranch = $branch
                message = @{ usage = @{ input_tokens = 10; output_tokens = 5 }; content = @() }
            }) | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 10 } |
                Set-Content (Join-Path $primaryDir 'session.jsonl') -Encoding utf8NoBOM

            # Sibling event — cwd = sibling clone path (DIFFERENT from primary, same remote)
            @(@{
                type = 'assistant'; uuid = 'ac3-sibling-01'; timestamp = '2026-01-01T00:00:00Z'
                cwd = $siblingCwdPath; gitBranch = $branch  # different path, same remote
                message = @{ usage = @{ input_tokens = 10; output_tokens = 5 }; content = @() }
            }) | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 10 } |
                Set-Content (Join-Path $siblingDir 'session.jsonl') -Encoding utf8NoBOM

            $result = @(Invoke-CostTranscriptWalk -Branch $branch -ParentCwd $script:TestRepoRoot -ProjectsRoot $tmpProjects -RepoRoot $script:TestRepoRoot)

            # AC3: both slug dirs admitted because both resolve to the same git identity
            $result.Count | Should -Be 2
            @($result | Where-Object { $_['uuid'] -eq 'ac3-primary-01' }).Count | Should -Be 1
            @($result | Where-Object { $_['uuid'] -eq 'ac3-sibling-01' }).Count | Should -Be 1

            Remove-Item -Recurse -Force $tmpProj
        }

        It 'excludes slug dir whose first-event cwd has unresolvable git identity (fail-closed per-candidate)' {
            # One matching slug dir (cwd = real repo root → identity resolves and matches).
            # One non-matching slug dir (cwd = fake path → git fails → excluded, fail-closed).
            $tmp = Join-Path ([IO.Path]::GetTempPath()) "cost-walker-d2-$([System.Guid]::NewGuid())"
            $branch = 'feature/d2-fail-closed-candidate'

            $matchSlug = Get-CostTranscriptSlug -CwdPath $script:TestRepoRoot
            $matchDir = Join-Path $tmp $matchSlug
            $null = New-Item -ItemType Directory -Path $matchDir -Force

            $nonMatchDir = Join-Path $tmp 'non-matching-slug'
            $null = New-Item -ItemType Directory -Path $nonMatchDir -Force

            $evMatch = script:New-AssistantEvent -Uuid 'd2-match-01' -Cwd $script:TestRepoRoot -Branch $branch
            $evNonMatch = script:New-AssistantEvent -Uuid 'd2-nomatch-01' -Cwd 'C:\fake\nonexistent\path' -Branch $branch

            script:Write-TestJsonl -Path (Join-Path $matchDir 'session.jsonl') -Events @($evMatch)
            script:Write-TestJsonl -Path (Join-Path $nonMatchDir 'session.jsonl') -Events @($evNonMatch)

            $result = @(Invoke-CostTranscriptWalk -Branch $branch -ParentCwd $script:TestRepoRoot -ProjectsRoot $tmp -RepoRoot $script:TestRepoRoot)

            # Only the matching dir's event is admitted; non-matching dir's event is excluded.
            $result.Count | Should -Be 1
            $result[0]['uuid'] | Should -Be 'd2-match-01'
            Remove-Item -Recurse -Force $tmp
        }

        It 'returns empty when target identity is unresolvable and no Slug is given (fail-closed)' {
            # When RepoRoot has no git remote AND Slug is omitted, identity resolution fails
            # and the backward-compat path is inactive (no Slug) — result must be empty.
            $tmp = Join-Path ([IO.Path]::GetTempPath()) "cost-walker-d2-$([System.Guid]::NewGuid())"
            $branch = 'feature/d2-fail-closed-target'

            $slugDir = Join-Path $tmp 'some-slug'
            $null = New-Item -ItemType Directory -Path $slugDir -Force

            $ev = script:New-AssistantEvent -Uuid 'd2-target-fail-01' -Cwd 'C:\fake\path' -Branch $branch
            script:Write-TestJsonl -Path (Join-Path $slugDir 'session.jsonl') -Events @($ev)

            # RepoRoot points to a path with no git remote; Slug is omitted.
            $result = @(Invoke-CostTranscriptWalk -Branch $branch -ParentCwd 'C:\fake\path' -ProjectsRoot $tmp -RepoRoot 'C:\fake\path')

            # Identity resolution fails for target AND no Slug → fail-closed: empty result.
            $result.Count | Should -Be 0
            Remove-Item -Recurse -Force $tmp
        }

        It 'admits worktree slug dir with hash name when primary Slug is given' {
            # Worktree session dirs use slug names like {slug}--claude-worktrees-{hash}.
            # They are discovered via the worktree-glob path when the primary Slug is given.
            $tmp = Join-Path ([IO.Path]::GetTempPath()) "cost-walker-d2-$([System.Guid]::NewGuid())"
            $slug = 'test--repo'
            $branch = $script:TestBranch

            $worktreeDir = Join-Path $tmp "$slug--claude-worktrees-deadbeef"
            $null = New-Item -ItemType Directory -Path $worktreeDir -Force

            # Event cwd is the worktree checkout path (a normal filesystem path, not the
            # primary repo root); branch filter is what matters after s3 cwd-check removal.
            $ev = script:New-AssistantEvent -Uuid 'd2-worktree-hash-01' -Cwd 'C:\Users\Test\.claude\worktrees\deadbeef' -Branch $branch
            script:Write-TestJsonl -Path (Join-Path $worktreeDir 'session.jsonl') -Events @($ev)

            $result = @(Invoke-CostTranscriptWalk -Slug $slug -Branch $branch -ParentCwd $script:TestCwd -ProjectsRoot $tmp)

            # Worktree dir is discovered via the $Slug--claude-worktrees-* glob.
            $result.Count | Should -Be 1
            $result[0]['uuid'] | Should -Be 'd2-worktree-hash-01'
            Remove-Item -Recurse -Force $tmp
        }

        It 'rejects slug dir whose first-event cwd resolves to a different git remote (AC4)' {
            $tmpProj = Join-Path ([IO.Path]::GetTempPath()) "cost-walker-ac4-$([System.Guid]::NewGuid())"
            $tmpProjects = Join-Path $tmpProj 'projects'
            $null = New-Item -ItemType Directory -Path $tmpProjects -Force

            # Matching slug dir — events cwd points to the REAL repo root (same identity as target)
            $matchSlug = Get-CostTranscriptSlug -CwdPath $script:TestRepoRoot
            $matchDir = Join-Path $tmpProjects $matchSlug
            $null = New-Item -ItemType Directory -Path $matchDir -Force

            # Non-matching slug dir — events cwd points to a tmp git repo with a DIFFERENT remote
            $otherRepoPath = Join-Path $tmpProj 'other-repo'
            $null = New-Item -ItemType Directory -Path $otherRepoPath -Force
            $null = & git init $otherRepoPath 2>&1
            $null = & git -C $otherRepoPath remote add origin 'https://github.com/fake-org/different-repo-ac4-test'

            $otherSlug = Get-CostTranscriptSlug -CwdPath $otherRepoPath
            $otherDir = Join-Path $tmpProjects $otherSlug
            $null = New-Item -ItemType Directory -Path $otherDir -Force

            $branch = 'feature/ac4-test'

            # Write matching event (should be admitted)
            @(@{
                type      = 'assistant'; uuid = 'ac4-match-01'; timestamp = '2026-01-01T00:00:00Z'
                cwd = $script:TestRepoRoot; gitBranch = $branch
                message = @{ usage = @{ input_tokens = 10; output_tokens = 5 }; content = @() }
            }) | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 10 } |
                Set-Content (Join-Path $matchDir 'session.jsonl') -Encoding utf8NoBOM

            # Write non-matching event (should be REJECTED because different remote)
            @(@{
                type      = 'assistant'; uuid = 'ac4-reject-01'; timestamp = '2026-01-01T00:00:00Z'
                cwd = $otherRepoPath; gitBranch = $branch
                message = @{ usage = @{ input_tokens = 10; output_tokens = 5 }; content = @() }
            }) | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 10 } |
                Set-Content (Join-Path $otherDir 'session.jsonl') -Encoding utf8NoBOM

            $result = @(Invoke-CostTranscriptWalk -Branch $branch -ParentCwd $script:TestRepoRoot -ProjectsRoot $tmpProjects -RepoRoot $script:TestRepoRoot)

            # AC4: different-remote slug dir must be rejected; only matching slug's event admitted
            $result.Count | Should -Be 1
            $result[0]['uuid'] | Should -Be 'ac4-match-01'

            Remove-Item -Recurse -Force $tmpProj
        }
    }
}

Describe 'Resolve-CostWalkerRepoIdentity' {
    BeforeAll {
        $script:LibPath = Join-Path $PSScriptRoot '../lib/cost-walker.ps1'
        if (Test-Path $script:LibPath) {
            . $script:LibPath
            . (Join-Path $PSScriptRoot '../lib/path-normalize.ps1')
        }
    }

    Context 'transport-agnostic normalization (Fix #760-E1)' {
        It 'normalizes plain HTTPS to host/path' {
            script:Resolve-CostWalkerRepoIdentity -RawUrl 'https://github.com/owner/repo' |
                Should -Be 'github.com/owner/repo'
        }
        It 'strips a trailing .git suffix' {
            script:Resolve-CostWalkerRepoIdentity -RawUrl 'https://github.com/owner/repo.git' |
                Should -Be 'github.com/owner/repo'
        }
        It 'normalizes scp-like SSH form to the same identity as HTTPS' {
            $ssh   = script:Resolve-CostWalkerRepoIdentity -RawUrl 'git@github.com:owner/repo.git'
            $https = script:Resolve-CostWalkerRepoIdentity -RawUrl 'https://github.com/owner/repo'
            $ssh   | Should -Be 'github.com/owner/repo'
            $ssh   | Should -Be $https -Because 'SSH and HTTPS forms of the same repo must match'
        }
        It 'normalizes ssh:// scheme form to the same identity' {
            script:Resolve-CostWalkerRepoIdentity -RawUrl 'ssh://git@github.com/owner/repo.git' |
                Should -Be 'github.com/owner/repo'
        }
        It 'strips credential userinfo (x-access-token) from HTTPS' {
            script:Resolve-CostWalkerRepoIdentity -RawUrl 'https://x-access-token:ghs_SECRET@github.com/owner/repo' |
                Should -Be 'github.com/owner/repo'
        }
        It 'is case-insensitive and trims trailing slashes' {
            script:Resolve-CostWalkerRepoIdentity -RawUrl 'HTTPS://GitHub.com/Owner/Repo/' |
                Should -Be 'github.com/owner/repo'
        }
        It 'returns $null for empty or whitespace input (fail-closed)' {
            script:Resolve-CostWalkerRepoIdentity -RawUrl ''    | Should -BeNullOrEmpty
            script:Resolve-CostWalkerRepoIdentity -RawUrl '   '  | Should -BeNullOrEmpty
        }
        It 'distinguishes different repos on the same host' {
            $a = script:Resolve-CostWalkerRepoIdentity -RawUrl 'git@github.com:owner/repo-a.git'
            $b = script:Resolve-CostWalkerRepoIdentity -RawUrl 'https://github.com/owner/repo-b'
            $a | Should -Not -Be $b
        }
    }
}
