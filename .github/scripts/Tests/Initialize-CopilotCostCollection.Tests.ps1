#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Initialize-CopilotCostCollection' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ScriptPath = Join-Path $script:RepoRoot 'skills/copilot-cost-collection/scripts/Initialize-CopilotCostCollection.ps1'
        $script:SentinelName = '.copilot-cost-collection-installed'

        function script:Read-JsonFile {
            param([Parameter(Mandatory)][string]$Path)

            return Get-Content -Path $Path -Raw | ConvertFrom-Json -AsHashtable
        }

        function script:New-IsolatedPaths {
            $root = Join-Path -Path 'TestDrive:' -ChildPath ([Guid]::NewGuid().ToString('N'))
            $workspace = Join-Path -Path $root -ChildPath 'workspace-one'
            $userHome = Join-Path -Path $root -ChildPath 'home'
            $userSettings = Join-Path -Path $root -ChildPath 'user-settings/settings.json'

            $null = New-Item -ItemType Directory -Path $workspace -Force
            $null = New-Item -ItemType Directory -Path $userHome -Force

            return [pscustomobject]@{
                Root         = $root
                Workspace    = $workspace
                UserHome     = $userHome
                UserSettings = $userSettings
            }
        }
    }

    It 'additively installs user settings, workspace settings, OTel directory, gitignore entry, and sentinel' {
        $paths = script:New-IsolatedPaths
        $workspaceSettingsDir = Join-Path -Path $paths.Workspace -ChildPath '.vscode'
        $workspaceSettingsPath = Join-Path -Path $workspaceSettingsDir -ChildPath 'settings.json'
        $gitignorePath = Join-Path -Path $paths.Workspace -ChildPath '.gitignore'

        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $paths.UserSettings) -Force
        @{ 'editor.fontSize' = 13 } | ConvertTo-Json | Set-Content -Path $paths.UserSettings -Encoding utf8NoBOM
        $null = New-Item -ItemType Directory -Path $workspaceSettingsDir -Force
        @{ 'files.trimTrailingWhitespace' = $true } | ConvertTo-Json | Set-Content -Path $workspaceSettingsPath -Encoding utf8NoBOM
        "existing.log`n" | Set-Content -Path $gitignorePath -NoNewline -Encoding utf8NoBOM

        $result = & $script:ScriptPath `
            -UserSettingsPath $paths.UserSettings `
            -WorkspacePath $paths.Workspace `
            -UserHome $paths.UserHome `
            -Yes `
            -NonInteractive

        $result.Changed | Should -BeTrue

        $userSettings = script:Read-JsonFile -Path $paths.UserSettings
        $userSettings['editor.fontSize'] | Should -Be 13
        $userSettings['github.copilot.chat.otel.enabled'] | Should -BeTrue
        $userSettings['github.copilot.chat.otel.exporterType'] | Should -Be 'file'
        $userSettings['github.copilot.chat.otel.captureContent'] | Should -BeFalse

        $workspaceSettings = script:Read-JsonFile -Path $workspaceSettingsPath
        $workspaceSettings['files.trimTrailingWhitespace'] | Should -BeTrue
        $workspaceSettings['github.copilot.chat.otel.outfile'] | Should -Be $result.OtelOutfilePath
        $workspaceSettings['github.copilot.chat.otel.outfile'] | Should -Not -Match '\$\{'
        ($workspaceSettings['github.copilot.chat.otel.outfile'] -replace '\\', '/') | Should -Match '/home/.copilot-otel/workspace-one/copilot\.jsonl$'

        Test-Path (Split-Path -Parent $result.OtelOutfilePath) | Should -BeTrue
        Test-Path $result.OtelOutfilePath | Should -BeFalse

        $gitignoreLines = @(Get-Content -Path $gitignorePath)
        $gitignoreLines | Should -Contain 'existing.log'
        @($gitignoreLines | Where-Object { $_ -eq $script:SentinelName }).Count | Should -Be 1
        @($gitignoreLines | Where-Object { $_ -eq '.vscode/settings.json' }).Count | Should -Be 1

        $sentinelPath = Join-Path -Path $paths.Workspace -ChildPath $script:SentinelName
        Test-Path $sentinelPath | Should -BeTrue
        $sentinel = Get-Content -Path $sentinelPath -Raw
        $sentinel | Should -Match 'copilot-cost-collection-installed: v1'
        $sentinel | Should -Match 'survival: within-worktree'
        $sentinel | Should -Match ([regex]::Escape($result.WorkspacePath))
        $sentinel | Should -Match ([regex]::Escape($result.OtelOutfilePath))
        $sentinel | Should -Match 'not durable plan or session memory'
    }

    It 'is idempotent when the workspace is already compliant' {
        $paths = script:New-IsolatedPaths

        $first = & $script:ScriptPath `
            -UserSettingsPath $paths.UserSettings `
            -WorkspacePath $paths.Workspace `
            -UserHome $paths.UserHome `
            -Yes `
            -NonInteractive

        $workspaceSettingsPath = Join-Path -Path $paths.Workspace -ChildPath '.vscode/settings.json'
        $gitignorePath = Join-Path -Path $paths.Workspace -ChildPath '.gitignore'
        $sentinelPath = Join-Path -Path $paths.Workspace -ChildPath $script:SentinelName
        $before = @{
            UserSettings      = Get-Content -Path $paths.UserSettings -Raw
            WorkspaceSettings = Get-Content -Path $workspaceSettingsPath -Raw
            Gitignore         = Get-Content -Path $gitignorePath -Raw
            Sentinel          = Get-Content -Path $sentinelPath -Raw
        }

        $second = & $script:ScriptPath `
            -UserSettingsPath $paths.UserSettings `
            -WorkspacePath $paths.Workspace `
            -UserHome $paths.UserHome `
            -Yes `
            -NonInteractive

        $first.Changed | Should -BeTrue
        $second.Changed | Should -BeFalse
        $second.Actions.Count | Should -Be 0
        Get-Content -Path $paths.UserSettings -Raw | Should -Be $before.UserSettings
        Get-Content -Path $workspaceSettingsPath -Raw | Should -Be $before.WorkspaceSettings
        Get-Content -Path $gitignorePath -Raw | Should -Be $before.Gitignore
        Get-Content -Path $sentinelPath -Raw | Should -Be $before.Sentinel
    }

    It 'only mutates install artifacts that need repair' {
        $paths = script:New-IsolatedPaths

        & $script:ScriptPath `
            -UserSettingsPath $paths.UserSettings `
            -WorkspacePath $paths.Workspace `
            -UserHome $paths.UserHome `
            -Yes `
            -NonInteractive

        $workspaceSettingsPath = Join-Path -Path $paths.Workspace -ChildPath '.vscode/settings.json'
        $gitignorePath = Join-Path -Path $paths.Workspace -ChildPath '.gitignore'
        $sentinelPath = Join-Path -Path $paths.Workspace -ChildPath $script:SentinelName
        $before = @{
            WorkspaceSettings = Get-Content -Path $workspaceSettingsPath -Raw
            Gitignore         = Get-Content -Path $gitignorePath -Raw
            Sentinel          = Get-Content -Path $sentinelPath -Raw
        }

        $userSettings = script:Read-JsonFile -Path $paths.UserSettings
        $userSettings.Remove('github.copilot.chat.otel.captureContent')
        $userSettings | ConvertTo-Json | Set-Content -Path $paths.UserSettings -Encoding utf8NoBOM

        $result = & $script:ScriptPath `
            -UserSettingsPath $paths.UserSettings `
            -WorkspacePath $paths.Workspace `
            -UserHome $paths.UserHome `
            -Yes `
            -NonInteractive

        $result.Changed | Should -BeTrue
        $result.Actions | Should -HaveCount 1
        $result.Actions[0] | Should -Match 'write user settings'
        Get-Content -Path $workspaceSettingsPath -Raw | Should -Be $before.WorkspaceSettings
        Get-Content -Path $gitignorePath -Raw | Should -Be $before.Gitignore
        Get-Content -Path $sentinelPath -Raw | Should -Be $before.Sentinel
        @((Get-Content -Path $gitignorePath) | Where-Object { $_ -eq $script:SentinelName }).Count | Should -Be 1
        @((Get-Content -Path $gitignorePath) | Where-Object { $_ -eq '.vscode/settings.json' }).Count | Should -Be 1
    }

    It 'additively gitignores workspace settings when writing the literal OTel outfile path' {
        $paths = script:New-IsolatedPaths
        $gitignorePath = Join-Path -Path $paths.Workspace -ChildPath '.gitignore'

        $result = & $script:ScriptPath `
            -UserSettingsPath $paths.UserSettings `
            -WorkspacePath $paths.Workspace `
            -UserHome $paths.UserHome `
            -Yes `
            -NonInteractive

        $result.Changed | Should -BeTrue
        $gitignoreLines = @(Get-Content -Path $gitignorePath)
        $gitignoreLines | Should -Contain '.vscode/settings.json'
    }

    It 'warns when workspace settings are already tracked because gitignore cannot protect the literal path' {
        $paths = script:New-IsolatedPaths
        $workspaceSettingsDir = Join-Path -Path $paths.Workspace -ChildPath '.vscode'
        $workspaceSettingsPath = Join-Path -Path $workspaceSettingsDir -ChildPath 'settings.json'
        $null = New-Item -ItemType Directory -Path $workspaceSettingsDir -Force
        @{ 'files.trimTrailingWhitespace' = $true } | ConvertTo-Json | Set-Content -Path $workspaceSettingsPath -Encoding utf8NoBOM

        $resolvedWorkspace = (Resolve-Path -Path $paths.Workspace).ProviderPath
        $gitPath = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $null = & $gitPath -C $resolvedWorkspace init 2>$null
        $null = & $gitPath -C $resolvedWorkspace add -f .vscode/settings.json 2>$null
        $null = & $gitPath -C $resolvedWorkspace ls-files --error-unmatch -- .vscode/settings.json 2>$null
        $LASTEXITCODE | Should -Be 0 -Because 'the fixture must make workspace settings tracked before installer runs'

        $result = & $script:ScriptPath `
            -UserSettingsPath $paths.UserSettings `
            -WorkspacePath $paths.Workspace `
            -UserHome $paths.UserHome `
            -Yes `
            -NonInteractive `
            -WarningVariable warnings

        $result.Changed | Should -BeTrue
        $warnings | Where-Object { [string]$_ -match '\.vscode/settings\.json' -and [string]$_ -match 'already tracked' -and [string]$_ -match '\.gitignore cannot protect' } | Should -Not -BeNullOrEmpty

        $gitignorePath = Join-Path -Path $paths.Workspace -ChildPath '.gitignore'
        @(Get-Content -Path $gitignorePath) | Should -Contain '.vscode/settings.json'
    }

    It 'fails clearly in non-interactive mode when install changes need confirmation and -Yes is absent' {
        $paths = script:New-IsolatedPaths

        { & $script:ScriptPath -UserSettingsPath $paths.UserSettings -WorkspacePath $paths.Workspace -UserHome $paths.UserHome -NonInteractive -ErrorAction Stop } |
            Should -Throw '*requires -Yes when -NonInteractive is specified*'

        Test-Path $paths.UserSettings | Should -BeFalse
        Test-Path (Join-Path -Path $paths.Workspace -ChildPath '.vscode/settings.json') | Should -BeFalse
        Test-Path (Join-Path -Path $paths.Workspace -ChildPath $script:SentinelName) | Should -BeFalse
    }

    It 'honors WhatIf without requiring -Yes or mutating local files' {
        $paths = script:New-IsolatedPaths

        $result = & $script:ScriptPath `
            -UserSettingsPath $paths.UserSettings `
            -WorkspacePath $paths.Workspace `
            -UserHome $paths.UserHome `
            -NonInteractive `
            -WhatIf

        $result.WhatIf | Should -BeTrue
        $result.Changed | Should -BeFalse
        $result.Actions.Count | Should -BeGreaterThan 0
        Test-Path $paths.UserSettings | Should -BeFalse
        Test-Path (Join-Path -Path $paths.Workspace -ChildPath '.vscode/settings.json') | Should -BeFalse
        Test-Path (Join-Path -Path $paths.Workspace -ChildPath $script:SentinelName) | Should -BeFalse
    }

    It 'reports invalid JSON settings instead of rewriting them with string manipulation' {
        $paths = script:New-IsolatedPaths
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $paths.UserSettings) -Force
        '{ invalid json' | Set-Content -Path $paths.UserSettings -Encoding utf8NoBOM

        { & $script:ScriptPath -UserSettingsPath $paths.UserSettings -WorkspacePath $paths.Workspace -UserHome $paths.UserHome -Yes -NonInteractive -ErrorAction Stop } |
            Should -Throw '*Failed to parse JSON settings at *settings.json*'
    }
}
