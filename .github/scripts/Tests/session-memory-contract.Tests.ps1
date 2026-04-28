#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    RED structural contract tests for the session-memory contract surface.

.DESCRIPTION
    Locks issue #440 Step 2 before the contract and citations exist. These tests
    verify the canonical session-memory contract skill shape, row coverage,
    citation/delegation rules, scan-discovered survival-label callouts, Claude
    command/shell fallback citations, tracking-format delegation, routing-config
    provenance, and #379/#384 deferral markers.
#>

Describe 'session-memory contract structural surface' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ContractSkill = Join-Path $script:RepoRoot 'skills\session-memory-contract\SKILL.md'
        $script:RoutingConfigPath = Join-Path $script:RepoRoot 'skills\routing-tables\assets\routing-config.json'

        $script:ReadContent = {
            param([string]$Path)

            if (Test-Path -LiteralPath $Path -PathType Leaf) {
                return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
            }

            return ''
        }

        $script:ContractContent = & $script:ReadContent -Path $script:ContractSkill
        $script:BaseSurvivalLabels = @(
            'per-dispatch',
            'within-conversation',
            'within-worktree',
            'durable'
        )
        $script:ContractRows = @(
            [pscustomobject]@{ Id = 'SMC-01'; Label = 'single-issue plan cache'; Pending384 = $true; FollowUp379 = $true },
            [pscustomobject]@{ Id = 'SMC-02'; Label = 'bundled plan cache'; Pending384 = $true; FollowUp379 = $true },
            [pscustomobject]@{ Id = 'SMC-03'; Label = 'design cache'; Pending384 = $true; FollowUp379 = $false },
            [pscustomobject]@{ Id = 'SMC-04'; Label = 'first-contact-assessed marker'; Pending384 = $false; FollowUp379 = $false },
            [pscustomobject]@{ Id = 'SMC-05'; Label = 'pre-PR review-state'; Pending384 = $false; FollowUp379 = $true },
            [pscustomobject]@{ Id = 'SMC-06'; Label = 'post-PR review-state resume'; Pending384 = $false; FollowUp379 = $false },
            [pscustomobject]@{ Id = 'SMC-07'; Label = 'run-once startup-check marker'; Pending384 = $false; FollowUp379 = $true },
            [pscustomobject]@{ Id = 'SMC-08'; Label = 'phase-completion markers'; Pending384 = $false; FollowUp379 = $false },
            [pscustomobject]@{ Id = 'SMC-09'; Label = 'calibration snapshots'; Pending384 = $false; FollowUp379 = $true },
            [pscustomobject]@{ Id = 'SMC-10'; Label = 'per-finding calibration cache'; Pending384 = $false; FollowUp379 = $false },
            [pscustomobject]@{ Id = 'SMC-11'; Label = 'cross-PR calibration state'; Pending384 = $false; FollowUp379 = $false },
            [pscustomobject]@{ Id = 'SMC-12'; Label = 'plugin release-hygiene decision'; Pending384 = $false; FollowUp379 = $false },
            [pscustomobject]@{ Id = 'SMC-13'; Label = '.copilot-tracking/ artifacts'; Pending384 = $false; FollowUp379 = $false },
            [pscustomobject]@{ Id = 'SMC-14'; Label = 'subagent-env-handshake state'; Pending384 = $false; FollowUp379 = $false }
        )

        $script:GetRelativePath = {
            param([string]$Path)

            return $Path -replace '/', '\'
        }

        $script:GetContractRowSegment = {
            param([string]$RowId)

            if ([string]::IsNullOrWhiteSpace($script:ContractContent)) {
                return ''
            }

            $start = $script:ContractContent.IndexOf($RowId, [System.StringComparison]::Ordinal)
            if ($start -lt 0) {
                return ''
            }

            $rowIds = @($script:ContractRows | ForEach-Object { $_.Id })
            $rowIndex = [array]::IndexOf($rowIds, $RowId)
            $next = -1
            if ($rowIndex -ge 0 -and $rowIndex -lt ($rowIds.Count - 1)) {
                $nextId = $rowIds[$rowIndex + 1]
                $next = $script:ContractContent.IndexOf($nextId, $start + $RowId.Length, [System.StringComparison]::Ordinal)
            }

            if ($next -gt $start) {
                return $script:ContractContent.Substring($start, $next - $start)
            }

            return $script:ContractContent.Substring($start)
        }

        $script:AssertSurvivalCallout = {
            param(
                [string]$Content,
                [string]$RowId,
                [string]$Path
            )

            $pattern = '(?is)(survival|survives|survival label).{0,320}\b' + [regex]::Escape($RowId) + '\b|\b' + [regex]::Escape($RowId) + '\b.{0,320}(survival|survives|survival label)'
            $Content | Should -Match $pattern -Because "$Path must carry a survival-label callout that cites $RowId"
        }

        $script:StateOwningSurfaces = @(
            [pscustomobject]@{ Path = 'skills\provenance-gate\SKILL.md'; Rows = @('SMC-04') },
            [pscustomobject]@{ Path = 'skills\provenance-gate\platforms\copilot.md'; Rows = @('SMC-04') },
            [pscustomobject]@{ Path = 'skills\provenance-gate\platforms\claude.md'; Rows = @('SMC-04') },
            [pscustomobject]@{ Path = 'skills\session-startup\SKILL.md'; Rows = @('SMC-07') },
            [pscustomobject]@{ Path = 'skills\plugin-release-hygiene\SKILL.md'; Rows = @('SMC-12') },
            [pscustomobject]@{ Path = 'skills\plugin-release-hygiene\platforms\copilot.md'; Rows = @('SMC-12') },
            [pscustomobject]@{ Path = 'skills\plugin-release-hygiene\platforms\claude.md'; Rows = @('SMC-12') },
            [pscustomobject]@{ Path = 'skills\validation-methodology\references\review-state-persistence.md'; Rows = @('SMC-05', 'SMC-06') },
            [pscustomobject]@{ Path = 'skills\validation-methodology\references\review-reconciliation.md'; Rows = @('SMC-05', 'SMC-06') },
            [pscustomobject]@{ Path = 'skills\calibration-pipeline\SKILL.md'; Rows = @('SMC-09', 'SMC-10', 'SMC-11') },
            [pscustomobject]@{ Path = 'skills\calibration-pipeline\references\metrics-schema.md'; Rows = @('SMC-09', 'SMC-10', 'SMC-11') },
            [pscustomobject]@{ Path = 'skills\customer-experience\references\orchestration-protocol.md'; Rows = @('SMC-03', 'SMC-08') },
            [pscustomobject]@{ Path = 'skills\customer-experience\references\defect-response.md'; Rows = @('SMC-03', 'SMC-08') },
            [pscustomobject]@{ Path = 'skills\tracking-format\SKILL.md'; Rows = @('SMC-13') },
            [pscustomobject]@{ Path = 'skills\subagent-env-handshake\SKILL.md'; Rows = @('SMC-14') }
        )

        $script:SharedAgentStateSurfaces = @(
            [pscustomobject]@{ Path = 'agents\Issue-Planner.agent.md'; Rows = @('SMC-01', 'SMC-03') },
            [pscustomobject]@{ Path = 'agents\Code-Conductor.agent.md'; Rows = @('SMC-01', 'SMC-02', 'SMC-03', 'SMC-08') }
        )

        $script:CommandAndShellSurfaces = @(
            [pscustomobject]@{ Path = 'commands\experience.md'; Rows = @('SMC-04', 'SMC-07') },
            [pscustomobject]@{ Path = 'commands\design.md'; Rows = @('SMC-04', 'SMC-07') },
            [pscustomobject]@{ Path = 'commands\plan.md'; Rows = @('SMC-07') },
            [pscustomobject]@{ Path = 'commands\orchestrate.md'; Rows = @('SMC-01', 'SMC-03', 'SMC-08') },
            [pscustomobject]@{ Path = 'commands\polish.md'; Rows = @('SMC-07') },
            [pscustomobject]@{ Path = 'agents\code-conductor.md'; Rows = @('SMC-01', 'SMC-03', 'SMC-06', 'SMC-08') },
            [pscustomobject]@{ Path = 'agents\code-smith.md'; Rows = @('SMC-01', 'SMC-03') },
            [pscustomobject]@{ Path = 'agents\test-writer.md'; Rows = @('SMC-01', 'SMC-03') },
            [pscustomobject]@{ Path = 'agents\refactor-specialist.md'; Rows = @('SMC-01', 'SMC-03') },
            [pscustomobject]@{ Path = 'agents\doc-keeper.md'; Rows = @('SMC-01', 'SMC-03') },
            [pscustomobject]@{ Path = 'agents\process-review.md'; Rows = @('SMC-01', 'SMC-03', 'SMC-09') },
            [pscustomobject]@{ Path = 'agents\issue-planner.md'; Rows = @('SMC-01', 'SMC-03') },
            [pscustomobject]@{ Path = 'agents\experience-owner.md'; Rows = @('SMC-04', 'SMC-08') },
            [pscustomobject]@{ Path = 'agents\research-agent.md'; Rows = @('SMC-13') },
            [pscustomobject]@{ Path = 'agents\specification.md'; Rows = @('SMC-13') }
        )
    }

    It 'publishes the canonical session-memory contract skill' {
        Test-Path -LiteralPath $script:ContractSkill -PathType Leaf | Should -BeTrue -Because 'skills/session-memory-contract/SKILL.md is the canonical operational contract for issue #440'
    }

    It 'defines the survival vocabulary and surface-naming clause' {
        foreach ($label in $script:BaseSurvivalLabels) {
            $script:ContractContent | Should -Match ([regex]::Escape($label)) -Because "the contract must define the base survival label '$label'"
        }

        $script:ContractContent | Should -Match '(?is)(\{base\}:\{surface\}|base:\s*surface|surface-naming|surface naming|surface-specific label)' -Because 'the contract must require surface-specific labels when survival changes by surface'
    }

    It 'lists SMC-01 through SMC-14 in order with the required row labels' {
        $lastIndex = -1

        foreach ($row in $script:ContractRows) {
            $index = $script:ContractContent.IndexOf($row.Id, [System.StringComparison]::Ordinal)
            $index | Should -BeGreaterThan $lastIndex -Because "$($row.Id) must exist after the previous SMC row"

            $segment = & $script:GetContractRowSegment -RowId $row.Id
            $segment | Should -Match ([regex]::Escape($row.Label)) -Because "$($row.Id) must describe '$($row.Label)'"
            $lastIndex = $index
        }
    }

    It 'defines the six rules and the generic namespace-traversal exemption' {
        $rulePatterns = @(
            [pscustomobject]@{ Name = 'per-shape read precedence'; Pattern = '(?is)(per-shape|shape-specific).{0,120}read precedence|read precedence.{0,120}(per-shape|shape-specific)' },
            [pscustomobject]@{ Name = 'write precedence'; Pattern = '(?is)write precedence' },
            [pscustomobject]@{ Name = 'honest gaps'; Pattern = '(?is)honest gaps?|known gaps?|document(ed)? gaps?' },
            [pscustomobject]@{ Name = 'no-new-mechanism'; Pattern = '(?is)no-new-mechanism|no new mechanism|do not introduce a new persistence mechanism' },
            [pscustomobject]@{ Name = 'survival-label'; Pattern = '(?is)survival-label|survival label' },
            [pscustomobject]@{ Name = 'cache-vs-durable conflict'; Pattern = '(?is)(cache.{0,80}durable.{0,80}conflict|durable.{0,80}cache.{0,80}conflict|cache-vs-durable)' }
        )

        foreach ($rule in $rulePatterns) {
            $script:ContractContent | Should -Match $rule.Pattern -Because "the contract must define the $($rule.Name) rule"
        }

        $script:ContractContent | Should -Match '(?is)(generic )?namespace traversal.{0,240}exempt|exempt.{0,240}(generic )?namespace traversal' -Because 'generic namespace traversal must be exempt from shape-specific survival callouts'
    }

    It 'marks provisional rows for issue 384 and fungibility follow-ups for issue 379' {
        foreach ($row in ($script:ContractRows | Where-Object { $_.Pending384 })) {
            $segment = & $script:GetContractRowSegment -RowId $row.Id
            $segment | Should -Match '(?is)pending-384|#384|issue #384' -Because "$($row.Id) must carry the pending-384 marker or equivalent visible provisional label"
            $segment | Should -Match '(?is)(update|revise|remove|resolve).{0,160}#?384|384.{0,160}(update|revise|remove|resolve)' -Because "$($row.Id) must include the one-line update instruction for issue #384 resolution"
        }

        foreach ($row in ($script:ContractRows | Where-Object { $_.FollowUp379 })) {
            $segment = & $script:GetContractRowSegment -RowId $row.Id
            $segment | Should -Match '(?is)#379|issue #379|follow-up.*379|cross-link.*379' -Because "$($row.Id) is a partial/no fungibility row and must identify the #379 follow-up or cross-link need"
        }
    }

    It 'labels pre-PR review-state as session-scoped instead of worktree-scoped' {
        $segment = & $script:GetContractRowSegment -RowId 'SMC-05'

        $segment | Should -Match '`within-conversation`' -Because 'pre-PR review-state is stored under /memories/session and survives only with the active session memory surface'
        $segment | Should -Not -Match '`within-worktree`' -Because 'the SMC-05 storage path is not a worktree-backed .copilot-tracking artifact'
    }

    It 'documents SMC-04 as a durable GitHub parser anchor with an honest Claude inline fallback gap' {
        $segment = & $script:GetContractRowSegment -RowId 'SMC-04'

        $segment | Should -Match '(?is)GitHub marker.{0,120}durable parser anchor|durable parser anchor.{0,120}GitHub marker' -Because 'SMC-04 must preserve the GitHub issue-comment marker as the durable parser anchor'
        $segment | Should -Match '(?is)local fallback.{0,160}(surface-bound|within-conversation:\{surface\}|write/read `/memories/session`|recovery input)' -Because 'SMC-04 must keep the local payload as bounded recovery input rather than a durable skip marker'
        $segment | Should -Match '(?is)inline/no-write Claude.{0,160}cannot persist.{0,80}recover|Claude.{0,160}cannot persist.{0,80}recover|cannot persist.{0,80}recover.{0,160}Claude' -Because 'SMC-04 must be honest that inline/no-write Claude cannot persist or recover the local fallback payload'
    }

    It 'marks bounded worktree and hook state as partial cross-tool fungibility' {
        foreach ($rowId in @('SMC-10', 'SMC-11', 'SMC-12', 'SMC-13')) {
            $segment = & $script:GetContractRowSegment -RowId $rowId

            $segment | Should -Match '\|\s*`partial - ' -Because "$rowId must use the leading 'partial -' fungibility label for bounded cross-tool reuse"
        }

        $smc12Segment = & $script:GetContractRowSegment -RowId 'SMC-12'
        $smc12Segment | Should -Match 'session_id' -Because 'SMC-12 must name Claude session_id keying explicitly'
        $smc12Segment | Should -Match '(?is)(keying.{0,80}diverg|diverg.{0,80}keying|session_id.{0,160}branch slug|branch slug.{0,160}session_id|same key)' -Because 'SMC-12 must document session_id-versus-branch key divergence and the same-key sharing condition'
    }

    It 'requires every SMC row to carry a citation or explicit delegated/informational note' {
        foreach ($row in $script:ContractRows) {
            $segment = & $script:GetContractRowSegment -RowId $row.Id
            $segment | Should -Match '(?is)(\[[^\]]+\]\([^)]+\)|\bcitations?\b|\bdelegated\b|\binformational\b)' -Because "$($row.Id) must be grounded by at least one citation or an explicit delegated/informational note"
        }
    }

    It 'requires scan-discovered state-owning skills and references to carry survival-label callouts' {
        foreach ($surface in $script:StateOwningSurfaces) {
            $path = Join-Path $script:RepoRoot $surface.Path
            Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue -Because "$($surface.Path) is a scan-discovered state-owning surface"
            $content = & $script:ReadContent -Path $path

            foreach ($rowId in $surface.Rows) {
                & $script:AssertSurvivalCallout -Content $content -RowId $rowId -Path $surface.Path
            }
        }
    }

    It 'requires shared agent bodies that own plan, design, and handoff state to cite their SMC rows' {
        foreach ($surface in $script:SharedAgentStateSurfaces) {
            $path = Join-Path $script:RepoRoot $surface.Path
            Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue -Because "$($surface.Path) is a state-owning shared agent body"
            $content = & $script:ReadContent -Path $path

            foreach ($rowId in $surface.Rows) {
                $content | Should -Match ('\b' + [regex]::Escape($rowId) + '\b') -Because "$($surface.Path) must cite $rowId where it owns plan, design, progress, or durable handoff state"
            }
        }
    }

    It 'requires command and shell surfaces to cite owning contract rows instead of bare memory fallback prose' {
        $bareFallbackPattern = '(?i)(Claude Code does not use `vscode/memory`|Not used in Claude Code|no equivalent session-memory tool|vscode/memory plan/design lookups|session-memory write surface|Claude Code inline currently lacks a session-memory write surface)'

        foreach ($surface in $script:CommandAndShellSurfaces) {
            $path = Join-Path $script:RepoRoot $surface.Path
            Test-Path -LiteralPath $path -PathType Leaf | Should -BeTrue -Because "$($surface.Path) is a scan-discovered Claude command or shell surface"
            $content = & $script:ReadContent -Path $path

            foreach ($rowId in $surface.Rows) {
                $content | Should -Match ('\b' + [regex]::Escape($rowId) + '\b') -Because "$($surface.Path) must cite the owning session-memory contract row $rowId"
            }

            $lineNumber = 0
            foreach ($line in ($content -split "`r?`n")) {
                $lineNumber++
                if ($line -match $bareFallbackPattern) {
                    $line | Should -Match '\bSMC-\d{2}\b' -Because "$($surface.Path) line $lineNumber must cite an SMC row when it describes Claude/vscode memory fallback behavior"
                }
            }
        }
    }

    It 'requires tracking-format to delegate or retire the Cloud Agent Handoff Protocol' {
        $path = Join-Path $script:RepoRoot 'skills\tracking-format\SKILL.md'
        $content = & $script:ReadContent -Path $path

        $content | Should -Match '(?is)Cloud Agent Handoff Protocol.{0,500}(skills/session-memory-contract/SKILL\.md|SMC-\d{2}).{0,500}(delegat|retir|canonical|contract)' -Because 'tracking-format must delegate the old cloud handoff guidance to the canonical session-memory contract'
        $content | Should -Not -Match '(?is)^## Cloud Agent Handoff Protocol\s*\r?\n(?:(?!^## ).)*\|\s*Phase\s*\|\s*Agent\s*\|\s*Output Location\s*\|' -Because 'the old phase/location table must not remain as a competing source of truth'
    }

    It 'requires routing-config plan-path routing to be contract-derived or delegated' {
        Test-Path -LiteralPath $script:RoutingConfigPath -PathType Leaf | Should -BeTrue
        $config = (& $script:ReadContent -Path $script:RoutingConfigPath) | ConvertFrom-Json -AsHashtable
        $planEntries = @(
            $config.specialist_dispatch.entries |
                Where-Object {
                    ([string]($_.file_type_or_task)) -match '/memories/session/plan-issue-\{ID\}\.md|plan-issue-\{ID\}'
                }
        )

        $planEntries | Should -HaveCount 1 -Because 'the specialist dispatch table should have exactly one plan-path routing entry'
        if ($planEntries.Count -gt 0) {
            $entry = $planEntries[0]
            $delegationText = @(
                'contract_source',
                'source_contract',
                'derived_from',
                'delegated_to',
                'contract_row'
            ) | ForEach-Object {
                if ($entry.ContainsKey($_)) {
                    [string]$entry[$_]
                }
            }

            ($delegationText -join ' ') | Should -Match '(?is)skills/session-memory-contract/SKILL\.md|SMC-01|contract-derived|delegated' -Because 'the plan-path routing row must identify that it is derived from or delegated to the session-memory contract'
        }
    }
}
