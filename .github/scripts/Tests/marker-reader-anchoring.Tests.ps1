#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Per-family fixture tests for issue #878 s6: per-pattern regex anchoring
    across the marker-reader inventory committed at
    Documents/Design/marker-reader-inventory.md (s1).

.DESCRIPTION
    Each anchored family gets three assertions per the s6 requirement
    contract: (a) a body carrying a backticked/inline marker mention mid-prose
    plus a real block selects the real block (asserted on PARSE RESULT, not
    merely "a match occurred" -- an Index-shift regression can leave matching
    green while region isolation breaks); (b) the count validator reports
    exactly one, not two; (c) a representative HISTORICAL placement, harvested
    from a real posted comment on this repo (not synthesized), still matches
    post-anchoring. The splice-writer family additionally gets (d) a
    byte-identity round-trip fixture proving non-target text in the body is
    unchanged after the write.

    Fixture bodies live under Tests/fixtures/marker-reader-anchoring/ and are
    committed as static files so CI does not depend on a live `gh` fetch.
    The *-historical.txt fixtures are harvested verbatim from real repo
    comments (issue #878's own plan/frame-slices comments, and PR #879's
    body) -- see the harvest provenance comment above each Describe block.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:FixtureRoot = Join-Path $PSScriptRoot 'fixtures/marker-reader-anchoring'

    . (Join-Path $script:RepoRoot '.github/scripts/lib/frame-spine-core.ps1')
    . (Join-Path $script:RepoRoot '.github/scripts/lib/frame-validate-core.ps1')
    . (Join-Path $script:RepoRoot '.github/scripts/lib/phase-containment-emission-check-core.ps1')
    . (Join-Path $script:RepoRoot '.github/scripts/lib/frame-credit-ledger-core.ps1')

    # s6 batch 2 additions — three of these are pure library files (no
    # top-level param block / exit-on-load logic), safe to dot-source
    # directly.
    . (Join-Path $script:RepoRoot '.github/scripts/lib/cost-rolling-history.ps1')
    . (Join-Path $script:RepoRoot '.github/scripts/lib/cost-fcl-helpers.ps1')
    . (Join-Path $script:RepoRoot '.github/scripts/lib/Get-FCLOriginContext.ps1')

    # frame-credit-ledger.ps1 (wrapper) has a top-level param block and runs
    # real logic on load — use the established safe no-op invocation (Pr=0
    # short-circuits before any gh call) already used by
    # frame-credit-ledger-orchestrator.Tests.ps1 to import its functions
    # (Get-FCLFrameSpineComments) without side effects.
    $script:FCLOrchestratorPath = Join-Path $script:RepoRoot '.github/scripts/frame-credit-ledger.ps1'
    . $script:FCLOrchestratorPath -Pr 0 -Mode warn -ErrorAction SilentlyContinue 2>$null

    # gate-reconciliation-core.ps1 also has a top-level param block that runs
    # real reconciliation logic on load — use the same safe no-op invocation
    # established by review-disposition-audit.Tests.ps1's Group 5
    # (IssueNumber=0 makes the main body a no-op; InMemoryMarkers=@() avoids
    # any gh/network call). -EventLogPath is pinned to a guaranteed-absent
    # path so Read-GateTokens' auto-discovery does not scan this real repo
    # checkout's actual memories/session/gate-events-*.jsonl or
    # .copilot-tracking/gate-events.jsonl (real session data, non-deterministic
    # across machines/sessions, and — combined with
    # phase-containment-emission-check-core.ps1's file-scope
    # `Set-StrictMode -Version Latest` leaking across this dot-source chain —
    # one real historical line trips a PropertyNotFoundException on
    # `$_.decision_id` for a non-object JSON line. Pinning the path sidesteps
    # both the non-determinism and the StrictMode interaction).
    $script:GateReconciliationPath = Join-Path $script:RepoRoot '.github/scripts/lib/gate-reconciliation-core.ps1'
    $script:NoGateEventsLogPath = Join-Path $script:FixtureRoot 'no-such-gate-events.jsonl'
    # gate-reconciliation-core.ps1 was never authored to run under inherited
    # StrictMode (it is not itself Set-StrictMode'd) — reset to Off for the
    # duration of this one dot-source so the leaked
    # `Set-StrictMode -Version Latest` from
    # phase-containment-emission-check-core.ps1 does not turn its own
    # ordinary soft property-miss handling (e.g. $Comment.body on shapes it
    # doesn't expect) into terminating errors.
    Set-StrictMode -Off
    . $script:GateReconciliationPath -IssueNumber 0 -Repo 'owner/repo' -GhCliPath 'gh' -InMemoryMarkers @() -EventLogPath $script:NoGateEventsLogPath

    $script:ReadFixture = {
        param([Parameter(Mandatory)][string]$Name)
        $path = Join-Path $script:FixtureRoot $Name
        # Normalize line endings the same way the production readers do
        # (Get-FSCCommentBlockPayloads / Get-FVPlanSliceBlock both normalize
        # CRLF->LF before matching); Get-Content -Raw on Windows can otherwise
        # introduce CRLF that the harvested fixture never had.
        $text = Get-Content -Path $path -Raw
        return ($text -replace "`r`n", "`n" -replace "`r", "`n")
    }
}

