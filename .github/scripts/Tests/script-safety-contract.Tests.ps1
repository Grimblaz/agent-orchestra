#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Contract tests for script safety patterns in production PowerShell scripts.

.DESCRIPTION
    Locks issue #212 W3b safety invariants:
      - Production scripts must not use Invoke-Expression or the iex alias
      - Production scripts must not call .Clone() on collections
      - $knownCategories in aggregate-review-scores.ps1 must contain exactly the 7 mandated taxonomy values

    Production scripts are defined as all .ps1 files under .github/scripts/ (root and /lib/)
    plus skill scripts under skills/**/scripts/, excluding test files. Update these
    tests only when the underlying safety contract intentionally changes.
#>

Describe 'script safety contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ScriptsRoot = Join-Path -Path $script:RepoRoot -ChildPath '.github' -AdditionalChildPath 'scripts'
        $script:SkillsRoot = Join-Path -Path $script:RepoRoot -ChildPath 'skills'
        $script:AggregateReviewScores = Join-Path $script:SkillsRoot 'calibration-pipeline/scripts/aggregate-review-scores.ps1'
        $script:AggregateReviewScoresCore = Join-Path $script:SkillsRoot 'calibration-pipeline/scripts/aggregate-review-scores-core.ps1'

        $script:ProductionScripts = @(
            Get-ChildItem -Path $script:ScriptsRoot -Recurse -Filter '*.ps1' |
                Where-Object { $_.DirectoryName -notmatch '[/\\]Tests([/\\]|$)' }
                Get-ChildItem -Path $script:SkillsRoot -Recurse -Filter '*.ps1' |
                    Where-Object {
                        $_.DirectoryName -match '[/\\]scripts([/\\]|$)' -and
                        $_.DirectoryName -notmatch '[/\\]Tests([/\\]|$)'
                    }
                ) | Sort-Object -Property FullName -Unique

                # Canonical taxonomy — sorted alphabetically for deterministic comparison
                $script:MandatedCategories = @(
                    'architecture', 'documentation-audit', 'implementation-clarity',
                    'pattern', 'performance', 'script-automation', 'security'
                )
            }

            It 'script safety: production scripts must not use Invoke-Expression or iex aliases' {
                $violations = $script:ProductionScripts | Where-Object {
                    $content = Get-Content -Path $_.FullName -Raw
                    $content -match '(?i)Invoke-Expression|\biex\b'
                } | Select-Object -ExpandProperty Name

        $violations | Should -HaveCount 0 -Because 'Invoke-Expression and its iex alias allow arbitrary code execution from strings, creating command-injection risk; use explicit cmdlet calls or operator pipelines instead'
    }

    It 'script safety: production scripts must not call .Clone() on collections' {
        $violations = $script:ProductionScripts | Where-Object {
            $content = Get-Content -Path $_.FullName -Raw
            $content -match '\.Clone\(\)'
        } | Select-Object -ExpandProperty Name

        $violations | Should -HaveCount 0 -Because 'avoid all `.Clone()` to prevent accidental use on `[ordered]` hashtables where it silently drops the ordered type; use explicit copy idioms (`| ConvertTo-Json | ConvertFrom-Json -AsHashtable`) in all cases'
    }

    It 'script safety: $knownCategories in aggregate-review-scores.ps1 must contain exactly the 7 mandated values' {
        $content = Get-Content -Path $script:AggregateReviewScoresCore -Raw

        $allMatches = [regex]::Matches($content, '(?s)\$knownCategories\s*=\s*@\((.*?)\)')
        $allMatches | Should -HaveCount 2 -Because '$knownCategories must be defined twice in aggregate-review-scores.ps1 (once for $accumulateFinding, once for emit loops) and both definitions must be present'

        $allMatches | ForEach-Object {
            $extractedSorted = [regex]::Matches($_.Groups[1].Value, "'([a-z-]+)'") |
                ForEach-Object { $_.Groups[1].Value } |
                Sort-Object

                ($extractedSorted -join ',') | Should -Be ($script:MandatedCategories -join ',') -Because 'every $knownCategories definition must contain exactly the 7 mandated taxonomy values (architecture, documentation-audit, implementation-clarity, pattern, performance, script-automation, security); drift breaks cross-script consistency and calibration data integrity'
            }
        }

        It 'script safety: test files must not spawn child pwsh processes (use dot-source + in-process call pattern)' {
            # Scope: detects statically-resolvable spawn forms only.
            # Variable/indirect invocation (e.g., $exe = 'pwsh'; & $exe) is out of scope —
            # AST cannot resolve runtime values. See Documents/Design/pester-suite-performance-audit.md.
            $allowlist = @(
                'audit-hub-artifact-paths.Tests.ps1',               # CLI integration tests: exercises script argument-parsing entry point; dot-source pattern cannot cover CLI flag paths
                'bootstrap-antigravity.Tests.ps1',                  # IRREDUCIBLE: exit-code-contract tests require real subprocess to capture exit code
                'branch-authority-gate.Tests.ps1',
                # cost-integration.Tests.ps1 — CONVERTED in s5: all spawn-based Its now use InvokeOrchestratorInProcess (in-process pattern)
                'frame-credit-ledger-fail-open.Tests.ps1',          # IRREDUCIBLE: 9 exit-code-contract Its that require subprocess to verify exit codes
                'phase-containment-emission-check.Tests.ps1',       # IRREDUCIBLE: 2 exit-code-contract Its (-Mode validation exit 2, fail-open lib-load exit 0) testing the top-level execution block, which is by definition skipped when dot-sourced (InvocationName == '.'); same class as frame-credit-ledger-fail-open.Tests.ps1's allowlisted exit-code contracts
                'frame-credit-ledger-orchestrated-origin-fallback.Tests.ps1', # IRREDUCIBLE (#794 s3): the $env:GITHUB_HEAD_REF fallback bug lives at Invoke-FrameCreditLedger's real script-entry call site; same class as frame-credit-ledger-suppress-failed-posts.Tests.ps1's runspace-isolation exemption below — an in-process dot-source call would not exercise the same boundary the bug lived in
                'frame-credit-ledger-orchestrator.Tests.ps1',       # kept 9 real-spawn smoke layer per s2 decision
                'frame-credit-ledger-suppress-failed-posts.Tests.ps1', # IRREDUCIBLE (#769 CR7): the off-switch bug lives in the cloned worker runspace; only a real subprocess exercises the runspace-isolation path an in-process dot-source call would mask
                'frame-spine-core.Tests.ps1',                       # IRREDUCIBLE: 1 spawn tests -CommentBodyStdin CLI switch (stdin-pipe contract; cannot simulate in-process without production code changes)
                'get-issue-drift.Tests.ps1',                        # IRREDUCIBLE: 1 spawn tests get-issue-drift.ps1 wrapper CLI surface (JSON output shape of the wrapper script)
                'goal-contract-validate-core.Tests.ps1',            # IRREDUCIBLE (#873 s6): the wrapper CLI smoke test spawns `& pwsh -File goal-contract-validate.ps1` because the wrapper guards its execution block on $isDotSourced ($MyInvocation.InvocationName -eq '.'), so dot-sourcing skips the top-level param block, JSON-stdout emission, and `exit $result.ExitCode` contract -- same class as newcomer-audit-wrapper.Tests.ps1's CLI-entry-point exemption above. The tree-kill timeout test separately spawns a real detached child process (via a runtime-resolved `(Get-Process -Id $PID).Path`, never a literal 'pwsh'/'powershell' name, so it is not what trips this AST guard -- it falls under the guard's own documented indirect/variable-invocation exclusion) to prove Process.Kill($true) reaps the entire descendant tree; an in-process call cannot create or observe a killed OS process tree
                'hub-artifact-paths-coverage.Tests.ps1',            # CLI integration tests: exercises -Diff mode against live repo; requires sub-process invocation
                'newcomer-audit-wrapper.Tests.ps1',                 # CLI integration tests (issue #751): 4 spawns exercise newcomer-audit.ps1's real argument-parsing entry point and exit-code contract (-Json/-Changed switches, no-args usage error) — dot-sourcing skips the top-level param block and exit codes, same class as audit-hub-artifact-paths.Tests.ps1
                'orchestra-spine-command.Tests.ps1',                # IRREDUCIBLE: exit-code-contract tests require real subprocess
                'plan-tree-state-verification-fail-open.Tests.ps1', # IRREDUCIBLE: exit-code-contract tests require real subprocess
                'post-merge-cleanup.Tests.ps1',                     # executor integration tests: post-merge-cleanup.ps1 is a top-level executable (no -core.ps1 library); the #656 AC6 failsafe test must spawn a subprocess to exercise the load-time exit 1, which dot-sourcing cannot test without terminating the Pester host
                'post-merge-cleanup-squash-merge.Tests.ps1',        # IRREDUCIBLE: exit-code + output contract tests for post-merge-cleanup.ps1 top-level executable; subprocess required (no -core.ps1 library)
                'script-safety-contract.Tests.ps1',                 # self-excluded: this file contains spawn-detection logic; AST scan would flag its own CommandAst nodes
                'session-cleanup-detector.Tests.ps1',
                'test-orphan-branch-auto-resolve-eligible.Tests.ps1', # IRREDUCIBLE: tri-state exit-code encoding (0/1/2) across subprocess boundary; converting would require architecture change to test helper
                'test-orphan-branch-commits-absorbed.Tests.ps1',    # IRREDUCIBLE: tri-state exit-code encoding (0/1/2) across subprocess boundary; converting would require architecture change to test helper
                'test-orphan-branch-github-signals.Tests.ps1'       # IRREDUCIBLE: tri-state exit-code encoding (0/1/2) across subprocess boundary; converting would require architecture change to test helper
            )

            # AST-based detection: catches both & pwsh / & powershell (CommandAst with command name)
            # and Start-Process -FilePath 'pwsh' / 'powershell' (named or positional FilePath argument).
            # String literals that contain 'pwsh' (e.g. assertion strings) are not CommandAst nodes
            # and are not flagged — this prevents false positives on files like Resolve-PersistDecision.Tests.ps1.
            $spawnTargets = [System.Collections.Generic.HashSet[string]]::new(
                [string[]]@('pwsh', 'powershell'),
                [System.StringComparer]::OrdinalIgnoreCase
            )
            $violations = Get-ChildItem -Path (Join-Path $script:ScriptsRoot 'Tests') -Filter '*.Tests.ps1' |
                Where-Object { $_.Name -notin $allowlist } |
                Where-Object {
                    $fileAst = [System.Management.Automation.Language.Parser]::ParseFile(
                        $_.FullName,
                        [ref]$null,
                        [ref]$null
                    )
                    $allCmds = $fileAst.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst]
                    }, $true)
                    $fileHasSpawn = $false
                    foreach ($cmd in $allCmds) {
                        $cmdName = $cmd.GetCommandName()
                        # Direct invocation: & pwsh ... or & powershell ...
                        if ($spawnTargets.Contains($cmdName)) {
                            $fileHasSpawn = $true
                            break
                        }
                        # Start-Process with -FilePath pwsh/powershell (named or positional)
                        if ($cmdName -eq 'Start-Process') {
                            $elems = $cmd.CommandElements
                            $elemCount = $elems.Count
                            for ($ei = 1; $ei -lt $elemCount; $ei++) {
                                $el = $elems[$ei]
                                # Named parameter: -FilePath followed by a string value
                                if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and
                                    $el.ParameterName -eq 'FilePath' -and ($ei + 1) -lt $elemCount) {
                                    $nextEl = $elems[$ei + 1]
                                    if ($nextEl -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                                        $spawnTargets.Contains($nextEl.Value)) {
                                        $fileHasSpawn = $true
                                        break
                                    }
                                }
                                # Positional first argument: Start-Process 'pwsh'
                                if ($ei -eq 1 -and $el -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                                    $spawnTargets.Contains($el.Value)) {
                                    $fileHasSpawn = $true
                                    break
                                }
                            }
                            if ($fileHasSpawn) { break }
                        }
                    }
                    $fileHasSpawn
                } |
                Select-Object -ExpandProperty Name

            $violations | Should -HaveCount 0 -Because 'test files must use the dot-source + in-process call pattern (dot-source lib/...core.ps1, call Invoke-... directly) instead of spawning a child pwsh process per test; spawning adds significant Pester suite overhead (see issue #257)'
        }

        It 'spawn-guard falsifiability: direct & pwsh invocation is detected by AST scan' {
            $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) "spawn-guard-falsifiability-direct-$([System.Guid]::NewGuid().ToString('N')).ps1"
            try {
                Set-Content -Path $tempFile -Value "& pwsh -File 'something.ps1'" -Encoding utf8
                $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                    $tempFile,
                    [ref]$null,
                    [ref]$null
                )
                $commands = $ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst]
                }, $true)
                $caught = $false
                foreach ($cmd in $commands) {
                    if ($cmd.GetCommandName() -in @('pwsh', 'powershell')) {
                        $caught = $true
                        break
                    }
                }
                $caught | Should -Be $true -Because 'the AST guard must detect direct & pwsh invocation'
            } finally {
                if (Test-Path $tempFile) { Remove-Item $tempFile -Force }
            }
        }

        It 'spawn-guard falsifiability: Start-Process -FilePath pwsh is detected by AST scan' {
            $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) "spawn-guard-falsifiability-startprocess-$([System.Guid]::NewGuid().ToString('N')).ps1"
            try {
                Set-Content -Path $tempFile -Value "Start-Process -FilePath 'pwsh' -ArgumentList @('-File', 'something.ps1')" -Encoding utf8
                $fAst = [System.Management.Automation.Language.Parser]::ParseFile(
                    $tempFile,
                    [ref]$null,
                    [ref]$null
                )
                $fCmds = $fAst.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst]
                }, $true)
                $fCaught = $false
                foreach ($cmd in $fCmds) {
                    if ($cmd.GetCommandName() -eq 'Start-Process') {
                        $fElems = $cmd.CommandElements
                        for ($fi = 1; $fi -lt $fElems.Count; $fi++) {
                            $fEl = $fElems[$fi]
                            if ($fEl -is [System.Management.Automation.Language.CommandParameterAst] -and
                                $fEl.ParameterName -eq 'FilePath' -and ($fi + 1) -lt $fElems.Count) {
                                $fNext = $fElems[$fi + 1]
                                if ($fNext -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                                    $fNext.Value -in @('pwsh', 'powershell')) {
                                    $fCaught = $true
                                    break
                                }
                            }
                        }
                        if ($fCaught) { break }
                    }
                }
                $fCaught | Should -Be $true -Because 'the AST guard must detect Start-Process -FilePath pwsh invocation'
            } finally {
                if (Test-Path $tempFile) { Remove-Item $tempFile -Force }
            }
        }

        It 'spawn-guard falsifiability: positional Start-Process pwsh is detected by AST scan' {
            $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) "spawn-guard-falsifiability-positional-$([System.Guid]::NewGuid().ToString('N')).ps1"
            try {
                Set-Content -Path $tempFile -Value "Start-Process 'pwsh' -ArgumentList '-NonInteractive', '-Command', 'exit 0' -NoNewWindow -Wait" -Encoding utf8
                $pAst = [System.Management.Automation.Language.Parser]::ParseFile(
                    $tempFile,
                    [ref]$null,
                    [ref]$null
                )
                $pCmds = $pAst.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst]
                }, $true)
                $pTargets = [System.Collections.Generic.HashSet[string]]::new(
                    [string[]]@('pwsh', 'powershell'),
                    [System.StringComparer]::OrdinalIgnoreCase
                )
                $pCaught = $false
                foreach ($cmd in $pCmds) {
                    if ($cmd.GetCommandName() -eq 'Start-Process') {
                        $pElems = $cmd.CommandElements
                        for ($pi = 1; $pi -lt $pElems.Count; $pi++) {
                            $pEl = $pElems[$pi]
                            # Positional first argument: Start-Process 'pwsh'
                            if ($pi -eq 1 -and
                                $pEl -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                                $pTargets.Contains($pEl.Value)) {
                                $pCaught = $true
                                break
                            }
                        }
                        if ($pCaught) { break }
                    }
                }
                $pCaught | Should -Be $true -Because 'the AST guard must detect positional Start-Process pwsh invocation'
            } finally {
                if (Test-Path $tempFile) { Remove-Item $tempFile -Force }
            }
        }
    }

