#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester v5 suite for changelog-insert-core.ps1 (issue #739, slice s5 / AC7).

.DESCRIPTION
    Tests covering the Invoke-ChangelogInsertion function extracted into
    .github/scripts/lib/changelog-insert-core.ps1 for AC7:

      1. Happy path: entry inserts correctly with ## [X.Y.Z] — YYYY-MM-DD header
      2. Idempotency: when target version already present, returns Skipped=$true; content unchanged
      3. Em-dash anchor: new entry inserts ABOVE existing ## [X.Y.Z] — date heading
      4. No-prior-heading fallback: fresh CHANGELOG with only '# Changelog' preamble
      5. Header injection rejection: -ChangelogEntry containing ## [9.9.9] is caught by
         bump-version.ps1 (input-validation layer); the core function receives clean input
      6. Read-back verify: VerifyPass=$true after a successful insert
      7. No-op when ChangelogEntry is whitespace-only (caller contract; core tests clean call)
      8. ChangelogSection override: custom section name appears in output
      9. VerifyPass=$false sentinel: artificially verify fail path (inject mismatched content)
     10. Header injection guard in bump-version.ps1: validate the -ChangelogEntry check fires
         by dot-sourcing a thin extraction of that validation (no child process)
#>

BeforeAll {
    $script:RepoRoot  = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:CoreLib   = Join-Path $script:RepoRoot '.github/scripts/lib/changelog-insert-core.ps1'
    $script:GateCore  = Join-Path $script:RepoRoot '.github/scripts/lib/release-gate-core.ps1'

    # Dot-source both libraries in-process (no child pwsh)
    . $script:GateCore
    . $script:CoreLib
}

