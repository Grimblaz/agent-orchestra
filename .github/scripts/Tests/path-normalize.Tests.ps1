#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Get-NormalizedPath' {
    BeforeAll {
        $script:LibPath = Join-Path $PSScriptRoot '..\lib\path-normalize.ps1'
        if (Test-Path $script:LibPath) { . $script:LibPath }
    }

    It 'function exists' { Get-Command Get-NormalizedPath -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty }
    It 'normalizes Windows backslash path' {
        Get-NormalizedPath -Path 'C:\Users\Micah\Code' | Should -Be '/c/Users/Micah/Code'
    }
    It 'normalizes Windows forward-slash path' {
        Get-NormalizedPath -Path 'C:/Users/Micah/Code' | Should -Be '/c/Users/Micah/Code'
    }
    It 'leaves git-bash /c/ form unchanged' {
        Get-NormalizedPath -Path '/c/Users/Micah/Code' | Should -Be '/c/Users/Micah/Code'
    }
    It 'strips trailing slash' {
        Get-NormalizedPath -Path '/c/Users/Micah/Code/' | Should -Be '/c/Users/Micah/Code'
    }
    It 'is idempotent' {
        $once  = Get-NormalizedPath -Path 'C:\Users\Micah\Code'
        $twice = Get-NormalizedPath -Path $once
        $twice | Should -Be $once
    }
    It 'handles empty string without error' {
        { Get-NormalizedPath -Path '' } | Should -Not -Throw
        Get-NormalizedPath -Path '' | Should -Be ''
    }
    It 'handles bare drive letter' {
        Get-NormalizedPath -Path 'C:' | Should -Be '/c'
    }
}
