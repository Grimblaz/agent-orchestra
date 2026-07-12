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
    # Issue #824 post-review fix (M13): Get-CostBaselineHarvestPortsTokenSum now
    # delegates to the relocated script:Get-FCLTokenSumFromBucket, and the
    # section-splice tests use the relocated $script:FCLCostPatternSectionRegex
    # (M18) — both must be dot-sourced before cost-baseline-harvest.ps1 itself.
    $script:FclHelpersLibPath = Join-Path $script:RepoRoot '.github/scripts/lib/cost-fcl-helpers.ps1'

    if (Test-Path $script:FclHelpersLibPath) {
        . $script:FclHelpersLibPath
    }
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

Describe 'Get-CostBaselineHarvestPersistedTokenSum (M4 post-review fix)' {
    It 'prefers the parsed totals.tokens bucket when present' {
        $entry = @{
            totals = @{ tokens = @{ input = 1000; output = 500; cache_creation = 0; cache_read = 0 } }
            ports  = @{ 'implement-code' = @{ tokens = @{ input = 10; output = 5; cache_creation = 0; cache_read = 0 } } }
        }
        script:Get-CostBaselineHarvestPersistedTokenSum -Entry $entry | Should -Be 1500
    }

    It 'falls back to the ports-only sum when totals.tokens is absent (pre-M4 persisted entries)' {
        $entry = @{
            ports = @{ 'implement-code' = @{ tokens = @{ input = 100; output = 50; cache_creation = 0; cache_read = 0 } } }
        }
        script:Get-CostBaselineHarvestPersistedTokenSum -Entry $entry | Should -Be 150
    }

    It 'falls back to the ports-only sum when totals exists but has no tokens key' {
        $entry = @{
            totals = @{ cost_estimate_usd = 0.05 }
            ports  = @{ 'implement-code' = @{ tokens = @{ input = 20; output = 10; cache_creation = 0; cache_read = 0 } } }
        }
        script:Get-CostBaselineHarvestPersistedTokenSum -Entry $entry | Should -Be 30
    }

    It 'returns 0 for a null entry' {
        script:Get-CostBaselineHarvestPersistedTokenSum -Entry $null | Should -Be 0
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
                    return (@{ comments = @(@{ body = $body; authorAssociation = 'OWNER' }) } | ConvertTo-Json -Depth 6 -Compress)
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
                    return (@{ comments = @(@{ body = $originalBody; authorAssociation = 'OWNER' }) } | ConvertTo-Json -Depth 6 -Compress)
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
                    return (@{ comments = @(@{ body = $originalBody; authorAssociation = 'OWNER' }) } | ConvertTo-Json -Depth 6 -Compress)
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

        It 'stamps upgrade_attempted_at when the re-walk finds nothing usable, so it exits future scans (M11)' {
            # Issue #824 post-review fix (M11): an empty re-walk used to leave
            # the row completely untouched, which meant it permanently
            # re-consumed the one-per-startup budget and starved every
            # candidate behind it. It must now reach the SAME terminal-state
            # stamp mechanism used for "still partial"/"lower token count".
            $pr = 922
            $originalBody = New-HarvestCompositeCommentBody -Pr $pr -PortReportsMarker '### Port Reports (must survive empty-rewalk stamp)'

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
                    return '{"state":"MERGED","mergedAt":"2026-06-01T00:00:00Z","mergeCommit":{"oid":"abc"},"headRefName":"feature/nothing"}'
                }
                if ($joined -match "pr view $pr --json comments") {
                    return (@{ comments = @(@{ body = $originalBody; authorAssociation = 'OWNER' }) } | ConvertTo-Json -Depth 6 -Compress)
                }
                return ''
            }
            function global:Invoke-CostSessionRender {
                param($Pr, $Branch, $Slug, $ParentCwd, $RepoRoot)
                return @{ CostSection = ''; Completeness = @{}; TokenSum = 0 }
            }
            $script:UpsertedBody = $null
            function global:Find-OrUpsertComment {
                param($Type, $Number, $Marker, $Body)
                $script:UpsertedBody = $Body
                return $null
            }

            $result = Invoke-CostBaselineHarvest -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

            $result.Promoted | Should -Be $false
            $result.Signal | Should -Be "upgrade expected for #$pr — transcript unavailable"
            $script:UpsertedBody | Should -Not -BeNullOrEmpty
            $script:UpsertedBody | Should -Match '### Port Reports \(must survive empty-rewalk stamp\)'
            $script:UpsertedBody | Should -Match 'upgrade_attempted_at: \d{4}-\d{2}-\d{2}T'
            (@([regex]::Matches($script:UpsertedBody, '<!--\s*cost-pattern-data')).Count) | Should -Be 1
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

    Context 'post-review fix (M2/M6/M8/M15/M19)' {
        It 'sets Console.OutputEncoding to UTF-8 before fetching the composite comment body (M2 mojibake guard)' {
            $originalEncoding = [Console]::OutputEncoding
            try {
                [Console]::OutputEncoding = [System.Text.Encoding]::ASCII

                $pr = 950
                function global:Get-CostRollingHistory {
                    return @{ timed_out = $false; entries = @(New-HarvestCandidateEntry -Pr $pr) }
                }
                function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }
                function global:Test-CostWalkerSessionTranscriptExists { return $true }
                $script:ObservedEncoding = $null
                function global:gh {
                    param([Parameter(ValueFromRemainingArguments = $true)]$Args)
                    $joined = $Args -join ' '
                    $global:LASTEXITCODE = 0
                    if ($joined -match "pr view $pr --json state") {
                        return '{"state":"MERGED","mergedAt":"2026-06-01T00:00:00Z","mergeCommit":{"oid":"abc"},"headRefName":"feature/enc"}'
                    }
                    if ($joined -match "pr view $pr --json comments") {
                        $script:ObservedEncoding = [Console]::OutputEncoding
                        $body = New-HarvestCompositeCommentBody -Pr $pr
                        return (@{ comments = @(@{ body = $body; authorAssociation = 'OWNER' }) } | ConvertTo-Json -Depth 6 -Compress)
                    }
                    return ''
                }
                function global:Invoke-CostSessionRender {
                    param($Pr, $Branch, $Slug, $ParentCwd, $RepoRoot)
                    return @{ CostSection = ''; Completeness = @{}; TokenSum = 0 }
                }

                $null = Invoke-CostBaselineHarvest -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

                $script:ObservedEncoding | Should -Not -BeNullOrEmpty
                $script:ObservedEncoding.WebName | Should -Be 'utf-8'
            }
            finally {
                [Console]::OutputEncoding = $originalEncoding
            }
        }

        It 'selects the earliest (lowest REST id) marker match, matching what Find-OrUpsertComment will PATCH, not the last chronological match (M6)' {
            $pr = 960
            $earliestBody = New-HarvestCompositeCommentBody -Pr $pr -PortReportsMarker '### EARLIEST (must be the splice target)'
            $latestBody = New-HarvestCompositeCommentBody -Pr $pr -PortReportsMarker '### LATEST (duplicate, must NOT be spliced)'

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
                    return '{"state":"MERGED","mergedAt":"2026-06-01T00:00:00Z","mergeCommit":{"oid":"abc"},"headRefName":"feature/dup"}'
                }
                if ($joined -match "pr view $pr --json comments") {
                    return (@{
                            comments = @(
                                @{ id = 'IC_1'; url = "https://github.com/o/r/pull/$pr#issuecomment-1001"; body = $earliestBody; authorAssociation = 'OWNER' },
                                @{ id = 'IC_2'; url = "https://github.com/o/r/pull/$pr#issuecomment-2002"; body = $latestBody; authorAssociation = 'OWNER' }
                            )
                        } | ConvertTo-Json -Depth 6 -Compress)
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
            $script:UpsertedBody | Should -Match '### EARLIEST \(must be the splice target\)'
            $script:UpsertedBody | Should -Not -Match '### LATEST'
        }

        It 'refreshes the rolling-history cache after a successful STAMP write too, not only after promotion (M8 part a)' {
            $pr = 980
            $originalBody = New-HarvestCompositeCommentBody -Pr $pr -PortReportsMarker '### Port Reports (stamp-refresh)'

            function global:Get-CostRollingHistory {
                param([switch]$ForceRefresh)
                if ($ForceRefresh) { $script:ForceRefreshCallCount++ }
                return @{ timed_out = $false; entries = @(New-HarvestCandidateEntry -Pr $pr) }
            }
            $script:ForceRefreshCallCount = 0
            function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }
            function global:Test-CostWalkerSessionTranscriptExists { return $true }
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)]$Args)
                $joined = $Args -join ' '
                $global:LASTEXITCODE = 0
                if ($joined -match "pr view $pr --json state") {
                    return '{"state":"MERGED","mergedAt":"2026-06-01T00:00:00Z","mergeCommit":{"oid":"abc"},"headRefName":"feature/stamp-refresh"}'
                }
                if ($joined -match "pr view $pr --json comments") {
                    return (@{ comments = @(@{ body = $originalBody; authorAssociation = 'OWNER' }) } | ConvertTo-Json -Depth 6 -Compress)
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
            function global:Find-OrUpsertComment { return $null }

            $result = Invoke-CostBaselineHarvest -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

            $result.Signal | Should -Be "upgrade expected for #$pr — still partial"
            $script:ForceRefreshCallCount | Should -Be 1
        }

        It 'replaces an existing upgrade_attempted_at line instead of appending a duplicate (M8 part b idempotent stamp)' {
            $pr = 981
            $sectionWithExistingStamp = "## Cost Pattern`n<!-- cost-pattern-data`ncapture_point: pr-creation-mid-session`nupgrade_attempted_at: 2026-06-01T00:00:00Z`nports:`n  - name: implement-code`n-->"
            $originalBody = New-HarvestCompositeCommentBody -Pr $pr -PortReportsMarker '### Port Reports (idempotent stamp)' -CostSection $sectionWithExistingStamp

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
                    return '{"state":"MERGED","mergedAt":"2026-06-01T00:00:00Z","mergeCommit":{"oid":"abc"},"headRefName":"feature/idempotent"}'
                }
                if ($joined -match "pr view $pr --json comments") {
                    return (@{ comments = @(@{ body = $originalBody; authorAssociation = 'OWNER' }) } | ConvertTo-Json -Depth 6 -Compress)
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

            $result.Signal | Should -Be "upgrade expected for #$pr — still partial"
            $script:UpsertedBody | Should -Match '### Port Reports \(idempotent stamp\)'
            (@([regex]::Matches($script:UpsertedBody, 'upgrade_attempted_at:'))).Count | Should -Be 1
            $script:UpsertedBody | Should -Not -Match '2026-06-01T00:00:00Z'
        }

        It 'skips the write and signals composite comment write failed when the section changed since the earlier read (M15 concurrency guard)' {
            $pr = 990
            $originalBody = New-HarvestCompositeCommentBody -Pr $pr -CostSection "## Cost Pattern`n<!-- cost-pattern-data`ncapture_point: pr-creation-mid-session`nports:`n  - name: implement-code`n-->"
            $changedBody = New-HarvestCompositeCommentBody -Pr $pr -CostSection "## Cost Pattern`n<!-- cost-pattern-data`ncapture_point: end-of-session`nports:`n  - name: implement-code`n  - name: someone-else-raced-us`n-->"

            function global:Get-CostRollingHistory {
                return @{ timed_out = $false; entries = @(New-HarvestCandidateEntry -Pr $pr) }
            }
            function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }
            function global:Test-CostWalkerSessionTranscriptExists { return $true }
            $script:FetchCallCount = 0
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)]$Args)
                $joined = $Args -join ' '
                $global:LASTEXITCODE = 0
                if ($joined -match "pr view $pr --json state") {
                    return '{"state":"MERGED","mergedAt":"2026-06-01T00:00:00Z","mergeCommit":{"oid":"abc"},"headRefName":"feature/race"}'
                }
                if ($joined -match "pr view $pr --json comments") {
                    $script:FetchCallCount++
                    $body = if ($script:FetchCallCount -eq 1) { $originalBody } else { $changedBody }
                    return (@{ comments = @(@{ body = $body; authorAssociation = 'OWNER' }) } | ConvertTo-Json -Depth 6 -Compress)
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
            $script:UpsertCalled = $false
            function global:Find-OrUpsertComment { $script:UpsertCalled = $true; return $null }

            $result = Invoke-CostBaselineHarvest -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

            $result.Promoted | Should -Be $false
            $result.Signal | Should -Be "upgrade expected for #$pr — composite comment write failed"
            $script:UpsertCalled | Should -Be $false
        }

        It 'treats a composite comment from a non-authorized author association as not found (M19 fail-closed authorship check)' {
            $pr = 970
            $body = New-HarvestCompositeCommentBody -Pr $pr

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
                    return '{"state":"MERGED","mergedAt":"2026-06-01T00:00:00Z","mergeCommit":{"oid":"abc"},"headRefName":"feature/forged"}'
                }
                if ($joined -match "pr view $pr --json comments") {
                    return (@{ comments = @(@{ body = $body; authorAssociation = 'NONE' }) } | ConvertTo-Json -Depth 6 -Compress)
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
            $script:UpsertCalled = $false
            function global:Find-OrUpsertComment { $script:UpsertCalled = $true; return $null }

            $result = Invoke-CostBaselineHarvest -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

            $result.Promoted | Should -Be $false
            $result.Signal | Should -Be "upgrade expected for #$pr — composite comment not found (may be deleted; will retry)"
            $script:UpsertCalled | Should -Be $false
        }
    }

    Context 'post-fix cycle 2 (F1/F2/F3)' {
        It 'F1: accepts a composite comment authored by github-actions with authorAssociation NONE (real production shape)' {
            $pr = 1001
            $body = New-HarvestCompositeCommentBody -Pr $pr

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
                    return '{"state":"MERGED","mergedAt":"2026-06-01T00:00:00Z","mergeCommit":{"oid":"abc"},"headRefName":"feature/f1-accept"}'
                }
                if ($joined -match "pr view $pr --json comments") {
                    return (@{ comments = @(@{ body = $body; author = @{ login = 'github-actions' }; authorAssociation = 'NONE' }) } | ConvertTo-Json -Depth 6 -Compress)
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
            $script:UpsertCalled = $false
            function global:Find-OrUpsertComment { $script:UpsertCalled = $true; return $null }

            $result = Invoke-CostBaselineHarvest -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

            $result.Promoted | Should -Be $true
            $script:UpsertCalled | Should -Be $true
        }

        It 'F1: still rejects a comment from an arbitrary non-bot, non-authorized commenter (forgery protection holds)' {
            $pr = 1002
            $body = New-HarvestCompositeCommentBody -Pr $pr

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
                    return '{"state":"MERGED","mergedAt":"2026-06-01T00:00:00Z","mergeCommit":{"oid":"abc"},"headRefName":"feature/f1-reject"}'
                }
                if ($joined -match "pr view $pr --json comments") {
                    return (@{ comments = @(@{ body = $body; author = @{ login = 'some-random-user' }; authorAssociation = 'NONE' }) } | ConvertTo-Json -Depth 6 -Compress)
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
            $script:UpsertCalled = $false
            function global:Find-OrUpsertComment { $script:UpsertCalled = $true; return $null }

            $result = Invoke-CostBaselineHarvest -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

            $result.Promoted | Should -Be $false
            $script:UpsertCalled | Should -Be $false
        }

        It 'F2: does not crash and reaches the terminal-state stamp path when Invoke-CostSessionRender throws' {
            $pr = 1003
            $originalBody = New-HarvestCompositeCommentBody -Pr $pr -PortReportsMarker '### Port Reports (F2 null-guard)'

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
                    return '{"state":"MERGED","mergedAt":"2026-06-01T00:00:00Z","mergeCommit":{"oid":"abc"},"headRefName":"feature/f2-null-guard"}'
                }
                if ($joined -match "pr view $pr --json comments") {
                    return (@{ comments = @(@{ body = $originalBody; authorAssociation = 'OWNER' }) } | ConvertTo-Json -Depth 6 -Compress)
                }
                return ''
            }
            function global:Invoke-CostSessionRender {
                param($Pr, $Branch, $Slug, $ParentCwd, $RepoRoot)
                throw 'simulated render failure'
            }
            $script:UpsertedBody = $null
            function global:Find-OrUpsertComment {
                param($Type, $Number, $Marker, $Body)
                $script:UpsertedBody = $Body
                return $null
            }

            $result = Invoke-CostBaselineHarvest -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

            $result.Attempted | Should -Be $true
            $result.Signal | Should -Be "upgrade expected for #$pr — transcript unavailable"
            $script:UpsertedBody | Should -Not -BeNullOrEmpty
            $script:UpsertedBody | Should -Match '### Port Reports \(F2 null-guard\)'
            $script:UpsertedBody | Should -Match 'upgrade_attempted_at: \d{4}-\d{2}-\d{2}T'
        }

        It 'F3: signals a distinguishable "not found (may be deleted; will retry)" outcome when no composite comment matches' {
            $pr = 1004

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
                    return '{"state":"MERGED","mergedAt":"2026-06-01T00:00:00Z","mergeCommit":{"oid":"abc"},"headRefName":"feature/f3-not-found"}'
                }
                if ($joined -match "pr view $pr --json comments") {
                    return (@{ comments = @() } | ConvertTo-Json -Depth 6 -Compress)
                }
                return ''
            }
            function global:Invoke-CostSessionRender {
                param($Pr, $Branch, $Slug, $ParentCwd, $RepoRoot)
                return @{ CostSection = ''; Completeness = @{}; TokenSum = 0 }
            }

            $result = Invoke-CostBaselineHarvest -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

            $result.Signal | Should -Be "upgrade expected for #$pr — composite comment not found (may be deleted; will retry)"
        }

        It 'F3: signals a distinguishable "cost section format mismatch (needs investigation)" outcome when the marker matches but the cost-pattern-data section regex does not' {
            $pr = 1005
            $malformedBody = @"
<!-- frame-credit-ledger-$pr -->
### Port Reports (F3 regex-mismatch)
- implement-code: passed

## Cost Pattern
this section is missing the cost-pattern-data HTML comment entirely

_end of comment_
"@

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
                    return '{"state":"MERGED","mergedAt":"2026-06-01T00:00:00Z","mergeCommit":{"oid":"abc"},"headRefName":"feature/f3-regex-mismatch"}'
                }
                if ($joined -match "pr view $pr --json comments") {
                    return (@{ comments = @(@{ body = $malformedBody; authorAssociation = 'OWNER' }) } | ConvertTo-Json -Depth 6 -Compress)
                }
                return ''
            }
            function global:Invoke-CostSessionRender {
                param($Pr, $Branch, $Slug, $ParentCwd, $RepoRoot)
                return @{ CostSection = ''; Completeness = @{}; TokenSum = 0 }
            }

            $result = Invoke-CostBaselineHarvest -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

            $result.Signal | Should -Be "upgrade expected for #$pr — cost section format mismatch (needs investigation)"
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