# ===========================================================================
# Family: frame-spine (frame-spine-core.ps1:57, Get-FSCCommentBlockPayloads)
# Harvest provenance: issue #878's own plan-issue-878 comment
# (https://github.com/Grimblaz/agent-orchestra/issues/878#issuecomment-5013462111),
# the real <!-- frame-spine ... --> block this very plan carries.
# ===========================================================================
Describe 'frame-spine anchoring (frame-spine-core.ps1:57)' -Tag 'unit' {

    It 'selects the real block, not the inline prose mention (parse-result assertion)' {
        $body = & $script:ReadFixture -Name 'frame-spine-prose-mention-plus-real.txt'
        $payloads = @(Get-FSCCommentBlockPayloads -CommentBody $body -BlockName 'frame-spine')

        $payloads.Count | Should -Be 1
        $payloads[0] | Should -Match 'spine_schema_version: 2'
        $payloads[0] | Should -Match 'slice_comment_id: 5013460780'
        # The prose lead-in must never bleed into the extracted payload.
        $payloads[0] | Should -Not -Match 'Heads up'
    }

    It 'count validator reports exactly one real block' {
        $body = & $script:ReadFixture -Name 'frame-spine-prose-mention-plus-real.txt'
        $payloads = @(Get-FSCCommentBlockPayloads -CommentBody $body -BlockName 'frame-spine')

        $payloads.Count | Should -Be 1
    }

    It 'still matches the real historical placement from issue #878''s own plan comment' {
        $body = & $script:ReadFixture -Name 'frame-spine-878-historical.txt'
        $payloads = @(Get-FSCCommentBlockPayloads -CommentBody $body -BlockName 'frame-spine')

        $payloads.Count | Should -Be 1
        $payloads[0] | Should -Match 'spine_schema_version: 2'
        $payloads[0] | Should -Match 's6:'
        $payloads[0] | Should -Match 'depends_on: \[s1\]'
    }
}

# ===========================================================================
# Family: frame-slice (frame-validate-core.ps1:228, Get-FVPlanSliceBlock) --
# the sibling of frame-spine-core.ps1:57 the plan's own citation missed but
# s1 found (byte-identical top-level-alternation shape, 'frame-slice'
# hard-coded instead of parameterized).
# Harvest provenance: issue #878's frame-slices-878 sibling comment
# (https://github.com/Grimblaz/agent-orchestra/issues/878#issuecomment-5013460780),
# the s1 slice block.
# ===========================================================================
Describe 'frame-slice anchoring (frame-validate-core.ps1:228)' -Tag 'unit' {

    It 'selects the real block, not the inline prose mention (parse-result assertion)' {
        $body = & $script:ReadFixture -Name 'frame-slice-prose-mention-plus-real.txt'
        $blocks = @(Get-FVPlanSliceBlock -CommentBody $body)

        $blocks.Count | Should -Be 1
        $blocks[0] | Should -Match 'step_id: s1'
        $blocks[0] | Should -Match 'migration-scan: true'
        $blocks[0] | Should -Not -Match 'Reminder'
    }

    It 'count validator reports exactly one real block' {
        $body = & $script:ReadFixture -Name 'frame-slice-prose-mention-plus-real.txt'
        $blocks = @(Get-FVPlanSliceBlock -CommentBody $body)

        $blocks.Count | Should -Be 1
    }

    It 'still matches the real historical placement from issue #878''s frame-slices sibling' {
        $body = & $script:ReadFixture -Name 'frame-slice-s1-878-historical.txt'
        $blocks = @(Get-FVPlanSliceBlock -CommentBody $body)

        $blocks.Count | Should -Be 1
        $blocks[0] | Should -Match 'step_id: s1'
        $blocks[0] | Should -Match 'ac-refs: \[AC4\]'
    }
}

