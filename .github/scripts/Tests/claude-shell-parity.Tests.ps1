#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
        Contract tests for Claude shell/shared-body section parity.

.DESCRIPTION
        Locks the contributor-facing parity contract between Claude shell files under
        agents/*.md and their paired shared bodies under agents/*.agent.md.

        For every discovered shell, these tests require:
            - the canonical session-startup trigger stub in the shell top-of-body
            - an explicit shared-body pointer in the Shared methodology section
            - one-to-one parity between shell-enumerated shared sections and body H2 headings

        This is the green parity-lock coverage for issue #382 Step 2.
#>

Describe 'Claude shell/shared-body parity contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:AgentsDirectory = Join-Path $script:RepoRoot 'agents'
        $script:CanonicalTriggerText = 'Before the first substantive response in a new conversation, load the `session-startup` skill and follow its protocol.'
        $script:ParitySuffixPattern = '($|: |\s+\(|\s*$)'

        $script:GetDocumentState = {
            param([string]$Path)
            if (-not (Test-Path $Path)) {
                return @{ Path = $Path; Content = '' }
            }
            try {
                $content = Get-Content -Path $Path -Raw -ErrorAction Stop
                return @{ Path = $Path; Content = $content }
            }
            catch {
                return @{ Path = $Path; Content = ''; Error = $_.Exception.Message }
            }
        }

        $script:GetTopBody = {
            param([string]$Content)

            $match = [regex]::Match($Content, '(?ms)\A---\r?\n.*?^---[ \t]*\r?\n(?<topBody>.*?)(?=^## |\z)')
            if (-not $match.Success) {
                return ''
            }

            return $match.Groups['topBody'].Value
        }

        $script:GetSharedMethodologySection = {
            param([string]$Content)

            $match = [regex]::Match($Content, '(?ms)^## Shared methodology\s*\r?\n(?<body>.*?)(?=^## |\z)')
            if (-not $match.Success) {
                return ''
            }

            return $match.Groups['body'].Value
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

        $script:ShellDocuments = @(
            Get-ChildItem -Path $script:AgentsDirectory -Filter '*.md' -File |
                Where-Object { $_.Name -notlike '*.agent.md' } |
                ForEach-Object {
                    $shell = & $script:GetDocumentState -Path $_.FullName
                    if ($shell.Content -notmatch [regex]::Escape($script:CanonicalTriggerText)) { return }
                    $hasCanonicalTrigger = $true
                    $hasSharedMethodologyHeading = $shell.Content -match '(?m)^## Shared methodology\s*$'
                    $sharedMethodology = if ($hasSharedMethodologyHeading) {
                        & $script:GetSharedMethodologySection -Content $shell.Content
                    }
                    else {
                        ''
                    }

                    $bodyPointer = if ([string]::IsNullOrWhiteSpace($sharedMethodology)) {
                        ''
                    }
                    else {
                        & $script:GetBodyPointer -SharedMethodology $sharedMethodology
                    }

                    $bodyPath = if ([string]::IsNullOrWhiteSpace($bodyPointer)) {
                        ''
                    }
                    else {
                        Join-Path $script:RepoRoot $bodyPointer
                    }

                    $bodyDocument = if ([string]::IsNullOrWhiteSpace($bodyPath)) {
                        @{ Path = ''; Content = '' }
                    }
                    else {
                        & $script:GetDocumentState -Path $bodyPath
                    }

                    $enumerationParagraph = & $script:GetShellEnumerationParagraph -SharedMethodology $sharedMethodology

                    [pscustomobject]@{
                        Name                 = $_.BaseName
                        ShellPath            = $_.FullName
                        ShellContent         = $shell.Content
                        HasCanonicalTrigger  = $hasCanonicalTrigger
                        HasSharedMethodology = $hasSharedMethodologyHeading
                        ShellTopBody         = & $script:GetTopBody -Content $shell.Content
                        SharedMethodology    = $sharedMethodology
                        BodyPointer          = $bodyPointer
                        BodyPath             = $bodyPath
                        BodyContent          = $bodyDocument.Content
                        EnumerationParagraph = $enumerationParagraph
                        ShellTokens          = @(& $script:GetShellSectionTokens -EnumerationParagraph $enumerationParagraph)
                        BodyHeadings         = @(& $script:GetBodyH2Headings -Content $bodyDocument.Content)
                    }
                }
        )
    }

    It 'discovers at least one paired-body shell to enforce parity against' {
        $script:ShellDocuments.Count | Should -BeGreaterThan 0 -Because 'parity enforcement requires at least one Claude shell in agents/ — if this fails, the discovery glob or filter may be broken'
    }

    It 'requires every agents/*.md file (excluding *.agent.md) to carry the canonical session-startup trigger stub' {
        $allShellFiles = Get-ChildItem -Path $script:AgentsDirectory -Filter '*.md' -File |
            Where-Object { $_.Name -notlike '*.agent.md' }
        foreach ($shellFile in $allShellFiles) {
            $content = Get-Content -Path $shellFile.FullName -Raw
            $content | Should -Match ([regex]::Escape($script:CanonicalTriggerText)) -Because "$($shellFile.Name) must carry the canonical session-startup trigger stub to be discoverable and to activate Step 9 runtime enforcement"
        }
    }

    It 'requires discovered Claude shells to exist as shared-methodology pairs with the canonical startup stub in the top body' {
        foreach ($shell in $script:ShellDocuments) {
            $shell.HasCanonicalTrigger | Should -BeTrue -Because "$($shell.Name) must include the canonical session-startup trigger stub"
            $shell.HasSharedMethodology | Should -BeTrue -Because "$($shell.Name) must include a Shared methodology section"
            $shell.BodyPointer | Should -Not -BeNullOrEmpty -Because "$($shell.Name) must declare a literal shared-body pointer in Shared methodology"
            (Test-Path $shell.BodyPath) | Should -BeTrue -Because "$($shell.Name) must point to an existing shared body"
            $shell.ShellTopBody | Should -Match ([regex]::Escape($script:CanonicalTriggerText)) -Because "$($shell.Name) must keep the canonical session-startup trigger in its top body"
            $shell.EnumerationParagraph | Should -Match '^After loading, follow everything under its ' -Because "$($shell.Name) must enumerate the shared-body sections it mirrors"
            $shell.ShellTokens.Count | Should -BeGreaterThan 0 -Because "$($shell.Name) must enumerate at least one shared-body section token"
        }
    }

    It 'requires every shell token to match exactly one shared-body H2 heading' {
        foreach ($shell in $script:ShellDocuments) {
            $shell.BodyContent | Should -Not -BeNullOrEmpty -Because "$($shell.Name) must have a readable shared body before bijection can be verified"
            foreach ($token in $shell.ShellTokens) {
                $headingMatches = @(& $script:GetHeadingMatchesForToken -Token $token -BodyHeadings $shell.BodyHeadings)

                $headingMatches.Count | Should -Be 1 -Because "$($shell.Name) token '$token' must map to exactly one shared-body H2 heading"
            }
        }
    }

    It 'requires every shared-body H2 heading to map back to exactly one shell token with matching counts' {
        foreach ($shell in $script:ShellDocuments) {
            $shell.BodyContent | Should -Not -BeNullOrEmpty -Because "$($shell.Name) must have a readable shared body before bijection can be verified"
            $shell.ShellTokens.Count | Should -Be $shell.BodyHeadings.Count -Because "$($shell.Name) must enumerate every shared-body H2 heading except the platform footer"

            foreach ($heading in $shell.BodyHeadings) {
                $tokenMatches = @(& $script:GetTokenMatchesForHeading -Heading $heading -ShellTokens $shell.ShellTokens)

                $tokenMatches.Count | Should -Be 1 -Because "$($shell.Name) heading '$heading' must map back to exactly one shell token"
            }
        }
    }
}
