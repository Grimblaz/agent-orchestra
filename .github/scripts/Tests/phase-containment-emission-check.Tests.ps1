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
# 4b. GH-7 regression (code-review response loop, PR #789): gh view stderr
#    must not be merged into the JSON stdout stream. `gh pr view` / `gh issue
#    view` previously used `2>&1`, which merges PowerShell error-stream
#    records (e.g. a benign gh deprecation/auth notice written via
#    Write-Error) into the array later piped to ConvertFrom-Json, corrupting
#    the parse and silently false-aborting the whole check (caught by the
#    existing try/catch, returns $null, no report emitted). The fix changes
#    both redirects to `2>$null`, matching the convention already used
#    elsewhere in this file (Find-OrUpsertComment) and in
#    phase-containment-rolling-history-core.ps1's REST/GraphQL paths.
# ---------------------------------------------------------------------------

Describe 'Invoke-PhaseContainmentEmissionCheckSingleTarget — GH-7 regression: gh view stderr must not corrupt JSON parse' {
    AfterEach {
        if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
            Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
        }
    }

    It 'parses PR comments successfully even when gh pr view emits benign stderr content alongside valid JSON stdout' {
        $prBody = '<!-- judge-rulings pr=1010 -->'
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $global:LASTEXITCODE = 0
            # Simulate a benign gh deprecation/auth notice on the PowerShell
            # error stream — the exact condition GH-7 identified as breaking
            # `2>&1`-based capture (Write-Error is what genuinely merges into
            # the array under 2>&1, unlike a raw stderr byte write).
            Write-Error 'gh: a benign deprecation notice' -ErrorAction Continue
            return (@{ comments = @(@{ body = $prBody }) } | ConvertTo-Json -Depth 6)
        }
        Mock Find-OrUpsertComment { return 'https://example.invalid/comment' }

        $report = Invoke-PhaseContainmentEmissionCheckSingleTarget -PrNumber '1010'

        # Pre-fix (2>&1), the merged ErrorRecord corrupted the JSON parse,
        # the catch block fired, and $null was returned with no report.
        $report | Should -Not -BeNullOrEmpty
        $report | Should -Match 'code-review #1010:'
    }

    It 'parses issue comments successfully even when gh issue view emits benign stderr content alongside valid JSON stdout' {
        $issueBody = '<!-- design-phase-complete-1011 -->'
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $global:LASTEXITCODE = 0
            Write-Error 'gh: a benign deprecation notice' -ErrorAction Continue
            return (@{ comments = @(@{ body = $issueBody }) } | ConvertTo-Json -Depth 6)
        }
        Mock Find-OrUpsertComment { return 'https://example.invalid/comment' }

        $report = Invoke-PhaseContainmentEmissionCheckSingleTarget -IssueNumber '1011'

        $report | Should -Not -BeNullOrEmpty
        $report | Should -Match 'design-challenge #1011:'
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

    It 'renders COULD NOT VERIFY when the body carries a real marker head with recognizable-but-unparseable vocabulary' {
        # Post-M6-fix: a bare head with NO follow-on vocabulary at all (e.g.
        # a lone '<!-- judge-rulings pr=1 -->' with nothing else) is now
        # correctly treated as a bare mention, not a real marker (M6). This
        # fixture instead anchors a real marker: the head IS followed by a
        # recognizable `judge_ruling:` field token, so Test-EmissionMarkerPresent
        # correctly identifies it as a real judge-rulings surface — but its
        # value ('maybe-sustained-ish') is unrecognized vocabulary, so DD3's
        # fail-loud invariant still applies via Get-SustainedFindingCount.
        $malformedBody = @'
<!-- judge-rulings
- id: Z1
  judge_ruling: maybe-sustained-ish
  judge_confidence: high
-->
'@
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $global:LASTEXITCODE = 0
            return (@{ comments = @(@{ body = $malformedBody }) } | ConvertTo-Json -Depth 6)
        }
        Mock Find-OrUpsertComment { return 'https://example.invalid/comment' }

        $report = Invoke-PhaseContainmentEmissionCheckSingleTarget -PrNumber '1'

        $report | Should -Match 'COULD NOT VERIFY -- treat as gap'
    }

    It 'renders clean (not could-not-verify) for a bare marker-head mention with no follow-on vocabulary (M6)' {
        $bareMentionBody = '<!-- judge-rulings pr=1 -->' # unclosed / no recognizable vocabulary anywhere nearby
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $global:LASTEXITCODE = 0
            return (@{ comments = @(@{ body = $bareMentionBody }) } | ConvertTo-Json -Depth 6)
        }
        Mock Find-OrUpsertComment { return 'https://example.invalid/comment' }

        $report = Invoke-PhaseContainmentEmissionCheckSingleTarget -PrNumber '1'

        $report | Should -Not -Match 'COULD NOT VERIFY'
        $report | Should -Match 'code-review #1: clean -- sustained=0 blocks=0'
    }

    It 'M13 fix: qualifies the sustained/blocks numbers on a COULD NOT VERIFY line so a skimming maintainer is not misled' {
        # ParseStatus could-not-verify means the numbers reflect only the
        # bodies that DID parse — a skimming maintainer reading
        # "sustained=1, blocks=0" could mistake it for a small, trustworthy
        # gap when the real count is unknown. The line must qualify the
        # numbers (e.g. "(partial, do not trust)") rather than presenting
        # them at face value.
        $malformedBody = @'
<!-- judge-rulings
- id: Z1
  judge_ruling: maybe-sustained-ish
  judge_confidence: high
-->
'@
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $global:LASTEXITCODE = 0
            return (@{ comments = @(@{ body = $malformedBody }) } | ConvertTo-Json -Depth 6)
        }
        Mock Find-OrUpsertComment { return 'https://example.invalid/comment' }

        $report = Invoke-PhaseContainmentEmissionCheckSingleTarget -PrNumber '1'

        $report | Should -Match 'COULD NOT VERIFY -- treat as gap \(partial, do not trust: sustained=\d+, blocks=\d+\)'
    }
}

