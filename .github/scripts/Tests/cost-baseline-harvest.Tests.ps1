#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Pester tests for Invoke-CostBaselineHarvest (issue #824, Step 4 part B).
#
# File under test: .github/scripts/lib/cost-baseline-harvest.ps1
#
# This harvest is deliberately tested at the function-boundary level: its real
# dependencies (Get-CostRollingHistory, Test-CostWalkerSessionTranscriptExists,
# Invoke-CostSessionRender, Find-OrUpsertComment, gh) are overridden with
# per-test mocks so each scenario (selection, verify-then-select, the live
# merge-commit check, the token no-downgrade guard, the section-splice, and
# the one-candidate-per-call budget cap) can be exercised in isolation without
# real network/filesystem access. One end-to-end test builds a realistic
# composite comment via the real renderer to prove the splice invariant.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:LibPath = Join-Path $script:RepoRoot '.github/scripts/lib/cost-baseline-harvest.ps1'
    $script:RendererLibPath = Join-Path $script:RepoRoot '.github/scripts/lib/cost-pattern-renderer.ps1'

    if (Test-Path $script:LibPath) {
        . $script:LibPath
    }
    if (Test-Path $script:RendererLibPath) {
        . $script:RendererLibPath
    }

    function global:New-HarvestCandidateEntry {
        param(
            [string]$CapturePoint = 'pr-creation-mid-session',
            [string]$SessionId = 'session-abc-123',
            [string]$HeadRef = 'feature/some-branch',
            [int]$Pr = 900,
            [Nullable[datetime]]$GeneratedAt = $null,
            [hashtable]$Ports = @{ 'implement-code' = @{ tokens = @{ input = 100; output = 50; cache_creation = 0; cache_read = 0 } } },
            [string]$UpgradeAttemptedAt = $null
        )
        $ts = if ($null -ne $GeneratedAt) { $GeneratedAt } else { (Get-Date).ToUniversalTime().AddDays(-1) }
        $entry = @{
            capture_point = $CapturePoint
            session_id    = $SessionId
            head_ref      = $HeadRef
            pr            = $Pr
            generated_at  = $ts.ToString('o')
            ports         = $Ports
        }
        if (-not [string]::IsNullOrWhiteSpace($UpgradeAttemptedAt)) {
            $entry['upgrade_attempted_at'] = $UpgradeAttemptedAt
        }
        return $entry
    }

    function global:New-HarvestCompositeCommentBody {
        param(
            [Parameter(Mandatory)][int]$Pr,
            [string]$PortReportsMarker = '### Port Reports (non-cost content)',
            [string]$CostSection = "## Cost Pattern`n<!-- cost-pattern-data`ncapture_point: pr-creation-mid-session`nports:`n  - name: implement-code`n-->"
        )
        return @"
<!-- frame-credit-ledger-$Pr -->
$PortReportsMarker
- implement-code: passed

$CostSection

_end of comment_
"@
    }
}