# ===========================================================================
# Family: judge-rulings head ($script:JudgeRulingsHeadPattern,
# phase-containment-emission-check-core.ps1:36, consumed via
# Get-RealJudgeRulingsHeadMatches). Audited callers before this change:
# Test-EmissionMarkerPresent (:778), Get-JudgeRulingsDuplicateDiagnosis
# (:478), Get-JudgeRulingsIsolatedRegion's M1 guard (:1974), the cross-body
# sibling check (:2558), and the design-challenge branch's sibling check
# (:2599) -- five callers, not the four the docstring names.
# Harvest provenance: issue #878's own phase-containment-ledger-878 sibling
# comment (https://github.com/Grimblaz/agent-orchestra/issues/878#issuecomment-5013464861),
# the real <!-- judge-rulings ... --> plan-surface block this plan posted.
# ===========================================================================
Describe 'judge-rulings head anchoring (phase-containment-emission-check-core.ps1:36)' -Tag 'unit' {

    It 'excludes a decoy attributed head embedded mid-line in prose (near-decoy window-bleed, parse-result assertion)' {
        # Pre-anchoring this decoy is a genuine window-bleed false positive:
        # the raw candidate "<!-- judge-rulings pr=778 -->" mid-sentence
        # passes the raw head scan, and its 400-char lookahead window bleeds
        # into the real block's own `judge_ruling:` vocabulary below it, so
        # BOTH candidates pass the vocab gate -- Get-RealJudgeRulingsHeadMatches
        # returns 2 "real" heads instead of 1. Anchoring excludes the decoy
        # at the raw-candidate stage (mid-line, not `(?m)^[ \t]*`), so only
        # the true head remains regardless of window content.
        $body = & $script:ReadFixture -Name 'judge-rulings-prose-mention-plus-real.txt'
        $realHeads = Get-RealJudgeRulingsHeadMatches -Body $body

        $realHeads.Count | Should -Be 1
        $body.Substring($realHeads[0].Index, 20) | Should -Match '^\s*<!-- judge-rulings'
    }

    It 'count validator reports exactly one real head' {
        $body = & $script:ReadFixture -Name 'judge-rulings-prose-mention-plus-real.txt'
        $realHeads = Get-RealJudgeRulingsHeadMatches -Body $body

        $realHeads.Count | Should -Be 1
    }

    It 'still matches the real historical placement from issue #878''s own ledger comment' {
        $body = & $script:ReadFixture -Name 'judge-rulings-878-historical.txt'
        $realHeads = Get-RealJudgeRulingsHeadMatches -Body $body

        $realHeads.Count | Should -Be 1
        $realHeads[0].Index | Should -Be 0
    }
}

