#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Port list defined at discovery scope so -ForEach can expand it before BeforeAll runs.
# Hashtable form required so Pester 5 can bind param($PortName) in each It block.
$script:ExpectedPortCases = @(
    @{ PortName = 'experience' }
    @{ PortName = 'design' }
    @{ PortName = 'plan' }
    @{ PortName = 'implement-code' }
    @{ PortName = 'implement-test' }
    @{ PortName = 'implement-refactor' }
    @{ PortName = 'implement-docs' }
    @{ PortName = 'review' }
    @{ PortName = 'ce-gate-cli' }
    @{ PortName = 'ce-gate-browser' }
    @{ PortName = 'ce-gate-canvas' }
    @{ PortName = 'ce-gate-api' }
    @{ PortName = 'release-hygiene' }
    @{ PortName = 'post-pr' }
    @{ PortName = 'post-fix-review' }
    @{ PortName = 'process-review' }
    @{ PortName = 'process-retrospective' }
)

$script:ExpectedPorts = $script:ExpectedPortCases | ForEach-Object { $_.PortName }

Describe 'frame port manifest' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:PortsDir = Join-Path $script:RepoRoot 'frame\ports'

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

        $expected = @(
            'ce-gate-api', 'ce-gate-browser', 'ce-gate-canvas', 'ce-gate-cli',
            'design', 'experience',
            'implement-code', 'implement-docs', 'implement-refactor', 'implement-test',
            'plan', 'post-fix-review', 'post-pr',
            'process-retrospective', 'process-review',
            'release-hygiene', 'review'
        ) | Sort-Object

        $actualPorts | Should -Be $expected
    }

    It 'declares an explicit applies enum in <PortName>.yaml' -ForEach $script:ExpectedPortCases {
        param($PortName)

        if (-not (& $script:RequirePortsDir)) {
            return
        }

        $portFile = Join-Path $script:PortsDir ($PortName + '.yaml')
        $portFile | Should -Exist

        $content = (Get-Content -Raw -Path $portFile) -replace '\r', ''
        $content | Should -Match '(?m)^applies:\s*(always|trigger-conditional)$'
    }

    It 'declares an explicit status enum in <PortName>.yaml' -ForEach $script:ExpectedPortCases {
        param($PortName)

        if (-not (& $script:RequirePortsDir)) {
            return
        }

        $portFile = Join-Path $script:PortsDir ($PortName + '.yaml')
        $portFile | Should -Exist

        $content = (Get-Content -Raw -Path $portFile) -replace '\r', ''
        $content | Should -Match '(?m)^status:\s*(stable|tbd-decision-pending|formalized-skeleton-deferred-to-\S+)$'
    }
}
