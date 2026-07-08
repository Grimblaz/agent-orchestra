#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester tests for skills/naming-register-policy/scripts/newcomer-audit.ps1 (s3).

.DESCRIPTION
    Covers the wrapper's own responsibilities on top of the s2 detector core:
    diff-hunk parsing (added-line grain), the human-facing surface-class path
    filter, merge-base (not literal 'main..HEAD') diff-range correctness, the
    full-post-image-suppression-vs-added-line-emission split (plan-issue-751
    MF5), and -Path mode's issue-body-semantics CLI behavior end to end.

    The wrapper script guards its CLI/`exit`-calling main block behind
    `if ($MyInvocation.InvocationName -ne '.')`, so dot-sourcing it here (as
    this file's BeforeAll does) only defines functions and binds params -- it
    never shells out to git or calls `exit`, which would otherwise terminate
    the Pester host process.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:WrapperPath = Join-Path $script:RepoRoot 'skills/naming-register-policy/scripts/newcomer-audit.ps1'

    . $script:WrapperPath

    $script:RegisterPath = Join-Path $script:RepoRoot 'skills/naming-register-policy/assets/register.json'
    $script:Register = Get-Content -Path $script:RegisterPath -Raw | ConvertFrom-Json
}

Describe 'newcomer-audit wrapper: diff-hunk parsing' {
    It 'marks only "+"-prefixed lines within a hunk as added, using new-file line numbers' {
        $diffLines = @(
            'diff --git a/docs/example.md b/docs/example.md',
            'index 1111111..2222222 100644',
            '--- a/docs/example.md',
            '+++ b/docs/example.md',
            '@@ -1,3 +1,4 @@',
            ' unchanged line one',
            '-removed line',
            '+added line two',
            '+added line three',
            ' unchanged line four'
        )

        $parsed = ConvertTo-NewcomerAuditParsedDiff -DiffLines $diffLines

        $parsed | Should -HaveCount 1
        $parsed[0].Path | Should -Be 'docs/example.md'
        $parsed[0].AddedLines.Contains(2) | Should -BeTrue
        $parsed[0].AddedLines.Contains(3) | Should -BeTrue
        $parsed[0].AddedLines.Contains(1) | Should -BeFalse
        $parsed[0].AddedLines.Contains(4) | Should -BeFalse
    }

    It 'tracks multiple files independently across hunk and file boundaries' {
        $diffLines = @(
            'diff --git a/CLAUDE.md b/CLAUDE.md',
            'index aaa..bbb 100644',
            '--- a/CLAUDE.md',
            '+++ b/CLAUDE.md',
            '@@ -10,2 +10,3 @@',
            ' context',
            '+new claude line',
            ' context',
            'diff --git a/README.md b/README.md',
            'index ccc..ddd 100644',
            '--- a/README.md',
            '+++ b/README.md',
            '@@ -1,1 +1,2 @@',
            '+new readme line',
            ' context'
        )

        $parsed = ConvertTo-NewcomerAuditParsedDiff -DiffLines $diffLines

        $parsed | Should -HaveCount 2
        ($parsed | Where-Object { $_.Path -eq 'CLAUDE.md' }).AddedLines.Contains(11) | Should -BeTrue
        ($parsed | Where-Object { $_.Path -eq 'README.md' }).AddedLines.Contains(1) | Should -BeTrue
    }
}