# ===========================================================================
# Family: pipeline-metrics splice-writer (frame-credit-ledger-core.ps1:709,
# Set-FCLDispatchCostSamplesInPrBody) and its reader sibling (:750,
# Read-PRMetricsBlock). :709's writer contract required whitespace
# preservation: anchoring shifts Match.Index onto any leading same-line
# indentation, so the fix captures that indentation in its own named group
# and re-emits it verbatim in the splice reconstruction, rather than merely
# prefixing the pattern with `^[ \t]*`.
# Harvest provenance: PR #879's own body
# (https://github.com/Grimblaz/agent-orchestra/pull/879), the real v4
# <!-- pipeline-metrics ... --> block that PR carries.
# ===========================================================================
Describe 'pipeline-metrics anchoring (frame-credit-ledger-core.ps1:709, :750)' -Tag 'unit' {

    It 'Read-PRMetricsBlock selects the real block, not the inline prose mention (parse-result assertion)' {
        $body = & $script:ReadFixture -Name 'pipeline-metrics-prose-mention-plus-real.txt'
        $result = Read-PRMetricsBlock -PrBody $body

        $result | Should -Not -BeNullOrEmpty
        $result.MetricsVersion | Should -Be 4
        $result.Credits.Count | Should -Be 2
        $result.Credits[0].port | Should -Be 'experience'
    }

    It 'count validator (non-fenced marker scan) reports exactly one real block' {
        # M17 fix (issue #878 judge-sustained review): this assertion used to
        # re-derive its own hand-copied regex literal instead of calling the
        # real production count validator (Test-PipelineMetricsV4Block) --
        # so a production-side edit to that function's own anchoring could
        # drift out of sync with this literal and this test would stay green
        # regardless. Test-PipelineMetricsV4Block is already dot-sourced in
        # this file's BeforeAll (frame-credit-ledger-core.ps1) and is
        # exercised against this exact fixture by the sibling 'pipeline-
        # metrics count-validator anchoring' Describe block below -- assert
        # against its real DetectedMarkerCount output here too, rather than a
        # copied pattern.
        $body = & $script:ReadFixture -Name 'pipeline-metrics-prose-mention-plus-real.txt'
        $result = Test-PipelineMetricsV4Block -PRBody $body

        $result.DetectedMarkerCount | Should -Be 1
    }

    It 'still matches the real historical placement from PR #879''s own body' {
        $body = & $script:ReadFixture -Name 'pipeline-metrics-879-historical.txt'
        $result = Read-PRMetricsBlock -PrBody $body

        $result | Should -Not -BeNullOrEmpty
        $result.MetricsVersion | Should -Be 4
        $result.Credits.Count | Should -Be 4
        $result.Credits[3].port | Should -Be 'orchestration'
    }

    It 'splice-writer preserves non-target prefix/suffix text byte-identically after the write (round-trip)' {
        $body = & $script:ReadFixture -Name 'pipeline-metrics-prose-mention-plus-real.txt'
        $updated = script:Set-FCLDispatchCostSamplesInPrBody -PrBody $body -Samples @()

        # Non-target text before and after the marker block must survive
        # the splice byte-identically.
        $updated | Should -Match ([regex]::Escape('## Summary'))
        $updated | Should -Match ([regex]::Escape('Trailer text after the block, untouched by any splice.'))
        $updated.Substring(0, $body.IndexOf('<!-- pipeline-metrics')) |
            Should -Be $body.Substring(0, $body.IndexOf('<!-- pipeline-metrics'))
    }

    It 'splice-writer re-emits leading same-line indentation instead of consuming it (synthetic edge case)' {
        # Synthetic, not harvested: real posted markers are always flush-left
        # in practice, but Set-FCLDispatchCostSamplesInPrBody's whitespace
        # capture-and-replay must be correct even if a marker is ever
        # preceded by leading whitespace on its own line (e.g. inside a
        # blockquote), since `(?m)^[ \t]*` willingly matches that whitespace
        # into the match -- the fix must re-emit it, not drop it.
        $indentedBody = "prefix text`n`n  <!-- pipeline-metrics`nmetrics_version: 4`npr_number: 1`n-->`n`nsuffix text"
        $updated = script:Set-FCLDispatchCostSamplesInPrBody -PrBody $indentedBody -Samples @()

        $updated | Should -Match "`n  <!-- pipeline-metrics"
        $updated | Should -Match ([regex]::Escape('prefix text'))
        $updated | Should -Match ([regex]::Escape('suffix text'))
    }
}

# ===========================================================================
# issue #878 s6 batch 2 -- remaining plan-cited sites (5013462111 step 6).
# ===========================================================================

# ===========================================================================
# Family: pipeline-metrics count-validator (frame-credit-ledger-core.ps1,
# Test-PipelineMetricsV4Block's Check 2b non-fenced marker scan). Standardized
# on the same lookahead-guarded + line-start-anchored shape as :709/:750
# above, per the inventory's "Observation for s6."
# ===========================================================================
Describe 'pipeline-metrics count-validator anchoring (Test-PipelineMetricsV4Block)' -Tag 'unit' {

    It 'reports exactly one marker against the real historical PR #879 body (parse-result assertion)' {
        $body = & $script:ReadFixture -Name 'pipeline-metrics-879-historical.txt'
        $result = Test-PipelineMetricsV4Block -PRBody $body

        $result.DetectedMarkerCount | Should -Be 1
    }

    It 'does not inflate the count when a decoy prose mention precedes the real block' {
        $body = & $script:ReadFixture -Name 'pipeline-metrics-prose-mention-plus-real.txt'
        $result = Test-PipelineMetricsV4Block -PRBody $body

        $result.DetectedMarkerCount | Should -Be 1
    }
}

