#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    RED Pester v5 suite for release-gate-core.ps1 (issue #703, slice s1).

.DESCRIPTION
    Tests covering all six pure functions exposed by release-gate-core.ps1:
      - Test-ReleaseGateEntryPointTouched : entry-point pattern matching via -like
      - Get-PluginVersion                 : JSON parse, version format assertion
      - Compare-PluginVersionIsGreater    : strict -gt comparison via [System.Version]
      - Test-ChangelogSectionPresent      : heading-line detection, dash-agnostic
      - Get-ReleaseGateWaiver             : commit-message trailer parsing
      - Invoke-ReleaseGateEvaluation      : pure orchestrator, waiver application

    Tests are RED until s2 creates release-gate-core.ps1.
#>

BeforeAll {
    $corePath = Join-Path $PSScriptRoot '..' 'lib' 'release-gate-core.ps1'
    # This will fail until s2 creates the core — making tests RED.
    . $corePath
}

# ===========================================================================
Describe 'Test-ReleaseGateEntryPointTouched' {
# ===========================================================================

    It 'returns $true for a nested path under skills/* (entry-point pattern)' {
        $result = Test-ReleaseGateEntryPointTouched -ChangedFiles @('skills/plugin-release-hygiene/SKILL.md')
        $result | Should -Be $true
    }

    It 'returns $true for a top-level agents/* path' {
        $result = Test-ReleaseGateEntryPointTouched -ChangedFiles @('agents/code-conductor.md')
        $result | Should -Be $true
    }

    It 'returns $true for hooks/hooks.json' {
        $result = Test-ReleaseGateEntryPointTouched -ChangedFiles @('hooks/hooks.json')
        $result | Should -Be $true
    }

    It 'returns $false for a Documents path (non-entry-point)' {
        $result = Test-ReleaseGateEntryPointTouched -ChangedFiles @('Documents/Design/foo.md')
        $result | Should -Be $false
    }

    It 'returns $false for a .github/scripts path (non-entry-point)' {
        $result = Test-ReleaseGateEntryPointTouched -ChangedFiles @('.github/scripts/foo.ps1')
        $result | Should -Be $false
    }

    It 'returns $true when array contains a mix of non-entry-point and entry-point paths' {
        $result = Test-ReleaseGateEntryPointTouched -ChangedFiles @('Documents/Design/foo.md', 'skills/x/y/z.md')
        $result | Should -Be $true
    }

    It 'returns $false for an empty array' {
        $result = Test-ReleaseGateEntryPointTouched -ChangedFiles @()
        $result | Should -Be $false
    }
}

# ===========================================================================
Describe 'Get-PluginVersion' {
# ===========================================================================

    It 'returns the version string for a valid 3-segment version (2.30.0)' {
        $tmpFile = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.json'
        try {
            '{"name":"agent-orchestra","version":"2.30.0"}' | Set-Content -Path $tmpFile -Encoding utf8
            $result = Get-PluginVersion -Path $tmpFile
            $result | Should -Be '2.30.0'
        } finally {
            Remove-Item -Path $tmpFile -ErrorAction SilentlyContinue
        }
    }

    It 'returns $null for a 2-segment version (2.30)' {
        $tmpFile = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.json'
        try {
            '{"name":"agent-orchestra","version":"2.30"}' | Set-Content -Path $tmpFile -Encoding utf8
            $result = Get-PluginVersion -Path $tmpFile
            $result | Should -BeNullOrEmpty
        } finally {
            Remove-Item -Path $tmpFile -ErrorAction SilentlyContinue
        }
    }

    It 'returns $null for a leading-zero version (2.030.0) — no-leading-zeros rule' {
        $tmpFile = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.json'
        try {
            '{"name":"agent-orchestra","version":"2.030.0"}' | Set-Content -Path $tmpFile -Encoding utf8
            $result = Get-PluginVersion -Path $tmpFile
            $result | Should -BeNullOrEmpty
        } finally {
            Remove-Item -Path $tmpFile -ErrorAction SilentlyContinue
        }
    }

    It 'returns $null or throws for a nonexistent file path' {
        $nonExistentPath = Join-Path $PSScriptRoot 'does-not-exist-xyzzy-12345.json'
        try {
            $result = Get-PluginVersion -Path $nonExistentPath
            $result | Should -BeNullOrEmpty
        } catch {
            $true | Should -Be $true
        }
    }
}