# ---------------------------------------------------------------------------
# Invoke-CostAttributionRepair (issue #825, Step 3) — targeted, maintainer-
# invoked single-PR re-attribution repair. Deliberately a SEPARATE Describe
# from Invoke-CostBaselineHarvest above: this function is not part of, and
# never calls into, script:Select-CostBaselineHarvestCandidates' automatic
# candidate loop or Invoke-CostBaselineHarvest's own promote/stamp machinery.
#
# The #814/#815 degraded fixture (M13): the real pre-#824 CI-written blocks
# for those PRs carry ONLY session_completeness/pr/branch (branch reads the
# literal string "HEAD", never a real ref) — no head_ref/session_id/
# capture_point. $script:PreV4DegradedCostSection reproduces that exact
# shape so the AC3 regression proves something real rather than a strawman.
# ---------------------------------------------------------------------------
Describe 'Invoke-CostAttributionRepair (issue #825 s3)' {

    BeforeAll {
        $script:PreV4DegradedCostSection = "## Cost Pattern`n<!-- cost-pattern-data`nsession_completeness: unknown`npr: 814`nbranch: HEAD`n-->"
    }

    It 'resolves the PR''s REAL head ref via gh pr view and passes it (never the persisted branch: HEAD field) to Invoke-CostSessionRender (M2/M15)' {
        $pr = 814
        $originalBody = New-HarvestCompositeCommentBody -Pr $pr -CostSection $script:PreV4DegradedCostSection

        function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match "pr view $pr --json state,headRefName,body") {
                return '{"state":"MERGED","headRefName":"feature/issue-814-real-branch","body":"Fixes #814","createdAt":"2026-06-01T00:00:00Z","mergedAt":"2026-06-05T00:00:00Z"}'
            }
            if ($joined -match "pr view $pr --json comments") {
                return (@{ comments = @(@{ body = $originalBody; authorAssociation = 'OWNER' }) } | ConvertTo-Json -Depth 6 -Compress)
            }
            return ''
        }
        $script:CapturedBranch = $null
        function global:Invoke-CostSessionRender {
            param($Pr, $Branch, $Slug, $ParentCwd, $RepoRoot, $PrBody, [switch]$AdmitCorroboratedFallback, $CorroborationWindowStart, $CorroborationWindowEnd)
            $script:CapturedBranch = $Branch
            return @{ CostSection = "## Cost Pattern`n<!-- cost-pattern-data`nsession_completeness: complete`npr: $Pr`nbranch: $Branch`n-->" }
        }
        function global:Find-OrUpsertComment { return $null }

        $null = Invoke-CostAttributionRepair -Pr $pr -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

        $script:CapturedBranch | Should -Be 'feature/issue-814-real-branch'
        $script:CapturedBranch | Should -Not -Be 'HEAD'
    }

    It 'skips a PR that is not MERGED, without ever calling Invoke-CostSessionRender' {
        $pr = 815
        function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $global:LASTEXITCODE = 0
            return '{"state":"OPEN","headRefName":"feature/still-open","body":""}'
        }
        $script:RenderCallCount = 0
        function global:Invoke-CostSessionRender { $script:RenderCallCount++; return @{ CostSection = '' } }

        $result = Invoke-CostAttributionRepair -Pr $pr -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

        $result.Attempted | Should -Be $false
        $result.Upserted | Should -Be $false
        $script:RenderCallCount | Should -Be 0
    }

    It 'skips when the gh pr view call itself fails' {
        $pr = 816
        function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $global:LASTEXITCODE = 1
            return ''
        }

        { Invoke-CostAttributionRepair -Pr $pr -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo' } | Should -Not -Throw
        $result = Invoke-CostAttributionRepair -Pr $pr -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'
        $result.Attempted | Should -Be $false
    }

    It 'skips repair (L9, issue #825 post-review fix) when the corroboration window cannot be resolved — unparseable/absent createdAt and empty commits — without ever calling Invoke-CostSessionRender or Find-OrUpsertComment' {
        $pr = 825001
        $originalBody = New-HarvestCompositeCommentBody -Pr $pr -CostSection $script:PreV4DegradedCostSection

        function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match "pr view $pr --json state,headRefName,body") {
                # createdAt absent entirely and commits an empty array — window start
                # cannot resolve via either the earliest-commit or createdAt fallback.
                return '{"state":"MERGED","headRefName":"feature/unresolvable-window","body":"","mergedAt":"2026-06-05T00:00:00Z","commits":[]}'
            }
            if ($joined -match "pr view $pr --json comments") {
                # A real session_completeness: unknown composite comment exists — this
                # test isolates the window-resolution guard, not the earlier
                # composite-comment/session_completeness gates.
                return (@{ comments = @(@{ body = $originalBody; authorAssociation = 'OWNER' }) } | ConvertTo-Json -Depth 6 -Compress)
            }
            return ''
        }
        $script:RenderCallCount = 0
        function global:Invoke-CostSessionRender { $script:RenderCallCount++; return @{ CostSection = '' } }
        $script:UpsertCalled = $false
        function global:Find-OrUpsertComment { $script:UpsertCalled = $true; return $null }

        $result = Invoke-CostAttributionRepair -Pr $pr -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

        $result.Attempted | Should -Be $false
        $result.Upserted | Should -Be $false
        $result.Signal | Should -Be "repair skipped for #$pr — corroboration window could not be resolved"
        $script:RenderCallCount | Should -Be 0
        $script:UpsertCalled | Should -Be $false
    }

    It 'skips when no composite comment is found for the PR' {
        $pr = 817
        function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match "pr view $pr --json state,headRefName,body") {
                return '{"state":"MERGED","headRefName":"feature/no-comment","body":""}'
            }
            if ($joined -match "pr view $pr --json comments") {
                return (@{ comments = @() } | ConvertTo-Json -Depth 6 -Compress)
            }
            return ''
        }
        $script:RenderCallCount = 0
        function global:Invoke-CostSessionRender { $script:RenderCallCount++; return @{ CostSection = '' } }

        $result = Invoke-CostAttributionRepair -Pr $pr -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

        $result.Attempted | Should -Be $false
        $script:RenderCallCount | Should -Be 0
    }

    It 'leaves an already-populated (non-unknown) persisted block untouched' {
        $pr = 818
        $populatedSection = "## Cost Pattern`n<!-- cost-pattern-data`nsession_completeness: complete`npr: $pr`nbranch: feature/already-good`n-->"
        $originalBody = New-HarvestCompositeCommentBody -Pr $pr -CostSection $populatedSection

        function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match "pr view $pr --json state,headRefName,body") {
                return '{"state":"MERGED","headRefName":"feature/already-good","body":""}'
            }
            if ($joined -match "pr view $pr --json comments") {
                return (@{ comments = @(@{ body = $originalBody; authorAssociation = 'OWNER' }) } | ConvertTo-Json -Depth 6 -Compress)
            }
            return ''
        }
        $script:RenderCallCount = 0
        function global:Invoke-CostSessionRender { $script:RenderCallCount++; return @{ CostSection = '' } }

        $result = Invoke-CostAttributionRepair -Pr $pr -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

        $result.Attempted | Should -Be $false
        $result.Signal | Should -Match 'not session_completeness: unknown'
        $script:RenderCallCount | Should -Be 0
    }

    It 'reproduces the pre-#824 #814/#815 degraded fixture shape and upserts a populated re-walk (populated-beats-empty-unknown, M13)' {
        $pr = 814
        $originalBody = New-HarvestCompositeCommentBody -Pr $pr -PortReportsMarker '### Port Reports (must survive repair)' -CostSection $script:PreV4DegradedCostSection

        function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match "pr view $pr --json state,headRefName,body") {
                return '{"state":"MERGED","headRefName":"feature/issue-814-real-branch","body":"Fixes #814","createdAt":"2026-06-01T00:00:00Z","mergedAt":"2026-06-05T00:00:00Z"}'
            }
            if ($joined -match "pr view $pr --json comments") {
                return (@{ comments = @(@{ body = $originalBody; authorAssociation = 'OWNER' }) } | ConvertTo-Json -Depth 6 -Compress)
            }
            return ''
        }
        $script:CapturedAdmit = $false
        function global:Invoke-CostSessionRender {
            param($Pr, $Branch, $Slug, $ParentCwd, $RepoRoot, $PrBody, [switch]$AdmitCorroboratedFallback, $CorroborationWindowStart, $CorroborationWindowEnd)
            $script:CapturedAdmit = [bool]$AdmitCorroboratedFallback
            return @{
                CostSection     = "## Cost Pattern`n<!-- cost-pattern-data`nsession_completeness: complete`npr: $Pr`nbranch: $Branch`n-->"
                CostEventsCount = 1
            }
        }
        $script:UpsertedBody = $null
        function global:Find-OrUpsertComment {
            param($Type, $Number, $Marker, $Body)
            $script:UpsertedBody = $Body
            return $null
        }

        $result = Invoke-CostAttributionRepair -Pr $pr -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

        $result.Attempted | Should -Be $true
        $result.Upserted | Should -Be $true
        $result.Signal | Should -Be "repaired #$pr — attribution re-walked and upserted"
        $script:CapturedAdmit | Should -Be $true
        $script:UpsertedBody | Should -Not -BeNullOrEmpty
        $script:UpsertedBody | Should -Match '### Port Reports \(must survive repair\)'
        $script:UpsertedBody | Should -Match 'session_completeness: complete'
        $script:UpsertedBody | Should -Not -Match 'session_completeness: unknown'
        (@([regex]::Matches($script:UpsertedBody, '<!--\s*cost-pattern-data')).Count) | Should -Be 1
    }

    It 'reports honestly and writes nothing when the re-walk finds no matching transcripts on this machine' {
        $pr = 815
        $originalBody = New-HarvestCompositeCommentBody -Pr $pr -PortReportsMarker '### Port Reports (must survive no-op)' -CostSection $script:PreV4DegradedCostSection

        function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match "pr view $pr --json state,headRefName,body") {
                return '{"state":"MERGED","headRefName":"feature/issue-815-real-branch","body":"Fixes #815","createdAt":"2026-06-01T00:00:00Z","mergedAt":"2026-06-05T00:00:00Z"}'
            }
            if ($joined -match "pr view $pr --json comments") {
                return (@{ comments = @(@{ body = $originalBody; authorAssociation = 'OWNER' }) } | ConvertTo-Json -Depth 6 -Compress)
            }
            return ''
        }
        function global:Invoke-CostSessionRender {
            param($Pr, $Branch, $Slug, $ParentCwd, $RepoRoot, $PrBody, [switch]$AdmitCorroboratedFallback, $CorroborationWindowStart, $CorroborationWindowEnd)
            return @{ CostSection = '' }
        }
        $script:UpsertCalled = $false
        function global:Find-OrUpsertComment { $script:UpsertCalled = $true; return $null }

        $result = Invoke-CostAttributionRepair -Pr $pr -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

        $result.Attempted | Should -Be $true
        $result.Upserted | Should -Be $false
        $result.Signal | Should -Match 'no matching transcripts'
        $script:UpsertCalled | Should -Be $false
    }

    It 'refuses to write (no empty-splice data loss) and signals budget-exhaustion when the re-walk finds events but composes an empty cost section (issue #825 CE Gate regression pin)' {
        # Data-loss reproduction: Invoke-CostSessionRender's step-6g budget-exhaustion
        # edge returns CostEventsCount > 0 but CostSection = '' when the render budget
        # is spent before the section is composed. The pre-fix caller guard gated only
        # on CostEventsCount, so the empty section was spliced over the persisted block
        # by Merge-CostBaselineHarvestSection (a pure substring splice) — DELETING the
        # Cost Pattern section from real merged PRs #814/#815. This pins the refusal.
        $pr = 814
        $originalBody = New-HarvestCompositeCommentBody -Pr $pr -PortReportsMarker '### Port Reports (must survive)' -CostSection $script:PreV4DegradedCostSection

        function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match "pr view $pr --json state,headRefName,body") {
                return '{"state":"MERGED","headRefName":"feature/issue-814-real-branch","body":"Fixes #814","createdAt":"2026-06-01T00:00:00Z","mergedAt":"2026-06-05T00:00:00Z"}'
            }
            if ($joined -match "pr view $pr --json comments") {
                return (@{ comments = @(@{ body = $originalBody; authorAssociation = 'OWNER' }) } | ConvertTo-Json -Depth 6 -Compress)
            }
            return ''
        }
        function global:Invoke-CostSessionRender {
            param($Pr, $Branch, $Slug, $ParentCwd, $RepoRoot, $PrBody, [switch]$AdmitCorroboratedFallback, $CorroborationWindowStart, $CorroborationWindowEnd)
            return @{ CostSection = ''; CostEventsCount = 5 }
        }
        $script:UpsertCalled = $false
        function global:Find-OrUpsertComment { $script:UpsertCalled = $true; return $null }

        $result = Invoke-CostAttributionRepair -Pr $pr -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

        $script:UpsertCalled | Should -Be $false
        $result.Upserted | Should -Be $false
        $result.Signal | Should -Match 'exhausted its render budget'
        $result.Signal | Should -Not -Match 'repaired'
    }

    It 'skips the write and signals a concurrent-change race when the section changed since the earlier read' {
        $pr = 819
        $originalBody = New-HarvestCompositeCommentBody -Pr $pr -CostSection $script:PreV4DegradedCostSection
        $changedBody = New-HarvestCompositeCommentBody -Pr $pr -CostSection "## Cost Pattern`n<!-- cost-pattern-data`nsession_completeness: complete`npr: $pr`nbranch: someone-else-raced-us`n-->"

        function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }
        $script:FetchCallCount = 0
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match "pr view $pr --json state,headRefName,body") {
                return '{"state":"MERGED","headRefName":"feature/race","body":"","createdAt":"2026-06-01T00:00:00Z","mergedAt":"2026-06-05T00:00:00Z"}'
            }
            if ($joined -match "pr view $pr --json comments") {
                $script:FetchCallCount++
                $body = if ($script:FetchCallCount -eq 1) { $originalBody } else { $changedBody }
                return (@{ comments = @(@{ body = $body; authorAssociation = 'OWNER' }) } | ConvertTo-Json -Depth 6 -Compress)
            }
            return ''
        }
        function global:Invoke-CostSessionRender {
            param($Pr, $Branch, $Slug, $ParentCwd, $RepoRoot, $PrBody, [switch]$AdmitCorroboratedFallback, $CorroborationWindowStart, $CorroborationWindowEnd)
            return @{ CostSection = "## Cost Pattern`n<!-- cost-pattern-data`nsession_completeness: complete`npr: $Pr`nbranch: $Branch`n-->"; CostEventsCount = 1 }
        }
        $script:UpsertCalled = $false
        function global:Find-OrUpsertComment { $script:UpsertCalled = $true; return $null }

        $result = Invoke-CostAttributionRepair -Pr $pr -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'

        $result.Upserted | Should -Be $false
        $result.Signal | Should -Match 'concurrent change'
        $script:UpsertCalled | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