# ===========================================================================
# Family: design-phase-complete (gate-reconciliation-core.ps1:158,
# Read-FindingDispositionIds). INVESTIGATED, not excluded -- see the
# code-comment at the anchoring site itself for the full false->loud polarity
# trace (opposite of :800's false->quiet/false-clean danger).
# Harvest provenance: issue #878's own design-phase-complete-878 comment
# (https://github.com/Grimblaz/agent-orchestra/issues/878#issuecomment-5013031816).
# ===========================================================================
Describe 'design-phase-complete anchoring (gate-reconciliation-core.ps1:158)' -Tag 'unit' {

    It 'recovers finding_dispositions from a decoy-prefixed real historical placement (parse-result assertion)' {
        $body = & $script:ReadFixture -Name 'design-phase-complete-prose-mention-plus-real.txt'
        $result = Read-FindingDispositionIds -Issue 878 -Repo 'owner/repo' -Gh 'gh' -InMem @($body)

        $result | Should -Contain 'M1'
    }

    It 'a decoy-only body (no real marker) contributes nothing' {
        # Isolate the decoy paragraph only (everything before the real marker
        # line) to prove the presence-gate itself rejects the mid-line mention.
        $full = & $script:ReadFixture -Name 'design-phase-complete-prose-mention-plus-real.txt'
        $decoyOnly = $full.Substring(0, $full.LastIndexOf('<!-- design-phase-complete-878 -->'))

        $result = Read-FindingDispositionIds -Issue 878 -Repo 'owner/repo' -Gh 'gh' -InMem @($decoyOnly)

        $result.Count | Should -Be 0
    }

    It 'still matches the real historical placement from issue #878''s own design-phase-complete comment' {
        $body = & $script:ReadFixture -Name 'design-phase-complete-878-historical.txt'
        $result = Read-FindingDispositionIds -Issue 878 -Repo 'owner/repo' -Gh 'gh' -InMem @($body)

        $result | Should -Contain 'M1'
        $result | Should -Contain 'M2'
        $result | Should -Contain 'M3'
    }
}

# ===========================================================================
# Family: judge-rulings PR-surface reader (frame-credit-ledger-core.ps1,
# ConvertFrom-JudgeRulingsComment) -- distinct from the plan-surface
# judge-rulings head above (phase-containment-emission-check-core.ps1:36):
# this reader parses the `- id:`/`points_awarded` shape, is a bare
# first-match [regex]::Match with no vocab gate (a documented gap this step
# does not close, only anchors).
# Harvest provenance: PR #879's own judge-rulings comment
# (https://github.com/Grimblaz/agent-orchestra/issues/879#issuecomment-5009836856).
# ===========================================================================
Describe 'judge-rulings PR-surface anchoring (frame-credit-ledger-core.ps1, ConvertFrom-JudgeRulingsComment)' -Tag 'unit' {

    It 'parses the real block, not the inline prose mention (parse-result assertion)' {
        $body = & $script:ReadFixture -Name 'judge-rulings-pr-surface-prose-mention-plus-real.txt'
        $rows = @(ConvertFrom-JudgeRulingsComment -CommentBody $body)

        $rows.Count | Should -Be 2
        $rows[0].id | Should -Be 'G1'
        $rows[0].points_awarded | Should -Be 'P+1'
    }

    It 'still parses the real historical placement from PR #879''s own judge-rulings comment' {
        $body = & $script:ReadFixture -Name 'judge-rulings-pr-surface-879-historical.txt'
        $rows = @(ConvertFrom-JudgeRulingsComment -CommentBody $body)

        $rows.Count | Should -Be 7
        $rows[0].id | Should -Be 'G1'
        $rows[0].points_awarded | Should -Be 'D+1'
    }
}

# ===========================================================================
# Family: frame-spine comment-selector (frame-credit-ledger.ps1:513,
# Get-FCLFrameSpineComments) -- a comment-selector sibling of
# frame-spine-core.ps1:57's block-extractor above; same family, different
# mechanism (-match filter over a comment list, not capture-group extraction).
# Reuses the frame-spine family's existing fixtures (same real placement).
# ===========================================================================
Describe 'frame-spine comment-selector anchoring (frame-credit-ledger.ps1:513)' -Tag 'unit' {

    It 'selects only the comment carrying the real block, not a decoy-only comment' {
        $decoyComment = [pscustomobject]@{ body = 'Heads up -- frame-spine convention changed, see the note.' }
        $realBody = & $script:ReadFixture -Name 'frame-spine-878-historical.txt'
        $realComment = [pscustomobject]@{ body = $realBody }

        $selected = @(script:Get-FCLFrameSpineComments -Comments @($decoyComment, $realComment))

        $selected.Count | Should -Be 1
        $selected[0].body | Should -Be $realBody
    }
}

