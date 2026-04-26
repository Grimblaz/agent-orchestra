#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'frame port manifest' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:PortsDir = Join-Path $script:RepoRoot 'frame\ports'
        $script:ExpectedPorts = @(
            'experience',
            'design',
            'plan',
            'implement-code',
            'implement-test',
            'implement-refactor',
            'implement-docs',
            'review',
            'ce-gate-cli',
            'ce-gate-browser',
            'ce-gate-canvas',
            'ce-gate-api',
            'release-hygiene',
            'post-pr',
            'post-fix-review',
            'process-review',
            'process-retrospective'
        )

        $script:RequirePortsDir = {
            if (-not (Test-Path $script:PortsDir)) {
                Set-ItResult -Skipped -Because 'frame/ports manifest not implemented yet'
                return $false
            }

            return $true
        }
    }

    It 'creates the full 17-port manifest under frame/ports' {
        $script:PortsDir | Should -Exist

        $actualPorts = @(
            Get-ChildItem -Path $script:PortsDir -Filter '*.yaml' -File | ForEach-Object { $_.BaseName }
        ) | Sort-Object

        $actualPorts | Should -Be ($script:ExpectedPorts | Sort-Object)
    }

    It 'declares an explicit applies enum in <PortName>.yaml' -ForEach $script:ExpectedPorts {
        param($PortName)

        if (-not (& $script:RequirePortsDir)) {
            return
        }

        $portFile = Join-Path $script:PortsDir ($PortName + '.yaml')
        $portFile | Should -Exist

        $content = Get-Content -Raw -Path $portFile
        $content | Should -Match '(?m)^applies:\s*(always|trigger-conditional)$'
    }

    It 'declares an explicit status enum in <PortName>.yaml' -ForEach $script:ExpectedPorts {
        param($PortName)

        if (-not (& $script:RequirePortsDir)) {
            return
        }

        $portFile = Join-Path $script:PortsDir ($PortName + '.yaml')
        $portFile | Should -Exist

        $content = Get-Content -Raw -Path $portFile
        $content | Should -Match '(?m)^status:\s*(stable|tbd-decision-pending)$'
    }
}
