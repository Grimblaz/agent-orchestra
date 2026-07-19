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
        $body = & $script:ReadFixture -Name 'pipeline-metrics-prose-mention-plus-real.txt'
        # Mirrors the shape of frame-credit-ledger-core.ps1's own post-write
        # non-fenced-marker count validator (Test-PipelineMetricsV4Block):
        # strip fenced code spans first, since the anchored pattern alone
        # cannot distinguish a real head from a decoy that happens to also
        # start a line -- inline-code-span stripping is explicitly a
        # non-goal of this step (RC), so this assertion targets the
        # anchored, non-fenced pattern directly against a decoy that is
        # NOT inside a fenced code span (only backtick-wrapped inline).
        $anchored = '(?m)^[ \t]*<!--\s*pipeline-metrics(?![\w-])'
        $matchCount = ([regex]::Matches($body, $anchored)).Count

        $matchCount | Should -Be 1
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