Describe 'Invoke-CostBaselineHarvest' {

    Context 'selection filter' {
        It 'filters out entries whose capture_point is not pr-creation-mid-session' {
            function global:Get-CostRollingHistory {
                return @{
                    timed_out = $false
                    entries   = @(New-HarvestCandidateEntry -CapturePoint 'end-of-session')
                }
            }
            $script:TranscriptCheckCallCount = 0
            function global:Test-CostWalkerSessionTranscriptExists { $script:TranscriptCheckCallCount++; return $true }
            function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }

            $result = Invoke-CostBaselineHarvest -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

            $result.Attempted | Should -Be $false
            $script:TranscriptCheckCallCount | Should -Be 0
        }

        It 'filters out entries outside the ~14-day horizon' {
            function global:Get-CostRollingHistory {
                return @{
                    timed_out = $false
                    entries   = @(New-HarvestCandidateEntry -GeneratedAt ((Get-Date).ToUniversalTime().AddDays(-20)))
                }
            }
            $script:TranscriptCheckCallCount = 0
            function global:Test-CostWalkerSessionTranscriptExists { $script:TranscriptCheckCallCount++; return $true }
            function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }

            $result = Invoke-CostBaselineHarvest -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

            $result.Attempted | Should -Be $false
            $script:TranscriptCheckCallCount | Should -Be 0
        }

        It 'admits an entry within the horizon' {
            function global:Get-CostRollingHistory {
                return @{
                    timed_out = $false
                    entries   = @(New-HarvestCandidateEntry -GeneratedAt ((Get-Date).ToUniversalTime().AddDays(-5)))
                }
            }
            $script:TranscriptCheckCallCount = 0
            function global:Test-CostWalkerSessionTranscriptExists { $script:TranscriptCheckCallCount++; return $false }
            function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }

            $null = Invoke-CostBaselineHarvest -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

            $script:TranscriptCheckCallCount | Should -Be 1
        }

        It 'skips (deprioritizes) an entry that already carries a non-empty upgrade_attempted_at stamp' {
            function global:Get-CostRollingHistory {
                return @{
                    timed_out = $false
                    entries   = @(New-HarvestCandidateEntry -UpgradeAttemptedAt '2026-07-01T00:00:00Z')
                }
            }
            $script:TranscriptCheckCallCount = 0
            function global:Test-CostWalkerSessionTranscriptExists { $script:TranscriptCheckCallCount++; return $true }
            function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }

            $result = Invoke-CostBaselineHarvest -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

            $result.Attempted | Should -Be $false
            $script:TranscriptCheckCallCount | Should -Be 0
        }

        It 'no-ops silently when Get-CostRollingHistory reports timed_out' {
            function global:Get-CostRollingHistory {
                return @{ timed_out = $true; entries = @() }
            }
            function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }

            $result = Invoke-CostBaselineHarvest -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

            $result.Attempted | Should -Be $false
            $result.Signal | Should -BeNullOrEmpty
        }
    }

    Context 'verify-then-select gate' {
        It 'proceeds to the live merge-commit check only when a local transcript exists' {
            function global:Get-CostRollingHistory {
                return @{ timed_out = $false; entries = @(New-HarvestCandidateEntry -Pr 901) }
            }
            function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }
            function global:Test-CostWalkerSessionTranscriptExists { return $false }
            $script:GhCallCount = 0
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)]$Args)
                $script:GhCallCount++
                $global:LASTEXITCODE = 0
                return ''
            }

            $result = Invoke-CostBaselineHarvest -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

            $result.Attempted | Should -Be $false
            $script:GhCallCount | Should -Be 0
        }

        It 'does not select a candidate whose transcript is missing, even when a later candidate is usable' {
            $entries = @(
                (New-HarvestCandidateEntry -Pr 902 -SessionId 'missing-session'),
                (New-HarvestCandidateEntry -Pr 903 -SessionId 'present-session')
            )
            function global:Get-CostRollingHistory {
                return @{ timed_out = $false; entries = $entries }
            }
            function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }
            function global:Test-CostWalkerSessionTranscriptExists {
                param($SessionId, $Branch, $ParentCwd, $RepoRoot, $ProjectsRoot)
                return $SessionId -eq 'present-session'
            }
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)]$Args)
                $joined = $Args -join ' '
                $global:LASTEXITCODE = 0
                if ($joined -match 'pr view 903 --json state') {
                    return '{"state":"MERGED","mergedAt":"2026-06-01T00:00:00Z","mergeCommit":{"oid":"abc"},"headRefName":"feature/present"}'
                }
                return ''
            }
            function global:Invoke-CostSessionRender {
                param($Pr, $Branch, $Slug, $ParentCwd, $RepoRoot)
                return @{ CostSection = ''; Completeness = @{ capture_point = 'n/a' }; TokenSum = 0 }
            }

            $result = Invoke-CostBaselineHarvest -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

            $result.Attempted | Should -Be $true
            $result.Pr | Should -Be 903
        }
    }

    Context 'merge-commit live-check gate' {
        It 'skips a candidate whose live gh pr view does not confirm MERGED' {
            function global:Get-CostRollingHistory {
                return @{ timed_out = $false; entries = @(New-HarvestCandidateEntry -Pr 904) }
            }
            function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }
            function global:Test-CostWalkerSessionTranscriptExists { return $true }
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)]$Args)
                $global:LASTEXITCODE = 0
                return '{"state":"OPEN","mergedAt":null,"mergeCommit":null,"headRefName":"feature/still-open"}'
            }
            $script:RenderCallCount = 0
            function global:Invoke-CostSessionRender { $script:RenderCallCount++; return @{ CostSection = ''; Completeness = @{}; TokenSum = 0 } }

            $result = Invoke-CostBaselineHarvest -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

            $result.Attempted | Should -Be $false
            $script:RenderCallCount | Should -Be 0
        }

        It 'skips a candidate when the gh pr view call itself fails' {
            function global:Get-CostRollingHistory {
                return @{ timed_out = $false; entries = @(New-HarvestCandidateEntry -Pr 905) }
            }
            function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }
            function global:Test-CostWalkerSessionTranscriptExists { return $true }
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)]$Args)
                $global:LASTEXITCODE = 1
                return ''
            }

            $result = Invoke-CostBaselineHarvest -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

            $result.Attempted | Should -Be $false
        }

        It 'uses the LIVE headRefName (not the persisted head_ref) as the re-walk Branch' {
            function global:Get-CostRollingHistory {
                return @{ timed_out = $false; entries = @(New-HarvestCandidateEntry -Pr 906 -HeadRef 'stale/persisted-ref') }
            }
            function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }
            function global:Test-CostWalkerSessionTranscriptExists { return $true }
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)]$Args)
                $global:LASTEXITCODE = 0
                return '{"state":"MERGED","mergedAt":"2026-06-01T00:00:00Z","mergeCommit":{"oid":"abc"},"headRefName":"live/actual-ref"}'
            }
            $script:CapturedBranch = $null
            function global:Invoke-CostSessionRender {
                param($Pr, $Branch, $Slug, $ParentCwd, $RepoRoot)
                $script:CapturedBranch = $Branch
                return @{ CostSection = ''; Completeness = @{}; TokenSum = 0 }
            }

            $null = Invoke-CostBaselineHarvest -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

            $script:CapturedBranch | Should -Be 'live/actual-ref'
        }
    }

    Context 'token no-downgrade guard' {
        BeforeEach {
            function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }
            function global:Test-CostWalkerSessionTranscriptExists { return $true }
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)]$Args)
                $joined = $Args -join ' '
                $global:LASTEXITCODE = 0
                if ($joined -match 'pr view \d+ --json state') {
                    return '{"state":"MERGED","mergedAt":"2026-06-01T00:00:00Z","mergeCommit":{"oid":"abc"},"headRefName":"feature/token-guard"}'
                }
                if ($joined -match 'pr view \d+ --json comments') {
                    $body = New-HarvestCompositeCommentBody -Pr 910
                    return (@{ comments = @(@{ body = $body }) } | ConvertTo-Json -Depth 6 -Compress)
                }
                return ''
            }
            function global:Find-OrUpsertComment {
                param($Type, $Number, $Marker, $Body)
                $script:UpsertedBody = $Body
                return $null
            }
        }

        It 'promotes when the re-walk TokenSum is >= the persisted TokenSum' {
            $persistedPorts = @{ 'implement-code' = @{ tokens = @{ input = 100; output = 50; cache_creation = 0; cache_read = 0 } } }
            function global:Get-CostRollingHistory {
                return @{ timed_out = $false; entries = @(New-HarvestCandidateEntry -Pr 910 -Ports $persistedPorts) }
            }
            function global:Invoke-CostSessionRender {
                param($Pr, $Branch, $Slug, $ParentCwd, $RepoRoot)
                return @{
                    CostSection  = "## Cost Pattern`n<!-- cost-pattern-data`ncapture_point: end-of-session`nports:`n  - name: implement-code`n-->"
                    Completeness = @{ completeness = 'complete'; capture_point = 'end-of-session' }
                    TokenSum     = 200
                }
            }

            $result = Invoke-CostBaselineHarvest -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

            $result.Promoted | Should -Be $true
            $result.Signal | Should -Be 'upgraded #910 to end-of-session'
        }

        It 'does not promote when the re-walk TokenSum is lower than the persisted TokenSum' {
            $persistedPorts = @{ 'implement-code' = @{ tokens = @{ input = 1000; output = 500; cache_creation = 0; cache_read = 0 } } }
            function global:Get-CostRollingHistory {
                return @{ timed_out = $false; entries = @(New-HarvestCandidateEntry -Pr 910 -Ports $persistedPorts) }
            }
            function global:Invoke-CostSessionRender {
                param($Pr, $Branch, $Slug, $ParentCwd, $RepoRoot)
                return @{
                    CostSection  = "## Cost Pattern`n<!-- cost-pattern-data`ncapture_point: end-of-session`nports:`n  - name: implement-code`n-->"
                    Completeness = @{ completeness = 'complete'; capture_point = 'end-of-session' }
                    TokenSum     = 50
                }
            }

            $result = Invoke-CostBaselineHarvest -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

            $result.Promoted | Should -Be $false
            $result.Signal | Should -Be 'upgrade expected for #910 — token count lower than persisted'
        }

        It 'does not promote a re-walk that is still partial (regardless of token sum)' {
            $persistedPorts = @{ 'implement-code' = @{ tokens = @{ input = 100; output = 50; cache_creation = 0; cache_read = 0 } } }
            function global:Get-CostRollingHistory {
                return @{ timed_out = $false; entries = @(New-HarvestCandidateEntry -Pr 910 -Ports $persistedPorts) }
            }
            function global:Invoke-CostSessionRender {
                param($Pr, $Branch, $Slug, $ParentCwd, $RepoRoot)
                return @{
                    CostSection  = "## Cost Pattern`n<!-- cost-pattern-data`ncapture_point: pr-creation-mid-session`nports:`n  - name: implement-code`n-->"
                    Completeness = @{ completeness = 'partial'; capture_point = 'pr-creation-mid-session' }
                    TokenSum     = 500
                }
            }

            $result = Invoke-CostBaselineHarvest -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

            $result.Promoted | Should -Be $false
            $result.Signal | Should -Be 'upgrade expected for #910 — still partial'
        }
    }

    Context 'section-splice' {
        It 'preserves non-cost content in the composite comment and leaves exactly one cost-pattern-data block after promotion' {
            $pr = 920
            $originalBody = New-HarvestCompositeCommentBody -Pr $pr -PortReportsMarker '### Port Reports (must survive)'

            function global:Get-CostRollingHistory {
                return @{ timed_out = $false; entries = @(New-HarvestCandidateEntry -Pr $pr) }
            }
            function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }
            function global:Test-CostWalkerSessionTranscriptExists { return $true }
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)]$Args)
                $joined = $Args -join ' '
                $global:LASTEXITCODE = 0
                if ($joined -match "pr view $pr --json state") {
                    return '{"state":"MERGED","mergedAt":"2026-06-01T00:00:00Z","mergeCommit":{"oid":"abc"},"headRefName":"feature/splice"}'
                }
                if ($joined -match "pr view $pr --json comments") {
                    return (@{ comments = @(@{ body = $originalBody }) } | ConvertTo-Json -Depth 6 -Compress)
                }
                return ''
            }
            function global:Invoke-CostSessionRender {
                param($Pr, $Branch, $Slug, $ParentCwd, $RepoRoot)
                return @{
                    CostSection  = "## Cost Pattern`n<!-- cost-pattern-data`ncapture_point: end-of-session`nports:`n  - name: implement-code`n-->"
                    Completeness = @{ completeness = 'complete'; capture_point = 'end-of-session' }
                    TokenSum     = 999
                }
            }
            $script:UpsertedBody = $null
            function global:Find-OrUpsertComment {
                param($Type, $Number, $Marker, $Body)
                $script:UpsertedBody = $Body
                return $null
            }

            $result = Invoke-CostBaselineHarvest -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

            $result.Promoted | Should -Be $true
            $script:UpsertedBody | Should -Not -BeNullOrEmpty
            $script:UpsertedBody | Should -Match '### Port Reports \(must survive\)'
            $script:UpsertedBody | Should -Match '_end of comment_'
            (@([regex]::Matches($script:UpsertedBody, '<!--\s*cost-pattern-data')).Count) | Should -Be 1
            $script:UpsertedBody | Should -Match 'capture_point: end-of-session'
        }

        It 'stamps upgrade_attempted_at on a non-promoted row while preserving non-cost content and single block count' {
            $pr = 921
            $originalBody = New-HarvestCompositeCommentBody -Pr $pr -PortReportsMarker '### Port Reports (must survive stamp)'

            function global:Get-CostRollingHistory {
                return @{ timed_out = $false; entries = @(New-HarvestCandidateEntry -Pr $pr) }
            }
            function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }
            function global:Test-CostWalkerSessionTranscriptExists { return $true }
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)]$Args)
                $joined = $Args -join ' '
                $global:LASTEXITCODE = 0
                if ($joined -match "pr view $pr --json state") {
                    return '{"state":"MERGED","mergedAt":"2026-06-01T00:00:00Z","mergeCommit":{"oid":"abc"},"headRefName":"feature/stamp"}'
                }
                if ($joined -match "pr view $pr --json comments") {
                    return (@{ comments = @(@{ body = $originalBody }) } | ConvertTo-Json -Depth 6 -Compress)
                }
                return ''
            }
            function global:Invoke-CostSessionRender {
                param($Pr, $Branch, $Slug, $ParentCwd, $RepoRoot)
                return @{
                    CostSection  = "## Cost Pattern`n<!-- cost-pattern-data`ncapture_point: pr-creation-mid-session`nports:`n  - name: implement-code`n-->"
                    Completeness = @{ completeness = 'partial'; capture_point = 'pr-creation-mid-session' }
                    TokenSum     = 1
                }
            }
            $script:UpsertedBody = $null
            function global:Find-OrUpsertComment {
                param($Type, $Number, $Marker, $Body)
                $script:UpsertedBody = $Body
                return $null
            }

            $result = Invoke-CostBaselineHarvest -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

            $result.Promoted | Should -Be $false
            $result.Signal | Should -Be "upgrade expected for #$pr — still partial"
            $script:UpsertedBody | Should -Match '### Port Reports \(must survive stamp\)'
            (@([regex]::Matches($script:UpsertedBody, '<!--\s*cost-pattern-data')).Count) | Should -Be 1
            $script:UpsertedBody | Should -Match 'upgrade_attempted_at: \d{4}-\d{2}-\d{2}T'
            # The original (persisted) section is preserved verbatim aside from the stamp —
            # capture_point stays the PERSISTED value (pr-creation-mid-session), not the
            # re-walk's, because a non-promoted row keeps its existing visible content.
            $script:UpsertedBody | Should -Match 'capture_point: pr-creation-mid-session'
        }

        It 'leaves the row completely untouched when the re-walk finds nothing usable' {
            $pr = 922
            function global:Get-CostRollingHistory {
                return @{ timed_out = $false; entries = @(New-HarvestCandidateEntry -Pr $pr) }
            }
            function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }
            function global:Test-CostWalkerSessionTranscriptExists { return $true }
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)]$Args)
                $global:LASTEXITCODE = 0
                return '{"state":"MERGED","mergedAt":"2026-06-01T00:00:00Z","mergeCommit":{"oid":"abc"},"headRefName":"feature/nothing"}'
            }
            function global:Invoke-CostSessionRender {
                param($Pr, $Branch, $Slug, $ParentCwd, $RepoRoot)
                return @{ CostSection = ''; Completeness = @{}; TokenSum = 0 }
            }
            $script:UpsertCalled = $false
            function global:Find-OrUpsertComment { $script:UpsertCalled = $true; return $null }

            $result = Invoke-CostBaselineHarvest -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

            $result.Promoted | Should -Be $false
            $result.Signal | Should -Be "upgrade expected for #$pr — transcript unavailable"
            $script:UpsertCalled | Should -Be $false
        }
    }

    Context 'one-candidate-per-call budget cap' {
        It 'invokes Invoke-CostSessionRender at most once even when multiple candidates are eligible' {
            $entries = @(
                (New-HarvestCandidateEntry -Pr 930 -SessionId 'session-930'),
                (New-HarvestCandidateEntry -Pr 931 -SessionId 'session-931')
            )
            function global:Get-CostRollingHistory {
                return @{ timed_out = $false; entries = $entries }
            }
            function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }
            function global:Test-CostWalkerSessionTranscriptExists { return $true }
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)]$Args)
                $global:LASTEXITCODE = 0
                return '{"state":"MERGED","mergedAt":"2026-06-01T00:00:00Z","mergeCommit":{"oid":"abc"},"headRefName":"feature/cap"}'
            }
            $script:RenderCallCount = 0
            $script:RenderedPrs = [System.Collections.Generic.List[int]]::new()
            function global:Invoke-CostSessionRender {
                param($Pr, $Branch, $Slug, $ParentCwd, $RepoRoot)
                $script:RenderCallCount++
                $script:RenderedPrs.Add($Pr)
                return @{ CostSection = ''; Completeness = @{}; TokenSum = 0 }
            }

            $result = Invoke-CostBaselineHarvest -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

            $script:RenderCallCount | Should -Be 1
            $script:RenderedPrs[0] | Should -Be 930
            $result.Pr | Should -Be 930
        }

        It 'moves to the next candidate (without spending the re-walk budget) when an earlier one fails verify-then-select' {
            $entries = @(
                (New-HarvestCandidateEntry -Pr 940 -SessionId 'missing'),
                (New-HarvestCandidateEntry -Pr 941 -SessionId 'present')
            )
            function global:Get-CostRollingHistory {
                return @{ timed_out = $false; entries = $entries }
            }
            function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }
            function global:Test-CostWalkerSessionTranscriptExists {
                param($SessionId, $Branch, $ParentCwd, $RepoRoot, $ProjectsRoot)
                return $SessionId -eq 'present'
            }
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)]$Args)
                $global:LASTEXITCODE = 0
                return '{"state":"MERGED","mergedAt":"2026-06-01T00:00:00Z","mergeCommit":{"oid":"abc"},"headRefName":"feature/cap-2"}'
            }
            $script:RenderCallCount = 0
            function global:Invoke-CostSessionRender {
                param($Pr, $Branch, $Slug, $ParentCwd, $RepoRoot)
                $script:RenderCallCount++
                return @{ CostSection = ''; Completeness = @{}; TokenSum = 0 }
            }

            $result = Invoke-CostBaselineHarvest -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

            $script:RenderCallCount | Should -Be 1
            $result.Pr | Should -Be 941
        }
    }

    Context 'fail-open' {
        It 'never throws when Get-CostRollingHistory itself throws' {
            function global:Get-CostRollingHistory { throw 'boom' }
            function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }

            { Invoke-CostBaselineHarvest -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo' } | Should -Not -Throw
        }

        It 'returns Attempted=$false and no signal when there are no candidates at all' {
            function global:Get-CostRollingHistory { return @{ timed_out = $false; entries = @() } }
            function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }

            $result = Invoke-CostBaselineHarvest -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

            $result.Attempted | Should -Be $false
            $result.Promoted | Should -Be $false
            $result.Signal | Should -BeNullOrEmpty
        }
    }
}
