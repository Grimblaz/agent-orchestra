
Describe 'Invoke-ReferenceLoader.ps1' {
    It 'matches triggers, emits critical no-match, escapes fences, marks untrusted, truncates, state drives nudge' {
        $fixtureRoot = Join-Path $PSScriptRoot 'fixtures/project-references/valid-repo'
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ProjectReferenceScriptRoot = Join-Path $script:RepoRoot 'skills/project-references/scripts'
        $issuePayloadPath = Join-Path $fixtureRoot 'synthetic-issue.json'
        $indexJsonPath = Join-Path $fixtureRoot 'index.json'
        $stateFilePath = Join-Path $fixtureRoot 'state.json'
        $declaredRoots = @(Join-Path $fixtureRoot 'root1', Join-Path $fixtureRoot 'root2')
        $result = & (Join-Path $script:ProjectReferenceScriptRoot 'invoke-reference-loader.ps1') -IssuePayloadPath $issuePayloadPath -IndexJsonPath $indexJsonPath -StateFilePath $stateFilePath -DeclaredRoots $declaredRoots | ConvertFrom-Json
        # Assert: label/glob/keyword triggers
        $result.matched | Should -Contain 'Sample Reference'
        # Assert: critical no-match
        $critRoot = Join-Path $PSScriptRoot 'fixtures/project-references/critical-no-match'
        $critIssuePayloadPath = Join-Path $critRoot 'synthetic-issue.json'
        $critIndexJsonPath = Join-Path $critRoot 'index.json'
        $critStateFilePath = Join-Path $critRoot 'state.json'
        $critDeclaredRoots = @(Join-Path $critRoot 'root1', Join-Path $critRoot 'root2')
        $critResult = & (Join-Path $script:ProjectReferenceScriptRoot 'invoke-reference-loader.ps1') -IssuePayloadPath $critIssuePayloadPath -IndexJsonPath $critIndexJsonPath -StateFilePath $critStateFilePath -DeclaredRoots $critDeclaredRoots
        $critResult | Should -Match '\[not loaded; triggers did not match — confirm scope does not intersect\]'
        # Assert: stale emits stale-ref
        $staleRoot = Join-Path $PSScriptRoot 'fixtures/project-references/stale-target'
        $staleIssue = @{ labels = @('stale'); files = @('missing-doc.md'); keywords = @('stale') }
        $staleIssuePayloadPath = Join-Path $staleRoot 'synthetic-issue.json'
        $staleIndexJsonPath = Join-Path $staleRoot 'index.json'
        $staleStateFilePath = Join-Path $staleRoot 'state.json'
        $staleDeclaredRoots = @(Join-Path $staleRoot 'root1', Join-Path $staleRoot 'root2')
        $staleResult = & (Join-Path $script:ProjectReferenceScriptRoot 'invoke-reference-loader.ps1') -IssuePayloadPath $staleIssuePayloadPath -IndexJsonPath $staleIndexJsonPath -StateFilePath $staleStateFilePath -DeclaredRoots $staleDeclaredRoots
        $staleResult | Should -Match '\[stale-ref: Stale Target'
        # Assert: fence-escape output is fenced and untrusted
        $fenceRoot = Join-Path $PSScriptRoot 'fixtures/project-references/fence-escape'
        $fenceIssue = @{ labels = @('fence'); files = @('fence-escape.md'); keywords = @('fence', 'escape') }
        $fenceIssuePayloadPath = Join-Path $fenceRoot 'synthetic-issue.json'
        $fenceIndexJsonPath = Join-Path $fenceRoot 'index.json'
        $fenceStateFilePath = Join-Path $fenceRoot 'state.json'
        $fenceDeclaredRoots = @(Join-Path $fenceRoot 'root1', Join-Path $fenceRoot 'root2')
        $fenceResult = & (Join-Path $script:ProjectReferenceScriptRoot 'invoke-reference-loader.ps1') -IssuePayloadPath $fenceIssuePayloadPath -IndexJsonPath $fenceIndexJsonPath -StateFilePath $fenceStateFilePath -DeclaredRoots $fenceDeclaredRoots | ConvertFrom-Json
        $fenceResult.untrusted | Should -BeTrue
        $fenceResult.rendered | Should -Match '```'
        # Assert: hard cap truncates to 10
        $many = @(1..12 | ForEach-Object { @{ name = "Ref$_"; target_path = "doc$_" } })
        $truncIssuePayloadPath = Join-Path $fixtureRoot 'synthetic-issue.json'
        $truncIndexJsonPath = Join-Path $fixtureRoot 'index.json'
        $truncStateFilePath = Join-Path $fixtureRoot 'state.json'
        $truncDeclaredRoots = @(Join-Path $fixtureRoot 'root1', Join-Path $fixtureRoot 'root2')
        $truncResult = & (Join-Path $script:ProjectReferenceScriptRoot 'invoke-reference-loader.ps1') -IssuePayloadPath $truncIssuePayloadPath -IndexJsonPath $truncIndexJsonPath -StateFilePath $truncStateFilePath -DeclaredRoots $truncDeclaredRoots | ConvertFrom-Json
        $truncResult.matched.Count | Should -Be 10
        # Assert: state file controls nudge_due and nudge_dismissed
        $state = @{ nudge_due = $true; nudge_dismissed = $false }
        $stateIssuePayloadPath = Join-Path $fixtureRoot 'synthetic-issue.json'
        $stateIndexJsonPath = Join-Path $fixtureRoot 'index.json'
        $stateStateFilePath = Join-Path $fixtureRoot 'state.json'
        $stateDeclaredRoots = @(Join-Path $fixtureRoot 'root1', Join-Path $fixtureRoot 'root2')
        $stateResult = & (Join-Path $script:ProjectReferenceScriptRoot 'invoke-reference-loader.ps1') -IssuePayloadPath $stateIssuePayloadPath -IndexJsonPath $stateIndexJsonPath -StateFilePath $stateStateFilePath -DeclaredRoots $stateDeclaredRoots | ConvertFrom-Json
        $stateResult.nudge_due | Should -BeTrue
        $stateResult.nudge_dismissed | Should -BeFalse
    }
}
