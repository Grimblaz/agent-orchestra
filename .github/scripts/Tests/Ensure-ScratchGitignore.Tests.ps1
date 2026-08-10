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
      T5 – handles an empty (zero-byte) .gitignore

    Issue #929 adds a second, deliberately separate destination:

      T6 – writes the ANCHORED goal-run runtime-state patterns to
           .git/info/exclude (not .gitignore), and git actually honours them
      T7 – idempotent on .git/info/exclude across a second run
      T8 – fails open (exit 0, .gitignore step still runs) outside a git repo
      T9 – NEVER writes the goal-run patterns into .gitignore

    Issue #929 AC2 — the integration claim, as a matched pair. AC2 spans two
    components (this script writes the ignore entries; the goal-contract
    validator's Test-GCTreeClean reads the resulting `git status`), so it
    lives beside the script's own suite rather than in the validator's suite,
    which is quarantined out of .github/workflows/pester.yml's selection and
    therefore never runs in CI. A regression test CI never runs cannot deliver
    AC2's stated purpose ("so the coupling cannot silently return").

      T10 – after the shipped script has run, a tree whose only content beyond
            the committed tree is the goal-run runtime-state pair reads back
            as IsClean = $true with an empty Porcelain
      T11 – negative control: the identical scenario WITHOUT the script run
            reports IsClean = $false with both files listed as `??`. Without
            this control T10 could pass for reasons unrelated to the mechanism.

      T12 – linked worktree: the exclude entries land in the SHARED
            common-dir exclude file (the only one git consults), not the
            per-worktree .git/worktrees/<name>/info/exclude

    D-new-4 – parity guards: both ignore lists the script owns are also
              present verbatim in this repo's own committed .gitignore. The
              #929 regression happened because the same ignore contract was
              hand-authored in two places with nothing asserting they agreed.
              Both guards AST-parse their list out of the script rather than
              restating it, so neither can drift from the thing it guards.
#>

Describe 'Ensure-ScratchGitignore.ps1' {

    BeforeAll {
        $script:RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ScriptFile = Join-Path $script:RepoRoot 'skills/session-startup/scripts/Ensure-ScratchGitignore.ps1'

        # The OTHER half of the #929 AC2 integration claim: Test-GCTreeClean is
        # the predicate New-GCDisposableWorktree calls on -RepoRoot before it
        # does anything else, so it is what actually observes whether this
        # script's ignore entries worked. Guarded rather than unguarded so a
        # missing lib fails inside the two AC2 cases (loudly, with a reason)
        # instead of taking down T1-T9 from BeforeAll.
        $script:ValidateCoreLib = Join-Path $script:RepoRoot '.github/scripts/lib/goal-contract-validate-core.ps1'
        if (Test-Path -LiteralPath $script:ValidateCoreLib) {
            . $script:ValidateCoreLib
        }

        # Canonical patterns expected in .gitignore after the script runs.
        # /*[Tt]emp* intentionally absent (RF4): over-matched template.md/attempt.js;
        # primary mangle shapes covered by /[A-Za-z]:* and /[A-Za-z][A-Za-z]sers*.
        # NOTE (#929): the goal-run runtime-state patterns are deliberately NOT in
        # this list. They go to .git/info/exclude, not .gitignore -- see the T6-T9
        # contexts. Listing them here previously encoded the wrong destination AND
        # the wrong (unanchored) form.
        $script:RequiredPatterns = @(
            '.tmp/',
            '/[A-Za-z][A-Za-z]sers*',
            '/[A-Za-z]:*',
            '/var*folders*',
            '/[Rr][Uu][Nn][Nn][Ee][Rr]*[Tt][Ee][Mm][Pp]*'
        )

        # The anchored forms the script writes to .git/info/exclude. Anchored
        # because the harness only ever writes at the worktree root; a bare
        # basename would also hide e.g. fixtures/goal-run-active.json.
        $script:GoalRunExcludePatterns = @(
            '/goal-run-active.json',
            '/goal-run-log.jsonl'
        )

        # Unique throwaway directory under the system temp path. No drive-letter
        # literals anywhere in this file: hard-coded 'C:\...' paths are a known
        # cause of ubuntu-latest CI breakage in this repo (see the NOTE blocks in
        # .github/workflows/pester.yml).
        function script:New-EsgTempDir {
            param([Parameter(Mandatory)][string]$Label)
            $path = Join-Path ([System.IO.Path]::GetTempPath()) "ensure-gitignore-$Label-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
            New-Item -ItemType Directory -Path $path -Force | Out-Null
            return $path
        }

        # A throwaway git repo with a LOCAL identity and a LOCAL core.excludesFile
        # override pointing at a path that does not exist. The override makes the
        # ignore assertions hermetic: whatever the operator happens to keep in
        # their global excludes file cannot silently satisfy (or defeat) them.
        function script:New-EsgTempRepo {
            param([Parameter(Mandatory)][string]$Label)
            $path = script:New-EsgTempDir -Label $Label
            & git -C $path init -q -b main . 2>&1 | Out-Null
            & git -C $path config user.email 'ensure-scratch-gitignore@example.com' 2>&1 | Out-Null
            & git -C $path config user.name  'ensure-scratch-gitignore'             2>&1 | Out-Null
            & git -C $path config core.excludesFile (Join-Path $path 'no-such-global-excludes') 2>&1 | Out-Null
            return $path
        }

        # A throwaway repo that already carries one COMMITTED file, so "the
        # only content beyond the committed tree" in the AC2 cases below is a
        # meaningful phrase rather than a description of an empty repo.
        function script:New-EsgSeededRepo {
            param([Parameter(Mandatory)][string]$Label)
            $repo = script:New-EsgTempRepo -Label $Label
            [System.IO.File]::WriteAllText((Join-Path $repo 'seed.txt'), "seed`n", [System.Text.UTF8Encoding]::new($false))
            & git -C $repo add -A 2>&1 | Out-Null
            & git -C $repo commit -q -m 'seed' 2>&1 | Out-Null
            return $repo
        }

        # Reads one literal string-array assignment out of the SHIPPED script by
        # AST-parsing it. Used by the D-new-4 parity guards so neither guard has
        # to carry its own copy of the list it compares -- a copy would recreate
        # the very duplication defect the guards exist to prevent. Parsing rather
        # than dot-sourcing or invoking also guarantees a parity guard can never
        # write to the working tree's .gitignore while it runs.
        # Throws (rather than returning empty) on parse failure, a rename, or a
        # restructure, so those failure modes go red instead of passing vacuously.
        function script:Get-EsgScriptArrayLiteral {
            param([Parameter(Mandatory)][string]$VariableName)

            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptFile, [ref]$tokens, [ref]$parseErrors)
            if (@($parseErrors).Count -ne 0) {
                throw "Ensure-ScratchGitignore.ps1 must parse cleanly before its ignore lists can be trusted; parse errors: $((@($parseErrors) | ForEach-Object { $_.Message }) -join ' | ')"
            }

            # The predicate deliberately closes over nothing: filtering by name
            # happens in the pipeline afterwards, so no variable capture has to
            # survive the ScriptBlock-to-delegate conversion FindAll performs.
            $assignment = @($ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        $node.Left -is [System.Management.Automation.Language.VariableExpressionAst]
                    }, $true)) |
                Where-Object { $_.Left.VariablePath.UserPath -eq $VariableName } |
                Select-Object -First 1

            if (-not $assignment) {
                throw "Ensure-ScratchGitignore.ps1 no longer assigns `$$VariableName. A rename or restructure must fail this parity guard loudly rather than silently stop guarding."
            }
            if ($assignment.Right -isnot [System.Management.Automation.Language.CommandExpressionAst]) {
                throw "`$$VariableName must stay a literal array expression this parity guard can read without executing the script."
            }

            return @($assignment.Right.Expression.SafeGetValue())
        }

        # The repo's own committed .gitignore, read as trimmed lines. This is the
        # SECOND authoring site the D-new-4 guards compare the script against.
        function script:Get-EsgRepoGitignoreLines {
            $repoGitignore = Join-Path $script:RepoRoot '.gitignore'
            if (-not (Test-Path -LiteralPath $repoGitignore)) {
                throw "The hub repo .gitignore ($repoGitignore) is the second authoring site these guards compare against, and it is missing."
            }
            return @(Get-Content -LiteralPath $repoGitignore | ForEach-Object { $_.TrimEnd() })
        }

        # Writes the two files the goal-run harness drops at its execution
        # worktree root (874-D6). Content is representative, not load-bearing:
        # what matters is that both paths exist on disk.
        function script:New-EsgGoalRunRuntimeState {
            param([Parameter(Mandatory)][string]$RepoPath)
            $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::WriteAllText((Join-Path $RepoPath 'goal-run-active.json'), "{`"issue`": 929}`n", $utf8NoBom)
            [System.IO.File]::WriteAllText((Join-Path $RepoPath 'goal-run-log.jsonl'),  "{`"event`": `"launch`"}`n", $utf8NoBom)
        }
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

    Context 'T6 — writes the anchored goal-run runtime-state patterns to .git/info/exclude' {
        It 'records both anchored patterns in .git/info/exclude and git actually stops reporting the two files' {
            $repo = script:New-EsgTempRepo -Label 't6'
            try {
                & $script:ScriptFile -RepoRoot $repo
                $LASTEXITCODE | Should -Be 0

                $excludePath = Join-Path $repo '.git/info/exclude'
                Test-Path -LiteralPath $excludePath | Should -Be $true -Because 'the goal-run runtime-state patterns belong in the per-clone, untracked exclude file'

                $excludeLines = @(Get-Content -LiteralPath $excludePath | ForEach-Object { $_.TrimEnd() })
                foreach ($pattern in $script:GoalRunExcludePatterns) {
                    $excludeLines | Should -Contain $pattern -Because "the anchored pattern '$pattern' must be written verbatim to .git/info/exclude"
                }

                # Behavioural half: the entries are worthless unless git honours
                # them. This is the actual #929 condition -- the goal-run harness
                # writes both files at its worktree root, and the contract
                # validator refuses a dirty -RepoRoot before doing anything else.
                $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
                [System.IO.File]::WriteAllText((Join-Path $repo 'goal-run-active.json'), "{`"issue`": 929}`n", $utf8NoBom)
                [System.IO.File]::WriteAllText((Join-Path $repo 'goal-run-log.jsonl'),  "{`"event`": `"launch`"}`n", $utf8NoBom)

                $porcelain = (@(& git -C $repo status --porcelain) -join "`n")
                $porcelain | Should -Not -Match 'goal-run-active\.json' -Because 'an excluded runtime-state file must not appear in git status'
                $porcelain | Should -Not -Match 'goal-run-log\.jsonl'   -Because 'an excluded runtime-state file must not appear in git status'
            }
            finally {
                Remove-Item -Recurse -Force $repo -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'T7 — idempotency on .git/info/exclude' {
        It 'does not duplicate the goal-run patterns when run a second time' {
            $repo = script:New-EsgTempRepo -Label 't7'
            try {
                & $script:ScriptFile -RepoRoot $repo
                $LASTEXITCODE | Should -Be 0
                & $script:ScriptFile -RepoRoot $repo
                $LASTEXITCODE | Should -Be 0

                $excludeLines = @(Get-Content -LiteralPath (Join-Path $repo '.git/info/exclude') | ForEach-Object { $_.TrimEnd() })
                foreach ($pattern in $script:GoalRunExcludePatterns) {
                    @($excludeLines | Where-Object { $_ -eq $pattern }).Count |
                        Should -Be 1 -Because "a second run must not append a duplicate '$pattern' entry"
                }
            }
            finally {
                Remove-Item -Recurse -Force $repo -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'T8 — fail-open outside a git repository' {
        It 'exits 0 and still applies the .gitignore scratch net when the directory is not a git repo' {
            $tempDir = script:New-EsgTempDir -Label 't8'
            try {
                # Precondition, asserted rather than assumed: if the system temp
                # path ever sits inside a git repo, the exclude step would
                # succeed and this case would silently stop testing fail-open.
                & git -C $tempDir rev-parse --git-common-dir 2>$null | Out-Null
                $LASTEXITCODE | Should -Not -Be 0 -Because 'precondition: the fixture directory must not be inside a git repository, or this case cannot exercise the fail-open path'

                & $script:ScriptFile -RepoRoot $tempDir -WarningAction SilentlyContinue
                $LASTEXITCODE | Should -Be 0 -Because 'Ensure-ScratchGitignore must never crash the SessionStart hook (fail-open)'

                # The two steps fail open INDEPENDENTLY: an exclude-step failure
                # must not suppress the scratch-containment step.
                $gitignorePath = Join-Path $tempDir '.gitignore'
                Test-Path -LiteralPath $gitignorePath | Should -Be $true -Because 'a failed exclude step must not prevent the .gitignore scratch net from being written'
                $lines = @(Get-Content -LiteralPath $gitignorePath | ForEach-Object { $_.TrimEnd() })
                $lines | Should -Contain '.tmp/' -Because 'the scratch-containment step is independent of the exclude step'
            }
            finally {
                Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'T9 — the goal-run patterns never reach .gitignore' {
        It 'leaves .gitignore free of any goal-run entry' {
            $repo = script:New-EsgTempRepo -Label 't9'
            try {
                & $script:ScriptFile -RepoRoot $repo
                $LASTEXITCODE | Should -Be 0

                $gitignoreContent = Get-Content -LiteralPath (Join-Path $repo '.gitignore') -Raw
                $gitignoreContent | Should -Not -Match 'goal-run' -Because '.gitignore is a TRACKED file; appending to it would itself dirty the launch repo and re-trigger the exact refused: uncommitted-changes halt #929 exists to prevent'
            }
            finally {
                Remove-Item -Recurse -Force $repo -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'T10/T11 — #929 AC2: the goal-run runtime-state pair reads as clean through Test-GCTreeClean' {

        # New-GCDisposableWorktree calls Test-GCTreeClean on -RepoRoot before
        # it does anything else, so if the two files the harness itself writes
        # at the worktree root are visible to `git status`, every run's first
        # predicate call halts with 'refused: uncommitted-changes'. These two
        # cases are a matched pair: the first proves the shipped ignore
        # mechanism makes that pair invisible, the second proves the first has
        # teeth by showing the identical scenario failing without it.

        BeforeEach {
            (Get-Command -Name 'Test-GCTreeClean' -ErrorAction SilentlyContinue) |
                Should -Not -BeNullOrEmpty -Because "the #929 AC2 integration claim spans this script and Test-GCTreeClean; if $($script:ValidateCoreLib) no longer defines it, this pair must fail loudly rather than silently stop guarding"
        }

        It 'T10: reports IsClean = $true when the ONLY files beyond the committed tree are goal-run-active.json and goal-run-log.jsonl, after the shipped ignore mechanism has run' {
            $repo = script:New-EsgSeededRepo -Label 't10'
            try {
                # Exercise the REAL production mechanism, not a hand-seeded
                # exclude file: Ensure-ScratchGitignore.ps1 is what the
                # SessionStart hook runs, so this case goes red if the shipped
                # script stops making the pair invisible to `git status` by ANY
                # mechanism. It deliberately does NOT pin the destination: the
                # fixture commits whatever the script wrote to .gitignore, so a
                # regression that moved the goal-run patterns back into
                # .gitignore would still leave this case green. T9 is the case
                # that forbids that destination, and T12 is the case that pins
                # WHICH exclude file the entries must reach.
                & $script:ScriptFile -RepoRoot $repo *>&1 | Out-Null
                $LASTEXITCODE | Should -Be 0

                # That script also extends .gitignore with the scratch-
                # containment net, which is itself an untracked change; commit
                # it so the tree genuinely starts clean rather than starting
                # dirty for an unrelated reason.
                & git -C $repo add -A 2>&1 | Out-Null
                & git -C $repo commit -q -m 'ignore protection' 2>&1 | Out-Null

                $precondition = Test-GCTreeClean -Path $repo
                $precondition.IsClean | Should -Be $true -Because 'precondition: the fixture repo must start clean, otherwise a later "clean" or "dirty" reading cannot be attributed to the goal-run files at all'

                script:New-EsgGoalRunRuntimeState -RepoPath $repo

                # Guard against the vacuous pass where the files were never
                # actually created and "clean" therefore proves nothing.
                Test-Path -LiteralPath (Join-Path $repo 'goal-run-active.json') | Should -Be $true -Because 'the runtime-state files must really be on disk for this assertion to mean anything'
                Test-Path -LiteralPath (Join-Path $repo 'goal-run-log.jsonl')   | Should -Be $true -Because 'the runtime-state files must really be on disk for this assertion to mean anything'

                $result = Test-GCTreeClean -Path $repo

                $result.IsClean | Should -Be $true -Because 'the goal-run harness writes these two files at its own execution worktree root, so a tree containing only them must read as clean or New-GCDisposableWorktree refuses every run with uncommitted-changes (#929)'
                @($result.Porcelain).Count | Should -Be 0 -Because 'no porcelain entry may survive for the goal-run runtime-state pair'
            }
            finally {
                Remove-Item -Recurse -Force $repo -ErrorAction SilentlyContinue
            }
        }

        It 'T11: reports IsClean = $false with both goal-run files listed as untracked when the ignore protection is absent (negative control)' {
            # Identical to T10 except Ensure-ScratchGitignore.ps1 is never run.
            # If this control ever passes as clean, T10 is no longer proving
            # anything.
            $repo = script:New-EsgSeededRepo -Label 't11'
            try {
                $precondition = Test-GCTreeClean -Path $repo
                $precondition.IsClean | Should -Be $true -Because 'precondition: the control fixture must also start clean, so its dirty reading is attributable to the goal-run files alone'

                script:New-EsgGoalRunRuntimeState -RepoPath $repo

                Test-Path -LiteralPath (Join-Path $repo 'goal-run-active.json') | Should -Be $true -Because 'the runtime-state files must really be on disk for this control to mean anything'
                Test-Path -LiteralPath (Join-Path $repo 'goal-run-log.jsonl')   | Should -Be $true -Because 'the runtime-state files must really be on disk for this control to mean anything'

                $result = Test-GCTreeClean -Path $repo

                $result.IsClean | Should -Be $false -Because 'without the ignore protection the harness runtime-state pair is plain untracked content, which is exactly the #929 halt'
                $porcelainJoined = (@($result.Porcelain) -join "`n")
                $porcelainJoined | Should -Match '\?\?\s+goal-run-active\.json'  -Because 'the unprotected control must show goal-run-active.json as untracked'
                $porcelainJoined | Should -Match '\?\?\s+goal-run-log\.jsonl'    -Because 'the unprotected control must show goal-run-log.jsonl as untracked'
            }
            finally {
                Remove-Item -Recurse -Force $repo -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'T12 — linked worktree: the entries reach the SHARED exclude file git actually reads' {

        # Every other git-repo case here builds its fixture with `git init`, i.e.
        # a main checkout, where `git rev-parse --git-common-dir` answers the
        # relative '.git'. Inside a LINKED worktree it answers an absolute path
        # to the shared .git, and --git-dir answers .git/worktrees/<name>, whose
        # info/exclude git never consults. The goal-run harness provisions linked
        # worktrees, so that is the shape #929 is actually about -- and without
        # this case a regression from --git-common-dir back to --git-dir keeps
        # the whole suite green while writing the patterns somewhere inert.

        It 'writes both patterns to the shared common-dir exclude file, leaves the per-worktree exclude untouched, and git inside the linked worktree honours them' {
            $mainRepo   = script:New-EsgSeededRepo -Label 't12-main'
            $linkedRoot = script:New-EsgTempDir   -Label 't12-linked'
            $linkedPath = Join-Path $linkedRoot 'wt'
            try {
                & git -C $mainRepo worktree add -q -b esg-t12 $linkedPath 2>&1 | Out-Null
                $LASTEXITCODE | Should -Be 0 -Because 'this case cannot exercise the linked-worktree path unless git actually creates the worktree'

                # Precondition, asserted rather than assumed: the fixture only
                # tests anything if --git-dir and --git-common-dir genuinely
                # diverge here. That divergence IS the linked-worktree condition
                # the script's flag choice exists for; asserted via git's own
                # answers rather than a path-shape check so it stays stable
                # across platforms and git versions.
                $wtGitDir    = ("$(& git -C $linkedPath rev-parse --git-dir        2>$null | Select-Object -First 1)").Trim()
                $wtCommonDir = ("$(& git -C $linkedPath rev-parse --git-common-dir 2>$null | Select-Object -First 1)").Trim()
                $wtGitDir    | Should -Not -BeNullOrEmpty
                $wtCommonDir | Should -Not -BeNullOrEmpty
                $wtGitDir | Should -Not -Be $wtCommonDir -Because 'a linked worktree is precisely the case where --git-dir and --git-common-dir differ; if they agree, this fixture degenerated into another main-checkout case'

                & $script:ScriptFile -RepoRoot $linkedPath
                $LASTEXITCODE | Should -Be 0

                # 1. The shared exclude file — the only one git consults — carries both patterns.
                $sharedExclude = Join-Path $mainRepo '.git/info/exclude'
                Test-Path -LiteralPath $sharedExclude | Should -Be $true -Because 'the shared common-dir exclude file is the one git applies to every worktree'
                $sharedLines = @(Get-Content -LiteralPath $sharedExclude | ForEach-Object { $_.TrimEnd() })
                foreach ($pattern in $script:GoalRunExcludePatterns) {
                    $sharedLines | Should -Contain $pattern -Because "'$pattern' must reach the SHARED .git/info/exclude when the script is pointed at a linked worktree"
                }

                # 2. Nothing was written to the per-worktree admin dir, which is
                #    where a regression to --git-dir would silently put it.
                $worktreesDir = Join-Path $mainRepo '.git/worktrees'
                $strayExcludes = @(
                    Get-ChildItem -LiteralPath $worktreesDir -Recurse -File -Filter 'exclude' -ErrorAction SilentlyContinue |
                        Where-Object {
                            $text = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue
                            $text -and ($text -match 'goal-run')
                        }
                )
                $strayExcludes.Count | Should -Be 0 -Because "git never consults .git/worktrees/<name>/info/exclude, so patterns landing there are inert; found: $($strayExcludes.FullName -join ' | ')"

                # 3. Behavioural half: git INSIDE the linked worktree must really
                #    stop reporting the pair. This is the condition the goal-run
                #    harness depends on, and it is what a --git-dir regression breaks.
                script:New-EsgGoalRunRuntimeState -RepoPath $linkedPath
                Test-Path -LiteralPath (Join-Path $linkedPath 'goal-run-active.json') | Should -Be $true -Because 'the runtime-state files must really be on disk for the status assertion to mean anything'
                Test-Path -LiteralPath (Join-Path $linkedPath 'goal-run-log.jsonl')   | Should -Be $true -Because 'the runtime-state files must really be on disk for the status assertion to mean anything'

                $porcelain = (@(& git -C $linkedPath status --porcelain) -join "`n")
                $porcelain | Should -Not -Match 'goal-run-active\.json' -Because 'an excluded runtime-state file must not appear in git status inside the linked worktree'
                $porcelain | Should -Not -Match 'goal-run-log\.jsonl'   -Because 'an excluded runtime-state file must not appear in git status inside the linked worktree'
            }
            finally {
                & git -C $mainRepo worktree remove --force $linkedPath 2>&1 | Out-Null
                & git -C $mainRepo worktree prune 2>&1 | Out-Null
                Remove-Item -Recurse -Force $linkedRoot -ErrorAction SilentlyContinue
                Remove-Item -Recurse -Force $mainRepo   -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'D-new-4 — script ignore lists / repo .gitignore parity' {
        It 'has every line the script requires present verbatim in this repo committed .gitignore' {
            # The list is read out of the script by parsing it, never restated
            # here: a test carrying its own copy of the list would recreate the
            # very duplication defect it exists to prevent. Parsing (rather than
            # dot-sourcing or invoking) also guarantees this test cannot write to
            # the working tree's .gitignore while it runs.
            $required = script:Get-EsgScriptArrayLiteral -VariableName 'requiredLines'
            $required.Count | Should -BeGreaterThan 0 -Because 'a parse that yields zero required lines must fail loudly, never pass vacuously'

            $actualLines = script:Get-EsgRepoGitignoreLines

            $missing = @($required | Where-Object { $_ -notin $actualLines })
            $missing.Count | Should -Be 0 -Because "these line(s) are required by Ensure-ScratchGitignore.ps1 but absent from the repo .gitignore: $($missing -join ' | ')"
        }

        It 'has every goal-run exclude pattern the script writes also committed verbatim in this repo own .gitignore' {
            # INTENT — read this before "fixing" it.
            #
            # The two lists differ in what the script does with them, and that
            # difference is the whole point of #929:
            #   $requiredLines       -> the script WRITES these into .gitignore.
            #                           The guard above is a same-destination
            #                           parity check.
            #   $goalRunExcludeLines -> the script writes these to
            #                           .git/info/exclude, and MUST NEVER write
            #                           them to .gitignore (see T9 — a tracked
            #                           .gitignore edit dirties the launch repo
            #                           and re-triggers the exact
            #                           'refused: uncommitted-changes' halt).
            #
            # So this is NOT asserting that the script writes to .gitignore. It
            # asserts a deliberate belt-and-braces property of the HUB repo:
            # the hub SEPARATELY COMMITS these same patterns to its own
            # .gitignore (#929 AC1), so hub clones are protected even before
            # the SessionStart hook has ever run. Deleting those lines from the
            # hub .gitignore previously failed no test at all.
            #
            # DO NOT "fix" a failure here by making the script append these to
            # .gitignore. That is precisely the regression #929 removed. Fix it
            # by restoring the lines to the hub's committed .gitignore.
            $goalRunLines = script:Get-EsgScriptArrayLiteral -VariableName 'goalRunExcludeLines'
            $goalRunLines.Count | Should -BeGreaterThan 0 -Because 'a parse that yields zero goal-run exclude lines must fail loudly, never pass vacuously'

            $actualLines = script:Get-EsgRepoGitignoreLines

            $missing = @($goalRunLines | Where-Object { $_ -notin $actualLines })
            $missing.Count | Should -Be 0 -Because "these goal-run pattern(s) are written to .git/info/exclude by Ensure-ScratchGitignore.ps1 and must ALSO stay committed in the hub repo .gitignore (#929 AC1), but are absent from it: $($missing -join ' | ')"
        }
    }

}
