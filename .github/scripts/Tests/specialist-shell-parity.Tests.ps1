# Requires -Version 7.0
# Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Focused parity coverage for the Phase 4 Claude specialist shells.

.DESCRIPTION
    Supplements the generic claude-shell-parity contract with specialist-specific
    checks for discovery, shared-body parity, canonical Step 0 handshake form,
    Claude tool-mapping table presence, and required literal gap announcements.
#>

Describe 'Phase 4 Claude specialist shell parity contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:AgentsDirectory = Join-Path $script:RepoRoot 'agents'
        $script:ParitySuffixPattern = '($|: |\s+\(|\s*$)'

        $script:GetDocumentState = {
            param([string]$Path)

            if (-not (Test-Path $Path)) {
                return @{ Path = $Path; Content = '' }
            }

            return @{ Path = $Path; Content = Get-Content -Path $Path -Raw -ErrorAction Stop }
        }

        $script:GetSectionBody = {
            param(
                [string]$Content,
                [string]$Heading
            )

            $pattern = '(?ms)^' + [regex]::Escape($Heading) + '\s*\r?\n(?<body>.*?)(?=^## |\z)'
            $match = [regex]::Match($Content, $pattern)
            if (-not $match.Success) {
                return ''
            }

            return $match.Groups['body'].Value
        }

        $script:GetSharedMethodologySection = {
            param([string]$Content)

            return & $script:GetSectionBody -Content $Content -Heading '## Shared methodology'
        }

        $script:GetBodyPointer = {
            param([string]$SharedMethodology)

            $match = [regex]::Match($SharedMethodology, '(?m)^The full tool-agnostic methodology for this role lives at `(?<pointer>agents/[^`]+\.agent\.md)` in the repo root\.\s*$')
            if (-not $match.Success) {
                return ''
            }

            return $match.Groups['pointer'].Value
        }

        $script:GetShellEnumerationParagraph = {
            param([string]$SharedMethodology)

            $match = [regex]::Match($SharedMethodology, '(?ms)^After loading, follow everything under its (?<paragraph>.*?)(?=\r?\n\r?\n|\z)')
            if (-not $match.Success) {
                return ''
            }

            return 'After loading, follow everything under its ' + $match.Groups['paragraph'].Value
        }

        $script:GetShellSectionTokens = {
            param([string]$EnumerationParagraph)

            return @(
                [regex]::Matches($EnumerationParagraph, '`(?<token>## [^`]+?)`') |
                    ForEach-Object { $_.Groups['token'].Value }
            )
        }

        $script:GetBodyH2Headings = {
            param([string]$Content)

            return @(
                [regex]::Matches($Content, '(?m)^## (?<title>[^\r\n]+)\s*$') |
                    ForEach-Object {
                        $title = $_.Groups['title'].Value.Trim()
                        if ($title -ne 'Platform-specific invocation') {
                            '## ' + $title
                        }
                    }
            )
        }

        $script:GetHeadingMatchesForToken = {
            param(
                [string]$Token,
                [string[]]$BodyHeadings
            )

            $pattern = '^' + [regex]::Escape($Token) + $script:ParitySuffixPattern
            return @($BodyHeadings | Where-Object { $_ -match $pattern })
        }

        $script:GetTokenMatchesForHeading = {
            param(
                [string]$Heading,
                [string[]]$ShellTokens
            )

            return @(
                $ShellTokens | Where-Object {
                    $Heading -match ('^' + [regex]::Escape($_) + $script:ParitySuffixPattern)
                }
            )
        }

        $script:NormalizeContent = {
            param([string]$Content)

            return ($Content -replace "`r`n?", "`n").Trim()
        }

        $script:ExpectedShells = @(
            [pscustomobject]@{
                Name                        = 'code-smith'
                BodyPointer                 = 'agents/Code-Smith.agent.md'
                RequiredLiteralAnnouncement = ''
            }
            [pscustomobject]@{
                Name                        = 'test-writer'
                BodyPointer                 = 'agents/Test-Writer.agent.md'
                RequiredLiteralAnnouncement = '`read/problems` (VS Code''s problems panel) has no Claude equivalent; use `Bash` runs of type-checker / linter to surface problems'
            }
            [pscustomobject]@{
                Name                        = 'refactor-specialist'
                BodyPointer                 = 'agents/Refactor-Specialist.agent.md'
                RequiredLiteralAnnouncement = '⚠️ SonarLint analysis unavailable in Claude Code — proceeding with non-SonarLint refactor checks per refactoring-methodology skill.'
            }
            [pscustomobject]@{
                Name                        = 'doc-keeper'
                BodyPointer                 = 'agents/Doc-Keeper.agent.md'
                RequiredLiteralAnnouncement = ''
            }
        )

        $script:CanonicalStepZero = & $script:GetSectionBody -Content (Get-Content -Path (Join-Path $script:AgentsDirectory 'code-critic.md') -Raw -ErrorAction Stop) -Heading '## Step 0: Environment Handshake Verification'

        $script:ShellDocuments = @(
            foreach ($expectedShell in $script:ExpectedShells) {
                $shellPath = Join-Path $script:AgentsDirectory ($expectedShell.Name + '.md')
                $shell = & $script:GetDocumentState -Path $shellPath
                $sharedMethodology = & $script:GetSharedMethodologySection -Content $shell.Content
                $bodyPointer = if ([string]::IsNullOrWhiteSpace($sharedMethodology)) {
                    ''
                }
                else {
                    & $script:GetBodyPointer -SharedMethodology $sharedMethodology
                }

                $bodyPath = if ([string]::IsNullOrWhiteSpace($bodyPointer)) {
                    Join-Path $script:RepoRoot $expectedShell.BodyPointer
                }
                else {
                    Join-Path $script:RepoRoot $bodyPointer
                }

                $bodyDocument = & $script:GetDocumentState -Path $bodyPath
                $enumerationParagraph = & $script:GetShellEnumerationParagraph -SharedMethodology $sharedMethodology

                [pscustomobject]@{
                    Name                        = $expectedShell.Name
                    ExpectedBodyPointer         = $expectedShell.BodyPointer
                    RequiredLiteralAnnouncement = $expectedShell.RequiredLiteralAnnouncement
                    ShellPath                   = $shellPath
                    ShellExists                 = Test-Path $shellPath
                    ShellContent                = $shell.Content
                    SharedMethodology           = $sharedMethodology
                    BodyPointer                 = $bodyPointer
                    BodyPath                    = $bodyPath
                    BodyContent                 = $bodyDocument.Content
                    StepZeroSection             = & $script:GetSectionBody -Content $shell.Content -Heading '## Step 0: Environment Handshake Verification'
                    ToolMappingSection          = & $script:GetSectionBody -Content $shell.Content -Heading '## Claude Code tool mapping'
                    EnumerationParagraph        = $enumerationParagraph
                    ShellTokens                 = @(& $script:GetShellSectionTokens -EnumerationParagraph $enumerationParagraph)
                    BodyHeadings                = @(& $script:GetBodyH2Headings -Content $bodyDocument.Content)
                }
            }
        )
    }

    It 'discovers the four Phase 4 specialist Claude shells by their required subagent names' {
        $discoveredNames = @(
            Get-ChildItem -Path $script:AgentsDirectory -Filter '*.md' -File |
                Where-Object { $_.Name -notlike '*.agent.md' } |
                Where-Object { (Get-Content -Path $_.FullName -Raw) -match '(?m)^## Shared methodology\s*$' } |
                ForEach-Object { $_.BaseName }
        )

        foreach ($expectedShell in $script:ExpectedShells) {
            $discoveredNames | Should -Contain $expectedShell.Name -Because "$($expectedShell.Name) must be discoverable as a Claude shell in agents/"
        }
    }

    It 'keeps each Phase 4 specialist shell paired to its expected shared body with H2 bijection' {
        foreach ($shell in $script:ShellDocuments) {
            $shell.ShellExists | Should -BeTrue -Because "$($shell.Name) must ship as a Claude shell wrapper"
            $shell.BodyPointer | Should -Be $shell.ExpectedBodyPointer -Because "$($shell.Name) must point to its locked shared body path"
            $shell.EnumerationParagraph | Should -Match '^After loading, follow everything under its ' -Because "$($shell.Name) must enumerate the shared-body sections it mirrors"
            $shell.ShellTokens.Count | Should -Be $shell.BodyHeadings.Count -Because "$($shell.Name) must enumerate every shared-body H2 heading except the platform footer"

            foreach ($token in $shell.ShellTokens) {
                $headingMatches = @(& $script:GetHeadingMatchesForToken -Token $token -BodyHeadings $shell.BodyHeadings)
                $headingMatches.Count | Should -Be 1 -Because "$($shell.Name) token '$token' must map to exactly one shared-body H2 heading"
            }

            foreach ($heading in $shell.BodyHeadings) {
                $tokenMatches = @(& $script:GetTokenMatchesForHeading -Heading $heading -ShellTokens $shell.ShellTokens)
                $tokenMatches.Count | Should -Be 1 -Because "$($shell.Name) heading '$heading' must map back to exactly one shell token"
            }
        }
    }

    It 'keeps Step 0 in the canonical environment-handshake form used by the existing specialist shell precedent' {
        $canonicalStepZero = & $script:NormalizeContent -Content $script:CanonicalStepZero
        $canonicalStepZero | Should -Not -BeNullOrEmpty -Because 'the existing code-critic shell is the canonical Phase 4 Step 0 template source'

        foreach ($shell in $script:ShellDocuments) {
            (& $script:NormalizeContent -Content $shell.StepZeroSection) | Should -Be $canonicalStepZero -Because "$($shell.Name) must keep the Step 0 handshake block in canonical verbatim form"
        }
    }

    It 'requires every Phase 4 specialist shell to include a Claude Code tool-mapping table' {
        foreach ($shell in $script:ShellDocuments) {
            $shell.ToolMappingSection | Should -Not -BeNullOrEmpty -Because "$($shell.Name) must include a Claude Code tool mapping section"
            $shell.ToolMappingSection | Should -Match '(?m)^\|\s*Shared body references\s*\|\s*Claude Code tool' -Because "$($shell.Name) must declare the standard tool-mapping table header"
            $shell.ToolMappingSection | Should -Match '(?m)^\|\s*[-: ]+\|\s*[-: ]+\|\s*$' -Because "$($shell.Name) must keep the Markdown table separator for the mapping table"
            $shell.ToolMappingSection | Should -Not -Match '(?ms)^\|.*\r?\n(?!\|)(\S.*)\r?\n\|' -Because "$($shell.Name) must not break the tool-mapping table with standalone text between table rows"
        }
    }

    It 'announces the required literal Claude-only tool gaps where applicable' {
        foreach ($shell in $script:ShellDocuments | Where-Object { -not [string]::IsNullOrWhiteSpace($_.RequiredLiteralAnnouncement) }) {
            $shell.ShellContent | Should -Match ([regex]::Escape($shell.RequiredLiteralAnnouncement)) -Because "$($shell.Name) must announce its locked Claude-only tool gap literally rather than silently degrading"
        }
    }
}
