#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester tests for Ensure-ScratchGitignore.ps1 (issue #643 AC5).

.DESCRIPTION
    Contract:
      T1 – appends .tmp/ and patterns to a .gitignore that lacks them
      T2 – does not add duplicate lines on re-run (idempotency)
      T3 – creates .gitignore if it does not exist
      T4 – exits 0 (fail-open) when .gitignore is unwritable (documented manual test note included)
#>

Describe 'Ensure-ScratchGitignore.ps1' {

    BeforeAll {
        $script:RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ScriptFile = Join-Path $script:RepoRoot 'skills\session-startup\scripts\Ensure-ScratchGitignore.ps1'

        # Canonical patterns expected to be present after the script runs.
        # /*[Tt]emp* intentionally absent (RF4): over-matched template.md/attempt.js;
        # primary mangle shapes covered by /[A-Za-z]:* and /[A-Za-z][A-Za-z]sers*.
        $script:RequiredPatterns = @(
            '.tmp/',
            '/[A-Za-z][A-Za-z]sers*',
            '/[A-Za-z]:*',
            '/var*folders*',
            '/[Rr][Uu][Nn][Nn][Ee][Rr]*[Tt][Ee][Mm][Pp]*'
        )
    }

    Context 'T1 — appends scratch-containment patterns when .gitignore lacks them' {
        It 'writes all required patterns to a .gitignore that has none of them' {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "ensure-gitignore-t1-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            try {
                # Seed with unrelated content
                Set-Content -Path (Join-Path $tempDir '.gitignore') -Value "node_modules/`nbuild/" -NoNewline

                & $script:ScriptFile -RepoRoot $tempDir
                $LASTEXITCODE | Should -Be 0

                $content = Get-Content (Join-Path $tempDir '.gitignore') -Raw
                foreach ($pattern in $script:RequiredPatterns) {
                    $content | Should -Match ([regex]::Escape($pattern)) -Because "pattern '$pattern' must be present after script runs"
                }

                # Pre-existing rules must survive intact and not be fused with the appended comment (RF2)
                $lines = Get-Content (Join-Path $tempDir '.gitignore')
                $lines | Should -Contain 'node_modules/' -Because 'pre-existing node_modules/ rule must not be corrupted'
                $lines | Should -Contain 'build/'        -Because 'pre-existing build/ rule must not be corrupted'
            }
            finally {
                Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'T2 — idempotency: no duplicate lines on re-run' {
        It 'does not add duplicate lines when run twice on the same .gitignore' {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "ensure-gitignore-t2-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            try {
                $gitignorePath = Join-Path $tempDir '.gitignore'

                # First run
                & $script:ScriptFile -RepoRoot $tempDir
                $LASTEXITCODE | Should -Be 0

                $linesAfterFirst = (Get-Content $gitignorePath) | Where-Object { $_ -ne '' }
                $countAfterFirst = $linesAfterFirst.Count

                # Second run — must be idempotent
                & $script:ScriptFile -RepoRoot $tempDir
                $LASTEXITCODE | Should -Be 0

                $linesAfterSecond = (Get-Content $gitignorePath) | Where-Object { $_ -ne '' }
                $countAfterSecond = $linesAfterSecond.Count

                $countAfterSecond | Should -Be $countAfterFirst -Because 'a second run must not add duplicate entries'
            }
            finally {
                Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'T3 — creates .gitignore when it does not exist' {
        It 'creates a new .gitignore containing all required patterns' {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "ensure-gitignore-t3-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            try {
                $gitignorePath = Join-Path $tempDir '.gitignore'
                Test-Path $gitignorePath | Should -Be $false -Because 'precondition: .gitignore must not exist before the test'

                & $script:ScriptFile -RepoRoot $tempDir
                $LASTEXITCODE | Should -Be 0

                Test-Path $gitignorePath | Should -Be $true -Because 'script must create .gitignore when absent'

                $content = Get-Content $gitignorePath -Raw
                foreach ($pattern in $script:RequiredPatterns) {
                    $content | Should -Match ([regex]::Escape($pattern)) -Because "newly created .gitignore must contain pattern '$pattern'"
                }
            }
            finally {
                Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'T4 — fail-open: exits 0 even when the .gitignore directory is non-existent' {
        It 'exits 0 when RepoRoot does not exist (no crash)' {
            $nonExistentDir = Join-Path ([System.IO.Path]::GetTempPath()) "ensure-gitignore-t4-nonexistent-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"

            & $script:ScriptFile -RepoRoot $nonExistentDir
            # Fail-open contract: script must always exit 0 regardless of errors
            $LASTEXITCODE | Should -Be 0 -Because 'Ensure-ScratchGitignore must never crash the hook (fail-open)'
        }
    }

    Context 'T5 — handles an empty (zero-byte) .gitignore correctly' {
        It 'T5: handles an empty (zero-byte) .gitignore correctly' {
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "ensure-gitignore-t5-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            try {
                # Arrange: zero-byte .gitignore
                $gitignorePath = Join-Path $tempDir '.gitignore'
                New-Item -ItemType File -Path $gitignorePath -Force | Out-Null  # zero-byte file

                # Act
                & $script:ScriptFile -RepoRoot $tempDir

                # Assert: script exits 0 AND patterns are present (not silently abandoned)
                $LASTEXITCODE | Should -Be 0
                $content = Get-Content $gitignorePath -Raw
                $content | Should -Match ([regex]::Escape('.tmp/'))
            }
            finally {
                Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
            }
        }
    }

}