# Composition/wiring regression (issue #825 s3): proves -AdmitCorroboratedFallback
# actually reaches Invoke-CostTranscriptWalk when Invoke-CostAttributionRepair
# calls the REAL (dot-sourced, not mocked) Invoke-CostSessionRender. This is the
# specific regression this slice's grounding surfaced: cost-session-render.ps1
# (as landed by s2) accepted no -AdmitCorroboratedFallback parameter at all and
# never threaded one into its own walkParameters hashtable, so s3's own plan
# text ("call Invoke-CostSessionRender with -AdmitCorroboratedFallback on") was
# not actually possible before this slice's own edit to that file. Only
# Invoke-CostTranscriptWalk is mocked (to capture what it actually receives,
# without touching the real filesystem); Resolve-BaselineEligibility and the
# Format-CostPattern* renderers run for REAL (dot-sourced from
# cost-completeness.ps1 / cost-pattern-renderer.ps1), matching the established
# "does NOT stub" convention already used by cost-integration.Tests.ps1's own
# issue #824 s3 caller-wiring invoker.
# ---------------------------------------------------------------------------
Describe 'Invoke-CostSessionRender AdmitCorroboratedFallback wiring, composed through Invoke-CostAttributionRepair (issue #825 s3)' {

    BeforeAll {
        $script:SessionRenderLibPath = Join-Path $script:RepoRoot '.github/scripts/lib/cost-session-render.ps1'
        $script:CompletenessLibPath = Join-Path $script:RepoRoot '.github/scripts/lib/cost-completeness.ps1'
        if (Test-Path $script:CompletenessLibPath) { . $script:CompletenessLibPath }
        if (Test-Path $script:SessionRenderLibPath) { . $script:SessionRenderLibPath }
    }

    It 'threads -AdmitCorroboratedFallback through to the real Invoke-CostTranscriptWalk call' {
        $pr = 820
        $originalBody = New-HarvestCompositeCommentBody -Pr $pr -CostSection "## Cost Pattern`n<!-- cost-pattern-data`nsession_completeness: unknown`npr: $pr`nbranch: HEAD`n-->"

        function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match "pr view $pr --json state,headRefName,body") {
                return '{"state":"MERGED","headRefName":"feature/issue-820-wiring","body":"Fixes #820","createdAt":"2026-06-01T00:00:00Z","mergedAt":"2026-06-05T00:00:00Z"}'
            }
            if ($joined -match "pr view $pr --json comments") {
                return (@{ comments = @(@{ body = $originalBody; authorAssociation = 'OWNER' }) } | ConvertTo-Json -Depth 6 -Compress)
            }
            return ''
        }

        $script:CapturedWalkParams = $null
        function global:Invoke-CostTranscriptWalk {
            param(
                [string]$Slug, [string]$Branch, [string]$ParentCwd, [string]$ProjectsRoot = '',
                [Nullable[int]]$IssueNumber = $null, [string]$RepoRoot = '',
                [switch]$AdmitCorroboratedFallback,
                [Nullable[datetime]]$CorroborationWindowStart = $null,
                [Nullable[datetime]]$CorroborationWindowEnd = $null,
                [ref]$RejectedDirCountVar,
                [Nullable[int]]$Tier2IssueNumber = $null
            )
            $script:CapturedWalkParams = $PSBoundParameters
            if ($null -ne $RejectedDirCountVar) { $RejectedDirCountVar.Value = 0 }
            return @(@{ type = 'assistant'; gitBranch = $Branch; uuid = 'evt-1'; message = @{ content = @() } })
        }
        function global:Invoke-CostCopilotWalk {
            param([string]$Branch, [string]$RepoRoot, [string]$OtelJsonlPath, [string]$WorkspaceFolderBasename = '')
            return @()
        }
        function global:Get-CostAttribution {
            param([object[]]$Events, [string]$RateTablePath = '')
            return @{
                ports                 = @{}
                orchestrator_overhead = @{ tokens = @{ input = 10; output = 5; cache_creation = 0; cache_read = 0 }; cost_estimate_usd = 0.0; cache_read_hit_ratio = 0.0 }
                dispatches            = @{ general_purpose_count = 0; unattributed_count = 0 }
                totals                = @{ total_cost_usd = 0.0; tokens = @{ input = 10; output = 5; cache_creation = 0; cache_read = 0 } }
            }
        }
        function global:Get-CostRollingHistory { param([int]$TimeoutSeconds = 10) return @{ timed_out = $false; entries = @() } }
        function global:Get-MostRecentRegimeCheckpoint { param([string]$Path) return $null }
        function global:Get-CostAnomalyFlags { param($ThisRun, [object[]]$RollingHistory, $RegimeCheckpoint) return @() }
        function global:Get-CostWalkerCurrentSessionId { param([string]$Slug, [string]$Branch, [string]$ParentCwd, [string]$RepoRoot = '') return '' }
        $script:UpsertedBody = $null
        function global:Find-OrUpsertComment {
            param($Type, $Number, $Marker, $Body)
            $script:UpsertedBody = $Body
            return $null
        }

        # Inline-execute the walker call (no isolated runspace) so the mocked
        # Invoke-CostTranscriptWalk's $script:CapturedWalkParams assignment
        # lands in THIS scope rather than a cloned runspace's own copy —
        # matches the established FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE
        # convention used throughout cost-integration.Tests.ps1.
        $previousInline = $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE
        $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE = '1'
        try {
            $result = Invoke-CostAttributionRepair -Pr $pr -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'
        }
        finally {
            $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE = $previousInline
        }

        $script:CapturedWalkParams | Should -Not -BeNullOrEmpty
        $script:CapturedWalkParams['AdmitCorroboratedFallback'] | Should -Be $true
        $script:CapturedWalkParams['Branch'] | Should -Be 'feature/issue-820-wiring'
        # M8 wiring gap fix: the PR's own createdAt/mergedAt (fetched on the same
        # gh pr view call as headRefName, no extra API round-trip) must reach the
        # walker call as the corroboration window — not stay $null/unbounded.
        # .ToUniversalTime() normalizes Kind (ConvertFrom-Json's date coercion
        # preserves Utc Kind; a bare string-literal [datetime] cast in this test
        # converts to Local Kind) so the comparison is instant-equality, not a
        # Kind/offset-display mismatch.
        $script:CapturedWalkParams['CorroborationWindowStart'].ToUniversalTime() | Should -Be ([datetime]'2026-06-01T00:00:00Z').ToUniversalTime()
        $script:CapturedWalkParams['CorroborationWindowEnd'].ToUniversalTime() | Should -Be ([datetime]'2026-06-05T00:00:00Z').ToUniversalTime()
        $result.Attempted | Should -Be $true
        $result.Upserted | Should -Be $true
        $script:UpsertedBody | Should -Match 'session_completeness'
        $script:UpsertedBody | Should -Not -Match 'session_completeness: unknown'
    }

    It 'derives the corroboration window start from the earliest commit authoredDate, not createdAt, when the PR has commits (M8 primary-branch coverage)' {
        # Gap: every other test's gh mock returns a commits-less JSON payload,
        # so only the createdAt fallback branch (Invoke-CostAttributionRepair
        # ln ~929) was ever exercised. This test supplies out-of-order commit
        # authoredDate values that predate createdAt by a multi-day span, and
        # proves the resolved window start is the EARLIEST authoredDate, not
        # createdAt — the primary branch (ln ~922-928) that was previously
        # uncovered.
        $pr = 822
        $originalBody = New-HarvestCompositeCommentBody -Pr $pr -CostSection "## Cost Pattern`n<!-- cost-pattern-data`nsession_completeness: unknown`npr: $pr`nbranch: HEAD`n-->"

        function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match "pr view $pr --json state,headRefName,body") {
                # createdAt trails the branch's real first commit by several
                # days (the #814 flagship gotcha this window bound exists
                # for) and the commits array is deliberately out of order so
                # a naive "first element" read would pick the wrong one.
                return '{"state":"MERGED","headRefName":"feature/issue-822-commits","body":"Fixes #822","createdAt":"2026-06-04T00:00:00Z","mergedAt":"2026-06-08T00:00:00Z","commits":[{"authoredDate":"2026-05-30T08:00:00Z"},{"authoredDate":"2026-05-28T10:00:00Z"},{"authoredDate":"2026-05-31T14:00:00Z"}]}'
            }
            if ($joined -match "pr view $pr --json comments") {
                return (@{ comments = @(@{ body = $originalBody; authorAssociation = 'OWNER' }) } | ConvertTo-Json -Depth 6 -Compress)
            }
            return ''
        }

        $script:CapturedWalkParams = $null
        function global:Invoke-CostTranscriptWalk {
            param(
                [string]$Slug, [string]$Branch, [string]$ParentCwd, [string]$ProjectsRoot = '',
                [Nullable[int]]$IssueNumber = $null, [string]$RepoRoot = '',
                [switch]$AdmitCorroboratedFallback,
                [Nullable[datetime]]$CorroborationWindowStart = $null,
                [Nullable[datetime]]$CorroborationWindowEnd = $null,
                [ref]$RejectedDirCountVar,
                [Nullable[int]]$Tier2IssueNumber = $null
            )
            $script:CapturedWalkParams = $PSBoundParameters
            if ($null -ne $RejectedDirCountVar) { $RejectedDirCountVar.Value = 0 }
            return @(@{ type = 'assistant'; gitBranch = $Branch; uuid = 'evt-1'; message = @{ content = @() } })
        }
        function global:Invoke-CostCopilotWalk {
            param([string]$Branch, [string]$RepoRoot, [string]$OtelJsonlPath, [string]$WorkspaceFolderBasename = '')
            return @()
        }
        function global:Get-CostAttribution {
            param([object[]]$Events, [string]$RateTablePath = '')
            return @{
                ports                 = @{}
                orchestrator_overhead = @{ tokens = @{ input = 10; output = 5; cache_creation = 0; cache_read = 0 }; cost_estimate_usd = 0.0; cache_read_hit_ratio = 0.0 }
                dispatches            = @{ general_purpose_count = 0; unattributed_count = 0 }
                totals                = @{ total_cost_usd = 0.0; tokens = @{ input = 10; output = 5; cache_creation = 0; cache_read = 0 } }
            }
        }
        function global:Get-CostRollingHistory { param([int]$TimeoutSeconds = 10) return @{ timed_out = $false; entries = @() } }
        function global:Get-MostRecentRegimeCheckpoint { param([string]$Path) return $null }
        function global:Get-CostAnomalyFlags { param($ThisRun, [object[]]$RollingHistory, $RegimeCheckpoint) return @() }
        function global:Get-CostWalkerCurrentSessionId { param([string]$Slug, [string]$Branch, [string]$ParentCwd, [string]$RepoRoot = '') return '' }
        $script:UpsertedBody = $null
        function global:Find-OrUpsertComment {
            param($Type, $Number, $Marker, $Body)
            $script:UpsertedBody = $Body
            return $null
        }

        $previousInline = $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE
        $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE = '1'
        try {
            $result = Invoke-CostAttributionRepair -Pr $pr -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'
        }
        finally {
            $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE = $previousInline
        }

        $script:CapturedWalkParams | Should -Not -BeNullOrEmpty
        # The earliest of the three out-of-order authoredDate values, NOT
        # createdAt (2026-06-04) and NOT the first array element (05-30).
        $script:CapturedWalkParams['CorroborationWindowStart'].ToUniversalTime() | Should -Be ([datetime]'2026-05-28T10:00:00Z').ToUniversalTime()
        $script:CapturedWalkParams['CorroborationWindowEnd'].ToUniversalTime() | Should -Be ([datetime]'2026-06-08T00:00:00Z').ToUniversalTime()
        $result.Attempted | Should -Be $true
        $result.Upserted | Should -Be $true
    }

    It 'excludes a fixture event timestamped outside the PR''s createdAt->mergedAt window, specifically through Invoke-CostAttributionRepair''s own call path (M8 post-review fix)' {
        # Distinct from cost-walker.Tests.ps1's own M8 unit test (which hand-supplies
        # a window directly to Invoke-CostTranscriptWalk): this proves
        # Invoke-CostAttributionRepair itself DERIVES the window from the target
        # PR's real createdAt/mergedAt and that a real walker honoring that window
        # would exclude an out-of-window event reached through this exact call
        # path — not merely that the switch/window values are captured in transit.
        $pr = 821
        $originalBody = New-HarvestCompositeCommentBody -Pr $pr -CostSection "## Cost Pattern`n<!-- cost-pattern-data`nsession_completeness: unknown`npr: $pr`nbranch: HEAD`n-->"

        function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match "pr view $pr --json state,headRefName,body") {
                return '{"state":"MERGED","headRefName":"feature/issue-821-window","body":"Fixes #821","createdAt":"2026-06-01T00:00:00Z","mergedAt":"2026-06-05T00:00:00Z"}'
            }
            if ($joined -match "pr view $pr --json comments") {
                return (@{ comments = @(@{ body = $originalBody; authorAssociation = 'OWNER' }) } | ConvertTo-Json -Depth 6 -Compress)
            }
            return ''
        }

        function global:Invoke-CostTranscriptWalk {
            param(
                [string]$Slug, [string]$Branch, [string]$ParentCwd, [string]$ProjectsRoot = '',
                [Nullable[int]]$IssueNumber = $null, [string]$RepoRoot = '',
                [switch]$AdmitCorroboratedFallback,
                [Nullable[datetime]]$CorroborationWindowStart = $null,
                [Nullable[datetime]]$CorroborationWindowEnd = $null,
                [ref]$RejectedDirCountVar,
                [Nullable[int]]$Tier2IssueNumber = $null
            )
            if ($null -ne $RejectedDirCountVar) { $RejectedDirCountVar.Value = 0 }

            # Two Tier-2 candidate events from a same-repo reused-branch-name
            # collision scenario (M8's own threat model): one inside the PR's
            # real lifetime, one from 3 days BEFORE it was even created (the
            # kind of stale, same-branch-name event M8 exists to exclude).
            # This mock applies the IDENTICAL window predicate cost-walker.ps1's
            # own Tier-2 loop applies (see Invoke-CostTranscriptWalk's
            # CorroborationWindowStart/End handling) so a non-null window
            # reaching this call actually changes what gets admitted — proving
            # the wiring, not just capturing it in transit.
            $inWindowEvent = @{ type = 'assistant'; gitBranch = $Branch; uuid = 'evt-in-window'; timestamp = '2026-06-02T00:00:00Z'; message = @{ content = @() } }
            $outOfWindowEvent = @{ type = 'assistant'; gitBranch = $Branch; uuid = 'evt-out-of-window'; timestamp = '2026-05-29T00:00:00Z'; message = @{ content = @() } }

            $admitted = [System.Collections.Generic.List[object]]::new()
            foreach ($ev in @($inWindowEvent, $outOfWindowEvent)) {
                $ts = [datetime]$ev['timestamp']
                if ($null -ne $CorroborationWindowStart -and $ts -lt $CorroborationWindowStart) { continue }
                if ($null -ne $CorroborationWindowEnd -and $ts -gt $CorroborationWindowEnd) { continue }
                $admitted.Add($ev)
            }
            return $admitted
        }
        function global:Invoke-CostCopilotWalk {
            param([string]$Branch, [string]$RepoRoot, [string]$OtelJsonlPath, [string]$WorkspaceFolderBasename = '')
            return @()
        }
        # Encodes admitted-event count into input tokens (100 per event) so the
        # final rendered/upserted body distinguishes "both events admitted"
        # (200) from "only the in-window event admitted" (100) without needing
        # the real cost-attribution.ps1 pipeline dot-sourced.
        function global:Get-CostAttribution {
            param([object[]]$Events, [string]$RateTablePath = '')
            $inputTokens = @($Events).Count * 100
            return @{
                ports                 = @{}
                orchestrator_overhead = @{ tokens = @{ input = $inputTokens; output = 0; cache_creation = 0; cache_read = 0 }; cost_estimate_usd = 0.0; cache_read_hit_ratio = 0.0 }
                dispatches            = @{ general_purpose_count = 0; unattributed_count = 0 }
                totals                = @{ total_cost_usd = 0.0; tokens = @{ input = $inputTokens; output = 0; cache_creation = 0; cache_read = 0 } }
            }
        }
        function global:Get-CostRollingHistory { param([int]$TimeoutSeconds = 10) return @{ timed_out = $false; entries = @() } }
        function global:Get-MostRecentRegimeCheckpoint { param([string]$Path) return $null }
        function global:Get-CostAnomalyFlags { param($ThisRun, [object[]]$RollingHistory, $RegimeCheckpoint) return @() }
        function global:Get-CostWalkerCurrentSessionId { param([string]$Slug, [string]$Branch, [string]$ParentCwd, [string]$RepoRoot = '') return '' }
        $script:UpsertedBody = $null
        function global:Find-OrUpsertComment {
            param($Type, $Number, $Marker, $Body)
            $script:UpsertedBody = $Body
            return $null
        }

        $previousInline = $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE
        $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE = '1'
        try {
            $result = Invoke-CostAttributionRepair -Pr $pr -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'
        }
        finally {
            $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE = $previousInline
        }

        $result.Attempted | Should -Be $true
        $result.Upserted | Should -Be $true
        $script:UpsertedBody | Should -Not -BeNullOrEmpty
        # Only the in-window event (100 input tokens) reached attribution — the
        # pre-createdAt event (which would make it 200) was excluded, proving
        # the M8 window bound actually took effect through this call path.
        $script:UpsertedBody | Should -Match 'input:\s*100'
        $script:UpsertedBody | Should -Not -Match 'input:\s*200'
    }

    It 'C10 regression pin: threads the branch-only Tier2IssueNumber (not the PR-body-derived IssueNumber) into the Tier-2 gate when the branch does not name an issue but the PR body does' {
        # Resolve-FCLLinkedIssueNumber checks the branch prefix FIRST and only
        # consults the PR body when the branch does not match — so the only
        # fixture shape where the two resolutions can actually diverge is a
        # non-issue-prefixed branch alongside a PR body that names an issue.
        # IssueNumber (IssueNumber-windowing, body-inclusive) must still resolve
        # via the body; Tier2IssueNumber (corroboration) must NOT — proving C2's
        # fix rejects the PR-body-derived number specifically for Tier 2.
        $pr = 823
        $originalBody = New-HarvestCompositeCommentBody -Pr $pr -CostSection "## Cost Pattern`n<!-- cost-pattern-data`nsession_completeness: unknown`npr: $pr`nbranch: HEAD`n-->"

        function global:Get-CostTranscriptSlug { param($CwdPath) return 'test-slug' }
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match "pr view $pr --json state,headRefName,body") {
                return '{"state":"MERGED","headRefName":"chore/unrelated-branch-name","body":"Fixes #999","createdAt":"2026-06-01T00:00:00Z","mergedAt":"2026-06-05T00:00:00Z"}'
            }
            if ($joined -match "pr view $pr --json comments") {
                return (@{ comments = @(@{ body = $originalBody; authorAssociation = 'OWNER' }) } | ConvertTo-Json -Depth 6 -Compress)
            }
            return ''
        }

        $script:CapturedWalkParams = $null
        function global:Invoke-CostTranscriptWalk {
            param(
                [string]$Slug, [string]$Branch, [string]$ParentCwd, [string]$ProjectsRoot = '',
                [Nullable[int]]$IssueNumber = $null, [string]$RepoRoot = '',
                [switch]$AdmitCorroboratedFallback,
                [Nullable[datetime]]$CorroborationWindowStart = $null,
                [Nullable[datetime]]$CorroborationWindowEnd = $null,
                [ref]$RejectedDirCountVar,
                [Nullable[int]]$Tier2IssueNumber = $null
            )
            $script:CapturedWalkParams = $PSBoundParameters
            if ($null -ne $RejectedDirCountVar) { $RejectedDirCountVar.Value = 0 }
            return @(@{ type = 'assistant'; gitBranch = $Branch; uuid = 'evt-1'; message = @{ content = @() } })
        }
        function global:Invoke-CostCopilotWalk {
            param([string]$Branch, [string]$RepoRoot, [string]$OtelJsonlPath, [string]$WorkspaceFolderBasename = '')
            return @()
        }
        function global:Get-CostAttribution {
            param([object[]]$Events, [string]$RateTablePath = '')
            return @{
                ports                 = @{}
                orchestrator_overhead = @{ tokens = @{ input = 10; output = 5; cache_creation = 0; cache_read = 0 }; cost_estimate_usd = 0.0; cache_read_hit_ratio = 0.0 }
                dispatches            = @{ general_purpose_count = 0; unattributed_count = 0 }
                totals                = @{ total_cost_usd = 0.0; tokens = @{ input = 10; output = 5; cache_creation = 0; cache_read = 0 } }
            }
        }
        function global:Get-CostRollingHistory { param([int]$TimeoutSeconds = 10) return @{ timed_out = $false; entries = @() } }
        function global:Get-MostRecentRegimeCheckpoint { param([string]$Path) return $null }
        function global:Get-CostAnomalyFlags { param($ThisRun, [object[]]$RollingHistory, $RegimeCheckpoint) return @() }
        function global:Get-CostWalkerCurrentSessionId { param([string]$Slug, [string]$Branch, [string]$ParentCwd, [string]$RepoRoot = '') return '' }
        function global:Find-OrUpsertComment { return $null }

        $previousInline = $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE
        $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE = '1'
        try {
            $null = Invoke-CostAttributionRepair -Pr $pr -ParentCwd 'C:\fake\cwd' -RepoRoot 'C:\fake\repo'
        }
        finally {
            $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE = $previousInline
        }

        $script:CapturedWalkParams | Should -Not -BeNullOrEmpty
        $script:CapturedWalkParams['IssueNumber'] | Should -Be 999
        $script:CapturedWalkParams.ContainsKey('Tier2IssueNumber') | Should -Be $true
        $script:CapturedWalkParams['Tier2IssueNumber'] | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# End-to-end regression pins (issue #825 post-review fix cycle, C1/C8/C9): the
