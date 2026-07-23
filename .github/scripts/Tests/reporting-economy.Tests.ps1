# Requires -Version 7.0
# Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Verifies the reporting-economy directive is present as the terminal bullet of
    ## Core Principles in every in-scope specialist agent body.

.DESCRIPTION
    The canonical directive text is defined once as a here-string fixture.
    Tests discover in-scope bodies dynamically (Glob agents/*.agent.md minus the
    pinned exclusion set) and assert:
      1. The count of in-scope bodies is exactly 12 and excluded bodies is exactly 5.
      2. Each in-scope body contains the directive as the terminal "- " bullet of
         its ## Core Principles section (not merely a substring anywhere in the file).

    MAINTAINER NOTE: when adding a new .agent.md body, decide whether it belongs in
    the exclusion set (orchestration / upstream / conductor bodies that have no
    specialist Core Principles list). If it is not excluded, the reporting-economy
    directive must be added to its ## Core Principles section as the final bullet
    before s2 or any subsequent implementation step touches the file.

    Helper scriptblocks (GetSectionBody, NormalizeContent) are copied verbatim from
    specialist-shell-parity.Tests.ps1 lines 31-44 and 136. They must not be
    reimported by dot-sourcing the parity test file (that would run parity tests).
#>

# ---------------------------------------------------------------------------
# BeforeDiscovery: data needed for -ForEach parameterization (discovery phase).
# This block runs before Pester builds the test tree, so -ForEach can use it.
# ---------------------------------------------------------------------------

BeforeDiscovery {
    $RepoRoot       = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $AgentsDirectory = Join-Path $RepoRoot 'agents'

    # Exclusion set — orchestration / upstream / conductor bodies that do not
    # carry a specialist ## Core Principles list.
    # BaseName comparison is PascalCase. Note: Get-ChildItem .BaseName for a file
    # named "Code-Conductor.agent.md" returns "Code-Conductor.agent" (only the
    # last extension is stripped), so we normalise by stripping the ".agent" suffix.
    $ExcludedBaseNames = @(
        'Code-Conductor',
        'Spine-Runner',
        'Experience-Owner',
        'Solution-Designer',
        'Issue-Planner'
    )

    $allBodies      = @(Get-ChildItem -Path $AgentsDirectory -Filter '*.agent.md' -File)
    $InScopeBodies  = @($allBodies | Where-Object { ($_.BaseName -replace '\.agent$', '') -notin $ExcludedBaseNames })

    # Expose for -ForEach parameterization as a plain array of hashtables
    $script:DiscoveryInScopeRows = @(
        $InScopeBodies | ForEach-Object {
            @{
                BaseName = ($_.BaseName -replace '\.agent$', '')
                FullName = $_.FullName
            }
        }
    )

    # Store counts for the count-guard test
    $script:DiscoveryInScopeCount  = $InScopeBodies.Count
    $script:DiscoveryExcludedCount = @($allBodies | Where-Object { ($_.BaseName -replace '\.agent$', '') -in $ExcludedBaseNames }).Count

    if (@($script:DiscoveryInScopeRows).Count -eq 0) {
        throw "no in-scope agent bodies found in $AgentsDirectory — coverage would silently vanish"
    }
}

Describe 'Reporting-economy directive in specialist agent bodies' {

    BeforeAll {
        $script:RepoRoot       = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:AgentsDirectory = Join-Path $script:RepoRoot 'agents'

        # ---------------------------------------------------------------------------
        # Helpers — copied verbatim from specialist-shell-parity.Tests.ps1 (lines
        # 31-44 and 136). Do NOT dot-source the parity file — that runs parity tests.
        # ---------------------------------------------------------------------------

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

        $script:NormalizeContent = {
            param([string]$Content)

            return ($Content -replace "`r`n?", "`n").Trim()
        }

        # ---------------------------------------------------------------------------
        # Canonical directive — single source of truth.
        # All comparisons use this fixture; do not retype the text elsewhere.
        # ---------------------------------------------------------------------------

        $script:CanonicalDirective = @'
- **Reporting economy.** Do not echo your tool-call transcript — the mechanical replay of reads and commands you ran (e.g., your platform's tool-call markers such as `[Tool: read]` / `[Tool: bash]`) — in your response; it costs the parent return-trip tokens with no value. Lead with the smallest advancing signal (file paths touched, pass/fail counts where applicable) and keep free narration to roughly 150 words or fewer. This cap is subordinate to any role-mandated structured output your role emits: when your role requires a structured artifact (for example a findings ledger, a `judge-rulings` block, a research document, a specification, a defect-analysis block), that artifact governs in full and the cap applies only to free narration around it — the named examples are illustrative, not exhaustive. The cap never suppresses required fixed-form output such as a Step 0 environment-handshake or divergence (ND-2) emission, a contract-locked tool-gap announcement, or a mandated report prefix. Evidence citations (`file:line`, quoted load-bearing snippets) are encouraged, not transcript noise. The parent may always request full detail.
'@

        $script:ExpectedInScopeCount  = 12
        $script:ExpectedExcludedCount = 5
    }

    It 'finds exactly 11 in-scope bodies and 5 excluded bodies' {
        # Re-derive the counts at run time (BeforeDiscovery script: vars don't survive into run phase).
        $allBodies     = @(Get-ChildItem -Path $script:AgentsDirectory -Filter '*.agent.md' -File)
        $ExcludedNames = @('Code-Conductor','Spine-Runner','Experience-Owner','Solution-Designer','Issue-Planner')
        $inCount = @($allBodies | Where-Object { ($_.BaseName -replace '\.agent$', '') -notin $ExcludedNames }).Count
        $exCount = @($allBodies | Where-Object { ($_.BaseName -replace '\.agent$', '') -in  $ExcludedNames }).Count

        $inCount | Should -Be $script:ExpectedInScopeCount -Because (
            "Expected $($script:ExpectedInScopeCount) in-scope bodies and $($script:ExpectedExcludedCount) excluded bodies; " +
            "got $inCount in-scope and $exCount excluded. " +
            "A new .agent.md file may need to be added to the exclusion set or vice versa."
        )

        $exCount | Should -Be $script:ExpectedExcludedCount -Because (
            "Expected $($script:ExpectedInScopeCount) in-scope bodies and $($script:ExpectedExcludedCount) excluded bodies; " +
            "got $inCount in-scope and $exCount excluded. " +
            "A new .agent.md file may need to be added to the exclusion set or vice versa."
        )
    }

    It 'contains the canonical reporting-economy directive as the terminal Core Principles bullet in <BaseName>' -ForEach $script:DiscoveryInScopeRows {
        $content     = Get-Content -Path $FullName -Raw -ErrorAction Stop
        $sectionBody = & $script:GetSectionBody -Content $content -Heading '## Core Principles'

        $normalizedDirective = & $script:NormalizeContent -Content $script:CanonicalDirective

        # --- Section must exist -------------------------------------------------------
        $sectionBody | Should -Not -BeNullOrEmpty -Because (
            "Body '$BaseName' must have a ## Core Principles section for the directive to live in"
        )

        $normalizedSection = & $script:NormalizeContent -Content $sectionBody
        $directivePresent  = $normalizedSection.Contains($normalizedDirective)

        # --- Terminal-bullet check ----------------------------------------------------
        # Extract every "- " bullet line from the section (lines starting with "- ").
        # The last such line must equal the canonical directive after LF-normalization.
        $bulletLines = @(
            ($sectionBody -split "`r?`n") |
                Where-Object { $_ -match '^- ' }
        )

        if ($bulletLines.Count -gt 0) {
            $lastBullet = & $script:NormalizeContent -Content $bulletLines[-1]

            if (-not $directivePresent) {
                # Directive is entirely absent from the section.
                $lastBullet | Should -Be $normalizedDirective -Because (
                    "Body '$BaseName' is in the in-scope set but the canonical directive is missing — " +
                    "add the directive (s2 step) OR add this body to the exclusion set"
                )
            }
            else {
                # Directive is present somewhere; confirm it is the terminal bullet.
                $lastBullet | Should -Be $normalizedDirective -Because (
                    "Body '$BaseName' has the canonical directive but it is NOT the terminal bullet of " +
                    "the Core Principles list — the directive must be the last ``- `` item before any " +
                    "heading or non-bullet content"
                )
            }
        }
        else {
            # No bullet lines found at all — treat as missing.
            $false | Should -BeTrue -Because (
                "Body '$BaseName' is in the in-scope set but the canonical directive is missing — " +
                "add the directive (s2 step) OR add this body to the exclusion set"
            )
        }
    }
}
