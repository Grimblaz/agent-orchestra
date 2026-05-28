#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    RED contract tests for issue #552 Step 1.

.DESCRIPTION
    Test honesty marker: these tests use file-content grep, lightweight
    YAML/frontmatter parsing, and frame-validator stubs only. They perform NO
    live Agent-tool dispatch.
#>

Describe 'Issue #552 Senior Engineer skill-as-adapter contracts (grep/YAML/validator only; NO live Agent-tool dispatch)' -Tag 'contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:SeniorEngineerBodyPath = Join-Path $script:RepoRoot 'agents\Senior-Engineer.agent.md'
        $script:SeniorEngineerShellPath = Join-Path $script:RepoRoot 'agents\senior-engineer.md'
        $script:SpineRunnerPath = Join-Path $script:RepoRoot 'agents\Spine-Runner.agent.md'
        $script:FrameValidateLibPath = Join-Path $script:RepoRoot '.github\scripts\lib\frame-validate-core.ps1'
        $script:FrameCreditEmissionPath = Join-Path $script:RepoRoot 'skills\frame-credit-emission\SKILL.md'
        $script:LedgerCorePath = Join-Path $script:RepoRoot '.github\scripts\lib\frame-credit-ledger-core.ps1'
        $script:ClaudeMdPath = Join-Path $script:RepoRoot 'CLAUDE.md'
        $script:PlanAuthoringPath = Join-Path $script:RepoRoot 'skills\plan-authoring\SKILL.md'
        $script:FrameArchitecturePath = Join-Path $script:RepoRoot 'Documents\Design\frame-architecture.md'
        $script:ImplementCodeAdapterPath = Join-Path $script:RepoRoot 'skills\implementation-discipline\adapters\implement-code-adapter.md'
        $script:AdversarialAdaptersPath = Join-Path $script:RepoRoot 'skills\adversarial-review\adapters'
        $script:CanonicalHandshakeShellPath = Join-Path $script:RepoRoot 'agents\code-critic.md'

        . $script:FrameValidateLibPath
        . $script:LedgerCorePath

        $script:ReadText = {
            param([Parameter(Mandatory)][string]$Path)
            return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop) -replace "`r`n?", "`n"
        }

        $script:GetFrontmatter = {
            param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)

            $match = [regex]::Match($Content, '(?ms)\A---\n(?<frontmatter>.*?)\n---(?:\n|\z)')
            if (-not $match.Success) { return '' }
            return $match.Groups['frontmatter'].Value
        }

        $script:GetFrontmatterScalar = {
            param(
                [Parameter(Mandatory)][AllowEmptyString()][string]$Frontmatter,
                [Parameter(Mandatory)][string]$FieldName
            )

            $match = [regex]::Match($Frontmatter, '(?m)^' + [regex]::Escape($FieldName) + ':\s*(?<value>.+?)\s*(?:#.*)?$')
            if (-not $match.Success) { return $null }
            return $match.Groups['value'].Value.Trim().Trim('"').Trim("'")
        }

        $script:GetFrontmatterList = {
            param(
                [Parameter(Mandatory)][AllowEmptyString()][string]$Frontmatter,
                [Parameter(Mandatory)][string]$FieldName
            )

            $scalar = & $script:GetFrontmatterScalar -Frontmatter $Frontmatter -FieldName $FieldName
            if ($null -eq $scalar) { return [string[]]@() }

            if ($scalar.StartsWith('[') -and $scalar.EndsWith(']')) {
                $inner = $scalar.Substring(1, $scalar.Length - 2).Trim()
                if ($inner.Length -eq 0) { return [string[]]@() }
                return [string[]]@($inner -split ',' | ForEach-Object { $_.Trim().Trim('"').Trim("'") })
            }

            return [string[]]@($scalar)
        }

        $script:NormalizeWhitespace = {
            param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
            return ([regex]::Replace($Content, '\s+', ' ')).Trim()
        }

        $script:GetSingleVariantAdapterFiles = {
            $skillsPath = Join-Path $script:RepoRoot 'skills'
            return [System.IO.FileInfo[]]@(
                Get-ChildItem -LiteralPath $skillsPath -Directory |
                ForEach-Object {
                    $adaptersPath = Join-Path $_.FullName 'adapters'
                    if (Test-Path -LiteralPath $adaptersPath) {
                        Get-ChildItem -LiteralPath $adaptersPath -Filter '*-adapter.md' -File |
                            Where-Object { $_.Name -notmatch '-(auto-na|explicit-skip)-adapter\.md$' }
                    }
                } |
                Sort-Object -Property FullName
            )
        }

        $script:GetRelativePath = {
            param([Parameter(Mandatory)][string]$Path)
            return ([System.IO.Path]::GetRelativePath($script:RepoRoot, $Path) -replace '\\', '/')
        }

        $script:GetSectionBody = {
            param(
                [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
                [Parameter(Mandatory)][string]$Heading
            )

            $match = [regex]::Match($Content, '(?ms)^' + [regex]::Escape($Heading) + '\s*\n(?<body>.*?)(?=^## |\z)')
            if (-not $match.Success) { return '' }
            return $match.Groups['body'].Value.Trim()
        }

        $script:GetPlanComment = {
            param(
                [AllowNull()][string]$ExecutorLine,
                [AllowNull()][string]$AdapterLine
            )

            $sliceFields = [System.Collections.Generic.List[string]]::new()
            if (-not [string]::IsNullOrWhiteSpace($AdapterLine)) { $sliceFields.Add($AdapterLine) | Out-Null }
            $sliceFields.Add('provides: [implement-code]') | Out-Null
            if (-not [string]::IsNullOrWhiteSpace($ExecutorLine)) { $sliceFields.Add($ExecutorLine) | Out-Null }
            $sliceFields.Add('depends-on: []') | Out-Null
            $sliceFields.Add('ac-refs: [AC10]') | Out-Null

            return [string](@(
                    '# Issue 552 plan fixture'
                    ''
                    '## Acceptance Criteria'
                    '- **AC10** Senior Engineer skill-as-adapter contracts are structurally validated.'
                    ''
                    '<!-- frame-spine'
                    'spine_schema_version: 1'
                    'generated_at: 2026-05-13T12:00:00Z'
                    'coverage: complete'
                    'ports:'
                    '  implement-code: [s1]'
                    'slices:'
                    '  s1:'
                    '    execution_mode: serial'
                    '    rc: GREEN code action'
                    '    ac_refs: [AC10]'
                    '    depends_on: []'
                    '    cycle: 1'
                    '-->'
                    ''
                    '<!-- frame-slice'
                    'id: s1'
                ) + $sliceFields.ToArray() + @(
                    'slice: |'
                    '  Step 1 - Implement Senior Engineer executor path'
                    '  Execution Mode: serial'
                    '  Requirement Contract:'
                    '    - AC10 structural validation'
                    '-->'
                ) -join "`n")
        }
    }

    Context 'Senior Engineer shell and body frontmatter guards' {

        It 'ships the Claude shell and shared body files for Senior Engineer' {
            $script:SeniorEngineerShellPath | Should -Exist
            $script:SeniorEngineerBodyPath | Should -Exist
        }

        It 'keeps Senior Engineer shell on dispatcher inheritance without model or effort overrides' {
            $content = & $script:ReadText -Path $script:SeniorEngineerShellPath
            $frontmatter = & $script:GetFrontmatter -Content $content

            (& $script:GetFrontmatterScalar -Frontmatter $frontmatter -FieldName 'model') | Should -BeNullOrEmpty
            (& $script:GetFrontmatterScalar -Frontmatter $frontmatter -FieldName 'effort') | Should -BeNullOrEmpty
            $frontmatter | Should -Match '# model/effort intentionally omitted: inherits dispatcher per agent-orchestra routing convention'
        }

        It 'keeps Senior Engineer body frontmatter free of provides declarations' {
            $content = & $script:ReadText -Path $script:SeniorEngineerBodyPath
            $frontmatter = & $script:GetFrontmatter -Content $content

            (& $script:GetFrontmatterList -Frontmatter $frontmatter -FieldName 'provides') | Should -BeNullOrEmpty
        }

        It 'runs the canonical Claude environment handshake before loading the Senior Engineer shared body' {
            $content = & $script:ReadText -Path $script:SeniorEngineerShellPath
            $canonicalContent = & $script:ReadText -Path $script:CanonicalHandshakeShellPath

            $stepZero = & $script:GetSectionBody -Content $content -Heading '## Step 0: Environment Handshake Verification'
            $canonicalStepZero = & $script:GetSectionBody -Content $canonicalContent -Heading '## Step 0: Environment Handshake Verification'

            $stepZero | Should -Be $canonicalStepZero -Because 'Senior Engineer is tree-capable and must use the established Claude subagent handshake before role work'
            $content.IndexOf('## Step 0: Environment Handshake Verification') | Should -BeLessThan $content.IndexOf('## Shared methodology')
        }
    }

    Context 'Senior Engineer body grep guards' {

        It 'contains the canonical D11 adversarial-independence halt sentence with whitespace tolerance' {
            $content = & $script:ReadText -Path $script:SeniorEngineerBodyPath
            $normalizedContent = & $script:NormalizeWhitespace -Content $content
            $canonical = "Halt when the slice's adapter path matches the adversarial-pattern regex and the executor is the default Senior Engineer; emit halt-return with reason: adversarial-independence-required"

            $normalizedContent.Contains($canonical) | Should -BeTrue -Because 'Senior Engineer must carry the exact D11 halt sentence, modulo whitespace only'
        }

        It 'does not search the skills tree heuristically' {
            $content = & $script:ReadText -Path $script:SeniorEngineerBodyPath
            $forbiddenPatterns = @('Glob.*skills/', 'Grep.*skills/', 'find skills/')

            foreach ($pattern in $forbiddenPatterns) {
                [regex]::IsMatch($content, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline) |
                Should -BeFalse -Because "Senior Engineer must use the planner-designated adapter path instead of '$pattern'"
            }
        }
    }

    Context 'single-variant work adapter file parity' {

        It 'discovers at least one new single-variant `{port}-adapter.md` work adapter' {
            @(& $script:GetSingleVariantAdapterFiles) | Should -Not -BeNullOrEmpty -Because 'issue #552 Step 3 introduces implementation-discipline/adapters/implement-code-adapter.md'
        }

        It 'requires `{port}-adapter.md` files to declare matching provides, work type, and pick guidance' {
            $violations = [System.Collections.Generic.List[string]]::new()

            foreach ($file in @(& $script:GetSingleVariantAdapterFiles)) {
                $relativePath = & $script:GetRelativePath -Path $file.FullName
                $port = [System.IO.Path]::GetFileNameWithoutExtension($file.Name) -replace '-adapter$', ''
                $content = & $script:ReadText -Path $file.FullName
                $frontmatter = & $script:GetFrontmatter -Content $content
                $provides = [string[]]@(& $script:GetFrontmatterList -Frontmatter $frontmatter -FieldName 'provides')
                $adapterType = & $script:GetFrontmatterScalar -Frontmatter $frontmatter -FieldName 'adapter-type'

                if (($provides -join ',') -cne $port) { $violations.Add("$relativePath provides [$($provides -join ', ')] instead of [$port]") | Out-Null }
                if ($adapterType -cne 'work') { $violations.Add("$relativePath adapter-type '$adapterType' is not work") | Out-Null }
                if ($content -notmatch '(?m)^## When to use\s*$') { $violations.Add("$relativePath is missing ## When to use") | Out-Null }
                if ($content -notmatch '(?im)^#{3,6}\s*Pick\b') { $violations.Add("$relativePath is missing Pick guidance") | Out-Null }
                if ($content -notmatch "(?im)^#{3,6}\s*Don'?t[- ]pick\b") { $violations.Add("$relativePath is missing Don't-pick guidance") | Out-Null }
            }

            ($violations -join "`n") | Should -Be ''
        }

        It 'leaves legacy predicate and selector-named work adapters outside the `{port}-adapter.md` parity rule' {
            $candidatePaths = @(& $script:GetSingleVariantAdapterFiles | ForEach-Object { & $script:GetRelativePath -Path $_.FullName })

            $candidatePaths | Should -Not -Contain 'skills/adversarial-review/adapters/standard.md'
            $candidatePaths | Should -Not -Contain 'skills/adversarial-review/adapters/lite.md'
            $candidatePaths | Should -Not -Contain 'skills/adversarial-review/adapters/judge-only.md'
            $candidatePaths | Should -Not -Contain 'skills/adversarial-review/adapters/proxy-github.md'
        }
    }

    Context 'frame-slice executor enum validation' {

        It 'parses executor from frame-slice blocks while keeping it optional' {
            $withoutExecutor = ConvertFrom-FVPlanSliceBlock -Block @'
id: s1
provides: [implement-code]
ac-refs: [AC10]
'@
            $withExecutor = ConvertFrom-FVPlanSliceBlock -Block @'
id: s1
provides: [implement-code]
executor: agents/Senior-Engineer.agent.md
ac-refs: [AC10]
'@

            $withoutExecutor.Executor | Should -Be ''
            $withExecutor.Executor | Should -Be 'agents/Senior-Engineer.agent.md'
        }

        It 'parses adapter from frame-slice blocks while keeping it optional' {
            $withoutAdapter = ConvertFrom-FVPlanSliceBlock -Block @'
id: s1
provides: [implement-code]
ac-refs: [AC10]
'@
            $withAdapter = ConvertFrom-FVPlanSliceBlock -Block @'
id: s1
adapter: skills/implementation-discipline/adapters/implement-code-adapter.md
provides: [implement-code]
ac-refs: [AC10]
'@

            $withoutAdapter.Adapter | Should -Be ''
            $withAdapter.Adapter | Should -Be 'skills/implementation-discipline/adapters/implement-code-adapter.md'
        }

        It 'accepts only absent executor, agents/*.agent.md paths, and inline' -ForEach @(
            @{ Case = 'absent'; Executor = $null; Expected = $true }
            @{ Case = 'empty'; Executor = ''; Expected = $true }
            @{ Case = 'agent path'; Executor = 'agents/Senior-Engineer.agent.md'; Expected = $true }
            @{ Case = 'inline'; Executor = 'inline'; Expected = $true }
            @{ Case = 'none is deferred'; Executor = 'none'; Expected = $false }
            @{ Case = 'bare agent name'; Executor = 'Senior-Engineer'; Expected = $false }
            @{ Case = 'skill path'; Executor = 'skills/implementation-discipline/SKILL.md'; Expected = $false }
            @{ Case = 'nested agent path'; Executor = 'agents/internal/Senior-Engineer.agent.md'; Expected = $false }
        ) {
            param($Case, $Executor, $Expected)

            Test-FVExecutorValue -Executor $Executor | Should -Be $Expected -Because "executor enum case '$Case' must match the issue #552 contract"
        }

        It 'keeps plan-mode validation in parity with the executor recognizer' -ForEach @(
            @{ Case = 'absent'; ExecutorLine = $null; ShouldPass = $true }
            @{ Case = 'agent path'; ExecutorLine = 'executor: agents/Senior-Engineer.agent.md'; ShouldPass = $true }
            @{ Case = 'inline'; ExecutorLine = 'executor: inline'; ShouldPass = $true }
            @{ Case = 'none'; ExecutorLine = 'executor: none'; ShouldPass = $false }
            @{ Case = 'invalid'; ExecutorLine = 'executor: agents/Senior-Engineer.md'; ShouldPass = $false }
        ) {
            param($Case, $ExecutorLine, $ShouldPass)

            $comment = & $script:GetPlanComment -ExecutorLine $ExecutorLine
            $result = Invoke-FrameValidate -Mode plan -CommentText $comment

            if ($ShouldPass) {
                $result.ExitCode | Should -Be 0 -Because "executor case '$Case' should be accepted"
                return
            }

            $result.ExitCode | Should -Not -Be 0 -Because "executor case '$Case' should be rejected"
            (@($result.Results).Detail -join "`n") | Should -Match 'invalid executor'
        }

        It 'rejects explicit and default Senior Engineer executor pairing for every adversarial-review adapter path' {
            $adapterPaths = @(
                Get-ChildItem -LiteralPath $script:AdversarialAdaptersPath -Filter '*.md' -File |
                Sort-Object -Property Name |
                ForEach-Object { & $script:GetRelativePath -Path $_.FullName }
            )

            $adapterPaths | Should -Not -BeNullOrEmpty

            foreach ($adapterPath in $adapterPaths) {
                foreach ($executorLine in @($null, 'executor: agents/Senior-Engineer.agent.md')) {
                    $comment = & $script:GetPlanComment -ExecutorLine $executorLine -AdapterLine "adapter: $adapterPath"
                    $result = Invoke-FrameValidate -Mode plan -CommentText $comment

                    $result.ExitCode | Should -Not -Be 0 -Because "$adapterPath must not be executable by the default Senior Engineer"
                    (@($result.Results).Detail -join "`n") | Should -Match 'adversarial-pattern adapter'
                }
            }
        }

        It 'rejects explicit and default Senior Engineer executor pairing for keyword adversarial adapter paths' -ForEach @(
            @{ Keyword = 'review'; AdapterPath = 'skills/example/adapters/review-findings-adapter.md' }
            @{ Keyword = 'adversarial'; AdapterPath = 'skills/example/adapters/adversarial-scan-adapter.md' }
            @{ Keyword = 'critique'; AdapterPath = 'skills/example/adapters/critique-output-adapter.md' }
            @{ Keyword = 'challenge'; AdapterPath = 'skills/example/adapters/challenge-plan-adapter.md' }
        ) {
            param($Keyword, $AdapterPath)

            foreach ($executorLine in @($null, 'executor: agents/Senior-Engineer.agent.md')) {
                $comment = & $script:GetPlanComment -ExecutorLine $executorLine -AdapterLine "adapter: $AdapterPath"
                $result = Invoke-FrameValidate -Mode plan -CommentText $comment

                $result.ExitCode | Should -Not -Be 0 -Because "keyword adversarial adapter '$Keyword' must not be executable by the default Senior Engineer"
                (@($result.Results).Detail -join "`n") | Should -Match 'adversarial-pattern adapter'
            }
        }

        It 'keeps explicit and default Senior Engineer executor valid for non-adversarial work adapters' {
            foreach ($executorLine in @($null, 'executor: agents/Senior-Engineer.agent.md')) {
                $comment = & $script:GetPlanComment -ExecutorLine $executorLine -AdapterLine 'adapter: skills/implementation-discipline/adapters/implement-code-adapter.md'
                $result = Invoke-FrameValidate -Mode plan -CommentText $comment

                $result.ExitCode | Should -Be 0
            }
        }

        It 'documents the deferred executor none semantics in the validator source' {
            $validatorContent = & $script:ReadText -Path $script:FrameValidateLibPath

            $validatorContent | Should -Match 'TODO\(follow-up\).*executor: none semantics'
        }
    }

    Context 'Spine-Runner Senior Engineer dispatch-table inspection' {

        It 'maps adversarial-pattern adapters plus default Senior Engineer executor to halt-return without live dispatch' {
            $content = & $script:ReadText -Path $script:SpineRunnerPath
            $pattern = '(?is)adversarial-pattern adapters.*agents/Senior-Engineer\.agent\.md.*halt-return.*adversarial-independence-required|agents/Senior-Engineer\.agent\.md.*adversarial-pattern adapters.*halt-return.*adversarial-independence-required'

            $content | Should -Match $pattern -Because 'the synthetic D11(b) fixture must be represented by documented dispatch-table/body text, not live Agent dispatch'
        }

        It 'documents absent executor defaulting for single-variant work adapters' {
            $content = & $script:ReadText -Path $script:SpineRunnerPath

            $content | Should -Match 'absent `executor:` or `executor: agents/\*\.agent\.md`' -Because 'Spine-Runner must not require planners to repeat the default Senior Engineer executor on every work-adapter slice'
            $content | Should -Match 'When `executor:` is absent, use `agents/Senior-Engineer\.agent\.md`' -Because 'the invocation contract must match plan-authoring and frame-architecture defaulting rules'
        }
    }

    Context 'cross-document enum string equality' {

        It 'uses the same executor enum literal in CLAUDE, plan-authoring, and frame architecture docs' {
            $literal = 'agents/*.agent.md path | inline'
            foreach ($path in @($script:ClaudeMdPath, $script:PlanAuthoringPath, $script:FrameArchitecturePath)) {
                $content = & $script:ReadText -Path $path
                $content | Should -Match ([regex]::Escape($literal)) -Because "$((& $script:GetRelativePath -Path $path)) must carry the shared executor enum literal"
            }
        }

        It 'uses the same adapter-type enum literal in CLAUDE, plan-authoring, and frame architecture docs' {
            $literal = 'work | predicate'
            foreach ($path in @($script:ClaudeMdPath, $script:PlanAuthoringPath, $script:FrameArchitecturePath)) {
                $content = & $script:ReadText -Path $path
                $content | Should -Match ([regex]::Escape($literal)) -Because "$((& $script:GetRelativePath -Path $path)) must carry the shared adapter-type enum literal"
            }
        }
    }

    Context 'Senior Engineer credit-emission schema forward compatibility' {

        It 'documents terminal-step credit emission with -Step while preserving spine-omitted legacy behavior' {
            $content = & $script:ReadText -Path $script:ImplementCodeAdapterPath

            $content | Should -Match '-Step \{terminal-step-id\}' -Because 'spine-backed terminal slices must pass the terminal step to the implement-code credit builder'
            $content | Should -Match 'spine-omitted|legacy' -Because 'adapter guidance must preserve existing semantics when no terminal step id is available'
        }

        It 'documents the same SE credit row keys as Build-ImplementCodeCreditRow' {
            # Cross-link #557: this guards the future credit-schema migration while SE remains additive.
            $canonicalRow = Build-ImplementCodeCreditRow -ValidationEvidence @(@{ Name = 'pester'; Status = 'passed' })
            $canonicalKeys = [string[]]@($canonicalRow.PSObject.Properties.Name | Where-Object { $_ -ne 'terminal-step-id' } | Sort-Object)
            $content = & $script:ReadText -Path $script:FrameCreditEmissionPath
            $sectionMatch = [regex]::Match($content, '(?ims)^### .*Senior Engineer.*?\n(?<body>.*?)(?=^### |^## |\z)')

            $sectionMatch.Success | Should -BeTrue -Because 'frame-credit-emission must document the Senior Engineer skill-adapter credit path'
            if (-not $sectionMatch.Success) { return }

            $documentedKeys = [string[]]@(
                [regex]::Matches($sectionMatch.Groups['body'].Value, '`(?<key>port|adapter|status|evidence)`') |
                ForEach-Object { $_.Groups['key'].Value } |
                Sort-Object -Unique
            )

            ($documentedKeys -join ',') | Should -Be ($canonicalKeys -join ',') -Because 'SE documentation must name exactly the same row keys as Build-ImplementCodeCreditRow'
        }
    }
}