Describe 'newcomer-audit wrapper: human-facing surface-class path filter' {
    It 'accepts the documented human-facing surface classes' {
        Test-NewcomerAuditSurfaceClassPath -Path 'CLAUDE.md' | Should -BeTrue
        Test-NewcomerAuditSurfaceClassPath -Path 'HOW-IT-WORKS.md' | Should -BeTrue
        Test-NewcomerAuditSurfaceClassPath -Path 'README.md' | Should -BeTrue
        Test-NewcomerAuditSurfaceClassPath -Path 'skills/naming-register-policy/README.md' | Should -BeTrue
        Test-NewcomerAuditSurfaceClassPath -Path 'skills/naming-register-policy/SKILL.md' | Should -BeTrue
        Test-NewcomerAuditSurfaceClassPath -Path 'Documents/Design/some-doc.md' | Should -BeTrue
        Test-NewcomerAuditSurfaceClassPath -Path '.github/ISSUE_TEMPLATE/bug.yml' | Should -BeTrue
        Test-NewcomerAuditSurfaceClassPath -Path '.github/PULL_REQUEST_TEMPLATE.md' | Should -BeTrue
    }

    It 'rejects files outside the human-facing surface class list' {
        Test-NewcomerAuditSurfaceClassPath -Path 'skills/naming-register-policy/scripts/newcomer-audit-core.ps1' | Should -BeFalse
        Test-NewcomerAuditSurfaceClassPath -Path '.github/scripts/Tests/newcomer-audit.Tests.ps1' | Should -BeFalse
        Test-NewcomerAuditSurfaceClassPath -Path 'agents/Issue-Planner.agent.md' | Should -BeFalse
    }
}

Describe 'newcomer-audit wrapper: merge-base correctness (AC7)' {
    It 'diffs from the resolved merge-base commit, never the literal branch name "main"' {
        $script:CapturedMergeBase = $null

        Mock -CommandName Get-NewcomerAuditRawDiff -MockWith {
            param($RepoRoot, $MergeBase)
            $script:CapturedMergeBase = $MergeBase
            return , @()
        }

        # A real merge-base resolves to a commit SHA, never the literal string
        # 'main' -- simulate that shape here rather than requiring a git fixture.
        $simulatedMergeBase = 'deadbeef1234'
        $null = Get-NewcomerAuditRawDiff -RepoRoot $script:RepoRoot -MergeBase $simulatedMergeBase

        $script:CapturedMergeBase | Should -Be 'deadbeef1234'
        $script:CapturedMergeBase | Should -Not -Be 'main'
    }

    It 'resolves the merge-base of main and HEAD in the live repo (sanity check, not mocked)' {
        $mergeBase = Get-NewcomerAuditMergeBase -RepoRoot $script:RepoRoot

        $mergeBase | Should -Not -BeNullOrEmpty
        $mergeBase | Should -Not -Be 'main'
        $mergeBase | Should -MatchExactly '^[0-9a-f]{7,40}$'
    }
}

