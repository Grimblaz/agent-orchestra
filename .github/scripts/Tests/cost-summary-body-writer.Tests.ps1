#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Tests for issue #489 s3 — the shared cost-summary PR-body text transform and
# its effectful writer, added to .github/scripts/lib/cost-fcl-helpers.ps1:
#   (a) script:Set-FCLPrBodyCostSummary    — PURE. Body-text in, body-text out.
#   (b) script:Update-FCLPrBodyCostSummary — PR number + body-text in; performs
#                                             the single `gh pr edit --body-file`
#                                             write. Fail-open.
#
# At RED, cost-fcl-helpers.ps1 does not yet define either function — every
# It-block below fails with CommandNotFoundException until the GREEN
# implementation lands.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:CoreLibPath = Join-Path $script:RepoRoot '.github/scripts/lib/frame-credit-ledger-core.ps1'
    $script:RendererLibPath = Join-Path $script:RepoRoot '.github/scripts/lib/cost-pattern-renderer.ps1'
    $script:HelpersLibPath = Join-Path $script:RepoRoot '.github/scripts/lib/cost-fcl-helpers.ps1'

    . $script:CoreLibPath
    . $script:RendererLibPath
    . $script:HelpersLibPath

    # Helper: build a realistic v4 PR body — the pipeline-metrics block as a
    # TRAILING HTML comment, matching production layout (CE Gate S1 method).
    $script:NewV4Body = {
        param(
            [string]$Yaml,
            [string]$Prefix = "## Summary`n`nA PR body.`n",
            [string]$Suffix = ''
        )
        return "$Prefix`n<!-- pipeline-metrics`n$Yaml`n-->$Suffix"
    }

    $script:BaseYaml = @'
metrics_version: 4
frame_version: 1
credits:
  - port: implement-code
    status: passed
    evidence: "tests GREEN"
'@

    $script:YamlWithDispatchSamples = @'
metrics_version: 4
frame_version: 1
credits:
  - port: implement-code
    status: passed
dispatch-cost-samples:
  - step-id: s1
    mode: spine
    bytes: 100
    rc-conformance: pass
    judge-disposition: accepted
'@

    # A prior cost_summary subtree containing a BLANK LINE and a '#'-comment
    # line inside it (must be treated as continuation, not a terminator),
    # followed by a dispatch-cost-samples section that must survive intact.
    $script:YamlWithStaleSubtreeAndBlank = @'
metrics_version: 4
frame_version: 1
credits:
  - port: implement-code
    status: passed
cost_summary:
  cost_usd_total: 1.0000

  # stale comment continuation
  tokens:
    input: 1
    output: 1
    cache_creation: 0
    cache_read: 0
  session_completeness: partial
  capture_point: pr-creation-mid-session
dispatch-cost-samples:
  - step-id: s1
    mode: spine
    bytes: 50
    rc-conformance: pass
    judge-disposition: accepted
'@

    $script:FencedDecoyBody = @'
## Summary

Example fenced documentation:

```text
<!-- pipeline-metrics
metrics_version: 4
frame_version: 1
credits: []
-->
```

<!-- pipeline-metrics
metrics_version: 4
frame_version: 1
credits:
  - port: implement-code
    status: passed
-->
'@

    $script:BodyWithOrphanBegin = @'
## Summary

