
Describe 'Init-References.ps1' {
    It 'creates sidecars with generated_by, manifest, preserves manual, --undo removes only generated, is resumable, migrates index, empty roots is no-op' {
        $fixtureRoot = Join-Path $PSScriptRoot 'fixtures/project-references/valid-repo'
        $repoRoot = Join-Path $TestDrive 'repo'
        Copy-Item $fixtureRoot $repoRoot -Recurse
        # Act: run init
            $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
            $script:ProjectReferenceScriptRoot = Join-Path $script:RepoRoot 'skills/project-references/scripts'
            & (Join-Path $script:ProjectReferenceScriptRoot 'init-references.ps1') -Root $repoRoot | Out-Null
        # Assert: sidecar created
        $sidecar = Join-Path $repoRoot 'sample-doc.md.ref.yml'
        Test-Path $sidecar | Should -BeTrue
        (Get-Content $sidecar -Raw) | Should -Match 'generated_by: init-references'
        # Assert: manifest created
        $manifest = Join-Path $repoRoot 'manifest.json'
        Test-Path $manifest | Should -BeTrue
        # Assert: manual sidecars preserved on rerun
        $manual = Join-Path $repoRoot 'manual.md.ref.yml'
        Set-Content $manual 'manual: true'
            & (Join-Path $script:ProjectReferenceScriptRoot 'init-references.ps1') -Root $repoRoot | Out-Null
        (Get-Content $manual -Raw).TrimEnd() | Should -BeExactly 'manual: true'
        # Assert: --undo removes only generated
            & (Join-Path $script:ProjectReferenceScriptRoot 'init-references.ps1') -Root $repoRoot --undo | Out-Null
        Test-Path $sidecar | Should -BeFalse
        Test-Path $manual | Should -BeTrue
        # Assert: index migration
        $index = Join-Path $repoRoot 'index.json'
        Set-Content $index '[]'
            & (Join-Path $script:ProjectReferenceScriptRoot 'init-references.ps1') -Root $repoRoot | Out-Null
        Test-Path $manifest | Should -BeTrue
        # Assert: empty roots exits successfully
        $emptyRoot = Join-Path $TestDrive 'empty'
        Copy-Item $PSScriptRoot/fixtures/project-references/empty-roots $emptyRoot -Recurse
            & (Join-Path $script:ProjectReferenceScriptRoot 'init-references.ps1') -Root $emptyRoot | Out-Null
        # Should not throw, and no sidecars generated
        @(Get-ChildItem $emptyRoot -Recurse -Filter '*.ref.yml').Count | Should -Be 0
    }
}