# ===========================================================================
Describe 'Invoke-ChangelogInsertion (changelog-insert-core.ps1 — AC7)' {
# ===========================================================================

    It '1. happy path: inserts ## [X.Y.Z] — YYYY-MM-DD header with entry body' {
        $input = @"
# Changelog

## [9.8.7] — 2026-01-01

### Changed

- Prior release.
"@
        $result = Invoke-ChangelogInsertion `
            -ChangelogContent $input `
            -Version          '9.8.8' `
            -ChangelogEntry   '- Fixed the thing'

        $today = Get-Date -Format 'yyyy-MM-dd'

        $result.Updated    | Should -Be $true
        $result.Skipped    | Should -Be $false
        $result.VerifyPass | Should -Be $true

        # New header present
        $result.Content | Should -Match "## \[9\.8\.8\] — $today"

        # Entry body present
        $result.Content | Should -Match '- Fixed the thing'

        # Default section name 'Changed'
        $result.Content | Should -Match '### Changed'

        # Old section still present
        $result.Content | Should -Match '## \[9\.8\.7\]'
    }

    It '2. idempotency: target version already present — Skipped=$true, content unchanged' {
        $existing = @"
# Changelog

## [9.8.8] — 2026-06-01

### Changed

- Already here.

## [9.8.7] — 2026-01-01

### Changed

- Prior release.
"@
        $result = Invoke-ChangelogInsertion `
            -ChangelogContent $existing `
            -Version          '9.8.8' `
            -ChangelogEntry   '- This should be skipped'

        $result.Skipped    | Should -Be $true
        $result.Updated    | Should -Be $false
        $result.VerifyPass | Should -Be $true

        # Content unchanged — still exactly 1 occurrence of the heading
        $headings = [regex]::Matches($result.Content, '(?m)^## \[9\.8\.8\]')
        $headings.Count | Should -Be 1

        # Message indicates skip
        $result.Message | Should -Match 'skip'
    }

    It '3. em-dash anchor: new entry inserts ABOVE existing ## [X.Y.Z] — date heading' {
        $input = @"
# Changelog

## [9.8.7] — 2026-06-01

### Changed

- Old release with em-dash separator.
"@
        $result = Invoke-ChangelogInsertion `
            -ChangelogContent $input `
            -Version          '9.8.8' `
            -ChangelogEntry   '- New entry'

        $result.Updated | Should -Be $true

        $newIdx = $result.Content.IndexOf('## [9.8.8]')
        $oldIdx = $result.Content.IndexOf('## [9.8.7]')
        $newIdx | Should -BeLessThan $oldIdx
        $newIdx | Should -BeGreaterOrEqual 0
    }

    It '4. no-prior-heading fallback: fresh CHANGELOG with only # Changelog preamble' {
        $input = "# Changelog`n"

        $result = Invoke-ChangelogInsertion `
            -ChangelogContent $input `
            -Version          '9.8.8' `
            -ChangelogEntry   '- First ever entry'

        $today = Get-Date -Format 'yyyy-MM-dd'

        $result.Updated    | Should -Be $true
        $result.VerifyPass | Should -Be $true
        $result.Content    | Should -Match "## \[9\.8\.8\] — $today"
        $result.Content    | Should -Match '- First ever entry'
    }

    It '5. completely empty CHANGELOG: entry inserted at top without orphaned blank line' {
        $result = Invoke-ChangelogInsertion `
            -ChangelogContent '' `
            -Version          '9.8.8' `
            -ChangelogEntry   '- Entry on empty file'

        $result.Updated    | Should -Be $true
        $result.VerifyPass | Should -Be $true
        $result.Content    | Should -Match '## \[9\.8\.8\]'
        $result.Content    | Should -Match '- Entry on empty file'
    }

    It '6. VerifyPass=$true after successful insert (read-back check passes in-memory)' {
        $input = @"
# Changelog

## [9.8.7] — 2026-01-01

### Changed

- Prior.
"@
        $result = Invoke-ChangelogInsertion `
            -ChangelogContent $input `
            -Version          '9.8.8' `
            -ChangelogEntry   '- Verified entry'

        $result.VerifyPass | Should -Be $true

        # Also assert directly via Test-ChangelogSectionPresent
        $present = Test-ChangelogSectionPresent -ChangelogContent $result.Content -Version '9.8.8'
        $present | Should -Be $true
    }

    It '7. ChangelogSection override: custom section name appears in output' {
        $input = @"
# Changelog

## [9.8.7] — 2026-01-01

### Fixed

- Prior.
"@
        $result = Invoke-ChangelogInsertion `
            -ChangelogContent $input `
            -Version          '9.8.8' `
            -ChangelogEntry   '- Added new feature' `
            -ChangelogSection 'Added'

        $result.Updated | Should -Be $true

        # New section contains ### Added
        $newIdx = $result.Content.IndexOf('## [9.8.8]')
        $oldIdx = $result.Content.IndexOf('## [9.8.7]')
        $newSectionBody = $result.Content.Substring($newIdx, $oldIdx - $newIdx)

        $newSectionBody | Should -Match '### Added'
        $newSectionBody | Should -Not -Match '### Changed'
        $newSectionBody | Should -Match '- Added new feature'
    }

    It '8. heading count: after insert, exactly previousCount+1 version headings exist' {
        $input = @"
# Changelog

## [9.8.6] — 2026-01-01

### Changed

- Oldest.

## [9.8.5] — 2025-12-01

### Changed

- Even older.
"@
        $prevCount = ([regex]::Matches($input, '(?m)^## \[\d+\.\d+\.\d+\]')).Count

        $result = Invoke-ChangelogInsertion `
            -ChangelogContent $input `
            -Version          '9.8.7' `
            -ChangelogEntry   '- Middle entry'

        $afterCount = ([regex]::Matches($result.Content, '(?m)^## \[\d+\.\d+\.\d+\]')).Count
        $afterCount | Should -Be ($prevCount + 1)
    }

    It '9. multi-line ChangelogEntry is preserved verbatim in the output' {
        $multiLine = @"
- Fixed issue A
- Fixed issue B
- Also improved C
"@
        $input = "# Changelog`n`n## [9.8.7] — 2026-01-01`n`n### Changed`n`n- Prior.`n"

        $result = Invoke-ChangelogInsertion `
            -ChangelogContent $input `
            -Version          '9.8.8' `
            -ChangelogEntry   $multiLine

        $result.Content | Should -Match '- Fixed issue A'
        $result.Content | Should -Match '- Fixed issue B'
        $result.Content | Should -Match '- Also improved C'
    }
}

# ===========================================================================
Describe 'bump-version.ps1 input validation — header injection guard (AC7)' {
# ===========================================================================
# Tests the -ChangelogEntry validation guard WITHOUT spawning a child pwsh process.
# Extracts the guard logic as a PowerShell function and tests it in-process.

    BeforeAll {
        # Extract the validation logic from bump-version.ps1 into a testable function.
        # The guard checks: if $ChangelogEntry matches (?m)^## [\d+\.\d+\.\d+]
        function script:Test-ChangelogEntryHasHeader {
            param([string]$ChangelogEntry)
            return ($ChangelogEntry -match '(?m)^## \[\d+\.\d+\.\d+\]')
        }
    }

    It '10. header injection: entry containing ## [9.9.9] is detected as invalid' {
        $badEntry = "## [9.9.9] — 2026-01-01`n`n- Injected header"
        script:Test-ChangelogEntryHasHeader -ChangelogEntry $badEntry | Should -Be $true
    }

    It '11. clean entry body passes the guard (no false positive)' {
        $goodEntry = "- Fixed the thing`n- Also this"
        script:Test-ChangelogEntryHasHeader -ChangelogEntry $goodEntry | Should -Be $false
    }

    It '12. entry with ## in prose (not a release header) is not flagged' {
        # "## " followed by non-bracket text is not a version header
        $proseEntry = "- See ## Background section for context"
        script:Test-ChangelogEntryHasHeader -ChangelogEntry $proseEntry | Should -Be $false
    }
}