# ===========================================================================
# Family: judge-rulings selector (frame-credit-ledger.ps1:1208) and the
# design-phase-complete / plan-issue OR-combined presence-gates in
# phase-containment-rolling-history-core.ps1 (:711-712, :781-782, :1053,
# :1123, :1387-1388, :1475). All six rolling-history sites, and the :1208
# selector, are embedded deep inside gh-dependent surface-scanning functions
# (GraphQL primary path + REST fallback, each with a capped hunt loop) --
# too heavy to exercise end-to-end here without a live/mocked `gh`. Per the
# same convention batch 1 used for its count-validator sub-test, these
# assertions target the anchored pattern text directly (copied verbatim from
# the production site) against the shared harvested fixtures, proving the
# anchor still recognizes the real historical placement and still rejects a
# decoy mid-line mention.
# ===========================================================================
Describe 'judge-rulings / design-phase-complete / plan-issue inline presence-gate anchoring (frame-credit-ledger.ps1:1208; phase-containment-rolling-history-core.ps1:711-712,781-782,1053,1123,1387-1388,1475)' -Tag 'unit' {

    It 'the anchored judge-rulings presence-gate matches the real historical PR #879 placement' {
        $body = & $script:ReadFixture -Name 'judge-rulings-878-historical.txt'
        ($body -match '(?m)^\s*<!--\s*judge-rulings') | Should -BeTrue
    }

    It 'the anchored judge-rulings presence-gate rejects a decoy-only mid-line mention' {
        $full = & $script:ReadFixture -Name 'judge-rulings-prose-mention-plus-real.txt'
        $decoyOnly = $full.Substring(0, $full.LastIndexOf('<!-- judge-rulings'))
        ($decoyOnly -match '(?m)^\s*<!--\s*judge-rulings') | Should -BeFalse
    }

    It 'the anchored design-phase-complete-{N}/plan-issue-{N} OR-gate matches the real historical placements' {
        $designBody = & $script:ReadFixture -Name 'design-phase-complete-878-historical.txt'
        $planBody = & $script:ReadFixture -Name 'plan-issue-878-historical.txt'

        (($designBody -match '(?m)^\s*<!--\s*design-phase-complete-878\s*-->') -or
         ($designBody -match '(?m)^\s*<!--\s*plan-issue-878\s*-->')) | Should -BeTrue

        (($planBody -match '(?m)^\s*<!--\s*design-phase-complete-878\s*-->') -or
         ($planBody -match '(?m)^\s*<!--\s*plan-issue-878\s*-->')) | Should -BeTrue
    }

    It 'the anchored design-phase-complete-{N}/plan-issue-{N} OR-gate rejects decoy-only mid-line mentions' {
        $full = & $script:ReadFixture -Name 'plan-issue-prose-mention-plus-real.txt'
        $decoyOnly = $full.Substring(0, $full.LastIndexOf('<!-- plan-issue-878 -->'))

        (($decoyOnly -match '(?m)^\s*<!--\s*design-phase-complete-878\s*-->') -or
         ($decoyOnly -match '(?m)^\s*<!--\s*plan-issue-878\s*-->')) | Should -BeFalse
    }
}

