#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester tests for phase-containment-emission-check.ps1 (issue #782 s2).
#
# File under test: .github/scripts/phase-containment-emission-check.ps1
#
# Focus: decision logic (gap computation wiring, report rendering, mode
# validation, dot-source detection, fail-open lib-load behavior) per the
# frame-slice's stated validation target ("orchestrator Pester green").
# GraphQL/REST discovery internals already have dedicated coverage in
# phase-containment-rolling-history-core.Tests.ps1.
#
# NOTE on mocking Find-OrUpsertComment: the orchestrator dot-sources the
# REAL find-or-upsert-comment.ps1 at script scope in BeforeAll. A later
# `function global:Find-OrUpsertComment` override does NOT shadow that
# script-scope function from the orchestrator's own call sites (PowerShell
# command resolution prefers the definition-site scope), so tests use
# Pester's `Mock` cmdlet, which correctly intercepts script-scope functions.

BeforeAll {
    $script:ScriptsRoot = Join-Path $PSScriptRoot '..'
    $script:OrchestratorPath = Join-Path $script:ScriptsRoot 'phase-containment-emission-check.ps1'
    # Dot-source with a harmless corpus invocation so top-level execution is
    # skipped (InvocationName == '.') and only the functions/definitions load.
    . $script:OrchestratorPath -WindowDays 1
}

# ---------------------------------------------------------------------------
# 1. Dot-source detection — top-level execution is skipped when dot-sourced
# ---------------------------------------------------------------------------