Describe 'Script safety: no host-native absolute-path literals in shipped scripts' {
    It 'no .ps1 script under skills/ or .github/scripts/ constructs a Windows host-native absolute path' {
        # Tightened regex: drive letter + colon + backslash + UPPERCASE path-char
        # (?-i) forces case-sensitive matching: [A-Z] only matches uppercase, which eliminates
        # false positives from PowerShell regex-escape sequences (\s, \d, \w, \n, etc.) that use
        # lowercase meta-chars. Real Windows top-level dirs (Users, Windows, Program) start uppercase.
        # PowerShell Function:\foo PSDrive also uses lowercase after the backslash, so is excluded.
        # Exclude: full-line comments (TrimStart starts with #)
        # Exclude: lines inside block comments (<# ... #>) — e.g. .SYNOPSIS/.NOTES doc strings
        # Exclude: lines containing "# host-path-ok" allow-comment
        # Exclude: test files under */Tests/* — test fixtures may legitimately reference host paths
        # Scope: .ps1 files only under skills/ and .github/scripts/ (non-test)

        $pattern = '(?-i)[A-Za-z]:\\[A-Z][A-Za-z0-9_\\]'

        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $searchPaths = @('skills', '.github/scripts') |
            ForEach-Object { Join-Path $repoRoot $_ } |
            Where-Object { Test-Path $_ }
        $scriptFiles = $searchPaths | ForEach-Object {
            Get-ChildItem -Path $_ -Recurse -Include '*.ps1' -File |
                Where-Object { $_.DirectoryName -notmatch '[/\\]Tests([/\\]|$)' }
        }

        $violations = [System.Collections.Generic.List[object]]::new()
        foreach ($file in $scriptFiles) {
            $lines = Get-Content $file.FullName -ErrorAction SilentlyContinue
            if (-not $lines) { continue }
            $inBlockComment = $false
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                # Track block comment state (<# opens, #> closes)
                if ($line -match '<#') { $inBlockComment = $true }
                if ($inBlockComment) {
                    if ($line -match '#>') { $inBlockComment = $false }
                    continue
                }
                # Skip full-line comments
                if ($line.TrimStart() -like '#*') { continue }
                # Skip lines with the allow-comment
                if ($line -match '# host-path-ok') { continue }
                # Check for the pattern
                if ($line -match $pattern) {
                    $violations.Add([PSCustomObject]@{
                        File    = $file.FullName
                        Line    = $i + 1
                        Content = $line.Trim()
                    })
                }
            }
        }

        $violations | Should -BeNullOrEmpty -Because (
            "shipped scripts must not construct Windows host-native paths (C:\...). " +
            "Use relative .tmp/ paths or /c/... git-bash form instead (see skills/terminal-hygiene/SKILL.md ## Scratch & Temp-File Hygiene). " +
            "To suppress a legitimate reference, add '# host-path-ok' on the same line."
        )
    }

    It 'the guard catches an injected C:\ literal (falsifiability check)' {
        $pattern = '(?-i)[A-Za-z]:\\[A-Z][A-Za-z0-9_\\]'
        'Get-Content "C:\Users\Foo\bar.txt"'   | Should -Match $pattern
        'Invoke-Script C:\Windows\System32\foo' | Should -Match $pattern
    }

    It 'the guard ignores common regex-escape patterns (no false positives)' {
        $pattern = '(?-i)[A-Za-z]:\\[A-Z][A-Za-z0-9_\\]'
        'checkpoints:\s*\['            | Should -Not -Match $pattern
        'Function:\gh'                 | Should -Not -Match $pattern
        'Remove-Item Function:\ -Force' | Should -Not -Match $pattern
        'pattern:\d+'                  | Should -Not -Match $pattern
        'key:\{'                       | Should -Not -Match $pattern
    }

    It 'documents the known lowercase-host-path miss (by design — trade-off documented in scratch-containment.md)' {
        # The guard intentionally misses lowercase-first-segment paths to avoid
        # false positives on regex-escape sequences (\s, \d, \w, Function:\)
        $pattern = '(?-i)[A-Za-z]:\\[A-Z][A-Za-z0-9_\\]'
        'C:\temp\foo.txt'    | Should -Not -Match $pattern -Because "lowercase host paths are a documented miss"
        'C:\dev\out.txt'     | Should -Not -Match $pattern -Because "lowercase host paths are a documented miss"
    }
}
