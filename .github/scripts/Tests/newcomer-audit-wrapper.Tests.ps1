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

Describe 'newcomer-audit wrapper: real end-to-end -Changed pipeline (regression lock-in)' {
    # Every other wrapper test above either mocks the diff or reimplements the
    # added-line filter inline -- none of them invoke the real wrapper binary
    # against a real git repo in -Changed mode. That gap is exactly why the
    # rename-exclusion (fix #9) and diff-header-spoof (fix #12) defects
    # shipped invisibly through 66 "passing" tests. This test builds a real
    # temporary git repo, runs the actual wrapper script as a subprocess with
    # -Changed -Json, and pins both regressions against real findings and a
    # real exit code.
    It 'finds a renamed-and-edited doc and survives a diff-syntax-spoofing added line' {
        $tempRepo = Join-Path ([System.IO.Path]::GetTempPath()) "newcomer-audit-e2e-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $tempRepo -Force | Out-Null

        Push-Location $tempRepo
        try {
            & git init -q -b main . 2>&1 | Out-Null
            & git config user.email 'newcomer-audit-e2e@example.com' 2>&1 | Out-Null
            & git config user.name 'newcomer-audit-e2e' 2>&1 | Out-Null

            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)

            # Seed 'main' with a CLAUDE.md-shaped file and a Documents/Design/
            # doc long enough to preserve a high rename-similarity score once
            # it is renamed AND edited on the feature branch.
            [System.IO.File]::WriteAllText((Join-Path $tempRepo 'CLAUDE.md'), "# Root doc`n`nOrdinary prose, no jargon here.`n", $utf8NoBom)

            New-Item -ItemType Directory -Path (Join-Path $tempRepo 'Documents/Design') -Force | Out-Null
            $originalDocContent = @'
# Design Doc

This document is long enough and distinctive enough that renaming it
while making a small edit still preserves a high content-similarity
score for git's rename detector.

Filler line one.
Filler line two.
Filler line three.
Filler line four.
'@
            [System.IO.File]::WriteAllText((Join-Path $tempRepo 'Documents/Design/original-doc.md'), $originalDocContent, $utf8NoBom)

            & git add -A 2>&1 | Out-Null
            & git commit -q -m 'seed main' 2>&1 | Out-Null

            & git checkout -q -b feature/e2e-test 2>&1 | Out-Null

            # (a) Rename-and-edit case (pins fix #9): rename the design doc AND
            # add an unexpanded stable-code term in the same commit.
            & git mv 'Documents/Design/original-doc.md' 'Documents/Design/renamed-doc.md' 2>&1 | Out-Null
            Add-Content -Path (Join-Path $tempRepo 'Documents/Design/renamed-doc.md') -Value "`nSee SMC-08 for the specific rule." -Encoding utf8NoBOM

            # (b) Diff-header-spoof case (pins fix #12): the added file content
            # line is exactly '++ b/fake-spoof.md' -- git's own '+' diff marker
            # turns this into a raw diff line of '+++ b/fake-spoof.md', which
            # is textually indistinguishable from a genuine file header. The
            # very next added line carries a real unexpanded stable-code term
            # ('CE Gate'); if the spoof line wrongly resets the parser's
            # current-file state, that finding is silently dropped.
            Add-Content -Path (Join-Path $tempRepo 'CLAUDE.md') -Value '++ b/fake-spoof.md' -Encoding utf8NoBOM
            Add-Content -Path (Join-Path $tempRepo 'CLAUDE.md') -Value 'See CE Gate for details.' -Encoding utf8NoBOM

            & git add -A 2>&1 | Out-Null
            & git commit -q -m 'feature: rename+edit doc, add spoof + real term to CLAUDE.md' 2>&1 | Out-Null

            $output = & pwsh -NoLogo -NoProfile -File $script:WrapperPath -Changed -Json 2>&1
            $exitCode = $LASTEXITCODE

            $exitCode | Should -Be 1 -Because "output was: $($output -join "`n")"

            $findings = ($output -join "`n") | ConvertFrom-Json

            ($findings | Where-Object { $_.file -eq 'Documents/Design/renamed-doc.md' -and $_.token -eq 'SMC-08' }) |
                Should -Not -BeNullOrEmpty -Because 'the renamed-and-edited doc must still be scanned under --diff-filter=ACMR (fix #9)'

            ($findings | Where-Object { $_.file -eq 'CLAUDE.md' -and $_.token -eq 'CE Gate' }) |
                Should -Not -BeNullOrEmpty -Because 'the real added-line finding after the spoofed +++ b/ line must survive (fix #12)'
        }
        finally {
            Pop-Location
            Remove-Item -Path $tempRepo -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