# ---------------------------------------------------------------------------
# 6b. 811-D1 s2: negative-gap-loud + differentiated could-not-verify render
# ---------------------------------------------------------------------------

Describe 'Format-EmissionGapLine — negative-gap-loud (811-D1 s2)' {
    It 'never renders clean when Gap.Gap is negative (more blocks than sustained)' {
        $gap = [PSCustomObject]@{
            SustainedCount = 1
            BlockCount     = 3
            Gap            = -2
            ParseStatus    = 'ok'
            Reason         = 'ok'
        }

        $line = Format-EmissionGapLine -Surface 'code-review' -Id 775 -Gap $gap

        $line | Should -Not -Match 'clean'
        $line | Should -Match 'GAP'
        $line | Should -Match 'sustained=1'
        $line | Should -Match 'blocks=3'
        $line | Should -Match 'excess=2'
    }

    It 'still renders clean when Gap.Gap is exactly zero' {
        $gap = [PSCustomObject]@{
            SustainedCount = 2
            BlockCount     = 2
            Gap            = 0
            ParseStatus    = 'ok'
            Reason         = 'ok'
        }

        $line = Format-EmissionGapLine -Surface 'code-review' -Id 775 -Gap $gap

        $line | Should -Match 'clean -- sustained=2 blocks=2'
    }

    It 'still renders GAP for a positive gap (unchanged behavior)' {
        $gap = [PSCustomObject]@{
            SustainedCount = 3
            BlockCount     = 0
            Gap            = 3
            ParseStatus    = 'ok'
            Reason         = 'ok'
        }

        $line = Format-EmissionGapLine -Surface 'code-review' -Id 778 -Gap $gap

        $line | Should -Match 'GAP -- sustained=3 blocks=0 missing=3'
    }
}