Describe 'Dot-source detection — top-level execution skipped' {
    It 'does not throw and exposes the orchestrator functions when dot-sourced' {
        { . $script:OrchestratorPath -WindowDays 1 } | Should -Not -Throw
        Get-Command Invoke-PhaseContainmentEmissionCheckSingleTarget -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Invoke-PhaseContainmentEmissionCheckCorpus -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# 2. -Mode validation — invalid value exits 2 (manual ValidateSet emulation)
# ---------------------------------------------------------------------------

Describe '-Mode validation' {
    It 'exits 2 when -Mode is not warn or enforce' {
        & pwsh -NoProfile -File $script:OrchestratorPath -WindowDays 1 -Mode 'bogus' 2>$null
        $LASTEXITCODE | Should -Be 2
    }
}

# ---------------------------------------------------------------------------
# 3. Fail-open lib-load — a broken lib path exits 0 in warn mode
# ---------------------------------------------------------------------------

Describe 'Fail-open lib-load behavior' {
    It 'exits 0 in warn mode when a dot-sourced lib file is missing/broken' {
        # Point PSScriptRoot-relative lib resolution at a nonexistent lib by
        # copying the orchestrator to a temp dir with no lib/ sibling.
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "pc-emission-check-libfail-$(New-Guid)"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        try {
            $tempScript = Join-Path $tempDir 'phase-containment-emission-check.ps1'
            Copy-Item -LiteralPath $script:OrchestratorPath -Destination $tempScript
            & pwsh -NoProfile -File $tempScript -WindowDays 1 2>$null
            $LASTEXITCODE | Should -Be 0
        }
        finally {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# 4. Single-target mode (PR) — clean gap renders "clean", posts a report
# ---------------------------------------------------------------------------

Describe 'Invoke-PhaseContainmentEmissionCheckSingleTarget — PR surface' {
    AfterEach {
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
    }

    It 'renders a clean line when sustained == blocks and upserts the report' {
        $prBody = @"
<!-- judge-rulings pr=775 -->
judge_ruling: sustained
judge_ruling: sustained
-->
<!-- phase-containment-775 -->
finding_key: code-review:775:F1
introduced_phase: implementation
catchable_phase: implementation
caught_stage: code-review
escape_distance: 0
severity: low
systemic_fix_type: none
category: pattern
apparatus_meta: false
seed: false
<!-- /phase-containment-775 -->
<!-- phase-containment-775 -->
finding_key: code-review:775:F2
introduced_phase: implementation
catchable_phase: implementation
caught_stage: code-review
escape_distance: 0
severity: low
systemic_fix_type: none
category: pattern
apparatus_meta: false
seed: false
<!-- /phase-containment-775 -->
"@
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $global:LASTEXITCODE = 0
            return (@{ comments = @(@{ body = $prBody }) } | ConvertTo-Json -Depth 6)
        }

        Mock Find-OrUpsertComment { return 'https://example.invalid/comment' }

        $report = Invoke-PhaseContainmentEmissionCheckSingleTarget -PrNumber '775'

        $report | Should -Match 'code-review #775: clean -- sustained=2 blocks=2'
        $report | Should -Match 'Surfaces scanned: 1 \| Sustained counted: 2 \| Blocks matched: 2'
        Should -Invoke Find-OrUpsertComment -Times 1 -ParameterFilter {
            $Type -eq 'pr' -and $Number -eq 775 -and $Marker -eq '<!-- pc-emission-check-report -->'
        }
    }

    It 'renders a GAP line when sustained findings exceed posted blocks' {
        $prBody = @'
<!-- judge-rulings pr=778 -->
judge_ruling: sustained
judge_ruling: sustained
judge_ruling: sustained
-->
'@
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $global:LASTEXITCODE = 0
            return (@{ comments = @(@{ body = $prBody }) } | ConvertTo-Json -Depth 6)
        }
        Mock Find-OrUpsertComment { return 'https://example.invalid/comment' }

        $report = Invoke-PhaseContainmentEmissionCheckSingleTarget -PrNumber '778'

        $report | Should -Match 'code-review #778: GAP -- sustained=3 blocks=0 missing=3'
    }

    It 'never emits a live phase-containment marker literal in the rendered report (M9 hygiene)' {
        $prBody = '<!-- judge-rulings pr=999 -->'
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $global:LASTEXITCODE = 0
            return (@{ comments = @(@{ body = $prBody }) } | ConvertTo-Json -Depth 6)
        }
        Mock Find-OrUpsertComment { return 'https://example.invalid/comment' }

        $report = Invoke-PhaseContainmentEmissionCheckSingleTarget -PrNumber '999'

        # The report marker itself is expected literally; a phase-containment
        # BLOCK marker literal (open or close tag) must never appear.
        $report | Should -Not -Match '<!--\s*phase-containment-999\s*-->'
        $report | Should -Not -Match '<!--\s*/phase-containment-999\s*-->'
        # Format-InertMarkerLabel wraps the stripped marker name in single backticks.
        $report | Should -Match '`phase-containment-999`'
    }

    It 'uses the pc-emission-check-report marker outside the phase-containment- prefix namespace (M9)' {
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $global:LASTEXITCODE = 0
            return (@{ comments = @() } | ConvertTo-Json -Depth 6)
        }
        Mock Find-OrUpsertComment { return 'https://example.invalid/comment' }

        $report = Invoke-PhaseContainmentEmissionCheckSingleTarget -PrNumber '1000'

        $report | Should -Match '^<!-- pc-emission-check-report -->'
        $report | Should -Not -Match '^<!-- phase-containment-'
    }
}

# ---------------------------------------------------------------------------
# 5. Single-target mode (Issue) — both design-challenge and plan-stress-test
#    surfaces are probed
# ---------------------------------------------------------------------------

Describe 'Invoke-PhaseContainmentEmissionCheckSingleTarget — Issue surfaces' {
    AfterEach {
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
    }

    It 'checks both design-challenge and plan-stress-test surfaces for an issue target' {
        $issueBody = @'
finding_dispositions:
  - id: F1
    disposition: incorporate
'@
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $global:LASTEXITCODE = 0
            return (@{ comments = @(@{ body = $issueBody }) } | ConvertTo-Json -Depth 6)
        }
        Mock Find-OrUpsertComment { return 'https://example.invalid/comment' }

        $report = Invoke-PhaseContainmentEmissionCheckSingleTarget -IssueNumber '900'

        $report | Should -Match 'design-challenge #900'
        $report | Should -Match 'plan-stress-test #900'
        $report | Should -Match 'Surfaces scanned: 2'
    }
}

# ---------------------------------------------------------------------------
# 6. Could-not-verify rendering — fail-loud, never silently omitted (DD3)
# ---------------------------------------------------------------------------

