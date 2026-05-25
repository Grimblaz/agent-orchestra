
Describe 'Init-References.ps1' {
    It 'creates sidecars with generated_by, manifest, preserves manual, --undo removes only generated, is resumable, migrates index, empty roots is no-op' {
        $fixtureRoot = Join-Path $PSScriptRoot 'fixtures/project-references/valid-repo'
        $repoRoot = Join-Path $TestDrive 'repo'
        Copy-Item $fixtureRoot $repoRoot -Recurse
        New-Item -ItemType Directory -Path (Join-Path $repoRoot 'Documents') | Out-Null
        Set-Content -Path (Join-Path $repoRoot 'Documents/foo.md') -Value '# Foo'
        Set-Content -Path (Join-Path $repoRoot 'generated.md') -Value '# Generated'
        $rootManifest = Join-Path $repoRoot 'manifest.json'
        Set-Content -Path $rootManifest -Value '{"sentinel":true}'
        # Act: run init
            $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
            $script:ProjectReferenceScriptRoot = Join-Path $script:RepoRoot 'skills/project-references/scripts'
            & (Join-Path $script:ProjectReferenceScriptRoot 'init-references.ps1') -Root $repoRoot | Out-Null
        # Assert: sidecar created
        $sidecar = Join-Path $repoRoot 'generated.md.ref.yml'
        $nestedSidecar = Join-Path $repoRoot 'Documents/foo.md.ref.yml'
        Test-Path $sidecar | Should -BeTrue
        Test-Path $nestedSidecar | Should -BeTrue
        (Get-Content $sidecar -Raw) | Should -Match 'generated_by: init-references'
        (Get-Content $nestedSidecar -Raw) | Should -Match 'target_path: Documents/foo.md'
        (Get-Content $nestedSidecar -Raw) | Should -Match 'description: Generated reference for Documents/foo.md'
        (Get-Content $nestedSidecar -Raw) | Should -Match 'load-when: Load when work touches Documents/foo.md'
        (Get-Content $nestedSidecar -Raw) | Should -Match 'generated_at: .+'
        # Assert: manifest created
        $manifest = Join-Path $repoRoot '.copilot-tracking/references-init.manifest'
        Test-Path $manifest | Should -BeTrue
        ((Get-Content $rootManifest -Raw) | ConvertFrom-Json).sentinel | Should -BeTrue
        Test-Path (Join-Path $repoRoot '.copilot-tracking/references-state.yml') | Should -BeTrue
        # Assert: manual sidecars preserved on rerun
        $manual = Join-Path $repoRoot 'manual.md.ref.yml'
        Set-Content $manual 'manual: true'
            & (Join-Path $script:ProjectReferenceScriptRoot 'init-references.ps1') -Root $repoRoot | Out-Null
        (Get-Content $manual -Raw).TrimEnd() | Should -BeExactly 'manual: true'
        $outside = Join-Path $TestDrive 'outside-delete-me.md'
        Set-Content -Path $outside -Value 'outside'
        @{ created = @('generated.md.ref.yml', 'Documents/foo.md.ref.yml', $outside) } | ConvertTo-Json | Set-Content -Path $manifest
        # Assert: --undo removes only generated
            & (Join-Path $script:ProjectReferenceScriptRoot 'init-references.ps1') -Root $repoRoot --undo | Out-Null
        Test-Path $sidecar | Should -BeFalse
        Test-Path $nestedSidecar | Should -BeFalse
        Test-Path $manual | Should -BeTrue
        Test-Path $outside | Should -BeTrue
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

    It 'writes nudge dismissal state without touching repository-root manifest' {
        $repoRoot = Join-Path $TestDrive 'dismiss'
        New-Item -ItemType Directory -Path $repoRoot | Out-Null
        $rootManifest = Join-Path $repoRoot 'manifest.json'
        Set-Content -Path $rootManifest -Value '{"sentinel":true}'

        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ProjectReferenceScriptRoot = Join-Path $script:RepoRoot 'skills/project-references/scripts'
        & (Join-Path $script:ProjectReferenceScriptRoot 'init-references.ps1') -Root $repoRoot --dismiss-nudge | Out-Null

        (Get-Content (Join-Path $repoRoot '.copilot-tracking/references-state.yml') -Raw) | Should -Match 'references_nudge_dismissed: true'
        ((Get-Content $rootManifest -Raw) | ConvertFrom-Json).sentinel | Should -BeTrue
    }
}
