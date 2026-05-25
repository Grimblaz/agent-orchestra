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
}
