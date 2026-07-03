#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Contract tests for the five-pass two-layer adversarial prosecution panel (issue #706).

.DESCRIPTION
    AC8 — Role-to-tier map resolution and fallback order declared in
          skills/adversarial-review/platforms/claude.md.

    AC5 — Cross-layer dedup prefers the deepest-tier finding when two passes
          report the same defect at the same code location and failure mode.
#>

Describe 'Adversarial review panel — role-to-tier map and fallback (AC8)' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:DispatcherPath = Join-Path $script:RepoRoot 'skills/adversarial-review/platforms/claude.md'
        $script:DispatcherContent = Get-Content -Path $script:DispatcherPath -Raw -ErrorAction Stop
    }

    It 'platforms/claude.md declares generalist-A mapped to sonnet in the role-to-tier map' {
        $script:DispatcherContent | Should -Match 'generalist-A:\s*sonnet' `
            -Because 'generalist-A pass must use sonnet tier per the role-to-tier map'
    }

    It 'platforms/claude.md declares generalist-B mapped to fable in the role-to-tier map' {
        $script:DispatcherContent | Should -Match 'generalist-B:\s*fable' `
            -Because 'generalist-B pass must use fable tier per the role-to-tier map'
    }

    It 'platforms/claude.md declares judge mapped to fable in the role-to-tier map' {
        $script:DispatcherContent | Should -Match 'judge:\s*fable' `
            -Because 'judge tier must use fable tier per the role-to-tier map'
    }

    It 'platforms/claude.md declares specialist mapped to opus in the role-to-tier map' {
        $script:DispatcherContent | Should -Match 'specialist:\s*opus' `
            -Because 'specialist passes must use opus tier per the role-to-tier map'
    }

    It 'platforms/claude.md declares the fallback order fable -> opus -> sonnet -> haiku' {
        $script:DispatcherContent | Should -Match '(?is)fallback order.{0,120}fable.{0,20}opus.{0,20}sonnet.{0,20}haiku' `
            -Because 'the fallback order must progress fable to opus to sonnet to haiku when a tier is unavailable'
    }

    It 'platforms/claude.md documents a five-pass two-layer prosecution panel for the standard adapter' {
        $script:DispatcherContent | Should -Match '(?is)5.pass|five.pass|2 generalist.{0,20}3 specialist|generalist-A.{0,200}generalist-B.{0,200}specialist' `
            -Because 'the standard adapter must document the two-layer panel with generalist and specialist pass roles'
    }

    It 'platforms/claude.md assigns Pass 1 (generalist-A) sonnet and Pass 2 (generalist-B) fable at Agent-tool call time' {
        $script:DispatcherContent | Should -Match '(?is)Pass 1.{0,80}generalist-A.{0,80}sonnet' `
            -Because 'Pass 1 generalist-A must set model: sonnet on the Agent tool call'
        $script:DispatcherContent | Should -Match '(?is)Pass 2.{0,80}generalist-B.{0,80}fable' `
            -Because 'Pass 2 generalist-B must set model: fable on the Agent tool call'
    }

    It 'platforms/claude.md assigns Passes 3, 4, and 5 (specialist) opus at Agent-tool call time' {
        $script:DispatcherContent | Should -Match '(?is)Pass 3.{0,120}opus' `
            -Because 'Pass 3 spec-correctness specialist must set model: opus on the Agent tool call'
        $script:DispatcherContent | Should -Match '(?is)Pass 4.{0,120}opus' `
            -Because 'Pass 4 spec-security specialist must set model: opus on the Agent tool call'
        $script:DispatcherContent | Should -Match '(?is)Pass 5.{0,120}opus' `
            -Because 'Pass 5 spec-architecture specialist must set model: opus on the Agent tool call'
    }
}

Describe 'Adversarial review panel — cross-layer dedup prefers deepest-tier finding (AC5)' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:DispatcherPath = Join-Path $script:RepoRoot 'skills/adversarial-review/platforms/claude.md'
        $script:DispatcherContent = Get-Content -Path $script:DispatcherPath -Raw -ErrorAction Stop
    }

    It 'platforms/claude.md documents the cross-layer dedup rule using failure-mode and code-location as the merge key' {
        $script:DispatcherContent | Should -Match '(?is)cross.layer dedup.{0,120}failure.mode.{0,80}code.location' `
            -Because 'cross-layer dedup must merge on same failure-mode plus same code-location, not perspective label'
    }

    It 'platforms/claude.md states that the deepest-tier finding wins when two passes report the same defect' {
        $script:DispatcherContent | Should -Match '(?is)prefer the finding from the deepest.tier pass' `
            -Because 'when two passes report the same defect, the deepest-tier finding must win'
    }

    It 'platforms/claude.md names Opus as preferred over Sonnet in the cross-layer dedup rule' {
        $script:DispatcherContent | Should -Match '(?is)Opus preferred over Sonnet' `
            -Because 'Opus tier is the deepest available tier for most passes and must win over Sonnet in cross-layer dedup'
    }

    It 'cross-layer dedup correctly identifies the deepest-tier winner for same code-location same failure-mode findings' {
        # Simulate two prosecution findings at the same location with the same failure mode.
        # Pass 1 (generalist-A, Sonnet) finds a null-check gap.
        # Pass 2 (generalist-B, Opus) finds the same null-check gap at the same location.
        # After cross-layer dedup, the Opus finding should be credited.

        $sonnetFinding = [pscustomobject]@{
            id           = 'F1-sonnet'
            pass         = 1
            tier         = 'sonnet'
            role         = 'generalist-A'
            failure_mode = 'null-check-missing'
            code_location = 'src/auth.ts:42'
            severity     = 'medium'
            description  = 'Null check missing (generalist-A/Sonnet)'
        }

        $opusFinding = [pscustomobject]@{
            id           = 'F1-opus'
            pass         = 2
            tier         = 'opus'
            role         = 'generalist-B'
            failure_mode = 'null-check-missing'
            code_location = 'src/auth.ts:42'
            severity     = 'high'
            description  = 'Null check missing (generalist-B/Opus)'
        }

        # Apply cross-layer dedup: group by failure_mode + code_location,
        # then select the deepest-tier finding.
        # Tier depth order: opus > sonnet (matching the fallback order in reverse: haiku < sonnet < opus < fable)
        $tierDepth = @{ 'fable' = 4; 'opus' = 3; 'sonnet' = 2; 'haiku' = 1 }

        $findings = @($sonnetFinding, $opusFinding)

        $grouped = $findings | Group-Object { "$($_.failure_mode)|$($_.code_location)" }
        $merged = @(
            $grouped | ForEach-Object {
                $_.Group | Sort-Object { $tierDepth[$_.tier] } -Descending | Select-Object -First 1
            }
        )

        # After dedup, exactly one finding should survive.
        $merged.Count | Should -Be 1 -Because 'two findings with the same failure-mode and code-location must merge to one'

        # The surviving finding must be from the deepest tier (Opus).
        $merged[0].tier | Should -Be 'opus' -Because 'the cross-layer dedup rule prefers the deepest-tier finding (Opus over Sonnet)'
        $merged[0].role | Should -Be 'generalist-B' -Because 'the generalist-B (Opus) pass produces the deepest-tier finding'
        $merged[0].id   | Should -Be 'F1-opus'      -Because 'the Opus finding id must be credited, not the Sonnet finding'
    }

    It 'cross-layer dedup does not merge findings at different code locations even with the same failure mode' {
        # Two findings with the same failure-mode but different code locations must NOT be merged.
        $finding1 = [pscustomobject]@{
            failure_mode  = 'null-check-missing'
            code_location = 'src/auth.ts:42'
            tier          = 'sonnet'
        }
        $finding2 = [pscustomobject]@{
            failure_mode  = 'null-check-missing'
            code_location = 'src/auth.ts:87'
            tier          = 'opus'
        }

        $findings = @($finding1, $finding2)
        $grouped = $findings | Group-Object { "$($_.failure_mode)|$($_.code_location)" }
        $merged = @(
            $grouped | ForEach-Object {
                $tierDepth = @{ 'fable' = 4; 'opus' = 3; 'sonnet' = 2; 'haiku' = 1 }
                $_.Group | Sort-Object { $tierDepth[$_.tier] } -Descending | Select-Object -First 1
            }
        )

        $merged.Count | Should -Be 2 -Because 'findings at different code locations must not be merged even if the failure mode is the same'
    }
}