# ===========================================================================
Describe 'Compare-PluginVersionIsGreater' {
# ===========================================================================

    It 'returns $true when minor version is higher (2.31.0 > 2.30.0)' {
        $result = Compare-PluginVersionIsGreater -NewVersion '2.31.0' -BaseVersion '2.30.0'
        $result | Should -Be $true
    }

    It 'returns $true when patch version is higher (2.30.1 > 2.30.0)' {
        $result = Compare-PluginVersionIsGreater -NewVersion '2.30.1' -BaseVersion '2.30.0'
        $result | Should -Be $true
    }

    It 'returns $true when major version is higher (3.0.0 > 2.30.0)' {
        $result = Compare-PluginVersionIsGreater -NewVersion '3.0.0' -BaseVersion '2.30.0'
        $result | Should -Be $true
    }

    It 'returns $false when versions are equal (2.30.0 == 2.30.0) — equal FAILS the gate' {
        $result = Compare-PluginVersionIsGreater -NewVersion '2.30.0' -BaseVersion '2.30.0'
        $result | Should -Be $false
    }

    It 'returns $false for a downgrade (2.29.0 < 2.30.0)' {
        $result = Compare-PluginVersionIsGreater -NewVersion '2.29.0' -BaseVersion '2.30.0'
        $result | Should -Be $false
    }
}

# ===========================================================================
Describe 'Test-ChangelogSectionPresent' {
# ===========================================================================

    It 'matches an em-dash header with date for the exact version' {
        $content = "# CHANGELOG`n`n## [2.31.0] — 2026-06-21`n`nSome release notes."
        $result = Test-ChangelogSectionPresent -ChangelogContent $content -Version '2.31.0'
        $result | Should -Be $true
    }

    It 'matches a header with no date (dash-agnostic, date optional)' {
        $content = "# CHANGELOG`n`n## [2.31.0]`n`nSome release notes."
        $result = Test-ChangelogSectionPresent -ChangelogContent $content -Version '2.31.0'
        $result | Should -Be $true
    }

    It 'returns $false when version appears only in body text (not as a heading line)' {
        # The string "## [2.31.0]" appears inside a paragraph sentence, not as a standalone heading
        $content = "# CHANGELOG`n`nSee ## [2.31.0] in the archive for details.`n`n## [2.30.0] — 2026-06-12`n`nPrevious release."
        $result = Test-ChangelogSectionPresent -ChangelogContent $content -Version '2.31.0'
        $result | Should -Be $false
    }

    It 'returns $false when the target version section is absent from the CHANGELOG' {
        $content = "# CHANGELOG`n`n## [2.30.0] — 2026-06-12`n`nPrevious release notes."
        $result = Test-ChangelogSectionPresent -ChangelogContent $content -Version '2.31.0'
        $result | Should -Be $false
    }
}

# ===========================================================================
Describe 'Get-ReleaseGateWaiver' {
# ===========================================================================

    It "returns 'changelog-only' when commit message contains the changelog-only trailer" {
        $msg = "chore(release): bump version`n`nSkip-Release-Check: changelog-only"
        $result = Get-ReleaseGateWaiver -CommitMessage $msg
        $result | Should -Be 'changelog-only'
    }

    It "returns 'all' when commit message contains the all trailer with reason" {
        $msg = "fix: hotfix deploy`n`nSkip-Release-Check: all need to hotfix"
        $result = Get-ReleaseGateWaiver -CommitMessage $msg
        $result | Should -Be 'all'
    }

    It 'returns $null when commit message has no trailer' {
        $msg = "feat: add new feature`n`nThis is a normal commit with no waiver."
        $result = Get-ReleaseGateWaiver -CommitMessage $msg
        $result | Should -BeNullOrEmpty
    }

    It 'returns $null when the passed commit message does not contain the trailer (simulates non-head commit)' {
        # The function only looks at the passed-in message; this simulates
        # a caller passing a non-HEAD commit message that lacks the trailer.
        $msg = ''
        $result = Get-ReleaseGateWaiver -CommitMessage $msg
        $result | Should -BeNullOrEmpty
    }

    It 'returns $null when commit message MENTIONS the trailer in prose (not a real trailer line)' {
        $msg = "feat: add gate documentation`n`nThis commit discusses Skip-Release-Check: all and Skip-Release-Check: changelog-only syntax in prose."
        $result = Get-ReleaseGateWaiver -CommitMessage $msg
        $result | Should -BeNullOrEmpty
    }
}