<!-- cost-summary:begin -->
**Session cost**: $1.0000 (partial, pr-creation-mid-session) - [full breakdown](https://example.com/old)

<!-- pipeline-metrics
metrics_version: 4
frame_version: 1
credits:
  - port: implement-code
    status: passed
-->
'@

    $script:FencedSentinelDecoyBody = @'
## Summary

Example fenced sentinel usage:

```text
<!-- cost-summary:begin -->
**Session cost**: $1.0000 (partial, capture) - [full breakdown](https://example.com/decoy)
<!-- cost-summary:end -->
```

<!-- pipeline-metrics
metrics_version: 4
frame_version: 1
credits:
  - port: implement-code
    status: passed
-->
'@

    $script:BodyWithOrphanBeginAndUnrelatedProse = @'
## Summary

<!-- cost-summary:begin -->
This is unrelated maintainer prose that happens to follow an orphaned begin marker.

<!-- pipeline-metrics
metrics_version: 4
frame_version: 1
credits:
  - port: implement-code
    status: passed
-->
'@

    $script:BodyWithOrphanBeginAndStaleSessionCostLine = @'
## Summary

<!-- cost-summary:begin -->
**Session cost**: $9.0000 (partial, mid-session) - [full breakdown](https://example.com/stale)

<!-- pipeline-metrics
metrics_version: 4
frame_version: 1
credits:
  - port: implement-code
    status: passed
-->
'@

    $script:BodyWithOrphanEnd = @'
## Summary

Some stray text
<!-- cost-summary:end -->
More text

<!-- pipeline-metrics
metrics_version: 4
frame_version: 1
credits:
  - port: implement-code
    status: passed
-->
'@

    $script:BodyWithDuplicatedPairs = @'
## Summary

<!-- cost-summary:begin -->
**Session cost**: $1.0000 (partial, pr-creation-mid-session) - [full breakdown](https://example.com/old1)
<!-- cost-summary:end -->

<!-- cost-summary:begin -->
**Session cost**: $2.0000 (complete, end-of-session) - [full breakdown](https://example.com/old2)
<!-- cost-summary:end -->

<!-- pipeline-metrics
metrics_version: 4
frame_version: 1
credits:
  - port: implement-code
    status: passed
-->
'@

    # A matched begin/end pair sitting at a distance with FOREIGN maintainer
    # content between them (not this writer's visible-line shape) — the
    # matched-pair branch must not blanket-delete the whole span (G7,
    # PR #870 judge-accepted fix, mirroring the orphan-begin precedent at
    # cost-fcl-helpers.ps1:995-1001).
    $script:BodyWithMatchedPairAndForeignContent = @'
## Summary

<!-- cost-summary:begin -->
This maintainer note landed between the sentinels by coincidence and must not be deleted.
<!-- cost-summary:end -->

<!-- pipeline-metrics
metrics_version: 4
frame_version: 1
credits:
  - port: implement-code
    status: passed
-->
'@

    # A non-fenced decoy `pipeline-metrics-v4` comment precedes the real
    # `pipeline-metrics` block — the marker regex used to lack a boundary
    # after the literal `pipeline-metrics`, so it could mis-anchor on this
    # decoy's `-v4` suffix (G6, PR #870 judge-accepted fix).
    $script:BodyWithNonFencedDecoyMarkerPrefix = @'
## Summary

<!-- pipeline-metrics-v4
some: unrelated
block: true
-->

<!-- pipeline-metrics
metrics_version: 4
frame_version: 1
credits:
  - port: implement-code
    status: passed
-->
'@

    $script:NewCostSummary = @{
        cost_usd_total        = 13.4269
        tokens                = @{ input = 1000; output = 500; cache_creation = 20; cache_read = 300 }
        session_completeness  = 'complete'
        capture_point         = 'end-of-session'
        source_comment        = 'https://github.com/example/example/pull/1#issuecomment-99'
    }
}

Describe 'Set-FCLPrBodyCostSummary — pure transform (issue #489 s3)' {

    It 'inserts the cost_summary YAML section and the visible sentinel-wrapped line when absent (items 1, 2, 3)' {
        $body = & $script:NewV4Body $script:BaseYaml
        $result = script:Set-FCLPrBodyCostSummary -PrBody $body -Degraded $false -CostSummary $script:NewCostSummary

        $result | Should -Match 'cost_usd_total: 13\.4269'
        $result | Should -Match 'tokens:'
        $result | Should -Match 'input: 1000'
        $result | Should -Match 'output: 500'
        $result | Should -Match 'cache_creation: 20'
        $result | Should -Match 'cache_read: 300'
        $result | Should -Match 'session_completeness: complete'
        $result | Should -Match 'capture_point: end-of-session'
        $result | Should -Match '<!-- cost-summary:begin -->'
        $result | Should -Match '<!-- cost-summary:end -->'
        $result | Should -Match '\*\*Session cost\*\*: \$13\.4269 \(complete, end-of-session\) - \[full breakdown\]\(https://github\.com/example/example/pull/1#issuecomment-99\)'
        $result | Should -Not -Match '—' -Because 'the visible line must use a plain ASCII hyphen, never an em-dash — this text round-trips through gh pr view/edit'
    }

    It 'locates the block by stripping fences first, ignoring a fenced decoy pipeline-metrics example above the real block (item 2)' {
        $result = script:Set-FCLPrBodyCostSummary -PrBody $script:FencedDecoyBody -Degraded $false -CostSummary $script:NewCostSummary

        $costSummaryIndex = $result.IndexOf('cost_summary:')
        $costSummaryIndex | Should -BeGreaterThan -1

        $before = $result.Substring(0, $costSummaryIndex)
        $fenceCount = ([regex]::Matches($before, '```')).Count
        ($fenceCount % 2) | Should -Be 0 -Because 'cost_summary must land in the real (non-fenced) block, not the fenced documentation example'

        $result | Should -Match '(?s)```text.*?credits: \[\].*?```' -Because 'the fenced decoy content must remain untouched'
    }

    It 'ignores a <Label>-fenced decoy pipeline-metrics example above the real block (F8)' -TestCases @(
        @{ Label = 'TILDE (~~~)'; FenceChar = [char]0x7E; FenceLength = 3 }
        @{ Label = '4-backtick'; FenceChar = [char]96; FenceLength = 4 }
    ) {
        param([string]$Label, [char]$FenceChar, [int]$FenceLength)

        $fence = [string]::new($FenceChar, $FenceLength)
        $realBlockYaml = "metrics_version: 4`nframe_version: 1`ncredits:`n  - port: implement-code`n    status: passed"
        $body = "## Summary`n`nExample fenced documentation:`n`n$fence`n<!-- pipeline-metrics`nmetrics_version: 4`nframe_version: 1`ncredits: []`n-->`n$fence`n`n<!-- pipeline-metrics`n$realBlockYaml`n-->"

        $result = script:Set-FCLPrBodyCostSummary -PrBody $body -Degraded $false -CostSummary $script:NewCostSummary

        $costSummaryIndex = $result.IndexOf('cost_summary:')
        $costSummaryIndex | Should -BeGreaterThan -1
        $before = $result.Substring(0, $costSummaryIndex)
        $fenceCount = ([regex]::Matches($before, [regex]::Escape($fence))).Count
        ($fenceCount % 2) | Should -Be 0 -Because "cost_summary must land in the real block, past the closed $Label fence — not inside the decoy"
        $result | Should -Match ([regex]::Escape('credits: []')) -Because "the $Label-fenced decoy content must remain untouched"
    }

    It 'positions cost_summary after credits: when no dispatch-cost-samples section exists (item 3)' {
        $body = & $script:NewV4Body $script:BaseYaml
        $result = script:Set-FCLPrBodyCostSummary -PrBody $body -Degraded $false -CostSummary $script:NewCostSummary

        $costSummaryIdx = $result.IndexOf('cost_summary:')
        $lastCreditLineIdx = $result.LastIndexOf('evidence: "tests GREEN"')

        $costSummaryIdx | Should -BeGreaterThan $lastCreditLineIdx
    }

    It 'positions cost_summary after dispatch-cost-samples: when both list sections are present (item 3)' {
        $body = & $script:NewV4Body $script:YamlWithDispatchSamples
        $result = script:Set-FCLPrBodyCostSummary -PrBody $body -Degraded $false -CostSummary $script:NewCostSummary

        $costSummaryIdx = $result.IndexOf('cost_summary:')
        $lastDcsLineIdx = $result.LastIndexOf('judge-disposition: accepted')

        $costSummaryIdx | Should -BeGreaterThan $lastDcsLineIdx
    }

    It 'anchors the visible sentinel span outside the trailing pipeline-metrics HTML comment (item 4)' {
        $body = & $script:NewV4Body $script:BaseYaml
        $result = script:Set-FCLPrBodyCostSummary -PrBody $body -Degraded $false -CostSummary $script:NewCostSummary

        $beginIdx = $result.IndexOf('<!-- cost-summary:begin -->')
        $markerIdx = $result.IndexOf('<!-- pipeline-metrics')

        $beginIdx | Should -BeGreaterThan -1
        $beginIdx | Should -BeLessThan $markerIdx -Because 'the visible line must render before/outside the hidden comment, not be swallowed inside it'

        $blockMatch = [regex]::Match($result, '(?s)<!--\s*pipeline-metrics\s*(?<block>.*?)\s*-->')
        $blockMatch.Groups['block'].Value | Should -Not -Match 'cost-summary:begin' -Because 'the visible span must not land inside the HTML comment — the design explicitly rejected a YAML-only summary'
    }

    It 'replaces the FULL cost_summary subtree on re-run, including a blank-line-containing subtree, without orphaning the following section (item 5)' {
        $body = & $script:NewV4Body $script:YamlWithStaleSubtreeAndBlank
        $result = script:Set-FCLPrBodyCostSummary -PrBody $body -Degraded $false -CostSummary $script:NewCostSummary

        $result | Should -Not -Match 'cost_usd_total: 1\.0000' -Because 'the stale subtree must be fully removed'
        $result | Should -Not -Match 'stale comment continuation'
        $result | Should -Not -Match 'session_completeness: partial'
        $result | Should -Not -Match 'capture_point: pr-creation-mid-session'
        $result | Should -Match 'cost_usd_total: 13\.4269'

        $result | Should -Match 'dispatch-cost-samples:'
        $result | Should -Match 'step-id: s1'
        $result | Should -Match 'judge-disposition: accepted' -Because 'the following section must survive intact — a naive stop-at-first-blank-line removal would orphan it'

        $result.IndexOf('cost_summary:') | Should -BeGreaterThan $result.LastIndexOf('judge-disposition: accepted') -Because 'cost_summary must be re-anchored after dispatch-cost-samples post-removal'
    }

    It 'escapes a source_comment URL containing multiple colons so it round-trips without truncation (item 6)' {
        $body = & $script:NewV4Body $script:BaseYaml
        $summary = $script:NewCostSummary.Clone()
        $summary['source_comment'] = 'https://github.com/example/example/pull/1#issuecomment-99:extra'
        $result = script:Set-FCLPrBodyCostSummary -PrBody $body -Degraded $false -CostSummary $summary

        $blockMatch = [regex]::Match($result, '(?s)<!--\s*pipeline-metrics\s*(?<block>.*?)\s*-->')
        $subtreeMatch = [regex]::Match($blockMatch.Groups['block'].Value, '(?s)cost_summary:.*')
        $roundTripped = script:Get-FCLNestedScalar -Block $subtreeMatch.Value -ParentKey 'cost_summary' -ChildKey 'source_comment'

        $roundTripped | Should -Be 'https://github.com/example/example/pull/1#issuecomment-99:extra' -Because 'Get-FCLScalar''s flat regex truncates at the first colon unless the writer quotes the value'
    }

    It 'escapes an embedded --> so the HTML comment is not terminated early, preserving credits[] for downstream readers (item 6)' {
        $body = & $script:NewV4Body $script:BaseYaml
        $summary = $script:NewCostSummary.Clone()
        $summary['session_completeness'] = 'complete--> <script>alert(1)</script>'
        $result = script:Set-FCLPrBodyCostSummary -PrBody $body -Degraded $false -CostSummary $summary

        $parsed = Read-PRMetricsBlock -PrBody $result
        $parsed.MetricsVersion | Should -Be 4
        @($parsed.Credits).Count | Should -Be 1 -Because 'an unescaped --> would prematurely close the HTML comment and truncate credits for every downstream reader'
    }

    It 'formats cost_usd_total with InvariantCulture even under a comma-decimal thread culture (item 7)' {
        $originalCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
            $body = & $script:NewV4Body $script:BaseYaml
            $result = script:Set-FCLPrBodyCostSummary -PrBody $body -Degraded $false -CostSummary $script:NewCostSummary

            $result | Should -Match 'cost_usd_total: 13\.4269' -Because 'InvariantCulture must be pinned regardless of the thread culture'
            $result | Should -Not -Match 'cost_usd_total: 13,4269'
            $result | Should -Match 'input: 1000'
            $result | Should -Match 'output: 500'
        }
        finally {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture
        }
    }

    It 'preserves the body''s original CRLF line endings end-to-end (item 8)' {
        $lfBody = & $script:NewV4Body $script:BaseYaml
        $crlfBody = $lfBody -replace "`n", "`r`n"

        $result = script:Set-FCLPrBodyCostSummary -PrBody $crlfBody -Degraded $false -CostSummary $script:NewCostSummary

        $result | Should -Match "`r`n" -Because 'CRLF must be preserved, not collapsed to LF'
        $bareLfCount = ([regex]::Matches($result, "(?<!`r)`n")).Count
        $bareLfCount | Should -Be 0 -Because 'every newline in the output must be part of a CRLF pair — a bare LF means the transform partially collapsed CRLF to LF'
    }

    It 'is a fixed point when called twice with identical inputs (item 9 precondition for the writer''s no-op guard)' {
        $body = & $script:NewV4Body $script:BaseYaml
        $once = script:Set-FCLPrBodyCostSummary -PrBody $body -Degraded $false -CostSummary $script:NewCostSummary
        $twice = script:Set-FCLPrBodyCostSummary -PrBody $once -Degraded $false -CostSummary $script:NewCostSummary

        $twice | Should -Be $once
    }

    It 'omits the source_comment YAML field and the visible link when no source comment is supplied' {
        $body = & $script:NewV4Body $script:BaseYaml
        $summary = $script:NewCostSummary.Clone()
        $summary.Remove('source_comment')
        $result = script:Set-FCLPrBodyCostSummary -PrBody $body -Degraded $false -CostSummary $summary

        $result | Should -Not -Match 'source_comment:'
        $visibleLineMatch = [regex]::Match($result, '\*\*Session cost\*\*:[^\r\n]*')
        $visibleLineMatch.Value | Should -Not -Match 'full breakdown'
        $visibleLineMatch.Value | Should -Match '\$13\.4269 \(complete, end-of-session\)'
    }

    It 'renders an explicit-null cost_usd_total as YAML null and "unknown" on the visible line, not a false $0.0000 (Fix 3, C7)' {
        $body = & $script:NewV4Body $script:BaseYaml
        $summary = $script:NewCostSummary.Clone()
        $summary['cost_usd_total'] = $null

        $result = script:Set-FCLPrBodyCostSummary -PrBody $body -Degraded $false -CostSummary $summary

        $result | Should -Match 'cost_usd_total: null' -Because 'a genuinely unknown cost must use the same bare YAML null convention as cost-pattern-renderer.ps1''s Format-CostRendererNullableCostYaml'
        $result | Should -Not -Match 'cost_usd_total: 0\.0000'
        $visibleLineMatch = [regex]::Match($result, '\*\*Session cost\*\*:[^\r\n]*')
        $visibleLineMatch.Value | Should -Match '\*\*Session cost\*\*: unknown' -Because 'an explicitly unknown cost must not render a confident $0.0000 headline'
    }

    It 'omits the parenthetical entirely when session_completeness and capture_point are both empty, instead of rendering (, ) (Fix 3, C7)' {
        $body = & $script:NewV4Body $script:BaseYaml
        $summary = $script:NewCostSummary.Clone()
        $summary['session_completeness'] = ''
        $summary['capture_point'] = ''

        $result = script:Set-FCLPrBodyCostSummary -PrBody $body -Degraded $false -CostSummary $summary

        $visibleLineMatch = [regex]::Match($result, '\*\*Session cost\*\*:[^\r\n]*')
        $visibleLineMatch.Value | Should -Not -Match '\(, \)' -Because 'an empty completeness/capture pair must not render as a bare (, )'
    }

    It 'sanitizes an embedded sentinel-close string out of the visible line so a crafted capture_point cannot forge a premature cost-summary:end (Fix 4, C4)' {
        $body = & $script:NewV4Body $script:BaseYaml
        $summary = $script:NewCostSummary.Clone()
        $summary['capture_point'] = 'end-of-session <!-- cost-summary:end --> injected'

        $result = script:Set-FCLPrBodyCostSummary -PrBody $body -Degraded $false -CostSummary $summary

        $visibleLineMatch = [regex]::Match($result, '\*\*Session cost\*\*:[^\r\n]*')
        $visibleLineMatch.Value | Should -Not -Match '-->' -Because 'an unescaped sentinel-close substring on the visible line would let a crafted value forge a premature cost-summary:end'
        ([regex]::Matches($result, '<!-- cost-summary:end -->')).Count | Should -Be 1 -Because 'exactly one real end sentinel must remain — the injected one must not have become a second real marker'
    }

    It 'strips characters that would break the markdown link shape out of a crafted source_comment link target (Fix 4, C4)' {
        $body = & $script:NewV4Body $script:BaseYaml
        $summary = $script:NewCostSummary.Clone()
        $summary['source_comment'] = 'https://example.com/pr)  <!-- cost-summary:end --> (evil'

        $result = script:Set-FCLPrBodyCostSummary -PrBody $body -Degraded $false -CostSummary $summary

        $visibleLineMatch = [regex]::Match($result, '\*\*Session cost\*\*:[^\r\n]*')
        $visibleLineMatch.Value | Should -Not -Match '-->'
        $linkMatch = [regex]::Match($visibleLineMatch.Value, '\[full breakdown\]\((?<url>[^)]*)\)')
        $linkMatch.Success | Should -Be $true -Because 'the link target must not contain an unescaped ) that would prematurely close the markdown link'
    }

    It 'repairs a begin-without-end sentinel pathology to a single canonical span (item 11)' {
        $result = script:Set-FCLPrBodyCostSummary -PrBody $script:BodyWithOrphanBegin -Degraded $false -CostSummary $script:NewCostSummary

        ([regex]::Matches($result, '<!-- cost-summary:begin -->')).Count | Should -Be 1
        ([regex]::Matches($result, '<!-- cost-summary:end -->')).Count | Should -Be 1
        $result | Should -Match '\$13\.4269'
        $result | Should -Not -Match '\$1\.0000 \(partial'
    }

    It 'repairs an end-before-begin sentinel pathology to a single canonical span (item 11)' {
        $result = script:Set-FCLPrBodyCostSummary -PrBody $script:BodyWithOrphanEnd -Degraded $false -CostSummary $script:NewCostSummary

        ([regex]::Matches($result, '<!-- cost-summary:begin -->')).Count | Should -Be 1
        ([regex]::Matches($result, '<!-- cost-summary:end -->')).Count | Should -Be 1
        $result | Should -Match 'Some stray text' -Because 'only the orphan marker LINE is removed, not surrounding prose'
        $result | Should -Match 'More text'
    }

    It 'does not touch cost-summary sentinel strings inside a fenced code-block example when repairing (Fix 2, C3, item a)' {
        $result = script:Set-FCLPrBodyCostSummary -PrBody $script:FencedSentinelDecoyBody -Degraded $false -CostSummary $script:NewCostSummary

        $result | Should -Match '(?s)```text.*?<!-- cost-summary:begin -->.*?\$1\.0000 \(partial, capture\).*?<!-- cost-summary:end -->.*?```' -Because 'the fenced decoy sentinel pair must remain untouched by the repair'
        ([regex]::Matches($result, '<!-- cost-summary:begin -->')).Count | Should -Be 2 -Because 'one inside the fence (untouched) plus one real fresh span'
        ([regex]::Matches($result, '<!-- cost-summary:end -->')).Count | Should -Be 2
        $result | Should -Match '\$13\.4269' -Because 'a real fresh span must still be inserted with current data'
    }

    It 'preserves unrelated prose following an orphan begin marker that does not match this writer''s visible-line shape (Fix 2, C3, item b)' {
        $result = script:Set-FCLPrBodyCostSummary -PrBody $script:BodyWithOrphanBeginAndUnrelatedProse -Degraded $false -CostSummary $script:NewCostSummary

        $result | Should -Match 'This is unrelated maintainer prose that happens to follow an orphaned begin marker\.' -Because 'unrelated prose is not orphaned span content and must survive'
        ([regex]::Matches($result, '<!-- cost-summary:begin -->')).Count | Should -Be 1
        ([regex]::Matches($result, '<!-- cost-summary:end -->')).Count | Should -Be 1
    }

    It 'removes a genuine stale Session cost line following an orphan begin marker (Fix 2, C3, item c — the legitimate case the repair exists for)' {
        $result = script:Set-FCLPrBodyCostSummary -PrBody $script:BodyWithOrphanBeginAndStaleSessionCostLine -Degraded $false -CostSummary $script:NewCostSummary

        $result | Should -Not -Match '\$9\.0000 \(partial, mid-session\)' -Because 'a stale **Session cost**: line right after an orphan begin is this writer''s own lost span content'
        $result | Should -Match '\$13\.4269'
        ([regex]::Matches($result, '<!-- cost-summary:begin -->')).Count | Should -Be 1
        ([regex]::Matches($result, '<!-- cost-summary:end -->')).Count | Should -Be 1
    }

    It 'collapses duplicated well-formed sentinel pairs to a single canonical span carrying the fresh hidden-YAML-authoritative content (item 11)' {
        $result = script:Set-FCLPrBodyCostSummary -PrBody $script:BodyWithDuplicatedPairs -Degraded $false -CostSummary $script:NewCostSummary

        ([regex]::Matches($result, '<!-- cost-summary:begin -->')).Count | Should -Be 1
        ([regex]::Matches($result, '<!-- cost-summary:end -->')).Count | Should -Be 1
        $result | Should -Not -Match '\$1\.0000'
        $result | Should -Not -Match '\$2\.0000'
        $result | Should -Match '\$13\.4269'
    }

    It 'preserves foreign maintainer content sitting between a matched but non-canonical sentinel pair, removing only the stray markers (G7 foreign-content-survives)' {
        $result = script:Set-FCLPrBodyCostSummary -PrBody $script:BodyWithMatchedPairAndForeignContent -Degraded $false -CostSummary $script:NewCostSummary

        $result | Should -Match 'This maintainer note landed between the sentinels by coincidence and must not be deleted\.' -Because 'a matched begin/end pair with non-writer-shaped content between them is foreign maintainer content, not lost span content'
        ([regex]::Matches($result, '<!-- cost-summary:begin -->')).Count | Should -Be 1
        ([regex]::Matches($result, '<!-- cost-summary:end -->')).Count | Should -Be 1
        $result | Should -Match '\$13\.4269' -Because 'a real fresh span must still be spliced with current data'
    }

    It 'anchors on the real pipeline-metrics block, not a preceding decoy pipeline-metrics-v4 comment (G6 decoy-marker-not-selected)' {
        $result = script:Set-FCLPrBodyCostSummary -PrBody $script:BodyWithNonFencedDecoyMarkerPrefix -Degraded $false -CostSummary $script:NewCostSummary

        $result | Should -Match '<!-- pipeline-metrics-v4' -Because 'the decoy block must remain untouched'
        $result | Should -Match '\$13\.4269' -Because 'the fresh span must be spliced using the real block data'
        $decoyIndex = $result.IndexOf('pipeline-metrics-v4')
        $sentinelIndex = $result.IndexOf('<!-- cost-summary:begin -->')
        $sentinelIndex | Should -BeGreaterThan $decoyIndex -Because 'the writer must anchor on the real pipeline-metrics block, which follows the decoy, not mis-match the decoy itself'
    }

    It 'AC1 forward-compat: adding cost_summary does not change credit parsing for Read-PRMetricsBlock or Test-PipelineMetricsV4Block' {
        $withoutBody = & $script:NewV4Body $script:BaseYaml
        $withBody = script:Set-FCLPrBodyCostSummary -PrBody $withoutBody -Degraded $false -CostSummary $script:NewCostSummary

        $parsedWithout = Read-PRMetricsBlock -PrBody $withoutBody
        $parsedWith = Read-PRMetricsBlock -PrBody $withBody

        ($parsedWithout.Credits | ConvertTo-Json -Depth 10 -Compress) | Should -Be ($parsedWith.Credits | ConvertTo-Json -Depth 10 -Compress) -Because 'adding the additive cost_summary field must not change credit parsing for existing v4 readers'

        (Test-PipelineMetricsV4Block -PRBody $withoutBody).Valid | Should -Be $true
        (Test-PipelineMetricsV4Block -PRBody $withBody).Valid | Should -Be $true
    }

    It 'returns the body unchanged when no non-fenced pipeline-metrics block exists (documented judgment call: fail-open no-op)' {
        $body = "## Summary`n`nJust a regular PR body with no marker.`n"
        $result = script:Set-FCLPrBodyCostSummary -PrBody $body -Degraded $false -CostSummary $script:NewCostSummary
        $result | Should -Be $body
    }
}

Describe 'Set-FCLPrBodyCostSummary — rolling_baseline_usd visible-line clause (issue #489 CE Gate follow-up)' {
    # S4/AC5 CE Gate finding: the visible cost-summary line showed only the
    # current PR's own dollar figure, with no baseline to judge it against.
    # rolling_baseline_usd is an OPTIONAL CostSummary key — a structured
    # @{ median_usd = [double]; sample_size = [int] } value the harvest's two
    # constructors populate from already-fetched rolling history. Absence
    # (the common case: no harvest has run yet, or too little history exists)
    # must render the visible line EXACTLY as it does today — the same
    # graceful-degradation contract as source_comment/capture_point above.

    It 'appends a "vs median, last N PRs" clause to the visible line when rolling_baseline_usd is present and cost is known' {
        $body = & $script:NewV4Body $script:BaseYaml
        $summary = $script:NewCostSummary.Clone()
        $summary['rolling_baseline_usd'] = @{ median_usd = 9.8765; sample_size = 12 }

        $result = script:Set-FCLPrBodyCostSummary -PrBody $body -Degraded $false -CostSummary $summary

        $visibleLineMatch = [regex]::Match($result, '\*\*Session cost\*\*:[^\r\n]*')
        $visibleLineMatch.Value | Should -Match '\$13\.4269 \(complete, end-of-session\) - vs \$9\.8765 median, last 12 PRs' -Because 'the baseline clause must land right after the cost/parenthetical and before the full-breakdown link'
        $visibleLineMatch.Value | Should -Match '\[full breakdown\]' -Because 'the baseline clause must not displace the existing source_comment link'
    }

    It 'omits the baseline clause entirely when rolling_baseline_usd is absent (graceful degradation — no harvest has run yet)' {
        $body = & $script:NewV4Body $script:BaseYaml
        $result = script:Set-FCLPrBodyCostSummary -PrBody $body -Degraded $false -CostSummary $script:NewCostSummary

        $visibleLineMatch = [regex]::Match($result, '\*\*Session cost\*\*:[^\r\n]*')
        $visibleLineMatch.Value | Should -Not -Match 'vs \$' -Because 'no rolling_baseline_usd key means the line must render exactly as it did before this feature'
        $visibleLineMatch.Value | Should -Match '\$13\.4269 \(complete, end-of-session\) - \[full breakdown\]'
    }

    It 'omits the baseline clause when cost_usd_total is unknown, even though a rolling_baseline_usd value is present (never compares a real number against "unknown")' {
        $body = & $script:NewV4Body $script:BaseYaml
        $summary = $script:NewCostSummary.Clone()
        $summary['cost_usd_total'] = $null
        $summary['rolling_baseline_usd'] = @{ median_usd = 9.8765; sample_size = 12 }

        $result = script:Set-FCLPrBodyCostSummary -PrBody $body -Degraded $false -CostSummary $summary

        $visibleLineMatch = [regex]::Match($result, '\*\*Session cost\*\*:[^\r\n]*')
        $visibleLineMatch.Value | Should -Match '\*\*Session cost\*\*: unknown'
        $visibleLineMatch.Value | Should -Not -Match 'vs \$' -Because 'an unknown current cost has nothing meaningful to compare against a baseline'
    }
}

Describe 'Set-FCLPrBodyCostSummary — degraded decision table (issue #489 s3, item 10)' {

    It 'degraded + no prior cost_summary -> writes the honest unavailable line and a capture_point: unavailable YAML section' {
        $body = & $script:NewV4Body $script:BaseYaml
        $result = script:Set-FCLPrBodyCostSummary -PrBody $body -Degraded $true -CostSummary $null

        $result | Should -Match '\*\*Session cost\*\*: unavailable \(attribution degraded\)'
        $result | Should -Match 'cost_summary:'
        $result | Should -Match 'capture_point: unavailable'
        $result | Should -Not -Match 'cost_usd_total:'
    }

    It 'degraded + a prior REAL summary exists -> leaves both surfaces untouched' {
        $body = & $script:NewV4Body $script:BaseYaml
        $seeded = script:Set-FCLPrBodyCostSummary -PrBody $body -Degraded $false -CostSummary $script:NewCostSummary

        $result = script:Set-FCLPrBodyCostSummary -PrBody $seeded -Degraded $true -CostSummary $null

        $result | Should -Be $seeded -Because 'a degraded run must never overwrite good data with a degraded blank'
    }

    It 'degraded + a prior DEGRADED line exists already -> no-op (the previously-unspecified cell the panel caught)' {
        $body = & $script:NewV4Body $script:BaseYaml
        $seededDegraded = script:Set-FCLPrBodyCostSummary -PrBody $body -Degraded $true -CostSummary $null

        $result = script:Set-FCLPrBodyCostSummary -PrBody $seededDegraded -Degraded $true -CostSummary $null

        $result | Should -Be $seededDegraded
    }

    It 'not degraded always writes normally, even over a previously-degraded body' {
        $body = & $script:NewV4Body $script:BaseYaml
        $seededDegraded = script:Set-FCLPrBodyCostSummary -PrBody $body -Degraded $true -CostSummary $null

        $result = script:Set-FCLPrBodyCostSummary -PrBody $seededDegraded -Degraded $false -CostSummary $script:NewCostSummary

        $result | Should -Match 'cost_usd_total: 13\.4269'
        $result | Should -Not -Match 'capture_point: unavailable'
        $result | Should -Match '\*\*Session cost\*\*: \$13\.4269'
        $result | Should -Not -Match 'unavailable \(attribution degraded\)'
    }
}

Describe 'Update-FCLPrBodyCostSummary — writer (issue #489 s3)' {

    BeforeEach {
        $global:GhCalls = @()
        $global:GhBodyFileContent = $null
    }

    AfterEach {
        Remove-Item function:global:gh -ErrorAction SilentlyContinue
    }

    BeforeAll {
        function script:Install-CostSummaryGhMock {
            param([int]$ExitCode = 0)
            $exitCodeCopy = $ExitCode
            Set-Item -Path function:global:gh -Value ([scriptblock]::Create(@"
param([Parameter(ValueFromRemainingArguments = `$true)]`$Args)
`$global:GhCalls += (`$Args -join ' ')
`$idx = [Array]::IndexOf(`$Args, '--body-file')
if (`$idx -ge 0 -and `$idx + 1 -lt `$Args.Count) {
    `$global:GhBodyFileContent = Get-Content -LiteralPath ([string]`$Args[`$idx + 1]) -Raw
}
`$global:LASTEXITCODE = $exitCodeCopy
return ''
"@))
        }
    }

    It 'writes via gh pr edit --body-file with the transformed body when the transform changes something' {
        Install-CostSummaryGhMock
        $body = & $script:NewV4Body $script:BaseYaml

        script:Update-FCLPrBodyCostSummary -Pr 4890001 -PrBody $body -Degraded $false -CostSummary $script:NewCostSummary

        $global:GhCalls.Count | Should -Be 1
        $global:GhCalls[0] | Should -Match 'pr edit 4890001'
        $global:GhBodyFileContent | Should -Match 'cost_usd_total: 13\.4269'
    }

    It 'compares against -OriginalBody instead of -PrBody for the no-op decision, so an already-mutated PrBody does not mask a real change (Fix 1, C1)' {
        Install-CostSummaryGhMock
        $trueOriginal = & $script:NewV4Body $script:BaseYaml -Prefix "## Summary`n`nUpstream mutation not yet applied.`n"
        # $PrBody has ALREADY been through an upstream transform the caller
        # applied before calling this writer (simulated here as a prefix text
        # change), and the cost-summary transform is a fixed point ON THAT
        # already-mutated text (seed it first so Set-FCLPrBodyCostSummary is a
        # no-op when applied to $mutatedPrBody a second time).
        $mutatedPrBody = $trueOriginal -replace 'Upstream mutation not yet applied\.', 'Upstream mutation ALREADY applied.'
        $mutatedPrBody = script:Set-FCLPrBodyCostSummary -PrBody $mutatedPrBody -Degraded $false -CostSummary $script:NewCostSummary

        script:Update-FCLPrBodyCostSummary -Pr 4890008 -PrBody $mutatedPrBody -Degraded $false -CostSummary $script:NewCostSummary -OriginalBody $trueOriginal

        $global:GhCalls.Count | Should -Be 1 -Because 'the final text differs from the TRUE original (still missing the upstream mutation), so the write must fire even though the cost-summary transform was a no-op on the already-mutated PrBody'
        $global:GhBodyFileContent | Should -Match 'Upstream mutation ALREADY applied\.' -Because 'the write must carry the upstream mutation through, not silently drop it'
    }

    It 'falls back to comparing against -PrBody when -OriginalBody is omitted, preserving current no-op behavior exactly (Fix 1 backward compatibility)' {
        Install-CostSummaryGhMock
        $body = & $script:NewV4Body $script:BaseYaml
        $seeded = script:Set-FCLPrBodyCostSummary -PrBody $body -Degraded $false -CostSummary $script:NewCostSummary

        script:Update-FCLPrBodyCostSummary -Pr 4890009 -PrBody $seeded -Degraded $false -CostSummary $script:NewCostSummary

        $global:GhCalls.Count | Should -Be 0 -Because 'no -OriginalBody supplied means the pre-existing PrBody-vs-transform-output comparison must still apply'
    }

    It 'skips the gh pr edit call entirely when the transform is a fixed point (item 9 no-op guard)' {
        Install-CostSummaryGhMock
        $body = & $script:NewV4Body $script:BaseYaml
        $seeded = script:Set-FCLPrBodyCostSummary -PrBody $body -Degraded $false -CostSummary $script:NewCostSummary

        script:Update-FCLPrBodyCostSummary -Pr 4890002 -PrBody $seeded -Degraded $false -CostSummary $script:NewCostSummary

        $global:GhCalls.Count | Should -Be 0
    }

    It 'fails open — warns to stderr and never throws — when gh pr edit fails' {
        Install-CostSummaryGhMock -ExitCode 1
        $body = & $script:NewV4Body $script:BaseYaml

        $stderrWriter = [System.IO.StringWriter]::new()
        $originalError = [Console]::Error
        [Console]::SetError($stderrWriter)
        $threw = $false
        try {
            script:Update-FCLPrBodyCostSummary -Pr 4890003 -PrBody $body -Degraded $false -CostSummary $script:NewCostSummary
        }
        catch { $threw = $true }
        finally { [Console]::SetError($originalError) }

        $threw | Should -Be $false
        $stderrWriter.ToString() | Should -Match '(?i)cost-summary'
    }

    It 'returns an edited-class outcome when the write succeeds (Fix 5, C12+C16)' {
        Install-CostSummaryGhMock
        $body = & $script:NewV4Body $script:BaseYaml

        $outcome = script:Update-FCLPrBodyCostSummary -Pr 4890005 -PrBody $body -Degraded $false -CostSummary $script:NewCostSummary

        $outcome.Outcome | Should -Be 'edited'
    }

    It 'returns a noop-class outcome when the transform is a fixed point (Fix 5)' {
        Install-CostSummaryGhMock
        $body = & $script:NewV4Body $script:BaseYaml
        $seeded = script:Set-FCLPrBodyCostSummary -PrBody $body -Degraded $false -CostSummary $script:NewCostSummary

        $outcome = script:Update-FCLPrBodyCostSummary -Pr 4890006 -PrBody $seeded -Degraded $false -CostSummary $script:NewCostSummary

        $outcome.Outcome | Should -Be 'noop'
    }

    It 'returns a failed-class outcome with a reason when gh pr edit fails (Fix 5)' {
        Install-CostSummaryGhMock -ExitCode 1
        $body = & $script:NewV4Body $script:BaseYaml

        $outcome = script:Update-FCLPrBodyCostSummary -Pr 4890007 -PrBody $body -Degraded $false -CostSummary $script:NewCostSummary

        $outcome.Outcome | Should -Be 'failed'
        $outcome.Reason | Should -Match '(?i)cost-summary'
    }

    It 'fails open when the pure transform itself throws' {
        Install-CostSummaryGhMock
        $body = & $script:NewV4Body $script:BaseYaml

        function script:Escape-FCLScalar { throw 'forced transform failure' }
        $stderrWriter = [System.IO.StringWriter]::new()
        $originalError = [Console]::Error
        [Console]::SetError($stderrWriter)
        $threw = $false
        try {
            script:Update-FCLPrBodyCostSummary -Pr 4890004 -PrBody $body -Degraded $false -CostSummary $script:NewCostSummary
        }
        catch { $threw = $true }
        finally {
            [Console]::SetError($originalError)
            . $script:CoreLibPath
        }

        $threw | Should -Be $false
        $global:GhCalls.Count | Should -Be 0
        $stderrWriter.ToString() | Should -Match '(?i)cost-summary transform failed'
    }
}

Describe 'Update-FCLPrBodyCostSummary — worker-runspace reachability (issue #489 s3, item 12)' {

    It 'produces identical output when invoked inside the pipeline hook''s worker-runspace clone (no new top-level $script: constants leak as $null)' {
        $body = & $script:NewV4Body $script:BaseYaml
        $summary = $script:NewCostSummary

        $iss = script:New-FCLInitialSessionStateClone
        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
        $rs.Open()
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.Runspace = $rs
        try {
            $null = $ps.AddScript({
                    param($BodyArg, $SummaryArg)
                    return script:Set-FCLPrBodyCostSummary -PrBody $BodyArg -Degraded $false -CostSummary $SummaryArg
                }).AddArgument($body).AddArgument($summary)

            $result = $ps.Invoke()
            $errors = @($ps.Streams.Error)

            $errors.Count | Should -Be 0 -Because "worker-runspace call must not throw (errors: $($errors -join '; '))"
            $inProcess = script:Set-FCLPrBodyCostSummary -PrBody $body -Degraded $false -CostSummary $summary
            [string]$result[0] | Should -Be $inProcess
        }
        finally {
            $ps.Dispose()
            $rs.Close()
            $rs.Dispose()
        }
    }
}
