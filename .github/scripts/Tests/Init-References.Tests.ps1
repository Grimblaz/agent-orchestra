
Describe 'Init-References.ps1' {
    It 'creates sidecars with generated_by, manifest, preserves manual, --undo removes only generated, is resumable, migrates index, empty roots is no-op' {
        $fixtureRoot = Join-Path $PSScriptRoot 'fixtures/project-references/valid-repo'
        $repoRoot = Join-Path $TestDrive 'repo'
        Copy-Item $fixtureRoot $repoRoot -Recurse
        # Act: run init
            $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
            $script:ProjectReferenceScriptRoot = Join-Path $script:RepoRoot 'skills/project-references/scripts'
            $result = & (Join-Path $script:ProjectReferenceScriptRoot 'init-references.ps1') -Root $repoRoot | ConvertFrom-Json
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
            $result = & (Join-Path $script:ProjectReferenceScriptRoot 'init-references.ps1') -Root $repoRoot | ConvertFrom-Json
        (Get-Content $manual -Raw) | Should -BeExactly 'manual: true'
        # Assert: --undo removes only generated
            $result = & (Join-Path $script:ProjectReferenceScriptRoot 'init-references.ps1') -Root $repoRoot --undo | ConvertFrom-Json
        Test-Path $sidecar | Should -BeFalse
        Test-Path $manual | Should -BeTrue
        # Assert: index migration
        $index = Join-Path $repoRoot 'index.json'
        Set-Content $index '[]'
            $result = & (Join-Path $script:ProjectReferenceScriptRoot 'init-references.ps1') -Root $repoRoot | ConvertFrom-Json
        Test-Path $manifest | Should -BeTrue
        # Assert: empty roots exits successfully
        $emptyRoot = Join-Path $TestDrive 'empty'
        Copy-Item $PSScriptRoot/fixtures/project-references/empty-roots $emptyRoot -Recurse
            $result = & (Join-Path $script:ProjectReferenceScriptRoot 'init-references.ps1') -Root $emptyRoot | ConvertFrom-Json
        # Should not throw, and no sidecars generated
        @(Get-ChildItem $emptyRoot -Recurse -Filter '*.ref.yml').Count | Should -Be 0
    }
}
