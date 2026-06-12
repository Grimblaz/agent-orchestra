#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '..' '..' '..' 'skills' 'upstream-onboarding' 'scripts' 'get-issue-drift-core.ps1'
    . $scriptPath
}

Describe 'Get-IssueDrift' {

    # ----------------------------------------------------------------
    # (a) Age-gate boundary tests
    # ----------------------------------------------------------------
    Context 'age gate' {

        It 'returns skipped for 6-day-old issue without consuming PrListOverride' {
            # 6 days old: ageHours ~= 144, which is < 168 (7*24) → skipped
            $recentDate = [DateTimeOffset]::UtcNow.AddDays(-6).ToString('o')
            $issueJson = '{"number":683,"title":"t","body":"","createdAt":"' + $recentDate + '"}'
            # Passing invalid JSON as PrListJsonOverride — if consumed, ConvertFrom-Json throws.
            # The age gate must short-circuit before parsing it.
            $result = Get-IssueDrift -IssueNumber 683 -ThresholdDays 7 `
                -IssueJsonOverride $issueJson `
                -PrListJsonOverride 'SENTINEL_SHOULD_NOT_BE_CALLED'
            $result.skipped | Should -Be 'below-threshold'
        }

        It 'returns skipped for 167h-old issue (1h below the 7-day threshold)' {
            # Gate: ageHours -le (ThresholdDays * 24). 167h is strictly below 168h → skipped.
            # Testing 1h inside the boundary is more reliable than testing exactly 168h,
            # since dynamic time comparison has sub-millisecond drift at the exact boundary.
            $recentDate = [DateTimeOffset]::UtcNow.AddHours(-167).ToString('o')
            $issueJson = '{"number":683,"title":"t","body":"","createdAt":"' + $recentDate + '"}'
            $result = Get-IssueDrift -IssueNumber 683 -ThresholdDays 7 `
                -IssueJsonOverride $issueJson `
                -PrListJsonOverride 'SENTINEL_SHOULD_NOT_BE_CALLED'
            $result.skipped | Should -Be 'below-threshold'
        }

        It 'scans for 8-day-old issue' {
            # 8 days old: ageHours ~= 192, which is > 168 → scanned
            $oldDate = [DateTimeOffset]::UtcNow.AddDays(-8).ToString('o')
            $issueJson = '{"number":683,"title":"t","body":"","createdAt":"' + $oldDate + '"}'
            $mergedDate = [DateTimeOffset]::UtcNow.AddDays(-7).ToString('o')
            $prJson = '[{"number":1,"title":"PR 1","mergedAt":"' + $mergedDate + '","changedFiles":1,"files":[{"path":"README.md","additions":1,"deletions":0}]}]'
            $result = Get-IssueDrift -IssueNumber 683 -ThresholdDays 7 `
                -IssueJsonOverride $issueJson `
                -PrListJsonOverride $prJson
            # Should NOT have skipped — the function ran and returned a scan result
            $result.skipped | Should -BeNullOrEmpty
            $result.PSObject.Properties.Name | Should -Contain 'total_merged_since'
        }
    }

    # ----------------------------------------------------------------
    # (b) Date boundary test — PR merged before createdAt on same calendar day
    # ----------------------------------------------------------------
    Context 'date boundary' {

        It 'excludes PR merged before createdAt on same calendar day' {
            # Issue created at noon; PR merged at 08:00 same day (4 hours BEFORE filing)
            $issueJson = '{"number":683,"title":"Test issue","body":"some body with `backtick-token`","createdAt":"2026-06-05T12:00:00Z"}'
            # PR merged at 08:00 — strictly before createdAt 12:00 → excluded by post-filter
            $prJson = '[{"number":100,"title":"feat: something","mergedAt":"2026-06-05T08:00:00Z","changedFiles":1,"files":[{"path":"backtick-token","additions":1,"deletions":0}]}]'
            $result = Get-IssueDrift -IssueNumber 683 -ThresholdDays 7 -Force `
                -IssueJsonOverride $issueJson `
                -PrListJsonOverride $prJson
            # PR merged before createdAt → excluded by post-filter → zero candidates → intersection: none
            $result.intersection | Should -Be 'none'
            $result.total_merged_since | Should -Be 0
        }
    }

    # ----------------------------------------------------------------
    # (b2) Offset-robustness test
    # ----------------------------------------------------------------
    Context 'offset robustness' {

        It 'compares non-Z offsets correctly' {
            # Issue createdAt: 2026-06-05T16:00:00+04:00 = 2026-06-05T12:00:00Z
            # PR1 mergedAt:   2026-06-05T13:00:00+01:00 = 2026-06-05T12:00:00Z  (exactly at createdAt, not strictly after → excluded)
            # PR2 mergedAt:   2026-06-05T14:00:00+01:00 = 2026-06-05T13:00:00Z  (1 hour after createdAt → included)
            $issueJson = '{"number":683,"title":"t","body":"some `README.md` ref","createdAt":"2026-06-05T16:00:00+04:00"}'
            $prJson = '[
                {"number":10,"title":"PR 10","mergedAt":"2026-06-05T13:00:00+01:00","changedFiles":1,"files":[{"path":"README.md","additions":1,"deletions":0}]},
                {"number":11,"title":"PR 11","mergedAt":"2026-06-05T14:00:00+01:00","changedFiles":1,"files":[{"path":"README.md","additions":1,"deletions":0}]}
            ]'
            $result = Get-IssueDrift -IssueNumber 683 -ThresholdDays 7 -Force `
                -IssueJsonOverride $issueJson `
                -PrListJsonOverride $prJson
            # PR1 is at exactly createdAt (not strictly after) → excluded
            # PR2 is 1 hour after → included
            # total_merged_since should be 1 (only PR2 passes the post-filter)
            $result.total_merged_since | Should -Be 1
        }
    }

    # ----------------------------------------------------------------
    # (c) Truncation test — 200-row PR fixture
    # ----------------------------------------------------------------
    Context 'truncation' {

        It 'sets truncated:true when PR list hits 200' {
            $oldDate = [DateTimeOffset]::UtcNow.AddDays(-30).ToString('o')
            $issueJson = '{"number":683,"title":"t","body":"","createdAt":"' + $oldDate + '"}'
            # Generate 200 PR entries with mergedAt after createdAt
            $mergedDate = [DateTimeOffset]::UtcNow.AddDays(-10).ToString('o')
            $prs = 1..200 | ForEach-Object {
                @{number=$_; title="PR $_"; mergedAt=$mergedDate; changedFiles=1; files=@(@{path="README.md";additions=1;deletions=0})}
            }
            $prJson = $prs | ConvertTo-Json -Depth 5
            $result = Get-IssueDrift -IssueNumber 683 -ThresholdDays 7 `
                -IssueJsonOverride $issueJson `
                -PrListJsonOverride $prJson
            $result.truncated | Should -Be $true
        }
    }

    # ----------------------------------------------------------------
    # (d) Token matching test — #591-shaped tokens
    # ----------------------------------------------------------------
    Context 'token matching' {

        It 'strips suffixes, normalizes backslashes, matches directory prefixes, and resolves leading-/ tokens' {
            $issueJson = '{"number":591,"title":"t","body":"some `skills/plan-authoring/SKILL.md:309` and `plan-authoring.md:309` and `/plan` and `skills/upstream-onboarding/` and `skills\\plan-authoring\\SKILL.md` refs","createdAt":"2020-01-01T00:00:00Z"}'
            # PRs:
            # PR 1: touches skills/plan-authoring/SKILL.md  (path match + backslash normalization)
            # PR 2: touches skills/plan-authoring/plan-authoring.md (basename-only token after suffix strip)
            # PR 3: touches unrelated/file.txt (should NOT match any token)
            # PR 4: touches skills/upstream-onboarding/SKILL.md (directory-prefix match)
            # PR 5: touches other/plan (leading-/ token /plan → strips to 'plan' → suffix-matches 'other/plan')
            $prJson = '[
                {"number":1,"title":"PR path match","mergedAt":"2020-01-02T00:00:00Z","changedFiles":1,"files":[{"path":"skills/plan-authoring/SKILL.md","additions":5,"deletions":1}]},
                {"number":2,"title":"PR basename match","mergedAt":"2020-01-02T00:00:00Z","changedFiles":1,"files":[{"path":"skills/plan-authoring/plan-authoring.md","additions":1,"deletions":0}]},
                {"number":3,"title":"PR no match","mergedAt":"2020-01-02T00:00:00Z","changedFiles":1,"files":[{"path":"unrelated/file.txt","additions":1,"deletions":0}]},
                {"number":4,"title":"PR dir prefix","mergedAt":"2020-01-02T00:00:00Z","changedFiles":1,"files":[{"path":"skills/upstream-onboarding/SKILL.md","additions":1,"deletions":0}]},
                {"number":5,"title":"PR leading-slash match","mergedAt":"2020-01-02T00:00:00Z","changedFiles":1,"files":[{"path":"other/plan","additions":1,"deletions":0}]}
            ]'
            $result = Get-IssueDrift -IssueNumber 591 -ThresholdDays 7 `
                -IssueJsonOverride $issueJson `
                -PrListJsonOverride $prJson
            $result.intersection | Should -Not -Be 'none'
            $result.candidates | Should -Not -BeNullOrEmpty
            $candidateNumbers = $result.candidates | ForEach-Object { $_.number }
            # PR 1: path match + backslash normalization
            $candidateNumbers | Should -Contain 1
            # PR 4: directory-prefix match
            $candidateNumbers | Should -Contain 4
            # PR 5: leading-/ token /plan strips to 'plan' → matches other/plan via suffix
            $candidateNumbers | Should -Contain 5
            # PR 3: unrelated file — no token matches
            $candidateNumbers | Should -Not -Contain 3
        }

        It 'matches tokens case-insensitively against file paths' {
            # Token in issue body is uppercase; file path in PR is lowercase → should still match
            $issueJson = '{"number":683,"title":"t","body":"some `README.MD` ref","createdAt":"2020-01-01T00:00:00Z"}'
            $prJson = '[{"number":10,"title":"PR ci","mergedAt":"2020-01-02T00:00:00Z","changedFiles":1,"files":[{"path":"readme.md","additions":1,"deletions":0}]}]'
            $result = Get-IssueDrift -IssueNumber 683 -ThresholdDays 7 `
                -IssueJsonOverride $issueJson `
                -PrListJsonOverride $prJson
            $result.candidates | Should -Not -BeNullOrEmpty
            $result.candidates[0].number | Should -Be 10
        }
    }

    # ----------------------------------------------------------------
    # (e) ExcludePaths override test
    # ----------------------------------------------------------------
    Context 'ExcludePaths' {

        It 'override changes the exclusion set — .github/ path excluded when in ExcludePaths' {
            $issueJson = '{"number":683,"title":"t","body":"some `.github/workflows/ci.yml` ref","createdAt":"2020-01-01T00:00:00Z"}'
            # PR touches only .github/workflows/ci.yml
            $prJson = '[{"number":50,"title":"CI update","mergedAt":"2020-01-02T00:00:00Z","changedFiles":1,"files":[{"path":".github/workflows/ci.yml","additions":1,"deletions":0}]}]'
            $result = Get-IssueDrift -IssueNumber 683 -ThresholdDays 7 `
                -IssueJsonOverride $issueJson `
                -PrListJsonOverride $prJson `
                -ExcludePaths @('.github/')
            # The only matched path is .github/workflows/ci.yml which is excluded → zero candidates
            $result.intersection | Should -Be 'none'
        }

        It 'excludes paths case-insensitively when ExcludePaths entry has different casing than file path' {
            # ExcludePaths uses uppercase prefix; file path is lowercase → should still be excluded
            $issueJson = '{"number":683,"title":"t","body":"some `.claude-plugin/plugin.json` ref","createdAt":"2020-01-01T00:00:00Z"}'
            $prJson = '[{"number":60,"title":"plugin update","mergedAt":"2020-01-02T00:00:00Z","changedFiles":1,"files":[{"path":".claude-plugin/plugin.json","additions":1,"deletions":0}]}]'
            $result = Get-IssueDrift -IssueNumber 683 -ThresholdDays 7 `
                -IssueJsonOverride $issueJson `
                -PrListJsonOverride $prJson `
                -ExcludePaths @('.CLAUDE-PLUGIN/')
            $result.intersection | Should -Be 'none'
        }

        It 'default exclusion set filters .claude-plugin/ candidates' {
            # Do NOT pass -ExcludePaths — let the default apply.
            # Default ExcludePaths includes '.claude-plugin/'
            $issueJson = '{"number":683,"title":"t","body":"some `.claude-plugin/plugin.json` ref","createdAt":"2020-01-01T00:00:00Z"}'
            $prJson = '[{"number":60,"title":"plugin update","mergedAt":"2020-01-02T00:00:00Z","changedFiles":1,"files":[{"path":".claude-plugin/plugin.json","additions":1,"deletions":0}]}]'
            $result = Get-IssueDrift -IssueNumber 683 -ThresholdDays 7 `
                -IssueJsonOverride $issueJson `
                -PrListJsonOverride $prJson
            # .claude-plugin/ is in the default ExcludePaths → zero candidates
            $result.intersection | Should -Be 'none'
        }
    }

    # ----------------------------------------------------------------
    # (f) Cap + more_count test
    # ----------------------------------------------------------------
    Context 'cap and more_count' {

        It 'caps candidates and sets more_count correctly' {
            # 12 PRs each touching the same token-matched path; cap at 5
            $issueJson = '{"number":683,"title":"t","body":"some `README.md` ref","createdAt":"2020-01-01T00:00:00Z"}'
            $mergedBase = [DateTimeOffset]::new(2020, 1, 2, 0, 0, 0, [TimeSpan]::Zero)
            $prs = 1..12 | ForEach-Object {
                $mergedAt = $mergedBase.AddHours($_).ToString('o')
                @{number=$_; title="PR $_"; mergedAt=$mergedAt; changedFiles=1; files=@(@{path="README.md";additions=1;deletions=0})}
            }
            $prJson = $prs | ConvertTo-Json -Depth 5
            $result = Get-IssueDrift -IssueNumber 683 -ThresholdDays 7 -Cap 5 `
                -IssueJsonOverride $issueJson `
                -PrListJsonOverride $prJson
            $result.candidates.Count | Should -Be 5
            $result.more_count | Should -Be 7
        }
    }

    # ----------------------------------------------------------------
    # (g) Output shape distinction tests
    # ----------------------------------------------------------------
    Context 'output shapes' {

        It 'returns skipped shape for below-threshold' {
            # Very recent issue (today)
            $todayDate = [DateTimeOffset]::UtcNow.ToString('o')
            $issueJson = '{"number":683,"title":"t","body":"","createdAt":"' + $todayDate + '"}'
            $result = Get-IssueDrift -IssueNumber 683 -ThresholdDays 7 `
                -IssueJsonOverride $issueJson `
                -PrListJsonOverride 'SENTINEL_SHOULD_NOT_BE_CALLED'
            $result.skipped | Should -Be 'below-threshold'
        }

        It 'returns error shape for malformed issue JSON' {
            $result = Get-IssueDrift -IssueNumber 683 `
                -IssueJsonOverride 'not-valid-json' `
                -PrListJsonOverride '[]'
            $result.error | Should -Not -BeNullOrEmpty
            $result.PSObject.Properties.Name | Should -Not -Contain 'skipped'
            $result.PSObject.Properties.Name | Should -Not -Contain 'candidates'
        }

        It 'returns error shape for issue JSON with non-numeric number field' {
            # Guarded parsing: [int]::TryParse should fail and return a structured error
            $result = Get-IssueDrift -IssueNumber 683 `
                -IssueJsonOverride '{"number":"not-a-number","title":"t","body":"","createdAt":"2020-01-01T00:00:00Z"}' `
                -PrListJsonOverride '[]'
            $result.error | Should -Not -BeNullOrEmpty
            $result.PSObject.Properties.Name | Should -Not -Contain 'candidates'
        }

        It 'returns intersection:none for empty body' {
            $issueJson = '{"number":683,"title":"t","body":"","createdAt":"2020-01-01T00:00:00Z"}'
            $prJson = '[{"number":1,"title":"PR 1","mergedAt":"2020-01-02T00:00:00Z","changedFiles":1,"files":[{"path":"README.md","additions":1,"deletions":0}]}]'
            $result = Get-IssueDrift -IssueNumber 683 -ThresholdDays 7 `
                -IssueJsonOverride $issueJson `
                -PrListJsonOverride $prJson
            $result.intersection | Should -Be 'none'
            $result.PSObject.Properties.Name | Should -Contain 'total_merged_since'
        }

        It 'returns intersection:none for whitespace body' {
            $issueJson = '{"number":683,"title":"t","body":"   ","createdAt":"2020-01-01T00:00:00Z"}'
            $prJson = '[{"number":1,"title":"PR 1","mergedAt":"2020-01-02T00:00:00Z","changedFiles":1,"files":[{"path":"README.md","additions":1,"deletions":0}]}]'
            $result = Get-IssueDrift -IssueNumber 683 -ThresholdDays 7 `
                -IssueJsonOverride $issueJson `
                -PrListJsonOverride $prJson
            $result.intersection | Should -Be 'none'
            $result.PSObject.Properties.Name | Should -Contain 'total_merged_since'
        }
    }

    # ----------------------------------------------------------------
    # (h) files_truncated test
    # ----------------------------------------------------------------
    Context 'files_truncated' {

        It 'sets files_truncated when files.Count lt changedFiles' {
            # changedFiles=5 but only 1 file in the list → files_truncated: $true
            $issueJson = '{"number":683,"title":"t","body":"some `skills/upstream-onboarding/SKILL.md` ref","createdAt":"2020-01-01T00:00:00Z"}'
            $prJson = '[{"number":50,"title":"big PR","mergedAt":"2020-01-02T00:00:00Z","changedFiles":5,"files":[{"path":"skills/upstream-onboarding/SKILL.md","additions":1,"deletions":0}]}]'
            $result = Get-IssueDrift -IssueNumber 683 -ThresholdDays 7 `
                -IssueJsonOverride $issueJson `
                -PrListJsonOverride $prJson
            # The PR should appear as a candidate since files_truncated is true but prFiles is non-null
            $result.candidates | Should -Not -BeNullOrEmpty
            $result.candidates[0].files_truncated | Should -Be $true
        }
    }

    # ----------------------------------------------------------------
    # (i) files_unavailable_count test — PR with null files
    # ----------------------------------------------------------------
    Context 'files unavailability' {

        It 'counts PRs with null files in files_unavailable_count' {
            $issueJson = '{"number":683,"title":"t","body":"some `README.md` ref","createdAt":"2020-01-01T00:00:00Z"}'
            # PR 1: files:null — cannot determine path overlap, dropped and counted
            # PR 2: normal files — matched and returned as candidate
            $prJson = '[
                {"number":1,"title":"PR null files","mergedAt":"2020-01-02T00:00:00Z","changedFiles":3,"files":null},
                {"number":2,"title":"PR normal","mergedAt":"2020-01-02T00:00:00Z","changedFiles":1,"files":[{"path":"README.md","additions":1,"deletions":0}]}
            ]'
            $result = Get-IssueDrift -IssueNumber 683 -ThresholdDays 7 `
                -IssueJsonOverride $issueJson `
                -PrListJsonOverride $prJson
            $result.candidates | Should -Not -BeNullOrEmpty
            $result.candidates[0].number | Should -Be 2
            $result.files_unavailable_count | Should -Be 1
        }
    }
}

Describe 'Get-IssueDrift wrapper (get-issue-drift.ps1)' {

    It 'outputs valid JSON with expected shape when invoked as a child process' {
        $wrapperPath = Join-Path $PSScriptRoot '..' '..' '..' 'skills' 'upstream-onboarding' 'scripts' 'get-issue-drift.ps1'
        $issueJson = '{"number":683,"title":"t","body":"some `README.md` ref","createdAt":"2020-01-01T00:00:00Z"}'
        $prJson = '[{"number":1,"title":"PR 1","mergedAt":"2020-01-02T00:00:00Z","changedFiles":1,"files":[{"path":"README.md","additions":1,"deletions":0}]}]'
        $stdout = pwsh -NoProfile -File $wrapperPath -IssueNumber 683 -ThresholdDays 7 `
            -IssueJsonOverride $issueJson -PrListJsonOverride $prJson
        $result = $stdout | ConvertFrom-Json
        $result | Should -Not -BeNullOrEmpty
        $result.PSObject.Properties.Name | Should -Contain 'issue_number'
        $result.candidates | Should -Not -BeNullOrEmpty
        $result.candidates[0].number | Should -Be 1
    }
}