# ENTIRE real pipeline (real Invoke-CostSessionRender -> real
# Invoke-CostTranscriptWalk -> real Get-CostAttribution) through
# Invoke-CostAttributionRepair, not the mocked-Invoke-CostTranscriptWalk
# composition tests above. Only Get-CostRollingHistory, Get-MostRecentRegimeCheckpoint,
# Get-CostAnomalyFlags, Invoke-CostCopilotWalk, gh, and Find-OrUpsertComment are
# mocked — everything that decides HOW MANY events get attributed runs for real.
# This is what makes C8 (the real walker honoring the test-only projects-root
# override) and C9 (the real walker's own M7 dedup guard, reached through this
# exact composition path) provable at all.
# ---------------------------------------------------------------------------
Describe 'Invoke-CostAttributionRepair end-to-end regression pins (issue #825 post-review fix)' {

    BeforeAll {
        $script:E2EPathNormalizeLibPath = Join-Path $script:RepoRoot '.github/scripts/lib/path-normalize.ps1'
        $script:E2EWalkerLibPath = Join-Path $script:RepoRoot '.github/scripts/lib/cost-walker.ps1'
        $script:E2ECompletenessLibPath = Join-Path $script:RepoRoot '.github/scripts/lib/cost-completeness.ps1'
        $script:E2ERendererLibPath = Join-Path $script:RepoRoot '.github/scripts/lib/cost-pattern-renderer.ps1'
        $script:E2ESessionRenderLibPath = Join-Path $script:RepoRoot '.github/scripts/lib/cost-session-render.ps1'

        # Deliberately NOT dot-sourcing cost-walker-copilot.ps1 or cost-attribution.ps1
        # here: dot-sourcing runs their function definitions into this BeforeAll's own
        # (Describe-container) scope, which sits BETWEEN each It's scope and true global
        # scope in PowerShell's function-resolution walk. A same-named `function
        # global:X` mock defined inside an It body is resolved AFTER that container
        # scope, so it would be silently shadowed by the real dot-sourced version the
        # moment production code (reached via the real, dot-sourced Invoke-CostTranscriptWalk
        # / Invoke-CostSessionRender) calls Invoke-CostCopilotWalk or Get-CostAttribution —
        # this was empirically confirmed: the REAL Invoke-CostCopilotWalk ran instead of
        # the mock and scanned this machine's actual git reflog, which is what made these
        # tests slow/resource-heavy before this fix. Every It below mocks both functions
        # instead, and neither one needs to be real for what these two tests verify.
        foreach ($libPath in @(
                $script:E2EPathNormalizeLibPath, $script:E2EWalkerLibPath,
                $script:E2ECompletenessLibPath, $script:E2ERendererLibPath,
                $script:E2ESessionRenderLibPath
            )) {
            if (Test-Path $libPath) { . $libPath }
        }

        function script:Write-E2ETestJsonl {
            param([string]$Path, [hashtable[]]$Events)
            $dir = Split-Path -Parent $Path
            if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
            $Events | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 10 } | Set-Content -Path $Path -Encoding utf8NoBOM
        }
    }

    It 'C8 regression pin: writes nothing when the REAL re-walk (real Invoke-CostTranscriptWalk, pointed at a temp projects root with no matching transcripts via the test-only env override) finds no activity' {
        $pr = 824
        $originalBody = New-HarvestCompositeCommentBody -Pr $pr -PortReportsMarker '### Port Reports (C8 real empty re-walk)' -CostSection "## Cost Pattern`n<!-- cost-pattern-data`nsession_completeness: unknown`npr: $pr`nbranch: HEAD`n-->"

        $tmpProjects = Join-Path ([IO.Path]::GetTempPath()) "cost-c8-empty-$([System.Guid]::NewGuid())"
        $null = New-Item -ItemType Directory -Path $tmpProjects -Force

        # Get-CostTranscriptSlug and Get-CostWalkerCurrentSessionId are deliberately left
        # REAL here (not mocked — see the BeforeAll comment on why a same-named global
        # mock would be silently shadowed by cost-walker.ps1's own dot-sourced version
        # anyway). Both are safe unmocked for this scenario: whatever real slug they
        # resolve for $script:RepoRoot, $tmpProjects is freshly empty so no directory
        # will ever match it.
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match "pr view $pr --json state,headRefName,body") {
                return '{"state":"MERGED","headRefName":"feature/issue-824-empty","body":"Fixes #824","createdAt":"2026-06-01T00:00:00Z","mergedAt":"2026-06-05T00:00:00Z"}'
            }
            if ($joined -match "pr view $pr --json comments") {
                return (@{ comments = @(@{ body = $originalBody; authorAssociation = 'OWNER' }) } | ConvertTo-Json -Depth 6 -Compress)
            }
            return ''
        }
        function global:Invoke-CostCopilotWalk {
            param([string]$Branch, [string]$RepoRoot, [string]$OtelJsonlPath, [string]$WorkspaceFolderBasename = '')
            return @()
        }
        function global:Get-CostRollingHistory { param([int]$TimeoutSeconds = 10) return @{ timed_out = $false; entries = @() } }
        function global:Get-MostRecentRegimeCheckpoint { param([string]$Path) return $null }
        function global:Get-CostAnomalyFlags { param($ThisRun, [object[]]$RollingHistory, $RegimeCheckpoint) return @() }
        # Get-CostWalkerCurrentSessionId is left REAL too (same shadowing reason as
        # Get-CostTranscriptSlug above — it's defined in cost-walker.ps1 alongside
        # Invoke-CostTranscriptWalk, which this Describe needs real). It does not honor
        # the test-only projects-root override (out of C8's scope — only
        # Invoke-CostTranscriptWalk was fixed), so it scans this machine's real
        # ~/.claude/projects; that is slower but bounded, and its return value is purely
        # informational (persisted session_id metadata) — not read by any assertion below.
        $script:E2EUpsertCalled = $false
        function global:Find-OrUpsertComment { $script:E2EUpsertCalled = $true; return $null }

        $previousInline = $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE
        $previousProjectsRoot = $env:FRAME_CREDIT_LEDGER_TEST_CLAUDE_PROJECTS_ROOT
        $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE = '1'
        $env:FRAME_CREDIT_LEDGER_TEST_CLAUDE_PROJECTS_ROOT = $tmpProjects
        try {
            $result = Invoke-CostAttributionRepair -Pr $pr -ParentCwd $script:RepoRoot -RepoRoot $script:RepoRoot
        }
        finally {
            $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE = $previousInline
            $env:FRAME_CREDIT_LEDGER_TEST_CLAUDE_PROJECTS_ROOT = $previousProjectsRoot
            Remove-Item -Recurse -Force $tmpProjects -ErrorAction SilentlyContinue
        }

        # Proves the C8 wiring: without the projects-root override reaching the REAL
        # Invoke-CostTranscriptWalk, the walk would fall back to the real user profile
        # and this assertion would be unreliable (machine-dependent). With it wired,
        # the temp root is authoritative and guaranteed empty.
        $result.Attempted | Should -Be $true
        $result.Upserted | Should -Be $false
        $result.Signal | Should -Match 'no matching transcripts'
        $script:E2EUpsertCalled | Should -Be $false
    }

    It 'C9 regression pin: single-counts (not double-counts) a spanning session admitted via both the primary Tier-1 dir and a Tier-2-corroborated worktree dir sharing the same session id' {
        $remoteProbe = @(& git -C $script:RepoRoot remote get-url origin 2>&1) | Select-Object -First 1
        if ($global:LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($remoteProbe)) {
            Set-ItResult -Skipped -Because 'cannot resolve test repo remote for Tier-2 identity resolution'
            return
        }

        $pr = 825
        $branch = 'feature/issue-825-spanning-session'
        $sessionId = 'spanning-session-825'
        $originalBody = New-HarvestCompositeCommentBody -Pr $pr -PortReportsMarker '### Port Reports (C9 spanning session)' -CostSection "## Cost Pattern`n<!-- cost-pattern-data`nsession_completeness: unknown`npr: $pr`nbranch: HEAD`n-->"

        $tmpProjects = Join-Path ([IO.Path]::GetTempPath()) "cost-c9-spanning-$([System.Guid]::NewGuid())"
        $null = New-Item -ItemType Directory -Path $tmpProjects -Force
        $missingCwd = Join-Path ([IO.Path]::GetTempPath()) "cost-c9-missing-worktree-$([System.Guid]::NewGuid())"

        # Real (non-mocked) slug derivation — resolved BEFORE Get-CostTranscriptSlug is
        # mocked below, so the primary dir's name matches exactly what the real walk's
        # primary-slug fallback (script:Resolve-CostWalkerPrimarySlugDir) looks for.
        $primarySlug = Get-CostTranscriptSlug -CwdPath $script:RepoRoot
        $primaryDir = Join-Path $tmpProjects $primarySlug
        $null = New-Item -ItemType Directory -Path $primaryDir -Force

        $candidateDir = Join-Path $tmpProjects 'corroborated-worktree-candidate'
        $null = New-Item -ItemType Directory -Path $candidateDir -Force

        # Primary dir's session file: a phase marker naming issue 825 (M14 cross-file
        # corroboration signal, consumed by the Tier-2 candidate below) plus the
        # session's own admitted assistant event (strict cwd+branch match).
        $phaseMarkerEvent = @{
            type      = 'user'
            message   = @{ content = '<command-name>/plan</command-name><command-args>825</command-args>' }
            gitBranch = 'main'
            timestamp = '2026-06-01T00:00:00Z'
        }
        $primaryAssistantEvent = @{
            type      = 'assistant'
            uuid      = 'evt-spanning-1'
            timestamp = '2026-06-02T00:00:00Z'
            cwd       = $script:RepoRoot
            gitBranch = $branch
            message   = @{ usage = @{ input_tokens = 10; output_tokens = 5 }; content = @() }
        }
        # Tier-2 candidate: SAME session id (file BaseName) and SAME event uuid as the
        # primary dir's event — simulating a deleted-worktree checkout of the identical
        # session. cwd points at a path that does not exist on disk (M9 cwd-absent
        # trigger); branch matches (Tier-2 branch-matched-file signal).
        $candidateAssistantEvent = @{
            type      = 'assistant'
            uuid      = 'evt-spanning-1'
            timestamp = '2026-06-02T00:05:00Z'
            cwd       = $missingCwd
            gitBranch = $branch
            message   = @{ usage = @{ input_tokens = 10; output_tokens = 5 }; content = @() }
        }

        script:Write-E2ETestJsonl -Path (Join-Path $primaryDir "$sessionId.jsonl") -Events @($phaseMarkerEvent, $primaryAssistantEvent)
        script:Write-E2ETestJsonl -Path (Join-Path $candidateDir "$sessionId.jsonl") -Events @($candidateAssistantEvent)

        # Get-CostTranscriptSlug and Get-CostWalkerCurrentSessionId are deliberately left
        # REAL (see the BeforeAll comment — a same-named global mock would be silently
        # shadowed by cost-walker.ps1's own dot-sourced version anyway). This is exactly
        # what we want here: $primaryDir was named using this same real function against
        # this same $script:RepoRoot, so the real re-resolution inside
        # Invoke-CostAttributionRepair lands on the identical slug/dir.
        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -match "pr view $pr --json state,headRefName,body") {
                return (@{ state = 'MERGED'; headRefName = $branch; body = 'Fixes #825'; createdAt = '2026-06-01T00:00:00Z'; mergedAt = '2026-06-05T00:00:00Z' } | ConvertTo-Json -Compress)
            }
            if ($joined -match "pr view $pr --json comments") {
                return (@{ comments = @(@{ body = $originalBody; authorAssociation = 'OWNER' }) } | ConvertTo-Json -Depth 6 -Compress)
            }
            return ''
        }
        function global:Invoke-CostCopilotWalk {
            param([string]$Branch, [string]$RepoRoot, [string]$OtelJsonlPath, [string]$WorkspaceFolderBasename = '')
            return @()
        }
        # Deterministic token accounting keyed on the REAL walk's own event count: 100
        # input tokens per DISTINCT admitted event, so single-counting (100) reads
        # differently from double-counting (200) in the final rendered/upserted body.
        function global:Get-CostAttribution {
            param([object[]]$Events, [string]$RateTablePath = '')
            $inputTokens = @($Events).Count * 100
            return @{
                ports                 = @{}
                orchestrator_overhead = @{ tokens = @{ input = $inputTokens; output = 0; cache_creation = 0; cache_read = 0 }; cost_estimate_usd = 0.0; cache_read_hit_ratio = 0.0 }
                dispatches            = @{ general_purpose_count = 0; unattributed_count = 0 }
                totals                = @{ total_cost_usd = 0.0; tokens = @{ input = $inputTokens; output = 0; cache_creation = 0; cache_read = 0 } }
            }
        }
        function global:Get-CostRollingHistory { param([int]$TimeoutSeconds = 10) return @{ timed_out = $false; entries = @() } }
        function global:Get-MostRecentRegimeCheckpoint { param([string]$Path) return $null }
        function global:Get-CostAnomalyFlags { param($ThisRun, [object[]]$RollingHistory, $RegimeCheckpoint) return @() }
        # Get-CostWalkerCurrentSessionId is left REAL too — see the C8 test's comment
        # above; its return value here is purely informational and unread by any assertion.
        $script:E2EUpsertedBody = $null
        function global:Find-OrUpsertComment {
            param($Type, $Number, $Marker, $Body)
            $script:E2EUpsertedBody = $Body
            return $null
        }

        $previousInline = $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE
        $previousProjectsRoot = $env:FRAME_CREDIT_LEDGER_TEST_CLAUDE_PROJECTS_ROOT
        $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE = '1'
        $env:FRAME_CREDIT_LEDGER_TEST_CLAUDE_PROJECTS_ROOT = $tmpProjects
        try {
            $result = Invoke-CostAttributionRepair -Pr $pr -ParentCwd $script:RepoRoot -RepoRoot $script:RepoRoot
        }
        finally {
            $env:FRAME_CREDIT_LEDGER_TEST_WALKER_INLINE = $previousInline
            $env:FRAME_CREDIT_LEDGER_TEST_CLAUDE_PROJECTS_ROOT = $previousProjectsRoot
            Remove-Item -Recurse -Force $tmpProjects -ErrorAction SilentlyContinue
            Remove-Item -Recurse -Force $missingCwd -ErrorAction SilentlyContinue
        }

        $result.Attempted | Should -Be $true
        $result.Upserted | Should -Be $true
        $script:E2EUpsertedBody | Should -Not -BeNullOrEmpty
        $script:E2EUpsertedBody | Should -Match 'input:\s*100'
        $script:E2EUpsertedBody | Should -Not -Match 'input:\s*200'
    }
}