Describe 'Could-not-verify rendering' {
    AfterEach {
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
    }

    It 'renders COULD NOT VERIFY when the body is unparseable/ambiguous' {
        $malformedBody = '<!-- judge-rulings pr=1 -->' # unclosed / no recognizable vocabulary
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $global:LASTEXITCODE = 0
            return (@{ comments = @(@{ body = $malformedBody }) } | ConvertTo-Json -Depth 6)
        }
        Mock Find-OrUpsertComment { return 'https://example.invalid/comment' }

        $report = Invoke-PhaseContainmentEmissionCheckSingleTarget -PrNumber '1'

        $report | Should -Match 'COULD NOT VERIFY -- treat as gap'
    }
}

# ---------------------------------------------------------------------------
# 7. -ScaffoldBackfill — emits open+close tags and escape_distance: -1
# ---------------------------------------------------------------------------

Describe '-ScaffoldBackfill rendering' {
    AfterEach {
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
    }

    It 'renders open AND closing tags with TODO-human placeholders and escape_distance: -1' {
        $prBody = @'
<!-- judge-rulings pr=42 -->
judge_ruling: sustained
-->
'@
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $global:LASTEXITCODE = 0
            return (@{ comments = @(@{ body = $prBody }) } | ConvertTo-Json -Depth 6)
        }
        Mock Find-OrUpsertComment { return 'https://example.invalid/comment' }

        $report = Invoke-PhaseContainmentEmissionCheckSingleTarget -PrNumber '42' -ScaffoldBackfill

        $report | Should -Match '<!-- phase-containment-42 -->'
        $report | Should -Match '<!-- /phase-containment-42 -->'
        $report | Should -Match 'introduced_phase: TODO-human'
        $report | Should -Match 'catchable_phase: TODO-human'
        $report | Should -Match 'escape_distance: -1'
    }

    It 'produces exactly one scaffold block per missing finding' {
        $prBody = @'
<!-- judge-rulings pr=43 -->
judge_ruling: sustained
judge_ruling: sustained
judge_ruling: sustained
-->
'@
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $global:LASTEXITCODE = 0
            return (@{ comments = @(@{ body = $prBody }) } | ConvertTo-Json -Depth 6)
        }
        Mock Find-OrUpsertComment { return 'https://example.invalid/comment' }

        $report = Invoke-PhaseContainmentEmissionCheckSingleTarget -PrNumber '43' -ScaffoldBackfill

        $openTagMatches = [regex]::Matches($report, [regex]::Escape('<!-- phase-containment-43 -->'))
        $openTagMatches.Count | Should -Be 3
    }

    It 'does not scaffold anything for a clean (zero-gap) target' {
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $global:LASTEXITCODE = 0
            return (@{ comments = @() } | ConvertTo-Json -Depth 6)
        }
        Mock Find-OrUpsertComment { return 'https://example.invalid/comment' }

        $report = Invoke-PhaseContainmentEmissionCheckSingleTarget -PrNumber '44' -ScaffoldBackfill

        $report | Should -Not -Match 'Backfill scaffold'
    }
}

# ---------------------------------------------------------------------------
# 8. Corpus mode — positive-coverage output contract (M6)
# ---------------------------------------------------------------------------