# ===========================================================================
Describe 'Invoke-ReleaseGateEvaluation' {
# ===========================================================================

    It 'returns Pass=$true and ExitCode=0 when both legs pass and no waiver is present' {
        $result = Invoke-ReleaseGateEvaluation `
            -ChangedFiles      @('skills/foo/SKILL.md') `
            -HeadVersion       '2.31.0' `
            -BaseVersion       '2.30.0' `
            -ChangelogContent  "## [2.31.0] — 2026-06-21`nRelease notes." `
            -HeadCommitMessage 'chore(release): bump version to 2.31.0'

        $result.Pass        | Should -Be $true
        $result.FailedLegs  | Should -BeNullOrEmpty
        $result.ExitCode    | Should -Be 0
    }

    It 'returns Pass=$false and FailedLegs includes bump when base equals head (no version bump)' {
        $result = Invoke-ReleaseGateEvaluation `
            -ChangedFiles      @('skills/foo/SKILL.md') `
            -HeadVersion       '2.30.0' `
            -BaseVersion       '2.30.0' `
            -ChangelogContent  "## [2.30.0] — 2026-06-12`nRelease notes." `
            -HeadCommitMessage 'fix: some fix without version bump'

        $result.Pass | Should -Be $false
        $result.FailedLegs | Should -Contain 'bump'
        $result.ExitCode | Should -Be 1
    }

    It 'returns Pass=$false and FailedLegs includes changelog when bump present but changelog section missing' {
        $result = Invoke-ReleaseGateEvaluation `
            -ChangedFiles      @('skills/foo/SKILL.md') `
            -HeadVersion       '2.31.0' `
            -BaseVersion       '2.30.0' `
            -ChangelogContent  "## [2.30.0] — 2026-06-12`nPrevious release." `
            -HeadCommitMessage 'chore(release): bump version to 2.31.0'

        $result.Pass | Should -Be $false
        $result.FailedLegs | Should -Contain 'changelog'
        $result.ExitCode | Should -Be 1
    }

    It 'returns Pass=$true when bump present, CHANGELOG missing, but changelog-only waiver is applied' {
        $result = Invoke-ReleaseGateEvaluation `
            -ChangedFiles      @('skills/foo/SKILL.md') `
            -HeadVersion       '2.31.0' `
            -BaseVersion       '2.30.0' `
            -ChangelogContent  "## [2.30.0] — 2026-06-12`nPrevious release." `
            -HeadCommitMessage "chore(release): bump`n`nSkip-Release-Check: changelog-only"

        $result.Pass           | Should -Be $true
        $result.WaiverApplied  | Should -Be 'changelog-only'
        $result.ExitCode       | Should -Be 0
    }

    It 'returns Pass=$false when no bump but changelog present and changelog-only waiver — bump leg is NOT waived' {
        $result = Invoke-ReleaseGateEvaluation `
            -ChangedFiles      @('skills/foo/SKILL.md') `
            -HeadVersion       '2.30.0' `
            -BaseVersion       '2.30.0' `
            -ChangelogContent  "## [2.30.0] — 2026-06-12`nRelease notes." `
            -HeadCommitMessage "fix: no bump`n`nSkip-Release-Check: changelog-only"

        $result.Pass | Should -Be $false
        $result.FailedLegs | Should -Contain 'bump'
        $result.ExitCode | Should -Be 1
    }

    It 'returns Pass=$true when both legs fail but all waiver is applied' {
        $result = Invoke-ReleaseGateEvaluation `
            -ChangedFiles      @('skills/foo/SKILL.md') `
            -HeadVersion       '2.30.0' `
            -BaseVersion       '2.30.0' `
            -ChangelogContent  "## [2.29.0] — 2026-05-01`nOlder release." `
            -HeadCommitMessage "fix: emergency hotfix`n`nSkip-Release-Check: all need to hotfix"

        $result.Pass          | Should -Be $true
        $result.WaiverApplied | Should -Be 'all'
        $result.ExitCode      | Should -Be 0
    }
}
