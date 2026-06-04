
Describe 'Invoke-ReferenceLoader.ps1' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ProjectReferenceScriptRoot = Join-Path $script:RepoRoot 'skills/project-references/scripts'
    }

    It 'matches triggers, emits critical no-match, escapes fences, marks untrusted, truncates, state drives nudge' {
        $fixtureRoot = Join-Path $PSScriptRoot 'fixtures/project-references/valid-repo'
        $issuePayloadPath = Join-Path $fixtureRoot 'synthetic-issue.json'
        $indexJsonPath = Join-Path $fixtureRoot 'index.json'
        $stateFilePath = Join-Path $fixtureRoot 'state.json'
        $declaredRoots = @((Join-Path -Path $fixtureRoot -ChildPath 'root1'), (Join-Path -Path $fixtureRoot -ChildPath 'root2'))
        $result = & (Join-Path $script:ProjectReferenceScriptRoot 'invoke-reference-loader.ps1') -IssuePayloadPath $issuePayloadPath -IndexJsonPath $indexJsonPath -StateFilePath $stateFilePath -DeclaredRoots $declaredRoots | ConvertFrom-Json
        # Assert: label/glob/keyword triggers
        $result.matched | Should -Contain 'Sample Reference'
        # Assert: critical no-match
        $critRoot = Join-Path $PSScriptRoot 'fixtures/project-references/critical-no-match'
        $critIssuePayloadPath = Join-Path $critRoot 'synthetic-issue.json'
        $critIndexJsonPath = Join-Path $critRoot 'index.json'
        $critStateFilePath = Join-Path $critRoot 'state.json'
        $critDeclaredRoots = @((Join-Path -Path $critRoot -ChildPath 'root1'), (Join-Path -Path $critRoot -ChildPath 'root2'))
        $critResult = & (Join-Path $script:ProjectReferenceScriptRoot 'invoke-reference-loader.ps1') -IssuePayloadPath $critIssuePayloadPath -IndexJsonPath $critIndexJsonPath -StateFilePath $critStateFilePath -DeclaredRoots $critDeclaredRoots
        $emDash = [char]0x2014
        $critResult | Should -Match "\[not loaded; triggers did not match $emDash confirm scope does not intersect\]"
        # Assert: stale emits stale-ref
        $staleRoot = Join-Path $PSScriptRoot 'fixtures/project-references/stale-target'
        $staleIssuePayloadPath = Join-Path $staleRoot 'synthetic-issue.json'
        $staleIndexJsonPath = Join-Path $staleRoot 'index.json'
        $staleStateFilePath = Join-Path $staleRoot 'state.json'
        $staleDeclaredRoots = @((Join-Path -Path $staleRoot -ChildPath 'root1'), (Join-Path -Path $staleRoot -ChildPath 'root2'))
        $staleResult = & (Join-Path $script:ProjectReferenceScriptRoot 'invoke-reference-loader.ps1') -IssuePayloadPath $staleIssuePayloadPath -IndexJsonPath $staleIndexJsonPath -StateFilePath $staleStateFilePath -DeclaredRoots $staleDeclaredRoots
        $staleResult | Should -Match '\[stale-ref: Stale Target'
        # Assert: fence-escape output is fenced and untrusted
        $fenceRoot = Join-Path $PSScriptRoot 'fixtures/project-references/fence-escape'
        $fenceIssuePayloadPath = Join-Path $fenceRoot 'synthetic-issue.json'
        $fenceIndexJsonPath = Join-Path $fenceRoot 'index.json'
        $fenceStateFilePath = Join-Path $fenceRoot 'state.json'
        $fenceDeclaredRoots = @((Join-Path -Path $fenceRoot -ChildPath 'root1'), (Join-Path -Path $fenceRoot -ChildPath 'root2'))
        $fenceResult = & (Join-Path $script:ProjectReferenceScriptRoot 'invoke-reference-loader.ps1') -IssuePayloadPath $fenceIssuePayloadPath -IndexJsonPath $fenceIndexJsonPath -StateFilePath $fenceStateFilePath -DeclaredRoots $fenceDeclaredRoots | ConvertFrom-Json
        $fenceResult.untrusted | Should -BeTrue
        # After render-all, rendered starts with a fence-open line; the global-max fence for this
        # body (longest run is 4 backticks) sizes to 5 backticks. The output must contain the
        # body sentinel and begin with an untrusted-content fence opener.
        $fenceResult.rendered | Should -Match '````` untrusted-content'
        $fenceResult.rendered | Should -Match 'Fence Escape'
        # Assert: default caps are surfaced; configured cap behavior is covered below
        $truncIssuePayloadPath = Join-Path $fixtureRoot 'synthetic-issue.json'
        $truncIndexJsonPath = Join-Path $fixtureRoot 'index.json'
        $truncStateFilePath = Join-Path $fixtureRoot 'state.json'
        $truncDeclaredRoots = @((Join-Path -Path $fixtureRoot -ChildPath 'root1'), (Join-Path -Path $fixtureRoot -ChildPath 'root2'))
        $truncResult = & (Join-Path $script:ProjectReferenceScriptRoot 'invoke-reference-loader.ps1') -IssuePayloadPath $truncIssuePayloadPath -IndexJsonPath $truncIndexJsonPath -StateFilePath $truncStateFilePath -DeclaredRoots $truncDeclaredRoots | ConvertFrom-Json
        $truncResult.max_critical_loaded | Should -Be 10
        $truncResult.max_total_loaded_bytes | Should -Be 102400
        # Assert: state file controls nudge_due and nudge_dismissed
        $stateIssuePayloadPath = Join-Path $fixtureRoot 'synthetic-issue.json'
        $stateIndexJsonPath = Join-Path $fixtureRoot 'index.json'
        $stateStateFilePath = Join-Path $fixtureRoot 'state.json'
        $stateDeclaredRoots = @((Join-Path -Path $fixtureRoot -ChildPath 'root1'), (Join-Path -Path $fixtureRoot -ChildPath 'root2'))
        $stateResult = & (Join-Path $script:ProjectReferenceScriptRoot 'invoke-reference-loader.ps1') -IssuePayloadPath $stateIssuePayloadPath -IndexJsonPath $stateIndexJsonPath -StateFilePath $stateStateFilePath -DeclaredRoots $stateDeclaredRoots | ConvertFrom-Json
        $stateResult.nudge_due | Should -BeFalse
        $stateResult.nudge_dismissed | Should -BeFalse
    }

    It 'preserves generated-index load-priority for critical under-match without trigger-level critical' {
        $repoRoot = Join-Path $TestDrive 'critical-index'
        Copy-Item $PSScriptRoot/fixtures/project-references/critical-no-match $repoRoot -Recurse
        & (Join-Path $script:ProjectReferenceScriptRoot 'generate-references-index.ps1') -Root $repoRoot | Out-Null

        $result = & (Join-Path $script:ProjectReferenceScriptRoot 'invoke-reference-loader.ps1') -IssuePayloadPath (Join-Path $repoRoot 'synthetic-issue.json') -IndexJsonPath (Join-Path $repoRoot '.references/index.json') -StateFilePath (Join-Path $repoRoot 'missing-state.yml') | ConvertFrom-Json

        $emDash = [char]0x2014
        $result.critical_under_match | Should -Contain "[not loaded; triggers did not match $emDash confirm scope does not intersect]"
    }

    It 'loads init-generated optional nested documents after index generation when deterministic fields intersect' {
        $repoRoot = Join-Path $TestDrive 'init-generated-loader'
        $documentsRoot = Join-Path $repoRoot 'Documents/nested'
        New-Item -ItemType Directory -Path $documentsRoot | Out-Null
        Set-Content -Path (Join-Path $documentsRoot 'foo.md') -Value '# Foo Reference'
        Set-Content -Path (Join-Path $documentsRoot 'bar.md') -Value '# Bar Reference'
        & (Join-Path $script:ProjectReferenceScriptRoot 'init-references.ps1') -Root $repoRoot | Out-Null
        & (Join-Path $script:ProjectReferenceScriptRoot 'generate-references-index.ps1') -Root $repoRoot | Out-Null
        Set-Content -Path (Join-Path $repoRoot 'issue.json') -Value '{"title":"Update foo","body":"The issue touches foo behavior.","labels":[],"files":["Documents/nested/foo.md"],"changed_paths":["Documents/nested/foo.md"]}'

        $validation = & (Join-Path $script:ProjectReferenceScriptRoot 'validate-references-index.ps1') -Root $repoRoot | ConvertFrom-Json
        $result = & (Join-Path $script:ProjectReferenceScriptRoot 'invoke-reference-loader.ps1') -IssuePayloadPath (Join-Path $repoRoot 'issue.json') -IndexJsonPath (Join-Path $repoRoot '.references/index.json') -StateFilePath (Join-Path $repoRoot '.copilot-tracking/references-state.yml') | ConvertFrom-Json

        $validation.stale.Count | Should -Be 0
        $result.matched | Should -Contain 'foo'
        $result.matched | Should -Not -Contain 'bar'
        $result.untrusted | Should -BeTrue
        $result.rendered | Should -Match '# Foo Reference'
    }

    It 'respects configured max_critical_loaded and max_total_loaded_bytes caps' {
        $criticalRoot = Join-Path $TestDrive 'critical-cap'
        New-Item -ItemType Directory -Path $criticalRoot | Out-Null
        Set-Content -Path (Join-Path $criticalRoot '.agent-orchestra.yml') -Value @(
            'references:'
            '  max_critical_loaded: 2'
            '  max_total_loaded_bytes: 1000'
        )
        1..3 | ForEach-Object {
            Set-Content -Path (Join-Path $criticalRoot "critical-$_.md") -Value "critical doc $_"
            Set-Content -Path (Join-Path $criticalRoot "critical-$_.md.ref.yml") -Value @(
                'schema_version: 1'
                "name: Critical $_"
                "target_path: critical-$_.md"
                "description: Critical fixture $_"
                'load-when: Load for cap validation'
                'load-priority: critical'
                'generated_by: manual'
                'generated_at: 2026-05-25T00:00:00.0000000Z'
                'triggers:'
                '  - labels: []'
                '    globs: ["*.md"]'
                '    keywords: [cap]'
                '    critical: false'
            )
        }
        Set-Content -Path (Join-Path $criticalRoot 'issue.json') -Value '{"title":"cap","body":"cap","labels":[],"files":["changed.md"],"changed_paths":["changed.md"]}'
        & (Join-Path $script:ProjectReferenceScriptRoot 'generate-references-index.ps1') -Root $criticalRoot | Out-Null
        $criticalResult = & (Join-Path $script:ProjectReferenceScriptRoot 'invoke-reference-loader.ps1') -IssuePayloadPath (Join-Path $criticalRoot 'issue.json') -IndexJsonPath (Join-Path $criticalRoot '.references/index.json') -StateFilePath (Join-Path $criticalRoot 'missing-state.yml') | ConvertFrom-Json
        $criticalResult.matched.Count | Should -Be 2
        @($criticalResult.budget_skipped | Where-Object reason -EQ 'max_critical_loaded').Count | Should -Be 1

        $byteRoot = Join-Path $TestDrive 'byte-cap'
        New-Item -ItemType Directory -Path $byteRoot | Out-Null
        Set-Content -Path (Join-Path $byteRoot '.agent-orchestra.yml') -Value @(
            'references:'
            '  max_critical_loaded: 10'
            '  max_total_loaded_bytes: 20'
        )
        1..2 | ForEach-Object {
            Set-Content -Path (Join-Path $byteRoot "doc-$_.md") -Value '123456789012345'
            Set-Content -Path (Join-Path $byteRoot "doc-$_.md.ref.yml") -Value @(
                'schema_version: 1'
                "name: Byte $_"
                "target_path: doc-$_.md"
                "description: Byte fixture $_"
                'load-when: Load for byte cap validation'
                'load-priority: recommended'
                'generated_by: manual'
                'generated_at: 2026-05-25T00:00:00.0000000Z'
                'triggers:'
                '  - labels: []'
                '    globs: ["*.md"]'
                '    keywords: [bytes]'
                '    critical: false'
            )
        }
        Set-Content -Path (Join-Path $byteRoot 'issue.json') -Value '{"title":"bytes","body":"bytes","labels":[],"files":["changed.md"],"changed_paths":["changed.md"]}'
        & (Join-Path $script:ProjectReferenceScriptRoot 'generate-references-index.ps1') -Root $byteRoot | Out-Null
        $byteResult = & (Join-Path $script:ProjectReferenceScriptRoot 'invoke-reference-loader.ps1') -IssuePayloadPath (Join-Path $byteRoot 'issue.json') -IndexJsonPath (Join-Path $byteRoot '.references/index.json') -StateFilePath (Join-Path $byteRoot 'missing-state.yml') | ConvertFrom-Json
        $byteResult.matched.Count | Should -Be 1
        @($byteResult.budget_skipped | Where-Object reason -EQ 'max_total_loaded_bytes').Count | Should -Be 1
        $byteResult.loaded_bytes | Should -BeLessOrEqual 20
    }

    It 'renders ALL matched critical bodies and preserves fence integrity across bodies (AC2 + MF7)' {
        # Two critical refs both matching the issue — caps set high so neither is budget-skipped.
        $renderAllRoot = Join-Path $TestDrive 'render-all'
        New-Item -ItemType Directory -Path $renderAllRoot | Out-Null
        Set-Content -Path (Join-Path $renderAllRoot '.agent-orchestra.yml') -Value @(
            'references:'
            '  max_critical_loaded: 10'
            '  max_total_loaded_bytes: 102400'
        )
        Set-Content -Path (Join-Path $renderAllRoot 'body-alpha.md') -Value "# Alpha Body`nSENTINEL_ALPHA"
        Set-Content -Path (Join-Path $renderAllRoot 'body-alpha.md.ref.yml') -Value @(
            'schema_version: 1'
            'name: Alpha'
            'target_path: body-alpha.md'
            'description: Alpha fixture'
            'load-when: Load for render-all test'
            'load-priority: critical'
            'generated_by: manual'
            'generated_at: 2026-06-01T00:00:00.0000000Z'
            'triggers:'
            '  - labels: []'
            '    globs: []'
            '    keywords: [renderall]'
            '    critical: false'
        )
        Set-Content -Path (Join-Path $renderAllRoot 'body-beta.md') -Value "# Beta Body`nSENTINEL_BETA"
        Set-Content -Path (Join-Path $renderAllRoot 'body-beta.md.ref.yml') -Value @(
            'schema_version: 1'
            'name: Beta'
            'target_path: body-beta.md'
            'description: Beta fixture'
            'load-when: Load for render-all test'
            'load-priority: critical'
            'generated_by: manual'
            'generated_at: 2026-06-01T00:00:00.0000000Z'
            'triggers:'
            '  - labels: []'
            '    globs: []'
            '    keywords: [renderall]'
            '    critical: false'
        )
        Set-Content -Path (Join-Path $renderAllRoot 'issue.json') -Value '{"title":"renderall","body":"renderall","labels":[],"files":[],"changed_paths":[]}'
        & (Join-Path $script:ProjectReferenceScriptRoot 'generate-references-index.ps1') -Root $renderAllRoot | Out-Null

        $renderAllResult = & (Join-Path $script:ProjectReferenceScriptRoot 'invoke-reference-loader.ps1') -IssuePayloadPath (Join-Path $renderAllRoot 'issue.json') -IndexJsonPath (Join-Path $renderAllRoot '.references/index.json') -StateFilePath (Join-Path $renderAllRoot 'missing-state.yml') | ConvertFrom-Json

        # Both bodies must appear in rendered output
        $renderAllResult.rendered | Should -Match 'SENTINEL_ALPHA'
        $renderAllResult.rendered | Should -Match 'SENTINEL_BETA'
        # Exactly 2 untrusted-content fence-open lines
        $fenceOpenMatches = ([regex]::Matches($renderAllResult.rendered, '`+ untrusted-content')).Count
        $fenceOpenMatches | Should -Be 2
        # untrusted must be true
        $renderAllResult.untrusted | Should -BeTrue
        # Both entries loaded — neither budget-skipped
        $renderAllResult.matched | Should -Contain 'Alpha'
        $renderAllResult.matched | Should -Contain 'Beta'
        $renderAllResult.budget_skipped.Count | Should -Be 0
    }

    It 'uses a uniform global-max fence so a longer backtick run in body B cannot close body A fence (MF7)' {
        # Body A has a 3-backtick run (standard triple fence); body B has a 5-backtick run.
        # Without global-max sizing, body A would get a 4-backtick fence which body B's 5-run
        # would not close — but A's 4-tick fence COULD be closed by content in B that has 4 ticks.
        # The uniform global-max fence (6 ticks here) must wrap BOTH bodies.
        $safetyRoot = Join-Path $TestDrive 'fence-safety'
        New-Item -ItemType Directory -Path $safetyRoot | Out-Null
        Set-Content -Path (Join-Path $safetyRoot '.agent-orchestra.yml') -Value @(
            'references:'
            '  max_critical_loaded: 10'
            '  max_total_loaded_bytes: 102400'
        )
        # Body A: contains a triple-backtick run
        Set-Content -Path (Join-Path $safetyRoot 'doc-a.md') -Value "# Doc A`n``````text`ncode`n```````nSENTINEL_A"
        Set-Content -Path (Join-Path $safetyRoot 'doc-a.md.ref.yml') -Value @(
            'schema_version: 1'
            'name: DocA'
            'target_path: doc-a.md'
            'description: Fence safety fixture A'
            'load-when: Load for fence safety test'
            'load-priority: critical'
            'generated_by: manual'
            'generated_at: 2026-06-01T00:00:00.0000000Z'
            'triggers:'
            '  - labels: []'
            '    globs: []'
            '    keywords: [fencesafety]'
            '    critical: false'
        )
        # Body B: contains a 5-backtick run (longer than A's 3-run)
        Set-Content -Path (Join-Path $safetyRoot 'doc-b.md') -Value "# Doc B`n`````````````text`ncode`n`````````````SENTINEL_B"
        Set-Content -Path (Join-Path $safetyRoot 'doc-b.md.ref.yml') -Value @(
            'schema_version: 1'
            'name: DocB'
            'target_path: doc-b.md'
            'description: Fence safety fixture B'
            'load-when: Load for fence safety test'
            'load-priority: critical'
            'generated_by: manual'
            'generated_at: 2026-06-01T00:00:00.0000000Z'
            'triggers:'
            '  - labels: []'
            '    globs: []'
            '    keywords: [fencesafety]'
            '    critical: false'
        )
        Set-Content -Path (Join-Path $safetyRoot 'issue.json') -Value '{"title":"fencesafety","body":"fencesafety","labels":[],"files":[],"changed_paths":[]}'
        & (Join-Path $script:ProjectReferenceScriptRoot 'generate-references-index.ps1') -Root $safetyRoot | Out-Null

        $safetyResult = & (Join-Path $script:ProjectReferenceScriptRoot 'invoke-reference-loader.ps1') -IssuePayloadPath (Join-Path $safetyRoot 'issue.json') -IndexJsonPath (Join-Path $safetyRoot '.references/index.json') -StateFilePath (Join-Path $safetyRoot 'missing-state.yml') | ConvertFrom-Json

        # Both sentinels present
        $safetyResult.rendered | Should -Match 'SENTINEL_A'
        $safetyResult.rendered | Should -Match 'SENTINEL_B'
        # Exactly 2 untrusted-content fence-open lines (one per body)
        $safetyFenceOpens = ([regex]::Matches($safetyResult.rendered, '`+ untrusted-content')).Count
        $safetyFenceOpens | Should -Be 2
        # The fence delimiter must be at least 6 backticks (5-run in body B + 1)
        $safetyResult.rendered | Should -Match '```````+ untrusted-content'
    }

    It 'does not read out-of-root target paths and reports them stale' {
        $repoRoot = Join-Path $TestDrive 'loader-escape'
        New-Item -ItemType Directory -Path $repoRoot | Out-Null
        $outside = Join-Path $TestDrive 'outside-secret.md'
        Set-Content -Path $outside -Value 'outside secret'
        Set-Content -Path (Join-Path $repoRoot 'escape.md.ref.yml') -Value @(
            'schema_version: 1'
            'name: Escape Target'
            'target_path: ../outside-secret.md'
            'description: Unsafe traversal fixture'
            'load-when: Never read outside root'
            'load-priority: recommended'
            'generated_by: manual'
            'generated_at: 2026-05-25T00:00:00.0000000Z'
            'triggers:'
            '  - labels: []'
            '    globs: []'
            '    keywords: [secret]'
            '    critical: false'
        )
        Set-Content -Path (Join-Path $repoRoot 'issue.json') -Value '{"title":"secret","body":"secret","labels":[],"files":[],"changed_paths":[]}'

        $result = & (Join-Path $script:ProjectReferenceScriptRoot 'invoke-reference-loader.ps1') -IssuePayloadPath (Join-Path $repoRoot 'issue.json') -IndexJsonPath (Join-Path $repoRoot '.references/index.json') -StateFilePath (Join-Path $repoRoot 'missing-state.yml') | ConvertFrom-Json

        $result.stale | Should -Contain "[stale-ref: Escape Target $([char]0x2192) ../outside-secret.md]"
        $result.rendered | Should -BeExactly ''
    }

    It 'sets nudge_due for no-convention repos only when threshold and state gates pass' {
        $aboveRoot = Join-Path $PSScriptRoot 'fixtures/project-references/nudge-no-convention-above-threshold'
        $belowRoot = Join-Path $PSScriptRoot 'fixtures/project-references/nudge-no-convention-below-threshold'
        $missingIssuePath = Join-Path $aboveRoot 'missing-issue.json'
        $missingStatePath = Join-Path $aboveRoot 'missing-state.json'
        $missingIndexPath = Join-Path $aboveRoot '.references/index.json'

        $aboveResult = & (Join-Path $script:ProjectReferenceScriptRoot 'invoke-reference-loader.ps1') -IssuePayloadPath $missingIssuePath -IndexJsonPath $missingIndexPath -StateFilePath $missingStatePath | ConvertFrom-Json
        $aboveResult.nudge_due | Should -BeTrue

        @('state-references-dismissed.json', 'state-legacy-dismissed.json', 'state-setup-complete.json') | ForEach-Object {
            $stateResult = & (Join-Path $script:ProjectReferenceScriptRoot 'invoke-reference-loader.ps1') -IssuePayloadPath $missingIssuePath -IndexJsonPath $missingIndexPath -StateFilePath (Join-Path $aboveRoot $_) | ConvertFrom-Json
            $stateResult.nudge_due | Should -BeFalse
        }

        $belowResult = & (Join-Path $script:ProjectReferenceScriptRoot 'invoke-reference-loader.ps1') -IssuePayloadPath (Join-Path $belowRoot 'missing-issue.json') -IndexJsonPath (Join-Path $belowRoot '.references/index.json') -StateFilePath (Join-Path $belowRoot 'missing-state.json') | ConvertFrom-Json
        $belowResult.nudge_due | Should -BeFalse
    }

    It 'suppresses nudge_due when a reference convention is already present' {
        $sidecarRoot = Join-Path $PSScriptRoot 'fixtures/project-references/nudge-convention-sidecar'
        $indexRoot = Join-Path $PSScriptRoot 'fixtures/project-references/nudge-convention-index'

        $sidecarResult = & (Join-Path $script:ProjectReferenceScriptRoot 'invoke-reference-loader.ps1') -IssuePayloadPath (Join-Path $sidecarRoot 'missing-issue.json') -IndexJsonPath (Join-Path $sidecarRoot '.references/index.json') -StateFilePath (Join-Path $sidecarRoot 'missing-state.json') | ConvertFrom-Json
        $sidecarResult.nudge_due | Should -BeFalse

        $indexResult = & (Join-Path $script:ProjectReferenceScriptRoot 'invoke-reference-loader.ps1') -IssuePayloadPath (Join-Path $indexRoot 'missing-issue.json') -IndexJsonPath (Join-Path $indexRoot '.references/index.json') -StateFilePath (Join-Path $indexRoot 'missing-state.json') | ConvertFrom-Json
        $indexResult.nudge_due | Should -BeFalse
    }

    It 'suppresses nudge_due after init writes setup-complete state even if generated sidecars are later undone' {
        $repoRoot = Join-Path $TestDrive 'setup-state'
        Copy-Item $PSScriptRoot/fixtures/project-references/nudge-no-convention-above-threshold $repoRoot -Recurse
        & (Join-Path $script:ProjectReferenceScriptRoot 'init-references.ps1') -Root $repoRoot | Out-Null
        & (Join-Path $script:ProjectReferenceScriptRoot 'init-references.ps1') -Root $repoRoot --undo | Out-Null

        $statePath = Join-Path $repoRoot '.copilot-tracking/references-state.yml'
        $result = & (Join-Path $script:ProjectReferenceScriptRoot 'invoke-reference-loader.ps1') -IssuePayloadPath (Join-Path $repoRoot 'missing-issue.json') -IndexJsonPath (Join-Path $repoRoot '.references/index.json') -StateFilePath $statePath | ConvertFrom-Json

        (Get-Content $statePath -Raw) | Should -Match 'references_setup_complete: true'
        $result.nudge_due | Should -BeFalse
    }
}