Describe 'Format-EmissionGapLine — differentiated could-not-verify render (811-D1 s2)' {
    It 'renders the head-missing variant when Reason is head-missing' {
        $gap = [PSCustomObject]@{
            SustainedCount = 0
            BlockCount     = 5
            Gap            = -5
            ParseStatus    = 'could-not-verify'
            Reason         = 'head-missing'
        }

        $line = Format-EmissionGapLine -Surface 'plan-stress-test' -Id 811 -Gap $gap

        $line | Should -Match 'COULD NOT VERIFY -- treat as gap'
        # M7 fix (issue #811 post-fix adversarial pass): the render used to
        # repeat 'blocks=' twice ("blocks=5 present ... blocks=5"); the
        # corrected render mentions blocks=N once, alongside sustained=N.
        $line | Should -Match 'machine-head missing, blocks=5 present'
        $line | Should -Match 'sustained=0'
        $line | Should -Not -Match 'blocks=5.*blocks=5'
        $line | Should -Not -Match 'unparseable'
    }

    It 'renders the head-corrupt variant when Reason is head-corrupt' {
        $gap = [PSCustomObject]@{
            SustainedCount = 0
            BlockCount     = 0
            Gap            = 0
            ParseStatus    = 'could-not-verify'
            Reason         = 'head-corrupt'
        }

        $line = Format-EmissionGapLine -Surface 'plan-stress-test' -Id 811 -Gap $gap

        $line | Should -Match 'COULD NOT VERIFY -- treat as gap'
        $line | Should -Match 'machine block present but unparseable'
        $line | Should -Not -Match 'machine-head missing'
    }

    It 'falls back to the generic M13 wording when Reason is absent from the Gap object' {
        $gap = [PSCustomObject]@{
            SustainedCount = 1
            BlockCount     = 0
            Gap            = 1
            ParseStatus    = 'could-not-verify'
        }

        $line = Format-EmissionGapLine -Surface 'code-review' -Id 1 -Gap $gap

        $line | Should -Match 'COULD NOT VERIFY -- treat as gap \(partial, do not trust: sustained=1, blocks=0\)'
    }

    It 'end-to-end: a compliant-but-headless plan-stress-test body renders the head-missing variant via the live orchestrator' {
        $issueBody = @'
<!-- plan-issue-811 -->

**Plan Stress-Test** (5-pass standard adapter)

- Challenge M1 -- Post-judge ruling: sustained -- Maintainer disposition: incorporate.
'@
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $global:LASTEXITCODE = 0
            return (@{ comments = @(@{ body = $issueBody }) } | ConvertTo-Json -Depth 6)
        }
        Mock Find-OrUpsertComment { return 'https://example.invalid/comment' }

        try {
            $report = Invoke-PhaseContainmentEmissionCheckSingleTarget -IssueNumber '811'

            # M7 fix (issue #811 post-fix adversarial pass): corrected render
            # mentions blocks=N once (machine-head missing, blocks=N present),
            # not twice.
            $report | Should -Match 'plan-stress-test #811: COULD NOT VERIFY -- treat as gap \(machine-head missing, blocks=0 present'
        }
        finally {
            if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
                Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
            }
        }
    }

    It 'end-to-end: a plan-stress-test body with a real-but-unparseable judge-rulings head renders the head-corrupt variant via the live orchestrator' {
        $issueBody = @'
<!-- plan-issue-812 -->

**Plan Stress-Test** (5-pass standard adapter)

<!-- judge-rulings
- id: Z1
  judge_ruling: maybe-sustained-ish
-->
'@
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $global:LASTEXITCODE = 0
            return (@{ comments = @(@{ body = $issueBody }) } | ConvertTo-Json -Depth 6)
        }
        Mock Find-OrUpsertComment { return 'https://example.invalid/comment' }

        try {
            $report = Invoke-PhaseContainmentEmissionCheckSingleTarget -IssueNumber '812'

            $report | Should -Match 'plan-stress-test #812: COULD NOT VERIFY -- treat as gap \(machine block present but unparseable'
        }
        finally {
            if (Get-Command 'gh' -CommandType Function -ErrorAction SilentlyContinue) {
                Remove-Item -Path Function:gh -ErrorAction SilentlyContinue
            }
        }
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

    It 'renders open AND closing marker labels (inert, M2 defense-in-depth) with TODO-human placeholders and escape_distance: -1' {
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

        # Fix A (M2 defense-in-depth): the scaffold's open/close tags render
        # via Format-InertMarkerLabel, never as live HTML-comment literals,
        # so a posted report can never be re-parsed as a phantom
        # phase-containment block by a later sweep (same hygiene as M9's
        # trailer mention).
        $report | Should -Not -Match '<!--\s*phase-containment-42\s*-->'
        $report | Should -Not -Match '<!--\s*/phase-containment-42\s*-->'
        $report | Should -Match '`phase-containment-42`'
        $report | Should -Match '`/phase-containment-42`'
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

        # Count only scaffold OPEN labels immediately followed by
        # finding_key: (the trailer mention's inert label at the bottom of
        # the report is a different occurrence of the same marker name, not
        # a scaffold block, and must not be double-counted here).
        $openTagMatches = [regex]::Matches($report, [regex]::Escape('`phase-containment-43`') + '\r?\nfinding_key:')
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

    It 'renders an INCOMPLETE banner but still scans the partial tuples (issue #772 D1) when the corpus is Truncated' {
        # Unlike the timeout/repo-resolution-failed early-return above (which
        # scans nothing), a Truncated corpus still carries partial tuples and
        # must still be scanned -- this is the load-bearing distinction the
        # not-clean branch must preserve.
        $prBody = @'
<!-- judge-rulings pr=775 -->
judge_ruling: sustained
judge_ruling: sustained
-->
'@

        Mock Get-PhaseContainmentCommentCorpus {
            return [PSCustomObject]@{
                Tuples    = @(@{ Number = 775; Surface = 'pr'; Bodies = @($prBody); CreatedAtValues = @('2024-01-01T00:00:00Z') })
                FetchedAt = (Get-Date)
                Source    = 'graphql'
                Truncated = $true
            }
        }

        $report = Invoke-PhaseContainmentEmissionCheckCorpus -WindowDays 30 -RepoOwner 'Grimblaz' -RepoName 'agent-orchestra'

        $report | Should -Match 'INCOMPLETE: corpus fetch truncated'
        # Still scanned, not skipped: the gap line for PR 775 must render.
        $report | Should -Match 'code-review #775: GAP -- sustained=2 blocks=0 missing=2'
        $report | Should -Match 'Surfaces scanned: 1 \| Sustained counted: 2 \| Blocks matched: 0'
    }
}
