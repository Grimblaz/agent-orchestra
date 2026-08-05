#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Diet guard and pointer-resolution tests for CLAUDE.md extraction (issue #694).

.DESCRIPTION
    EXPECTED-RED until s8 of issue #694 — these tests encode the target state BEFORE
    content is moved. They will fail (red) until all four extraction slices (s3–s6) are
    complete. After s8 lands, all five tests must be green.

    Two concerns are tested:

    AC1  — Diet guard: CLAUDE.md must shrink below 200 lines (production target: <190).
    AC6  — Pointer resolution: each destination file exists and contains a sentinel that
            proves the moved content landed there.

    Destination files and their sentinels:
        skills/session-memory-contract/references/handoff-markers.md
            sentinel: 'experience-owner-complete'              (added in s3)
        skills/routing-tables/SKILL.md
            sentinel: 'first match per command-family'         (added in s4)
        skills/session-startup/SKILL.md
            sentinel: 'auto-mode-boundary-recipe:begin'        (added in s5)
        Documents/Design/agent-body-architecture.md
            sentinel: 'CLAUDE_CODE_SUBAGENT_MODEL'             (added in s6)
#>

Describe 'CLAUDE.md diet (#694)' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ClaudeMdPath = Join-Path $script:RepoRoot 'CLAUDE.md'
    }

    # ─────────────────────────────────────────────────────────────
    # AC1: Diet guard
    # ─────────────────────────────────────────────────────────────
    Context 'Diet guard' {

        It 'CLAUDE.md is below the 200-line diet budget' {
            # plan target: <190 lines; test threshold: 200 (guard with margin)
            # Uses (Get-Content).Count which correctly counts LF-separated lines on all platforms.
            $lines = @(Get-Content $script:ClaudeMdPath).Count
            $lines | Should -BeLessThan 200
        }
    }

    # ─────────────────────────────────────────────────────────────
    # AC6: Pointer resolution (expected-red until s8)
    # Each It block asserts BOTH existence AND sentinel presence so
    # the full target state is captured in one failure per destination.
    # ─────────────────────────────────────────────────────────────
    Context 'Pointer resolution (expected-red until s8)' {

        It 'handoff-markers.md exists and contains sentinel ''experience-owner-complete'' (s3)' {
            $path = Join-Path $script:RepoRoot 'skills/session-memory-contract/references/handoff-markers.md'
            Test-Path $path | Should -BeTrue -Because 's3 must create skills/session-memory-contract/references/handoff-markers.md'
            $content = Get-Content $path -Raw -ErrorAction SilentlyContinue
            $content | Should -Match 'experience-owner-complete' `
                -Because 's3 must land the cross-tool handoff marker table into handoff-markers.md'
        }

        It 'skills/routing-tables/SKILL.md exists and contains sentinel ''first match per command-family'' (s4)' {
            $path = Join-Path $script:RepoRoot 'skills/routing-tables/SKILL.md'
            Test-Path $path | Should -BeTrue -Because 'skills/routing-tables/SKILL.md must exist'
            $content = Get-Content $path -Raw -ErrorAction SilentlyContinue
            $content | Should -Match 'first match per command-family' `
                -Because 's4 must move the intent-routing mechanics block (including the first-match rule) into this skill'
        }

        It 'skills/session-startup/SKILL.md exists and contains sentinel ''auto-mode-boundary-recipe:begin'' (s5)' {
            $path = Join-Path $script:RepoRoot 'skills/session-startup/SKILL.md'
            Test-Path $path | Should -BeTrue -Because 'skills/session-startup/SKILL.md must exist'
            $content = Get-Content $path -Raw -ErrorAction SilentlyContinue
            $content | Should -Match 'auto-mode-boundary-recipe:begin' `
                -Because 's5 must move the auto-mode boundary recipe sentinel block into this skill'
        }

        It 'Documents/Design/agent-body-architecture.md exists and contains sentinel ''CLAUDE_CODE_SUBAGENT_MODEL'' (s6)' {
            $path = Join-Path $script:RepoRoot 'Documents/Design/agent-body-architecture.md'
            Test-Path $path | Should -BeTrue -Because 'Documents/Design/agent-body-architecture.md must exist'
            $content = Get-Content $path -Raw -ErrorAction SilentlyContinue
            $content | Should -Match 'CLAUDE_CODE_SUBAGENT_MODEL' `
                -Because 's6 must land the per-agent model routing table (including the CLAUDE_CODE_SUBAGENT_MODEL override env-var) into this design doc'
        }

        # ─────────────────────────────────────────────────────────────
        # Issue #998 destinations. The convention this Context records is
        # that EACH destination carries a sentinel proving the moved content
        # landed there. #998 extracted two more sections to pay for the
        # finished-run statement and registered no sentinel for either, so
        # deleting either moved section left CLAUDE.md's pointer dangling
        # with this suite green (review finding M21). These two close that.
        # The sentinels are strings from the MOVED body, not from content
        # that was already at the destination — a sentinel satisfied by
        # pre-existing text proves nothing about the move.
        # ─────────────────────────────────────────────────────────────

        It 'agent-body-architecture.md contains the moved Senior Engineer adapter mechanics (#998)' {
            $path = Join-Path $script:RepoRoot 'Documents/Design/agent-body-architecture.md'
            $content = Get-Content $path -Raw -ErrorAction SilentlyContinue
            $content | Should -Match 'adversarial-independence-required' `
                -Because '#998 moved the Senior Engineer adapter mechanics here; this string is from the moved body, so its absence means the move was reverted or deleted while CLAUDE.md still points here'
            $content | Should -Match '\{port\}-auto-na-adapter\.md' `
                -Because 'the adapter file conventions moved with it'
        }

        It 'routing-tables/SKILL.md contains the moved handshake disposition table (#998)' {
            $path = Join-Path $script:RepoRoot 'skills/routing-tables/SKILL.md'
            $content = Get-Content $path -Raw -ErrorAction SilentlyContinue
            $content | Should -Match 'Handshake disposition by command' `
                -Because '#998 moved the per-command handshake table here from CLAUDE.md'
            $content | Should -Match 'orchestra:review-judge' `
                -Because 'the table''s own rows moved with it, not just its heading'
        }

        It 'CLAUDE.md still points at both #998 destinations' {
            # The other half of the pair: a sentinel at the destination proves
            # the content landed, and this proves the pointer to it survives.
            $content = Get-Content $script:ClaudeMdPath -Raw -ErrorAction SilentlyContinue
            $content | Should -Match 'agent-body-architecture\.md#senior-engineer--skill-as-adapter-pattern' `
                -Because 'CLAUDE.md must resolve a reader to the moved adapter mechanics'
            $content | Should -Match 'routing-tables/SKILL\.md' `
                -Because 'CLAUDE.md must resolve a reader to the moved handshake table'
        }
    }
}
