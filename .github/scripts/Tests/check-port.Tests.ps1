#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester contract tests for check-port.ps1 / Invoke-CheckPort.

.DESCRIPTION
    RED-phase tests for a port-availability checker.
    Target library: skills/terminal-hygiene/scripts/check-port-core.ps1
    Exported function: Invoke-CheckPort -Port [int]
    Private helpers (mocked): Test-CPSocketBind, Get-CPWindowsPortInfo

    All socket interactions are mocked — no real TCP connections.
#>

Describe 'check-port.ps1' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:LibFile = Join-Path $script:RepoRoot 'skills/terminal-hygiene/scripts/check-port-core.ps1'
        . $script:LibFile
    }

    Context 'port not in use' {

        It 'returns InUse $false when socket bind succeeds' {
            # Arrange
            Mock Test-CPSocketBind { return $true }
            Mock Get-CPWindowsPortInfo { return $null }

            # Act
            $result = Invoke-CheckPort -Port 9999

            # Assert
            $result.InUse | Should -Be $false
            $result.Pid | Should -BeNullOrEmpty
            $result.ProcessName | Should -BeNullOrEmpty
        }
    }

    Context 'port in use — Windows with PID enrichment' {

        It 'returns InUse $true with process details when Get-CPWindowsPortInfo provides them' {
            # Arrange
            Mock Test-CPSocketBind { return $false }
            Mock Get-CPWindowsPortInfo {
                return @{ OwningProcess = 1234; ProcessName = 'node' }
            }

            # Act
            $result = Invoke-CheckPort -Port 3000

            # Assert
            $result.InUse | Should -Be $true
            $result.Pid | Should -Be 1234
            $result.ProcessName | Should -Be 'node'
        }
    }

    Context 'port in use — cross-platform (no Get-NetTCPConnection)' {

        It 'returns InUse $true with null PID and ProcessName when enrichment unavailable' {
            # Arrange
            Mock Test-CPSocketBind { return $false }
            Mock Get-CPWindowsPortInfo { return $null }

            # Act
            $result = Invoke-CheckPort -Port 3000

            # Assert
            $result.InUse | Should -Be $true
            $result.Pid | Should -BeNullOrEmpty
            $result.ProcessName | Should -BeNullOrEmpty
        }
    }

    Context 'output structure contract' {

        It 'always includes InUse, Pid, and ProcessName properties when port is available' {
            # Arrange
            Mock Test-CPSocketBind { return $true }
            Mock Get-CPWindowsPortInfo { return $null }

            # Act
            $result = Invoke-CheckPort -Port 9999

            # Assert
            $result.PSObject.Properties.Name | Should -Contain 'InUse'
            $result.PSObject.Properties.Name | Should -Contain 'Pid'
            $result.PSObject.Properties.Name | Should -Contain 'ProcessName'
        }

        It 'always includes InUse, Pid, and ProcessName properties when port is in use' {
            # Arrange
            Mock Test-CPSocketBind { return $false }
            Mock Get-CPWindowsPortInfo {
                return @{ OwningProcess = 5678; ProcessName = 'python' }
            }

            # Act
            $result = Invoke-CheckPort -Port 8080

            # Assert
            $result.PSObject.Properties.Name | Should -Contain 'InUse'
            $result.PSObject.Properties.Name | Should -Contain 'Pid'
            $result.PSObject.Properties.Name | Should -Contain 'ProcessName'
        }

        It 'has exactly 3 properties on the result object' {
            # Arrange
            Mock Test-CPSocketBind { return $true }
            Mock Get-CPWindowsPortInfo { return $null }

            # Act
            $result = Invoke-CheckPort -Port 9999

            # Assert
            $result.PSObject.Properties.Name | Should -HaveCount 3
        }
    }

    Context 'error handling — non-fatal degradation' {

        It 'does not throw when Test-CPSocketBind throws unexpectedly' {
            # Arrange
            Mock Test-CPSocketBind { throw 'Unexpected socket error' }
            Mock Get-CPWindowsPortInfo { return $null }

            # Act & Assert
            { Invoke-CheckPort -Port 8080 } | Should -Not -Throw
        }

        It 'returns safe defaults when Test-CPSocketBind throws' {
            # Arrange
            Mock Test-CPSocketBind { throw 'Unexpected socket error' }
            Mock Get-CPWindowsPortInfo { return $null }

            # Act
            $result = Invoke-CheckPort -Port 8080

            # Assert
            $result.InUse | Should -Be $false
            $result.Pid | Should -BeNullOrEmpty
            $result.ProcessName | Should -BeNullOrEmpty
        }

        It 'returns safe defaults when Get-CPWindowsPortInfo throws unexpectedly' {
            # Arrange
            Mock Test-CPSocketBind { return $false }
            Mock Get-CPWindowsPortInfo { throw 'Unexpected netstat error' }

            # Act
            $result = Invoke-CheckPort -Port 8080

            # Assert
            $result.InUse | Should -Be $true
            $result.Pid | Should -BeNullOrEmpty
            $result.ProcessName | Should -BeNullOrEmpty
        }
    }
}
