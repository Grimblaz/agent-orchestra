
Describe 'Generate-ReferencesIndex.ps1' {
    It 'generates .references/index.json and Documents/INDEX.md with sorted, LF, deterministic output' {
        # Arrange
        $fixtureRoot = Join-Path $PSScriptRoot 'fixtures/project-references/valid-repo'
        $expectedIndex = Join-Path $fixtureRoot 'expected-index.json'
        $repoRoot = Join-Path $TestDrive 'repo'
        Copy-Item $fixtureRoot $repoRoot -Recurse
        $indexPath = Join-Path $repoRoot '.references/index.json'
        $indexMdPath = Join-Path $repoRoot 'Documents/INDEX.md'
        # Act
            $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
            $script:ProjectReferenceScriptRoot = Join-Path $script:RepoRoot 'skills/project-references/scripts'
            & (Join-Path $script:ProjectReferenceScriptRoot 'generate-references-index.ps1') -Root $repoRoot | Out-Null
        # Assert
        Test-Path $indexPath | Should -BeTrue
        Test-Path $indexMdPath | Should -BeTrue
        $actual = Get-Content $indexPath -Raw
        $expected = Get-Content $expectedIndex -Raw
        # Remove generated_at for deterministic compare
        $actualNoGen = ($actual -replace '"generated_at": ".*?",?\r?\n', '') -replace "`r`n", "`n"
        $expectedNoGen = ($expected -replace '"generated_at": ".*?",?\r?\n', '') -replace "`r`n", "`n"
        ($actualNoGen | ConvertFrom-Json | ConvertTo-Json -Depth 20 -Compress) | Should -BeExactly ($expectedNoGen | ConvertFrom-Json | ConvertTo-Json -Depth 20 -Compress)
        # Assert LF endings
        (($actual -split "\r?\n") -join "`n") | Should -BeExactly $actual
        # Assert sorted by name
        $json = $actual | ConvertFrom-Json
        $names = $json | ForEach-Object { $_.name }
        $names | Should -Be ($names | Sort-Object)
        ($json | Where-Object name -EQ 'Sample Reference').'load-priority' | Should -BeExactly 'recommended'
        ($json | Where-Object name -EQ 'Sample Reference').description | Should -BeExactly 'Sample project reference'
        ($json | Where-Object name -EQ 'Sample Reference').'load-when' | Should -BeExactly 'Load when API reference work touches sample-doc.md'
    }
    It 'is deterministic on rerun after normalizing generated_at' {
        $repoRoot = Join-Path $TestDrive 'repo2'
        Copy-Item $PSScriptRoot/fixtures/project-references/valid-repo $repoRoot -Recurse
        . (Join-Path $script:ProjectReferenceScriptRoot 'generate-references-index.ps1') -Root $repoRoot
        $first = Get-Content (Join-Path $repoRoot '.references/index.json') -Raw
        Start-Sleep -Milliseconds 100
        . (Join-Path $script:ProjectReferenceScriptRoot 'generate-references-index.ps1') -Root $repoRoot
        $second = Get-Content (Join-Path $repoRoot '.references/index.json') -Raw
        $firstNoGen = $first -replace '"generated_at": ".*?",?\r?\n', ''
        $secondNoGen = $second -replace '"generated_at": ".*?",?\r?\n', ''
        $firstNoGen | Should -BeExactly $secondNoGen
    }
}
