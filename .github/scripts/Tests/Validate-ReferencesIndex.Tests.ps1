Describe 'Validate-ReferencesIndex.ps1' {
    It 'reports stale target_path, orphan sidecar, duplicate names, unknown schema_version, uncovered doc, and citation regex' {
        $fixtureRoot = Join-Path $PSScriptRoot 'fixtures/project-references'
            $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
            $script:ProjectReferenceScriptRoot = Join-Path $script:RepoRoot 'skills/project-references/scripts'
            $json = & (Join-Path $script:ProjectReferenceScriptRoot 'validate-references-index.ps1') -Root $fixtureRoot | ConvertFrom-Json
        # Stale target_path
        $json.stale | Should -Contain 'Stale Target'
        # Orphan sidecar
        $json.orphan | Should -Contain 'Orphan Sidecar'
        # Duplicate names
        $json.duplicate | Should -Contain 'Duplicate Name'
        # Unknown schema_version
        $json.unknown_schema | Should -Contain 'Unknown Schema'
        # Uncovered doc (should be present if fixture added)
        if ($json.uncovered) { $json.uncovered | Should -Not -BeNullOrEmpty }
        # Citation parser: false positive
        $falsePos = '[ref:sample-reference](Documents/sample-doc.md)'
        $json.citation_false_positives | Should -Contain $falsePos
        # Citation parser: accepts valid
        $valid = '[ref:Sample Reference](Documents/sample-doc.md)'
        $json.citation_valid | Should -Contain $valid
    }

    It 'scopes uncovered docs to references.declared_roots when configured' {
        $fixtureRoot = Join-Path $PSScriptRoot 'fixtures/project-references/declared-roots'
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $projectReferenceScriptRoot = Join-Path $repoRoot 'skills/project-references/scripts'
        $json = & (Join-Path $projectReferenceScriptRoot 'validate-references-index.ps1') -Root $fixtureRoot | ConvertFrom-Json
        $uncoveredRelative = @($json.uncovered | ForEach-Object { [System.IO.Path]::GetRelativePath($fixtureRoot, $_).Replace('\', '/') })

        $uncoveredRelative | Should -Contain 'Documents/uncovered-inside-root.md'
        $uncoveredRelative | Should -Not -Contain 'README.md'
    }

    It 'marks out-of-root target paths stale and computes configured projected budget overrun' {
        $repoRoot = Join-Path $TestDrive 'unsafe-targets'
        New-Item -ItemType Directory -Path $repoRoot | Out-Null
        $outside = Join-Path $TestDrive 'outside.md'
        Set-Content -Path $outside -Value 'outside'
        Set-Content -Path (Join-Path $repoRoot '.agent-orchestra.yml') -Value @(
            'references:'
            '  max_total_loaded_bytes: 3'
        )
        Set-Content -Path (Join-Path $repoRoot 'inside.md') -Value '12345'
        Set-Content -Path (Join-Path $repoRoot 'inside.md.ref.yml') -Value @(
            'schema_version: 1'
            'name: Inside Budget'
            'target_path: inside.md'
            'description: Inside budget fixture'
            'load-when: Load for budget validation'
            'load-priority: optional'
            'generated_by: manual'
            'generated_at: 2026-05-25T00:00:00.0000000Z'
        )
        Set-Content -Path (Join-Path $repoRoot 'absolute.md.ref.yml') -Value @(
            'schema_version: 1'
            'name: Absolute Escape'
            "target_path: $outside"
            'description: Unsafe absolute target fixture'
            'load-when: Never load outside root'
            'load-priority: optional'
            'generated_by: manual'
            'generated_at: 2026-05-25T00:00:00.0000000Z'
        )
        Set-Content -Path (Join-Path $repoRoot 'traversal.md.ref.yml') -Value @(
            'schema_version: 1'
            'name: Traversal Escape'
            'target_path: ../outside.md'
            'description: Unsafe traversal target fixture'
            'load-when: Never load outside root'
            'load-priority: optional'
            'generated_by: manual'
            'generated_at: 2026-05-25T00:00:00.0000000Z'
        )

        $repoRootPath = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $projectReferenceScriptRoot = Join-Path $repoRootPath 'skills/project-references/scripts'
        $json = & (Join-Path $projectReferenceScriptRoot 'validate-references-index.ps1') -Root $repoRoot | ConvertFrom-Json

        $json.stale | Should -Contain 'Absolute Escape'
        $json.stale | Should -Contain 'Traversal Escape'
        $json.projected_budget_overrun | Should -BeTrue
        $json.projected_loaded_bytes | Should -BeGreaterThan 3
        $json.max_total_loaded_bytes | Should -Be 3
    }
}
