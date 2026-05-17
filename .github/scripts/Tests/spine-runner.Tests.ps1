#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Contract tests for the Spine-Runner minimal frame-walking conductor.

.DESCRIPTION
    Locks issue #555 Step 7 coverage against the current production surfaces:
    agents/Spine-Runner.agent.md plus the Claude/Copilot command shells. The
    runner has no standalone executable resolver yet, so resolver, evidence,
    halt, and refusal checks are structural/prose-contract tests rather than
    helper-driven simulations of production behavior.
#>

Describe 'Spine-Runner frame-walking contract' -Tag 'contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:SpineRunnerPath = Join-Path $script:RepoRoot 'agents\Spine-Runner.agent.md'
        $script:ClaudeCommandPath = Join-Path $script:RepoRoot 'commands\spine-run.md'
        $script:ClaudeShellPath = Join-Path $script:RepoRoot 'agents\spine-runner.md'
        $script:FrameCreditEmissionPath = Join-Path $script:RepoRoot 'skills\frame-credit-emission\SKILL.md'
        $script:PortsDirectory = Join-Path $script:RepoRoot 'frame\ports'
        $script:CopilotPromptPath = Join-Path $script:RepoRoot '.github\prompts\spine-run.prompt.md'
        $script:OrchestratePromptPath = Join-Path $script:RepoRoot '.github\prompts\orchestrate.prompt.md'
        $script:FrameSpineParseTestsPath = Join-Path $script:RepoRoot '.github\scripts\Tests\frame-spine-parse.Tests.ps1'
        $script:ConductorSpineDispatchTestsPath = Join-Path $script:RepoRoot '.github\scripts\Tests\code-conductor-spine-dispatch.Tests.ps1'
        $script:NoFrameRefusal = 'No frame found on plan-issue-{ID}. Run /plan first.'

        $script:Normalize = {
            param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)

            return ($Content -replace "`r`n?", "`n")
        }

        $script:ReadNormalized = {
            param([Parameter(Mandatory)][string]$Path)

            return & $script:Normalize -Content (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop)
        }

        $script:GetMarkdownSection = {
            param(
                [Parameter(Mandatory)][string]$Content,
                [Parameter(Mandatory)][string]$Heading
            )

            $pattern = '(?ms)^' + [regex]::Escape($Heading) + '\s*\n(?<body>.*?)(?=^## |\z)'
            $match = [regex]::Match($Content, $pattern)
            $match.Success | Should -BeTrue -Because "Spine-Runner must keep an extractable $Heading section"

            if (-not $match.Success) { return '' }
            return $match.Groups['body'].Value
        }

        $script:GetMarkdownSubsection = {
            param(
                [Parameter(Mandatory)][string]$Content,
                [Parameter(Mandatory)][string]$Heading
            )

            $pattern = '(?ms)^' + [regex]::Escape($Heading) + '\s*\n(?<body>.*?)(?=^### |^## |\z)'
            $match = [regex]::Match($Content, $pattern)
            $match.Success | Should -BeTrue -Because "Frame credit emission must keep an extractable $Heading subsection"

            if (-not $match.Success) { return '' }
            return $match.Groups['body'].Value
        }

        $script:GetFrontmatter = {
            param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)

            $match = [regex]::Match($Content, '(?ms)\A---\n(?<frontmatter>.*?)\n---(?:\n|\z)')
            if (-not $match.Success) { return '' }
            return $match.Groups['frontmatter'].Value
        }

        $script:GetFrontmatterScalar = {
            param(
                [Parameter(Mandatory)][string]$Frontmatter,
                [Parameter(Mandatory)][string]$FieldName
            )

            $match = [regex]::Match($Frontmatter, "(?m)^$([regex]::Escape($FieldName)):\s*(?<value>.+?)\s*$")
            if (-not $match.Success) { return $null }
            return $match.Groups['value'].Value.Trim().Trim('"').Trim("'")
        }

        $script:GetFrontmatterFieldNames = {
            param([Parameter(Mandatory)][string]$Frontmatter)

            return @(
                $Frontmatter -split "`n" |
                Where-Object { $_ -match '^([A-Za-z0-9_-]+):' } |
                ForEach-Object { [regex]::Match($_, '^([A-Za-z0-9_-]+):').Groups[1].Value }
            )
        }

        $script:GetDispatchLine = {
            param([Parameter(Mandatory)][string]$Content)

            return @($Content -split "`n" | Where-Object { $_ -match '^Start the .+ for: \{\{input\}\}$' } | Select-Object -First 1)[0]
        }

        $script:GetPortLocusRows = {
            param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)

            $rows = [System.Collections.Generic.List[object]]::new()
            foreach ($line in ($Content -split "`n")) {
                if ($line -notmatch '^\|\s*\d+\s*\|') { continue }

                $cells = @(
                    $line.Trim().Trim('|') -split '\|' |
                    ForEach-Object { ($_.Trim() -replace '^`|`$', '') }
                )

                if ($cells.Count -lt 4) { continue }

                $rows.Add([pscustomobject]@{
                        AddOrder = [int]$cells[0]
                        Port     = $cells[1]
                        Locus    = $cells[2]
                        Adapter  = ($cells[3] -replace '\[([^\]]+)\]\([^\)]+\)', '$1')
                    }) | Out-Null
            }

            return @($rows.ToArray())
        }

        $script:AssertContractMentions = {
            param(
                [Parameter(Mandatory)][string]$Content,
                [Parameter(Mandatory)][string[]]$Patterns,
                [Parameter(Mandatory)][string]$Because
            )

            foreach ($pattern in $Patterns) {
                $Content | Should -Match $pattern -Because $Because
            }
        }

        $script:SpineRunnerLines = Get-Content -LiteralPath $script:SpineRunnerPath -ErrorAction Stop
        $script:SpineRunnerContent = & $script:ReadNormalized -Path $script:SpineRunnerPath
        $script:ClaudeCommandContent = & $script:ReadNormalized -Path $script:ClaudeCommandPath
        $script:ClaudeShellContent = & $script:ReadNormalized -Path $script:ClaudeShellPath
        $script:FrameCreditEmissionContent = & $script:ReadNormalized -Path $script:FrameCreditEmissionPath
        $script:CopilotPromptContent = & $script:ReadNormalized -Path $script:CopilotPromptPath
        $script:OrchestratePromptContent = & $script:ReadNormalized -Path $script:OrchestratePromptPath
        $script:FrameSpineParseTestsContent = & $script:ReadNormalized -Path $script:FrameSpineParseTestsPath
        $script:ConductorSpineDispatchTestsContent = & $script:ReadNormalized -Path $script:ConductorSpineDispatchTestsPath

        $script:SpineRunnerFrontmatter = & $script:GetFrontmatter -Content $script:SpineRunnerContent
        $script:ClaudeShellFrontmatter = & $script:GetFrontmatter -Content $script:ClaudeShellContent

        $script:AdapterResolverSection = & $script:GetMarkdownSection -Content $script:SpineRunnerContent -Heading '## Adapter Resolver'
        $script:EvidenceVerificationSection = & $script:GetMarkdownSection -Content $script:SpineRunnerContent -Heading '## Evidence Verification'
        $script:FailureHandlingSection = & $script:GetMarkdownSection -Content $script:SpineRunnerContent -Heading '## Failure Handling'
        $script:InvocationContractSection = & $script:GetMarkdownSection -Content $script:SpineRunnerContent -Heading '## Invocation Contract'
        $script:SkillOnlyLocusSection = & $script:GetMarkdownSubsection -Content $script:FrameCreditEmissionContent -Heading '### `skill-only`'
    }

    Context 'body budget and skill loading discipline' {

        It 'keeps the shared body within the 250-line budget including frontmatter and bracketed lines' {
            $script:SpineRunnerLines.Count | Should -BeLessOrEqual 250 -Because 'the minimal walker body must stay compact enough for dispatch contexts'
        }

        It 'does not include direct Load skills/ directives outside frame-slice dispatch' {
            $loadSkillLines = @($script:SpineRunnerLines | Where-Object { $_ -match '\bLoad\s+skills/' })

            $loadSkillLines | Should -HaveCount 0 -Because 'Spine-Runner should resolve adapters rather than broad-loading skills from the shared body'
        }

        It 'keeps a recognizable stage-manager persona that reinforces cue discipline' {
            $script:SpineRunnerContent | Should -Match '(?is)You\s+are\s+a\s+.*stage\s+manager.*prompt\s+book' -Because 'the shared body should carry a recognizable role archetype without depending on the retired frame-walker phrase'
            $script:SpineRunnerContent | Should -Match '(?is)cue[s]?.*verified\s+evidence|verified\s+evidence.*cue[s]?' -Because 'the persona should frame progress as cue-driven and evidence-gated'
            $script:SpineRunnerContent | Should -Match '(?is)frozen\s+map|Freeze\s+`walk_start`' -Because 'the persona contract should imply a frozen execution map'
            $script:SpineRunnerContent | Should -Match '(?is)slice\s+by\s+slice|current\s+slice.*advance\s+to\s+the\s+next\s+slice\s+only\s+after\s+verification\s+succeeds' -Because 'the persona contract should imply one cue or slice at a time'
            $script:SpineRunnerContent | Should -Match '(?is)evidence\s+as\s+the\s+completion\s+signal|evidence.*before.*progress|verified\s+evidence' -Because 'the persona contract should put evidence before progress'
            $script:SpineRunnerContent | Should -Match '(?is)preserve.*(stop\s+state|halt\s+history)|Preserve\s+all\s+older\s+halt\s+comments' -Because 'the persona contract should preserve halt or stop-state handoff history'
            $script:SpineRunnerContent | Should -Not -Match 'disciplined\s+frame\s+walker' -Because 'the retired persona phrase should not return'
        }
    }

    Context 'tool surface contract' {

        It 'declares the broad Copilot tool surface needed for frame walking and CE evidence' {
            $expectedTools = @(
                'vscode/askQuestions',
                'vscode',
                'execute',
                'read',
                'agent',
                'edit',
                'search',
                'web',
                'github/*',
                'vscode/memory',
                'todo',
                'browser/*'
            )

            foreach ($tool in $expectedTools) {
                $toolPattern = '(?m)^\s*-\s+"?' + [regex]::Escape($tool) + '"?\s*$'
                $script:SpineRunnerFrontmatter | Should -Match $toolPattern -Because "Spine-Runner must declare '$tool' in its Copilot tool surface"
            }

            $retiredBrowserChildTools = @(
                'browser/openBrowserPage',
                'browser/readPage',
                'browser/screenshotPage',
                'browser/clickElement',
                'browser/hoverElement',
                'browser/dragElement',
                'browser/typeInPage',
                'browser/handleDialog',
                'browser/runPlaywrightCode'
            )

            foreach ($tool in $retiredBrowserChildTools) {
                $toolPattern = '(?m)^\s*-\s+"?' + [regex]::Escape($tool) + '"?\s*$'
                $script:SpineRunnerFrontmatter | Should -Not -Match $toolPattern -Because "Spine-Runner should declare the shared parent browser capability instead of the retired '$tool' child entry"
            }
        }

        It 'maps shared question, web, and browser surfaces onto Claude shell equivalents' {
            $script:ClaudeShellFrontmatter | Should -Match '(?m)^tools:\s*.*\bWebFetch\b.*\bAskUserQuestion\b' -Because 'the Claude shell must expose equivalents for shared web and question surfaces'
            $script:ClaudeShellContent | Should -Match '\|\s*`vscode/askQuestions`\s*\|\s*`AskUserQuestion`\s*\|' -Because 'the shared askQuestions surface must map to AskUserQuestion in Claude'
            $script:ClaudeShellContent | Should -Match '\|\s*`web`\s*\|\s*`WebFetch`\s+for\s+known\s+URLs\s*\|' -Because 'the shared web surface must map to WebFetch in Claude'
            $script:ClaudeShellContent | Should -Match '\|\s*Shared\s+parent\s+browser\s+capability\s*\(`browser/\*`\)\s*\|.*WebFetch.*computer-use.*surface\s+the\s+limitation' -Because 'the Claude shell must acknowledge shared parent browser fallback behavior instead of inventing browser coverage'
        }
    }

    Context 'adapter resolver behavior contract' {

        It 'freezes walk_start and keeps resolution stable after later CWD or slice changes' {
            & $script:AssertContractMentions `
                -Content $script:AdapterResolverSection `
                -Patterns @(
                'Freeze\s+`walk_start`\s+once\s+per\s+walk\s+before\s+resolving\s+any\s+adapter',
                'Record\s+the\s+initial\s+CWD.*working-tree\s+root.*branch.*HEAD.*issue\s+ID.*PR\s+number.*ordered\s+slice\s+IDs.*adapter\s+paths.*timestamp',
                'Do\s+not\s+replace\s+this\s+map\s+after\s+`Set-Location`,\s+subagent\s+dispatch,\s+terminal\s+work,\s+or\s+slice\s+advancement',
                'Freeze\s+the\s+resolved\s+map\s+for\s+the\s+whole\s+walk'
            ) `
                -Because 'frozen-resolution stability must be part of the Spine-Runner contract'
        }

        It 'prefers source-tree adapters before plugin cache but protects consumer worktrees from shadowing' {
            & $script:AssertContractMentions `
                -Content $script:AdapterResolverSection `
                -Patterns @(
                'Agent\s+Orchestra\s+source\s+tree.*search\s+`\{root\}/\{adapter\s+path\}`\s+before\s+plugin-cache\s+roots',
                'consumer\s+or\s+other\s+working\s+tree.*search\s+plugin-cache\s+roots\s+first',
                'try\s+`\{root\}/\{adapter\s+path\}`\s+only\s+as\s+an\s+explicit\s+fallback\s+after\s+plugin-cache\s+misses',
                '`consumer-worktree-fallback`\s+warning',
                '`working-tree-shadow`\s+warning',
                'first\s+existing\s+adapter\s+file\s+in\s+the\s+applicable\s+lookup\s+order\s+wins'
            ) `
                -Because 'adapter precedence must be source-first for plugin development and plugin-cache-first for consumer repos'
        }

        It 'documents plugin-cache roots and source-tree classification signals' {
            & $script:AssertContractMentions `
                -Content $script:AdapterResolverSection `
                -Patterns @(
                '`plugin\.json`,\s+`\.claude-plugin/plugin\.json`,\s+`agents/Code-Conductor\.agent\.md`,\s+and\s+`skills/frame-credit-emission/SKILL\.md`\s+all\s+exist',
                'AGENT_ORCHESTRA_PLUGIN_ROOT',
                'platform-provided\s+agent\s+body\s+root',
                'installed\s+`agent-orchestra@agent-orchestra`\s+plugin\s+cache\s+locations'
            ) `
                -Because 'plugin-cache resolution must be explicit and source-tree classification must be deterministic'
        }

        It 'halts on unresolved adapters with the full searched-location list' {
            & $script:AssertContractMentions `
                -Content $script:AdapterResolverSection `
                -Patterns @(
                'recording\s+every\s+searched\s+location',
                'If\s+any\s+adapter\s+file\s+is\s+not\s+found,\s+halt\s+for\s+AC5\s+with\s+the\s+full\s+searched-location\s+list',
                'Do\s+not\s+guess\s+a\s+nearby\s+adapter,\s+normalize\s+to\s+another\s+port,\s+or\s+continue\s+with\s+inline\s+prose'
            ) `
                -Because 'resolver misses must be observable and non-lossy'
        }

        It 'records root kind and content identity in the frozen map' {
            & $script:AssertContractMentions `
                -Content $script:AdapterResolverSection `
                -Patterns @(
                'keyed\s+by\s+slice\s+ID',
                'absolute\s+path',
                'root\s+kind\s+\(`working-tree`,\s+`plugin-cache`,\s+or\s+`consumer-worktree-fallback`\)',
                'git\s+blob\s+SHA\s+or\s+file\s+hash'
            ) `
                -Because 'subsequent invocation and evidence checks must use a stable resolved adapter identity'
        }
    }

    Context 'halt marker sequence preservation' {

        It 'preserves halt N=1 and N=2 markers while the latest sentinel points to N=2' {
            $issueCommentsAfterTwoHalts = @(
                '<!-- spine-run-halt-555-1 -->',
                'halt N: 1',
                '<!-- spine-run-latest-halt-555 -->',
                'latest N: 1',
                '<!-- spine-run-halt-555-2 -->',
                'halt N: 2',
                '<!-- spine-run-latest-halt-555 -->',
                'latest N: 2'
            ) -join "`n"

            $haltNumbers = @(
                [regex]::Matches($issueCommentsAfterTwoHalts, '<!--\s*spine-run-halt-555-(?<number>\d+)\s*-->') |
                ForEach-Object { [int]$_.Groups['number'].Value }
            )
            $latestSentinelMatches = @([regex]::Matches($issueCommentsAfterTwoHalts, '(?s)<!--\s*spine-run-latest-halt-555\s*-->.*?latest N:\s*(?<number>\d+)'))
            $latestSentinelNumber = [int]$latestSentinelMatches[-1].Groups['number'].Value

            ($haltNumbers -join ',') | Should -Be '1,2' -Because 'a second halt must not rewrite or coalesce the first halt marker'
            $latestSentinelNumber | Should -Be 2 -Because 'the latest sentinel must point at the newest halt number'

            & $script:AssertContractMentions `
                -Content $script:FailureHandlingSection `
                -Patterns @(
                'N\s+=\s+max\(existing\s+spine-run-halt\s+numbers\s+for\s+this\s+issue\)\s+\+\s+1',
                '<!--\s+spine-run-halt-\{ID\}-\{N\}\s+-->',
                'Preserve\s+all\s+older\s+halt\s+comments',
                '<!--\s+spine-run-latest-halt-\{ID\}\s+-->',
                'points?\s+to\s+the\s+new\s+N|names\s+the\s+latest\s+N'
            ) `
                -Because 'the prose contract must match the halt sequence fixture'
        }
    }

    Context 'port to locus parity' {

        It 'mirrors every frame-credit-emission port to locus row in the Spine-Runner verification dispatch table' {
            $sourceRows = @(& $script:GetPortLocusRows -Content $script:FrameCreditEmissionContent)
            $runnerRows = @(& $script:GetPortLocusRows -Content $script:EvidenceVerificationSection)
            $portFiles = @(Get-ChildItem -LiteralPath $script:PortsDirectory -Filter '*.yaml' -File | Sort-Object BaseName)

            $portFiles | Should -HaveCount 17 -Because 'frame/ports currently declares the canonical 17 frame ports'
            $sourceRows | Should -HaveCount $portFiles.Count -Because 'frame-credit-emission must expose one canonical port to locus row per frame/ports YAML file'
            $runnerRows.Count | Should -Be $sourceRows.Count -Because 'Spine-Runner must mirror each canonical row in its verification dispatch table'

            $sourceSignatures = @($sourceRows | ForEach-Object { '{0}|{1}|{2}' -f $_.AddOrder, $_.Port, $_.Locus })
            $runnerSignatures = @($runnerRows | ForEach-Object { '{0}|{1}|{2}' -f $_.AddOrder, $_.Port, $_.Locus })
            $sourcePorts = @($sourceRows | ForEach-Object { $_.Port } | Sort-Object)
            $filePorts = @($portFiles | ForEach-Object { $_.BaseName } | Sort-Object)

            ($sourcePorts -join "`n") | Should -BeExactly ($filePorts -join "`n") -Because 'the authoritative locus table must cover every frame/ports YAML file exactly once'
            ($runnerSignatures -join "`n") | Should -BeExactly ($sourceSignatures -join "`n") -Because 'Spine-Runner dispatch inference must stay in exact table parity with frame-credit-emission'
            $sourceRows | Where-Object { $_.Port -eq 'release-hygiene' } | Select-Object -ExpandProperty Locus | Should -Be 'pr-body-pipeline-metrics'
            $sourceRows | Where-Object { $_.Port -eq 'post-fix-review' } | Select-Object -ExpandProperty Locus | Should -Be 'pr-body-pipeline-metrics'
            $sourceRows | Where-Object { $_.Port -eq 'process-retrospective' } | Select-Object -ExpandProperty Locus | Should -Be 'deferred-skill-only'
        }

        It 'distinguishes post-pr and review builder guidance for skill-only ports' {
            & $script:AssertContractMentions `
                -Content $script:SkillOnlyLocusSection `
                -Patterns @(
                'Ports\s+owned\s+by\s+skills\s+rather\s+than\s+agents',
                'For\s+`post-pr`,\s+call\s+`Build-PostPrCreditRow`\s+with\s+the\s+post-merge\s+checklist\s+outcomes\s+from\s+the\s+`post-pr-review`\s+skill',
                'For\s+`review`,\s+follow\s+the\s+review-credit-emission\s+reference,\s+call\s+`Build-ReviewCreditRow`',
                'review-specific\s+evidence\s+such\s+as\s+judge\s+ruling\s+status,\s+reviewed\s+PR\s+context,\s+and\s+persisted\s+review\s+ledger\s+or\s+sentinel\s+details'
            ) `
                -Because 'post-pr and review are both skill-only, but each requires a distinct builder and evidence source'

            $script:SkillOnlyLocusSection | Should -Not -Match 'skill-only\s+builder' -Because 'skill-owned ports should not be described with ambiguous skill-only builder wording'
            $script:SkillOnlyLocusSection | Should -Not -Match 'generic\s+builder' -Because 'skill-owned ports must name the concrete builder for each port'
        }
    }

    Context 'terminal-slice and success reporting contract' {

        It 'verifies terminal PR-body credits only at terminal slices and reports successful walks compactly' {
            & $script:AssertContractMentions `
                -Content $script:SpineRunnerContent `
                -Patterns @(
                'Terminal\s+PR-body\s+credit\s+rows\s+are\s+verified\s+when\s+a\s+slice\s+is\s+explicitly\s+terminal\s+for\s+that\s+port\s+or\s+when\s+the\s+runner\s+is\s+processing\s+the\s+last\s+unresolved\s+slice\s+for\s+that\s+port',
                'non-terminal\s+slices\s+need\s+adapter\s+completion\s+evidence',
                'PR-body\s+`credits\[\]`\s+checks\s+wait\s+until.*`#terminal`.*`terminal:\s+true`.*no\s+later\s+unresolved\s+slice\s+in\s+the\s+frozen\s+ordered\s+walk\s+has\s+the\s+same\s+port',
                'The\s+last\s+unresolved\s+slice\s+for\s+a\s+port\s+must\s+close\s+any\s+pending\s+terminal\s+credit\s+verification\s+even\s+without\s+an\s+explicit\s+terminal\s+marker',
                'On\s+a\s+complete\s+walk,\s+print\s+one\s+compact\s+stdout/report\s+payload',
                'completed\s+slice\s+IDs.*adapters\s+invoked\s+as\s+relative\s+paths.*terminal\s+credits\s+verified.*skipped\s+or\s+not-applicable\s+rows\s+observed.*warning\s+count.*`halt_count:\s+0`'
            ) `
                -Because 'success output must summarize completed execution while terminal credit evidence remains tied to terminal slices'
        }

        It 'blocks final success when terminal credit verification remains pending' {
            & $script:AssertContractMentions `
                -Content $script:EvidenceVerificationSection `
                -Patterns @(
                'Before\s+reporting\s+final\s+success,\s+assert\s+that\s+no\s+terminal\s+credit\s+verifications\s+remain\s+pending',
                'If\s+any\s+port\s+remains\s+pending,\s+halt\s+with\s+S2\s+evidence\s+details',
                'port,\s+completed\s+slice\s+IDs,\s+unresolved\s+terminal\s+expectation,\s+expected\s+evidence\s+surface,\s+observed\s+evidence\s+or\s+`none`,\s+inspected\s+issue\s+or\s+PR\s+source,\s+and\s+the\s+frozen\s+resolver\s+map',
                'prevents\s+a\s+completed\s+single-slice\s+or\s+last-slice\s+walk\s+from\s+leaving\s+terminal\s+credit\s+verification\s+open'
            ) `
                -Because 'single-slice and last-slice walks must not silently complete with unresolved terminal evidence'
        }
    }

    Context 'per-locus evidence dispatch fixtures' {

        It 'requires agent-pre-pr evidence to use matching credit-input marker payloads and halt when absent' {
            $presentEvidence = @(
                '<!-- credit-input-plan-555 -->',
                'port: plan',
                'adapter: agents/Issue-Planner.agent.md',
                'evidence: "issue #555; plan marker posted"'
            ) -join "`n"
            $absentEvidence = 'issue comment without credit-input marker'

            $presentEvidence | Should -Match '<!--\s*credit-input-plan-555\s*-->'
            $presentEvidence | Should -Match '(?m)^port:\s*plan$'
            $presentEvidence | Should -Match '(?m)^adapter:\s*agents/Issue-Planner\.agent\.md$'
            $presentEvidence | Should -Match '(?m)^evidence:\s*".+"$'
            $absentEvidence | Should -Not -Match '<!--\s*credit-input-plan-555\s*-->'

            & $script:AssertContractMentions `
                -Content $script:EvidenceVerificationSection `
                -Patterns @(
                '`agent-pre-pr`',
                '<!--\s+credit-input-\{port\}-\{ID\}\s+-->',
                'matching\s+`port`.*adapter\s+path\s+used\s+by\s+this\s+run.*non-empty\s+flat\s+`evidence`\s+string',
                'If\s+the\s+expected\s+surface\s+is\s+unavailable,\s+malformed,\s+or\s+contradicted.*halt'
            ) `
                -Because 'agent-pre-pr success and failure evidence must be contractually distinguishable'
        }

        It 'requires agent-post-pr evidence to use a terminal-step PR body credit row and halt when absent' {
            $presentEvidence = @(
                '<!-- pipeline-metrics -->',
                'credits:',
                '  - port: implement-test',
                '    terminal-step-id: 7',
                '    adapter: agents/Test-Writer.agent.md',
                '    status: passed',
                '    evidence: "Pester spine-runner.Tests.ps1 passed"'
            ) -join "`n"
            $absentEvidence = '<!-- pipeline-metrics -->' + "`n" + 'credits: []'

            $presentEvidence | Should -Match '(?m)^\s*-\s*port:\s*implement-test$'
            $presentEvidence | Should -Match '(?m)^\s*terminal-step-id:\s*7$'
            $presentEvidence | Should -Match '(?m)^\s*evidence:\s*".+"$'
            $absentEvidence | Should -Not -Match '(?m)^\s*-\s*port:\s*implement-test$'

            & $script:AssertContractMentions `
                -Content $script:EvidenceVerificationSection `
                -Patterns @(
                '`agent-post-pr`',
                'PR\s+body\s+`<!--\s+pipeline-metrics\s+-->`\s+block',
                '`credits\[\]`\s+row\s+for\s+the\s+port\s+and\s+terminal\s+step\s+number',
                'adapter/status\s+relationship',
                'human-readable\s+evidence\s+from\s+the\s+run',
                'If\s+the\s+expected\s+surface\s+is\s+unavailable,\s+malformed,\s+or\s+contradicted.*halt'
            ) `
                -Because 'agent-post-pr completion must be tied to the PR body row for the current terminal step'
        }

        It 'requires ce-gate-per-surface evidence to include row, step, status, evidence, and defects_found' {
            $presentEvidence = @(
                '<!-- pipeline-metrics -->',
                'credits:',
                '  - port: ce-gate-api',
                '    surface: api',
                '    terminal-step-id: 9',
                '    status: passed',
                '    evidence: "API CE scenario exercised"',
                '    defects_found: 0'
            ) -join "`n"
            $absentEvidence = @(
                '<!-- pipeline-metrics -->',
                'credits:',
                '  - port: ce-gate-api',
                '    surface: api',
                '    terminal-step-id: 9',
                '    status: passed'
            ) -join "`n"

            $presentEvidence | Should -Match '(?m)^\s*-\s*port:\s*ce-gate-api$'
            $presentEvidence | Should -Match '(?m)^\s*surface:\s*api$'
            $presentEvidence | Should -Match '(?m)^\s*terminal-step-id:\s*9$'
            $presentEvidence | Should -Match '(?m)^\s*defects_found:\s*0$'
            $absentEvidence | Should -Not -Match '(?m)^\s*defects_found:'

            & $script:AssertContractMentions `
                -Content $script:EvidenceVerificationSection `
                -Patterns @(
                '`ce-gate-per-surface`',
                'exact\s+`ce-gate-\{surface\}`\s+row\s+tied\s+to\s+the\s+step',
                'surface\s+name,\s+terminal\s+step\s+ID,\s+status,\s+evidence,\s+and\s+`defects_found`',
                'If\s+the\s+expected\s+surface\s+is\s+unavailable,\s+malformed,\s+or\s+contradicted.*halt'
            ) `
                -Because 'each CE Gate surface must independently prove its row-level outcome'
        }

        It 'requires auto-na evidence to match the predicate outcome and fail on status mismatch' {
            $presentEvidence = @(
                '<!-- pipeline-metrics -->',
                'credits:',
                '  - port: implement-docs',
                '    adapter: skills/documentation-finalization/adapters/implement-docs-auto-na-adapter.md',
                '    status: not-applicable',
                '    evidence: "predicate evaluated false"'
            ) -join "`n"
            $mismatchedEvidence = $presentEvidence -replace 'status: not-applicable', 'status: passed'

            $presentEvidence | Should -Match '(?m)^\s*status:\s*not-applicable$'
            $mismatchedEvidence | Should -Match '(?m)^\s*status:\s*passed$'

            & $script:AssertContractMentions `
                -Content $script:InvocationContractSection `
                -Patterns @(
                'adapter\s+name\s+ends\s+with\s+`-auto-na-adapter\.md`',
                'evaluate\s+its\s+predicate\s+before\s+credit\s+verification',
                'Unknown,\s+parse-error,\s+or\s+predicate/status\s+mismatch\s+is\s+a\s+halt'
            ) `
                -Because 'auto-na invocation must evaluate the real predicate before verification'

            & $script:AssertContractMentions `
                -Content $script:EvidenceVerificationSection `
                -Patterns @(
                '`auto-na`\s+or\s+`explicit-skip`',
                'predicate\s+or\s+skip\s+outcome\s+recorded\s+during\s+invocation\s+matches\s+the\s+emitted\s+row\s+or\s+credit-input\s+marker',
                '`auto-na`\s+expects\s+`status:\s+not-applicable`'
            ) `
                -Because 'auto-na completion must be evidence-matched to a not-applicable predicate outcome'
        }

        It 'resolves predicate evaluation from the frozen adapter root and halts when the evaluator is unavailable' {
            & $script:AssertContractMentions `
                -Content $script:InvocationContractSection `
                -Patterns @(
                'resolve\s+`\{frozen\s+root\}/\.github/scripts/lib/frame-predicate-core\.ps1`',
                'where\s+`\{frozen\s+root\}`\s+is\s+the\s+resolved\s+root\s+that\s+supplied\s+the\s+adapter',
                'dot-source\s+that\s+evaluator',
                'ConvertTo-FVPredicate',
                'Test-FVPredicateAgainstChangeset\s+-Ast\s+\{ast\}\s+-Changeset\s+\{changeset\}',
                'If\s+the\s+evaluator\s+is\s+missing,\s+halt\s+with\s+`predicate-evaluator-unavailable/source-tree-required`\s+and\s+include\s+the\s+searched\s+locations'
            ) `
                -Because 'auto-na and explicit-skip predicates must use the evaluator from the frozen adapter root, not from the current working directory'

            $script:InvocationContractSection | Should -Not -Match '(?i)(current\s+working\s+directory|CWD).{0,160}\.github/scripts/lib/frame-predicate-core\.ps1' -Because 'predicate evaluation must not be described as CWD-relative dot-sourcing'
        }
    }

    Context 'AC4 refusal contract' {

        It 'requires exact no-frame refusal text and zero side effects for empty plan inputs' {
            $emptyIssueBodies = @(
                'plain issue body with no durable plan marker',
                '<!-- plan-issue-555 -->' + "`n" + 'body with no frame-spine block',
                '<!-- plan-issue-555 -->' + "`n" + '<!-- frame-spine' + "`n" + '-->'
            )

            foreach ($emptyIssueBody in $emptyIssueBodies) {
                $emptyIssueBody | Should -Not -Match '(?m)^spine_schema_version:\s*2$'
            }

            $combinedContract = @(
                $script:SpineRunnerContent,
                $script:ClaudeCommandContent,
                $script:ClaudeShellContent,
                $script:CopilotPromptContent
            ) -join "`n"

            $combinedContract | Should -Match ([regex]::Escape($script:NoFrameRefusal)) -Because 'AC4 requires this exact refusal string when no executable frame exists'
            $combinedContract | Should -Match '(?is)(no\s+marker|no\s+`?<!--\s*frame-spine|empty\s+spine).{0,900}No\s+frame\s+found\s+on\s+plan-issue-\{ID\}\.\s+Run\s+/plan\s+first\.' -Because 'the refusal must be tied to no marker, no spine block, or empty spine cases'
            $combinedContract | Should -Match '(?is)No\s+frame\s+found\s+on\s+plan-issue-\{ID\}\.\s+Run\s+/plan\s+first\..{0,700}(zero\s+side\s+effects|no\s+side\s+effects|do\s+not\s+post|post\s+no\s+comments)' -Because 'AC4 refusal must not post halt markers or mutate issue/PR state'
        }
    }

    Context 'existing v2 parse fixture ownership' {

        It 'keeps Code-Conductor schema v2 adapter lookup coverage in the existing dispatch test file' {
            $script:ConductorSpineDispatchTestsContent | Should -Match 'uses\s+the\s+spine\s+lookup\s+path\s+to\s+select\s+the\s+active\s+slice\s+from\s+a\s+schema\s+v2\s+plan\s+with\s+adapters' -Because 'Step 7 must verify the Step 1 fixture remains rather than duplicating it'
            $script:ConductorSpineDispatchTestsContent | Should -Match 'spine_schema_version:\s+2'
            $script:ConductorSpineDispatchTestsContent | Should -Match 'adapter:\s+agents/Test-Writer\.agent\.md'
            $script:ConductorSpineDispatchTestsContent | Should -Match 'Invoke-FSCSpineLookupCli'
        }

        It 'keeps parser-level schema v2 adapter coverage in frame-spine-parse.Tests.ps1' {
            $script:FrameSpineParseTestsContent | Should -Match 'accepts\s+schema\s+v2\s+spine\s+YAML\s+when\s+each\s+slice\s+declares\s+an\s+adapter' -Because 'parser acceptance belongs in frame-spine-parse.Tests.ps1'
            $script:FrameSpineParseTestsContent | Should -Match 'spine_schema_version:\s+2'
            $script:FrameSpineParseTestsContent | Should -Match 'adapter:\s+agents/Code-Smith\.agent\.md'
            $script:FrameSpineParseTestsContent | Should -Match 'adapter:\s+agents/Test-Writer\.agent\.md'
            $script:FrameSpineParseTestsContent | Should -Match 'AdapterRaw'
        }
    }

    Context 'Claude command and Copilot prompt dispatch targets' {

        It 'dispatches the Claude slash command to the registered shell while the Copilot prompt targets the Copilot agent name' {
            $claudeFrontmatter = & $script:GetFrontmatter -Content $script:ClaudeCommandContent
            $copilotFrontmatter = & $script:GetFrontmatter -Content $script:CopilotPromptContent

            (& $script:GetFrontmatterScalar -Frontmatter $claudeFrontmatter -FieldName 'agent') | Should -Be 'spine-runner'
            (& $script:GetFrontmatterScalar -Frontmatter $copilotFrontmatter -FieldName 'agent') | Should -Be 'Spine-Runner'
            $script:ClaudeCommandContent | Should -Match 'dispatches\s+to\s+`spine-runner`'
            $script:CopilotPromptContent | Should -Match 'Copilot\s+resolves\s+`agent:\s+Spine-Runner`'
        }
    }

    Context 'Copilot prompt mirror' {

        It 'keeps the spine-run prompt frontmatter in the same three-field shape as orchestrate' {
            $spineFrontmatter = & $script:GetFrontmatter -Content $script:CopilotPromptContent
            $orchestrateFrontmatter = & $script:GetFrontmatter -Content $script:OrchestratePromptContent

            $spineFrontmatter | Should -Not -BeNullOrEmpty
            $orchestrateFrontmatter | Should -Not -BeNullOrEmpty

            (& $script:GetFrontmatterFieldNames -Frontmatter $spineFrontmatter) -join ',' | Should -Be 'agent,description,argument-hint'
            (& $script:GetFrontmatterFieldNames -Frontmatter $orchestrateFrontmatter) -join ',' | Should -Be 'agent,description,argument-hint'
            (& $script:GetFrontmatterScalar -Frontmatter $spineFrontmatter -FieldName 'agent') | Should -Be 'Spine-Runner'
        }

        It 'keeps the spine-run Copilot dispatch line in parity with the orchestrate prompt pattern' {
            $spineDispatchLine = & $script:GetDispatchLine -Content $script:CopilotPromptContent
            $orchestrateDispatchLine = & $script:GetDispatchLine -Content $script:OrchestratePromptContent

            $spineDispatchLine | Should -Be 'Start the Spine-Runner walk for: {{input}}'

            $normalizedSpineDispatch = $spineDispatchLine -replace 'Spine-Runner walk', '{agent workflow}'
            $normalizedOrchestrateDispatch = $orchestrateDispatchLine -replace 'Code-Conductor hub mode orchestration workflow', '{agent workflow}'
            $normalizedSpineDispatch | Should -Be $normalizedOrchestrateDispatch -Because 'Copilot prompt dispatch text should follow the same Start the {workflow} for: {{input}} pattern'
        }
    }
}