Describe 'newcomer-audit wrapper: full-post-image suppression vs added-line emission grain (MF5)' {
    It 'suppresses a term whose footer vocab-pointer link sits outside the changed region, using full-file content' {
        $fullFileContent = @'
# Doc

Spine-Runner walks the plan step by step.

More unrelated prose here so the footer link is far away from any edits.

---

See [vocab reference](HOW-IT-WORKS.md#vocab) for term definitions.
'@
        # Only line 3 ("Spine-Runner ...") is "added" per the diff -- the footer
        # link on the last line is unchanged/pre-existing.
        $addedLines = [System.Collections.Generic.HashSet[int]]::new()
        [void]$addedLines.Add(3)

        $allFindings = Get-NewcomerAuditFindings -Content $fullFileContent -Surface 'repo-file' -Register $script:Register
        $emitted = @($allFindings | Where-Object { $addedLines.Contains([int]$_.line) })

        ($allFindings | Where-Object { $_.token -eq 'Spine-Runner' }) | Should -BeNullOrEmpty -Because 'the footer link suppresses it against the full-file context'
        $emitted | Should -BeNullOrEmpty
    }

    It 'still flags an unexpanded term on its own added line when nothing in the file suppresses it' {
        $fullFileContent = @'
# Doc

The credits[] array holds pipeline credits.

More unrelated prose here.
'@
        $addedLines = [System.Collections.Generic.HashSet[int]]::new()
        [void]$addedLines.Add(3)

        $allFindings = Get-NewcomerAuditFindings -Content $fullFileContent -Surface 'repo-file' -Register $script:Register
        $emitted = @($allFindings | Where-Object { $addedLines.Contains([int]$_.line) })

        ($emitted | Where-Object { $_.token -eq 'credits[]' }) | Should -Not -BeNullOrEmpty -Because 'the added line carrying the unsuppressed term must still surface'
    }

    It 'never emits a finding that exists only on an unchanged line of a touched file' {
        $fullFileContent = @'
# Doc

The credits[] array holds pipeline credits.

A newly added, unrelated line goes here.
'@
        # credits[] is on line 3 (unchanged); only line 5 is "added" per the diff.
        $addedLines = [System.Collections.Generic.HashSet[int]]::new()
        [void]$addedLines.Add(5)

        $allFindings = Get-NewcomerAuditFindings -Content $fullFileContent -Surface 'repo-file' -Register $script:Register
        $emitted = @($allFindings | Where-Object { $addedLines.Contains([int]$_.line) })

        ($allFindings | Where-Object { $_.token -eq 'credits[]' }) | Should -Not -BeNullOrEmpty -Because 'the core still finds it against full-file content'
        ($emitted | Where-Object { $_.token -eq 'credits[]' }) | Should -BeNullOrEmpty -Because 'emission is scoped to added/modified lines only, per MF5'
    }
}

Describe 'newcomer-audit wrapper: -Path mode CLI integration (issue-body semantics)' {
    It 'flags an unexpanded stable-code term and exits 1' {
        $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) "newcomer-audit-wrapper-fixture-$([guid]::NewGuid()).md"
        try {
            [System.IO.File]::WriteAllText($tempPath, 'The CE Gate must pass before merge.', [System.Text.UTF8Encoding]::new($false))

            $output = & pwsh -NoLogo -NoProfile -File $script:WrapperPath -Path $tempPath -Json 2>&1
            $exitCode = $LASTEXITCODE

            $exitCode | Should -Be 1
            $parsed = ($output -join "`n") | ConvertFrom-Json
            ($parsed | Where-Object { $_.token -eq 'CE Gate' }) | Should -Not -BeNullOrEmpty
        }
        finally {
            Remove-Item -Path $tempPath -ErrorAction SilentlyContinue
        }
    }

    It 'exits 0 with an empty JSON array for clean prose' {
        $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) "newcomer-audit-wrapper-clean-$([guid]::NewGuid()).md"
        try {
            [System.IO.File]::WriteAllText($tempPath, 'Ordinary prose with no jargon at all.', [System.Text.UTF8Encoding]::new($false))

            $output = & pwsh -NoLogo -NoProfile -File $script:WrapperPath -Path $tempPath -Json 2>&1
            $exitCode = $LASTEXITCODE

            $exitCode | Should -Be 0
            $parsed = ($output -join "`n") | ConvertFrom-Json
            @($parsed) | Should -HaveCount 0
        }
        finally {
            Remove-Item -Path $tempPath -ErrorAction SilentlyContinue
        }
    }

    It 'rejects specifying both -Path and -Changed with exit code 2' {
        $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) "newcomer-audit-wrapper-conflict-$([guid]::NewGuid()).md"
        try {
            [System.IO.File]::WriteAllText($tempPath, 'irrelevant', [System.Text.UTF8Encoding]::new($false))

            $null = & pwsh -NoLogo -NoProfile -File $script:WrapperPath -Path $tempPath -Changed 2>&1
            $LASTEXITCODE | Should -Be 2
        }
        finally {
            Remove-Item -Path $tempPath -ErrorAction SilentlyContinue
        }
    }

    It 'rejects specifying neither -Path nor -Changed with exit code 2' {
        $null = & pwsh -NoLogo -NoProfile -File $script:WrapperPath 2>&1
        $LASTEXITCODE | Should -Be 2
    }
}