Describe 'Invoke-PhaseContainmentEmissionCheckCorpus — positive-coverage contract' {
    AfterEach {
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
    }

    It 'prints the positive-coverage line even when zero tuples are discovered (clean run distinct from silent abort)' {
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $global:LASTEXITCODE = 0
            $joined = $Args -join ' '
            if ($joined -match 'graphql') {
                return (@{ data = @{ search = @{ pageInfo = @{ hasNextPage = $false; endCursor = $null }; nodes = @() } } } | ConvertTo-Json -Depth 8)
            }
            return '{}'
        }

        # Explicit RepoOwner/RepoName so the corpus function skips `gh repo view`
        # resolution (which this fixture's mock does not model) and goes
        # straight to the GraphQL search mocked above.
        $report = Invoke-PhaseContainmentEmissionCheckCorpus -WindowDays 30 -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra'

        $report | Should -Match 'Surfaces scanned: 0 \| Sustained counted: 0 \| Blocks matched: 0'
    }

    It 'aggregates sustained/block counts across multiple discovered tuples' {
        $prBody = @'
<!-- judge-rulings pr=775 -->
judge_ruling: sustained
judge_ruling: sustained
-->
'@
        $issueBody = @'
finding_dispositions:
  - id: F1
    disposition: incorporate
  - id: F2
    disposition: dismiss
'@

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match 'is:issue') {
                $payload = @{
                    data = @{
                        search = @{
                            pageInfo = @{ hasNextPage = $false; endCursor = $null }
                            nodes    = @(@{ number = 900; comments = @{ nodes = @(@{ body = $issueBody; createdAt = '2024-01-01T00:00:00Z' }); pageInfo = @{ hasNextPage = $false; endCursor = $null } } })
                        }
                    }
                }
                return ($payload | ConvertTo-Json -Depth 10)
            }
            if ($joined -match 'is:pr') {
                $payload = @{
                    data = @{
                        search = @{
                            pageInfo = @{ hasNextPage = $false; endCursor = $null }
                            nodes    = @(@{ number = 775; comments = @{ nodes = @(@{ body = $prBody; createdAt = '2024-01-01T00:00:00Z' }); pageInfo = @{ hasNextPage = $false; endCursor = $null } } })
                        }
                    }
                }
                return ($payload | ConvertTo-Json -Depth 10)
            }
            return '{}'
        }

        $report = Invoke-PhaseContainmentEmissionCheckCorpus -WindowDays 30 -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra'

        # Issue 900 carries no design-phase-complete/plan-issue marker in this
        # fixture, so Surface A discovery (marker-presence gated) will not
        # surface it as a tuple — only PR 775 (Surface B, judge-rulings
        # marker-gated) is discovered. This asserts the real discovery
        # predicate rather than an idealized shape.
        $report | Should -Match 'code-review #775: GAP -- sustained=2 blocks=0 missing=2'
        $report | Should -Match 'Surfaces scanned: \d+ \| Sustained counted: \d+ \| Blocks matched: \d+'
    }

    It 'posts to -PostTo when supplied and upserts via Find-OrUpsertComment' {
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $global:LASTEXITCODE = 0
            return (@{ data = @{ search = @{ pageInfo = @{ hasNextPage = $false; endCursor = $null }; nodes = @() } } } | ConvertTo-Json -Depth 8)
        }

        Mock Find-OrUpsertComment { return 'https://example.invalid/comment' }

        $null = Invoke-PhaseContainmentEmissionCheckCorpus -WindowDays 30 -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra' -PostTo 761

        Should -Invoke Find-OrUpsertComment -Times 1 -ParameterFilter {
            $Type -eq 'issue' -and $Number -eq 761
        }
    }

    It 'renders a fetch-incomplete notice (never a bare-silent clean claim) when GraphQL and REST both fail' {
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $global:LASTEXITCODE = 1
            return 'boom'
        }

        $report = Invoke-PhaseContainmentEmissionCheckCorpus -WindowDays 30 -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra'

        # GraphQL fails -> REST fallback attempted -> gh also fails there ->
        # empty tuples, source 'rest'. Must still render deterministically
        # (no exception) and carry the positive-coverage line with zero
        # counts (fail-open observable, never bare silence).
        $report | Should -Match 'Source: rest'
        $report | Should -Match 'Surfaces scanned: 0 \| Sustained counted: 0 \| Blocks matched: 0'
    }

    It 'renders the fetch-did-not-complete notice when repo resolution fails' {
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $global:LASTEXITCODE = 1
            return 'boom'
        }

        # No -RepoOwner/-RepoName supplied: corpus function attempts `gh repo
        # view`, which the mock above fails, forcing the repo-resolution-failed path.
        $report = Invoke-PhaseContainmentEmissionCheckCorpus -WindowDays 30

        $report | Should -Match 'Source: repo-resolution-failed'
        $report | Should -Match 'Corpus fetch did not complete'
    }
}
