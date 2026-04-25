# Requires -Version 7.0
# Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Focused parity coverage for the Claude specialist shells.

.DESCRIPTION
    Supplements the generic claude-shell-parity contract with specialist-specific
    checks for discovery, shared-body parity, canonical Step 0 handshake form,
    Claude tool-mapping table presence, and required literal gap announcements.
#>

Describe 'Claude specialist shell parity contract' {

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

            $headings = [System.Collections.Generic.List[string]]::new()
            $inFence = $false

            foreach ($line in ($Content -split "\r?\n")) {
                if ($line.StartsWith('```') -or $line.StartsWith('~~~')) {
                    $inFence = -not $inFence
                    continue
                }

                if ($inFence) {
                    continue
                }

                $match = [regex]::Match($line, '^## (?<title>[^\r\n]+)\s*$')
                if (-not $match.Success) {
                    continue
                }

                $title = $match.Groups['title'].Value.Trim()
                if ($title -ne 'Platform-specific invocation') {
                    $null = $headings.Add('## ' + $title)
                }
            }

            return @($headings)
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

        $script:GetMarkedFencedTextBlock = {
            param(
                [string]$Content,
                [string]$MarkerName
            )

            $pattern = '(?ms)<!--\s*' + [regex]::Escape($MarkerName) + '\s*-->\s*```text\s*\r?\n(?<body>.*?)\r?\n```\s*<!--\s*/' + [regex]::Escape($MarkerName) + '\s*-->'
            $match = [regex]::Match($Content, $pattern)
            if (-not $match.Success) {
                return ''
            }

            return $match.Groups['body'].Value
        }

        $script:GetSingleQuotedHereStringBody = {
            param(
                [string]$Content,
                [string]$VariableName
            )

            $lines = $Content -split "`r?`n"
            $startPattern = '^\s*' + [regex]::Escape($VariableName) + '\s*=\s*@''\s*$'
            $startIndex = -1

            for ($index = 0; $index -lt $lines.Count; $index++) {
                if ($lines[$index] -match $startPattern) {
                    $startIndex = $index + 1
                    break
                }
            }

            if ($startIndex -lt 0) {
                return ''
            }

            $bodyLines = [System.Collections.Generic.List[string]]::new()

            for ($index = $startIndex; $index -lt $lines.Count; $index++) {
                if ($lines[$index] -eq "'@") {
                    return [string]::Join("`n", $bodyLines)
                }

                $null = $bodyLines.Add($lines[$index])
            }

            return ''
        }

        $script:UiIteratorCe6Literal = @'
⚠️ UI-Iterator browser tools unavailable.

Primary path — Claude-in-Chrome MCP:
  1. Install the Claude Chrome extension and connect it to this Claude Code session.
  2. Re-run /polish.

Fallback path — Claude_Preview MCP:
  1. Run mcp__Claude_Preview__preview_start against your dev server URL (e.g. http://localhost:3000).
  2. Re-run /polish.

Final fallback — manual screenshot paste:
  Paste a screenshot of the current state and the agent will proceed with manual iteration. Note: this loses the verify-after-edit cycle that automated polish provides.
'@

        $script:ExpectedShells = @(
            [pscustomobject]@{
                Name                        = 'code-smith'
                BodyPointer                 = 'agents/Code-Smith.agent.md'
                RequiredLiteralAnnouncement = ''
                RequiresHeadingBijection    = $true
            }
            [pscustomobject]@{
                Name                        = 'test-writer'
                BodyPointer                 = 'agents/Test-Writer.agent.md'
                RequiredLiteralAnnouncement = '`read/problems` (VS Code''s problems panel) has no Claude equivalent; use `Bash` runs of type-checker / linter to surface problems'
                RequiresHeadingBijection    = $true
            }
            [pscustomobject]@{
                Name                        = 'refactor-specialist'
                BodyPointer                 = 'agents/Refactor-Specialist.agent.md'
                RequiredLiteralAnnouncement = '⚠️ SonarLint analysis unavailable in Claude Code — proceeding with non-SonarLint refactor checks per refactoring-methodology skill.'
                RequiresHeadingBijection    = $true
            }
            [pscustomobject]@{
                Name                        = 'doc-keeper'
                BodyPointer                 = 'agents/Doc-Keeper.agent.md'
                RequiredLiteralAnnouncement = ''
                RequiresHeadingBijection    = $true
            }
            [pscustomobject]@{
                Name                        = 'process-review'
                BodyPointer                 = 'agents/Process-Review.agent.md'
                RequiredLiteralAnnouncement = ''
                RequiresHeadingBijection    = $true
            }
            [pscustomobject]@{
                Name                        = 'ui-iterator'
                BodyPointer                 = 'agents/UI-Iterator.agent.md'
                RequiredLiteralAnnouncement = $script:UiIteratorCe6Literal
                RequiresHeadingBijection    = $true
            }
            [pscustomobject]@{
                Name                        = 'research-agent'
                BodyPointer                 = 'agents/Research-Agent.agent.md'
                RequiredLiteralAnnouncement = ''
                RequiresHeadingBijection    = $true
            }
            [pscustomobject]@{
                Name                        = 'specification'
                BodyPointer                 = 'agents/Specification.agent.md'
                RequiredLiteralAnnouncement = ''
                RequiresHeadingBijection    = $true
            }
        )

        $script:CanonicalStepZero = & $script:GetSectionBody -Content (Get-Content -Path (Join-Path $script:AgentsDirectory 'code-critic.md') -Raw -ErrorAction Stop) -Heading '## Step 0: Environment Handshake Verification'
        $script:BrowserToolsDesignDocument = & $script:GetDocumentState -Path (Join-Path $script:RepoRoot 'Documents/Design/claude-browser-tools.md')
        $script:PolishCommandDocument = & $script:GetDocumentState -Path (Join-Path $script:RepoRoot 'commands/polish.md')
        $script:DesignDocumentCe6Literal = & $script:GetMarkedFencedTextBlock -Content $script:BrowserToolsDesignDocument.Content -MarkerName 'ce6-literal'
        $script:ThisTestDocument = & $script:GetDocumentState -Path (Join-Path $script:RepoRoot '.github/scripts/Tests/specialist-shell-parity.Tests.ps1')
        $script:UiIteratorCe6LiteralSource = & $script:GetSingleQuotedHereStringBody -Content $script:ThisTestDocument.Content -VariableName '$script:UiIteratorCe6Literal'

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
                    RequiresHeadingBijection    = $expectedShell.RequiresHeadingBijection
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
                    Ce6Literal                  = & $script:GetMarkedFencedTextBlock -Content $shell.Content -MarkerName 'ce6-literal'
                }
            }
        )
    }

    It 'discovers the specialist Claude shells by their required subagent names' {
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

    It 'keeps each specialist shell paired to its expected shared body, enforcing H2 bijection where required' {
        foreach ($shell in $script:ShellDocuments) {
            $shell.ShellExists | Should -BeTrue -Because "$($shell.Name) must ship as a Claude shell wrapper"
            $shell.BodyPointer | Should -Be $shell.ExpectedBodyPointer -Because "$($shell.Name) must point to its locked shared body path"
            $shell.EnumerationParagraph | Should -Match '^After loading, follow everything under its ' -Because "$($shell.Name) must enumerate the shared-body sections it mirrors"

            if ($shell.RequiresHeadingBijection) {
                $shell.ShellTokens.Count | Should -Be $shell.BodyHeadings.Count -Because "$($shell.Name) must enumerate every shared-body H2 heading except the platform footer"
            }
            else {
                $shell.ShellTokens.Count | Should -BeGreaterThan 0 -Because "$($shell.Name) must still enumerate the shared-body sections it mirrors even when the shell intentionally documents only an operational subset"
            }

            foreach ($token in $shell.ShellTokens) {
                if ($shell.RequiresHeadingBijection) {
                    $headingMatches = @(& $script:GetHeadingMatchesForToken -Token $token -BodyHeadings $shell.BodyHeadings)
                    $headingMatches.Count | Should -Be 1 -Because "$($shell.Name) token '$token' must map to exactly one shared-body H2 heading"
                }
            }

            foreach ($heading in $shell.BodyHeadings) {
                $tokenMatches = @(& $script:GetTokenMatchesForHeading -Heading $heading -ShellTokens $shell.ShellTokens)

                if ($shell.RequiresHeadingBijection) {
                    $tokenMatches.Count | Should -Be 1 -Because "$($shell.Name) heading '$heading' must map back to exactly one shell token"
                }
                else {
                    $tokenMatches.Count | Should -BeLessOrEqual 1 -Because "$($shell.Name) must not map multiple shell tokens back to the same shared-body heading"
                }
            }
        }
    }

    It 'keeps Step 0 in the canonical environment-handshake form used by the existing specialist shell precedent' {
        $canonicalStepZero = & $script:NormalizeContent -Content $script:CanonicalStepZero
        $canonicalStepZero | Should -Not -BeNullOrEmpty -Because 'the existing code-critic shell is the canonical specialist-shell Step 0 template source'

        foreach ($shell in $script:ShellDocuments) {
            (& $script:NormalizeContent -Content $shell.StepZeroSection) | Should -Be $canonicalStepZero -Because "$($shell.Name) must keep the Step 0 handshake block in canonical verbatim form"
        }
    }

    It 'requires every specialist shell to include a Claude Code tool-mapping table' {
        foreach ($shell in $script:ShellDocuments) {
            $shell.ToolMappingSection | Should -Not -BeNullOrEmpty -Because "$($shell.Name) must include a Claude Code tool mapping section"
            $shell.ToolMappingSection | Should -Match '(?m)^\|\s*Shared body references\s*\|\s*Claude Code tool' -Because "$($shell.Name) must declare the standard tool-mapping table header"
            $shell.ToolMappingSection | Should -Match '(?m)^\|\s*[-: ]+\|\s*[-: ]+\|\s*$' -Because "$($shell.Name) must keep the Markdown table separator for the mapping table"
            $shell.ToolMappingSection | Should -Not -Match '(?ms)^\|.*\r?\n(?!\|)(\S.*)\r?\n\|' -Because "$($shell.Name) must not break the tool-mapping table with standalone text between table rows"
        }
    }

    It 'announces the required literal Claude-only tool gaps where applicable' {
        foreach ($shell in $script:ShellDocuments | Where-Object { -not [string]::IsNullOrWhiteSpace($_.RequiredLiteralAnnouncement) }) {
            (& $script:NormalizeContent -Content $shell.ShellContent) | Should -Match ([regex]::Escape((& $script:NormalizeContent -Content $shell.RequiredLiteralAnnouncement))) -Because "$($shell.Name) must announce its locked Claude-only tool gap literally rather than silently degrading"
        }
    }

    It 'keeps the CE6 literal locked across the design doc, the UI-Iterator shell, the /polish command, and the parity fixture' {
        $uiIteratorShell = $script:ShellDocuments | Where-Object { $_.Name -eq 'ui-iterator' } | Select-Object -First 1

        $uiIteratorShell | Should -Not -BeNullOrEmpty -Because 'the UI-Iterator shell fixture must exist for CE6 parity assertions'

        $normalizedDesignLiteral = & $script:NormalizeContent -Content $script:DesignDocumentCe6Literal
        $normalizedShellLiteral = & $script:NormalizeContent -Content $uiIteratorShell.Ce6Literal
        $normalizedPolishCommandContent = & $script:NormalizeContent -Content $script:PolishCommandDocument.Content
        $normalizedFixtureLiteral = & $script:NormalizeContent -Content $script:UiIteratorCe6LiteralSource

        $normalizedDesignLiteral | Should -Not -BeNullOrEmpty -Because 'the design doc must keep the CE6 literal inside the locked marker block'
        $normalizedShellLiteral | Should -Not -BeNullOrEmpty -Because 'the UI-Iterator shell must keep the CE6 literal inside the locked marker block'
        $normalizedPolishCommandContent | Should -Not -BeNullOrEmpty -Because 'the /polish command document must exist for CE6 parity assertions'
        $normalizedFixtureLiteral | Should -Not -BeNullOrEmpty -Because 'the parity fixture must keep the CE6 literal inside the locked single-quoted here-string'
        $normalizedDesignLiteral | Should -Be $normalizedShellLiteral -Because 'the UI-Iterator shell CE6 block must stay byte-identical to the design doc literal after LF normalization'
        $normalizedPolishCommandContent | Should -Match ([regex]::Escape($normalizedDesignLiteral)) -Because 'the /polish command must embed the locked CE6 literal byte-identically rather than drifting from the design contract'
        $normalizedDesignLiteral | Should -Be $normalizedFixtureLiteral -Because 'the parity fixture CE6 literal must stay byte-identical to the design doc literal after LF normalization'
    }
}
