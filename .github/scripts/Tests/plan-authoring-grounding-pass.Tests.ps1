#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#!
.SYNOPSIS
    Contract tests for issue #473 plan-authoring Grounding Pass.

.DESCRIPTION
    Locks the RED assertion-existence contract for the Grounding Pass step that
    must be added to the Discovery Workflow in skills/plan-authoring/SKILL.md.
    All assertions are RED until Step 2 authors the content.

    Sections verified:
    - ## Discovery Workflow  -> ### 4. Grounding Pass heading + invariants
    - ## Alignment Workflow  -> factual-correction exemption sentence
    - ## Tree-State Verification Discipline -> reciprocal Grounding Pass anchor
#>

Describe 'Plan-authoring Grounding Pass contract' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:PlanAuthoringPath = Join-Path $script:RepoRoot 'skills/plan-authoring/SKILL.md'

        $script:GetNormalizedContent = {
            param([string]$Path)

            return ((Get-Content -Path $Path -Raw -ErrorAction Stop) -replace "`r`n?", "`n")
        }

        # Returns the body of an H2 section, stopping at the next H2 boundary.
        # Stop regex: ^##\s+  (two hashes followed by at least one space — H2 only).
        $script:GetMarkdownSection = {
            param(
                [string]$Content,
                [string]$Heading
            )

            $headingMatch = [regex]::Match($Content, ('(?m)^{0}\s*$' -f [regex]::Escape($Heading)))
            if (-not $headingMatch.Success) {
                return ''
            }

            $bodyStart = $headingMatch.Index + $headingMatch.Length
            $remaining = $Content.Substring($bodyStart)
            $nextHeading = [regex]::Match($remaining, '(?m)^##\s+')

            if ($nextHeading.Success) {
                return $remaining.Substring(0, $nextHeading.Index)
            }

            return $remaining
        }

        $script:PlanAuthoringContent = & $script:GetNormalizedContent -Path $script:PlanAuthoringPath

        # Pre-load the three target sections.
        $script:DiscoverySection  = & $script:GetMarkdownSection -Content $script:PlanAuthoringContent -Heading '## Discovery Workflow'
        $script:AlignmentSection  = & $script:GetMarkdownSection -Content $script:PlanAuthoringContent -Heading '## Alignment Workflow'
        $script:TreeStateSection  = & $script:GetMarkdownSection -Content $script:PlanAuthoringContent -Heading '## Tree-State Verification Discipline'
    }

    # -------------------------------------------------------------------------
    # It 1 — Heading position (Discovery scope)
    # ### 4. Grounding Pass must exist and appear after ### 3. Keep the Research Subagent Bounded
    # -------------------------------------------------------------------------
    It 'defines ### 4. Grounding Pass heading in the Discovery Workflow section after ### 3' {
        $h3_3Index = $script:DiscoverySection.IndexOf('### 3. Keep the Research Subagent Bounded', [System.StringComparison]::Ordinal)
        $h3Index   = $script:DiscoverySection.IndexOf('### 4. Grounding Pass', [System.StringComparison]::Ordinal)

        $h3_3Index | Should -BeGreaterOrEqual 0 -Because '### 3. Keep the Research Subagent Bounded must already exist in the Discovery section'
        $h3Index   | Should -BeGreaterOrEqual 0 -Because '### 4. Grounding Pass heading must be present in the Discovery section'
        $h3Index   | Should -BeGreaterThan $h3_3Index -Because '### 4. Grounding Pass must appear after ### 3. Keep the Research Subagent Bounded'
    }

    # -------------------------------------------------------------------------
    # It 2 — Invariant (Discovery scope)
    # -------------------------------------------------------------------------
    It 'states the no-ungrounded-artifact invariant in the Discovery Workflow section' {
        $script:DiscoverySection | Should -Match 'no plan step may name an ungrounded artifact' -Because 'the invariant must be stated verbatim in the Grounding Pass content'
    }

    # -------------------------------------------------------------------------
    # It 3 — Write-back rule (Discovery scope)
    # Three separate sub-assertions: correct/update the issue, before drafting, names/paths/shapes/counts
    # -------------------------------------------------------------------------
    It 'states the write-back rule (correct-or-update, before drafting, names/paths/shapes/counts) in the Discovery Workflow section' {
        $script:DiscoverySection | Should -Match '(correct|update)\s+the\s+issue' -Because 'the write-back rule must direct the planner to correct or update the issue'
        $script:DiscoverySection | Should -Match 'before drafting' -Because 'the write-back rule must require the correction to happen before drafting'
        $script:DiscoverySection | Should -Match '(names|paths|shapes|counts)' -Because 'the write-back rule must enumerate the artifact properties that require correction'
    }

    # -------------------------------------------------------------------------
    # It 4 — #591 carve-out (Discovery scope)
    # Proximity-anchored regex — migration-scan and #591 must appear together
    # -------------------------------------------------------------------------
    It 'documents the #591 migration-scan carve-out in the Discovery Workflow section' {
        $script:DiscoverySection | Should -Match 'migration[- ]scan .*#591|Step-1 exhaustive scan.*#591|#591.*Step-1 exhaustive scan' -Because 'the Grounding Pass must acknowledge the migration-scan carve-out that #591 introduced'
    }

    # -------------------------------------------------------------------------
    # It 5 — Observation note (Discovery scope)
    # #467 and per-port must both appear in the Discovery section
    # -------------------------------------------------------------------------
    It 'references #467 and per-port in the Discovery Workflow section' {
        $script:DiscoverySection | Should -Match '#467'    -Because 'the Grounding Pass observation note must cite issue #467'
        $script:DiscoverySection | Should -Match 'per-port' -Because 'the Grounding Pass observation note must use the per-port qualifier'
    }

    # -------------------------------------------------------------------------
    # It 6 — Subagent contradiction-reporting (scoped to ### 3. Keep the Research Subagent Bounded)
    # Extract the ### 3 sub-section from the Discovery section body, then assert.
    # -------------------------------------------------------------------------
    It 'directs the Research Subagent to report contradictions in the ### 3 subsection' {
        # Find the start of ### 3 within the Discovery section body.
        $h3_3Start = $script:DiscoverySection.IndexOf('### 3. Keep the Research Subagent Bounded', [System.StringComparison]::Ordinal)
        $h3_3Start | Should -BeGreaterOrEqual 0 -Because '### 3. Keep the Research Subagent Bounded must exist in the Discovery section'

        # Find the next ### boundary after ### 3 (end of the sub-section).
        $afterH3_3   = $script:DiscoverySection.Substring($h3_3Start + '### 3. Keep the Research Subagent Bounded'.Length)
        $nextH3Match = [regex]::Match($afterH3_3, '(?m)^###\s+')

        $h3_3Body = if ($nextH3Match.Success) {
            $afterH3_3.Substring(0, $nextH3Match.Index)
        } else {
            $afterH3_3
        }

        $h3_3Body | Should -Match 'report'        -Because 'the Research Subagent bounded section must instruct it to report what it found'
        $h3_3Body | Should -Match 'contradiction'  -Because 'the Research Subagent bounded section must explicitly name contradictions as something to report'
    }

    # -------------------------------------------------------------------------
    # It 7 — Alignment exemption sentence (Alignment scope)
    # -------------------------------------------------------------------------
    It 'includes a factual-correction exemption sentence in the Alignment Workflow section' {
        $script:AlignmentSection | Should -Match 'factual correction' -Because 'the Alignment section must document the exemption for factual corrections sourced from the Grounding Pass'
        $script:AlignmentSection | Should -Match 'material'           -Because 'the Alignment exemption sentence must distinguish material scope changes from factual corrections'
    }

    # -------------------------------------------------------------------------
    # It 8 — Tree-State reciprocal anchor (Tree-State scope)
    # -------------------------------------------------------------------------
    It 'includes a reciprocal Grounding Pass anchor in the Tree-State Verification Discipline section' {
        $script:TreeStateSection | Should -Match 'Grounding Pass' -Because 'Tree-State Verification Discipline must reference the Grounding Pass as its upstream discovery peer'
        $script:TreeStateSection | Should -Match 'step[- ]?prose'  -Because 'Tree-State Verification Discipline must use step-prose language to anchor the reciprocal reference'
    }
}