# ===========================================================================
# Family: cost-pattern-data (cost-rolling-history.ps1:33,36,726,785;
# cost-session-render.ps1:391,519). :33/:36 are exercised via the real
# production function (Get-CostPatternDataFromComment); :726/:785/:391/:519
# are embedded inside heavy gh-dependent walker functions, so those four are
# asserted against the anchored pattern text directly, mirroring the
# rolling-history-family sub-tests above.
# Harvest provenance: PR #879's own cost-pattern-data comment
# (https://github.com/Grimblaz/agent-orchestra/issues/879#issuecomment-5009741930).
# ===========================================================================
Describe 'cost-pattern-data anchoring (cost-rolling-history.ps1:33,36,726,785; cost-session-render.ps1:391,519)' -Tag 'unit' {

    It 'Get-CostPatternDataFromComment extracts the real block, not the inline prose mention (parse-result assertion)' {
        $body = & $script:ReadFixture -Name 'cost-pattern-data-prose-mention-plus-real.txt'
        $yaml = script:Get-CostPatternDataFromComment -Body $body

        $yaml | Should -Not -BeNullOrEmpty
        $yaml | Should -Match 'session_completeness: complete'
        $yaml | Should -Not -Match 'Heads up'
    }

    It 'Get-CostPatternDataFromComment still matches the real historical placement from PR #879''s own comment' {
        $body = & $script:ReadFixture -Name 'cost-pattern-data-878-historical.txt'
        $yaml = script:Get-CostPatternDataFromComment -Body $body

        $yaml | Should -Not -BeNullOrEmpty
        $yaml | Should -Match 'pr: 879'
        $yaml | Should -Match 'session_completeness: partial'
    }

    It 'the anchored comment-selector pattern (:726/:785/:391) matches the real historical placement and rejects a decoy-only mention' {
        $real = & $script:ReadFixture -Name 'cost-pattern-data-878-historical.txt'
        ($real -match '(?m)^\s*<!--\s*cost-pattern-data') | Should -BeTrue

        $full = & $script:ReadFixture -Name 'cost-pattern-data-prose-mention-plus-real.txt'
        $decoyOnly = $full.Substring(0, $full.LastIndexOf('<!-- cost-pattern-data'))
        ($decoyOnly -match '(?m)^\s*<!--\s*cost-pattern-data') | Should -BeFalse
    }

    It 'the anchored splice-adjacent raw-block pattern (:519) captures the full real block via .Value' {
        $body = & $script:ReadFixture -Name 'cost-pattern-data-878-historical.txt'
        $rawMatch = [regex]::Match($body, '(?m)^[ \t]*<!--\s*cost-pattern-data[\s\S]*?-->')

        $rawMatch.Success | Should -BeTrue
        $rawMatch.Value | Should -Match 'pr: 879'
        $rawMatch.Value.TrimEnd() | Should -Match '-->$' # closing tag present in the captured .Value
    }
}

# ===========================================================================
# Family: plan-issue / design-issue combined alternation (Get-FCLOriginContext.ps1:101,
# cost-fcl-helpers.ps1:95, Resolve-FCLLinkedIssueNumber / Get-FCLOriginContext's PR-body
# fallback). Rule 1 (alternation): the `(?:plan|design)-issue-` alternation sits INSIDE
# the marker word, after the `^\s*<!--\s*` anchor prefix, so both branches share one
# anchor -- no separate per-branch grouping is needed the way frame-spine's top-level
# alternation required.
# Harvest provenance: no real PR body carrying this literal marker was found in this
# repo (PR bodies link issues via branch name / issue_id field in practice; the
# marker fallback is a last-resort path). The historical-placement fixture instead
# reuses issue #878's own real, byte-identical `<!-- plan-issue-878 -->` line
# (https://github.com/Grimblaz/agent-orchestra/issues/878#issuecomment-5013462111) --
# honest substitute: the marker family's real line-start placement convention is
# identical regardless of which surface (issue comment vs. PR body) it is posted on.
# ===========================================================================
Describe 'plan-issue/design-issue combined anchoring (Get-FCLOriginContext.ps1:101, cost-fcl-helpers.ps1:95)' -Tag 'unit' {

    It 'Get-FCLOriginContext resolves the real marker, not the inline prose mention (parse-result assertion)' {
        $body = & $script:ReadFixture -Name 'plan-design-issue-prose-mention-plus-real.txt'
        $result = Get-FCLOriginContext -PrBody $body -HeadRef ''

        $result.IsOrchestratedOrigin | Should -BeTrue
        $result.LinkedIssueNumber | Should -Be 878
        $result.DetectionMethod | Should -Be 'body'
    }

    It 'Get-FCLOriginContext still resolves the real historical plan-issue-878 placement' {
        $body = & $script:ReadFixture -Name 'plan-issue-878-historical.txt'
        $result = Get-FCLOriginContext -PrBody $body -HeadRef ''

        $result.IsOrchestratedOrigin | Should -BeTrue
        $result.LinkedIssueNumber | Should -Be 878
    }

    It 'Resolve-FCLLinkedIssueNumber (cost-fcl-helpers.ps1) resolves the same real historical placement' {
        $body = & $script:ReadFixture -Name 'plan-issue-878-historical.txt'
        $result = script:Resolve-FCLLinkedIssueNumber -PrBody $body -Branch ''

        $result | Should -Be 878
    }
}