Describe 'Adversarial review panel — generalist-B/judge fable re-tier prose literals (AC9)' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:DispatcherPath = Join-Path $script:RepoRoot 'skills/adversarial-review/platforms/claude.md'
        $script:DispatcherContent = Get-Content -Path $script:DispatcherPath -Raw -ErrorAction Stop
    }

    It 'platforms/claude.md role-to-tier map declares generalist-B: fable' {
        $script:DispatcherContent | Should -Match '(?im)^\s*generalist-B:\s*fable\s*$' `
            -Because 'AC9 requires the role-to-tier map to declare generalist-B mapped to fable'
    }

    It 'platforms/claude.md role-to-tier map declares judge: fable' {
        $script:DispatcherContent | Should -Match '(?im)^\s*judge:\s*fable\s*$' `
            -Because 'AC9 requires the role-to-tier map to declare a judge key mapped to fable'
    }

    It 'platforms/claude.md declares a durable negative rule that the spec-security specialist lens is never mapped to fable' {
        $script:DispatcherContent | Should -Match '(?is)spec-security specialist lens \(Pass 4\) is never mapped to .fable.' `
            -Because 'the spec-security specialist lens (Pass 4) must never be mapped to fable per the negative rule'
    }

    It 'platforms/claude.md keeps Pass 4 (spec-security specialist) assigned to opus at Agent-tool call time' {
        $script:DispatcherContent | Should -Match '(?is)Pass 4.{0,120}spec-security specialist.{0,120}opus' `
            -Because 'Pass 4 spec-security specialist must stay on model: opus, never fable'
        $script:DispatcherContent | Should -Not -Match '(?is)Pass 4.{0,120}spec-security specialist.{0,120}fable' `
            -Because 'the Pass 4 dispatch bullet must never assign fable to the spec-security specialist'
    }
}

Describe 'Adversarial review panel — generalist-B refusal reroute prose literals (CR3)' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:DispatcherPath = Join-Path $script:RepoRoot 'skills/adversarial-review/platforms/claude.md'
        $script:DispatcherContent = Get-Content -Path $script:DispatcherPath -Raw -ErrorAction Stop
    }

    It 'platforms/claude.md documents the generalist-B refusal reroute retrying once on fable' {
        $script:DispatcherContent | Should -Match '(?is)generalist-B refusal reroute.{0,400}retry that pass once on .fable.' `
            -Because 'the refusal-reroute rule must retry the Pass 2 (generalist-B) dispatch once on fable before falling back'
    }

    It 'platforms/claude.md documents the generalist-B refusal reroute falling back to opus' {
        $script:DispatcherContent | Should -Match '(?is)generalist-B refusal reroute.{0,600}re-dispatch Pass 2 on .model: opus.' `
            -Because 'the refusal-reroute rule must fall back to model: opus after the fable retry also refuses'
    }

    It 'platforms/claude.md documents a degraded-tier note for the generalist-B refusal reroute' {
        $script:DispatcherContent | Should -Match '(?is)generalist-B refusal reroute.{0,800}degraded tier.{0,120}Pass 2 \(generalist-B\) degraded to opus after refusal' `
            -Because 'the refusal-reroute rule must visibly note the degraded tier when Pass 2 falls back to opus'
    }
}
