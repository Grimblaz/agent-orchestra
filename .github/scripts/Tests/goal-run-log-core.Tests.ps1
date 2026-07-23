#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Coverage for .github/scripts/lib/goal-run-log-core.ps1 (issue #874,
    fix M9): the run-log writer/reader that skills/goal-run/schemas/
    goal-run-log.schema.json previously had no location, writer, or reader
    for at all.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:LibPath = Join-Path $script:RepoRoot '.github/scripts/lib/goal-run-log-core.ps1'
    . $script:LibPath
}

Describe 'goal-run-log-core.ps1: lib resolves' -Tag 'unit' {
    It 'exists at the expected path' {
        (Test-Path -LiteralPath $script:LibPath) | Should -Be $true
    }
}

Describe 'Get-GoalRunLogPath' -Tag 'unit' {
    It 'resolves goal-run-log.jsonl at the worktree root, alongside goal-run-active.json' {
        $path = Get-GoalRunLogPath -WorktreePath 'fake/gr-874'
        $path | Should -Be (Join-Path 'fake/gr-874' 'goal-run-log.jsonl')
    }
}

Describe 'Test-GoalRunLogEntry (schema-validating check)' -Tag 'unit' {
    It 'accepts a well-formed checkpoint entry' {
        $entry = [pscustomobject]@{
            schema_version = 1
            issue          = 874
            type           = 'checkpoint'
            timestamp      = '2026-07-23T01:00:00Z'
            commit_sha     = 'abc1234'
            summary        = 'entering stage 1'
        }
        (Test-GoalRunLogEntry -Entry $entry -RepoRoot $script:RepoRoot).IsValid | Should -Be $true
    }

    It 'rejects a checkpoint entry missing commit_sha' {
        $entry = [pscustomobject]@{
            schema_version = 1
            issue          = 874
            type           = 'checkpoint'
            timestamp      = '2026-07-23T01:00:00Z'
            summary        = 'entering stage 1'
        }
        (Test-GoalRunLogEntry -Entry $entry -RepoRoot $script:RepoRoot).IsValid | Should -Be $false
    }

    It 'reports a violation rather than throwing when the schema file cannot be found' {
        $entry = [pscustomobject]@{ schema_version = 1; issue = 874; type = 'checkpoint'; timestamp = '2026-07-23T01:00:00Z'; commit_sha = 'abc1234'; summary = 'x' }
        $result = Test-GoalRunLogEntry -Entry $entry -RepoRoot 'C:\definitely\not\a\repo\root'
        $result.IsValid | Should -Be $false
        $result.Violations.Count | Should -BeGreaterThan 0
    }
}

Describe 'Add-GoalRunLogEntry + Test-GoalRunLogHasCheckpoint (writer/reader round trip)' -Tag 'unit' {

    BeforeEach {
        $script:WorktreePath = Join-Path $TestDrive "gr-log-$([Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:WorktreePath -Force | Out-Null
    }

    It 'writes a well-formed checkpoint entry and reads it back as a real file' {
        $result = Add-GoalRunLogEntry -WorktreePath $script:WorktreePath -Issue 874 -EntryType 'checkpoint' `
            -Data @{ commit_sha = 'abc1234'; summary = 'stage 1: entering' } -RepoRoot $script:RepoRoot

        $result.Success | Should -Be $true
        $logPath = Get-GoalRunLogPath -WorktreePath $script:WorktreePath
        (Test-Path -LiteralPath $logPath) | Should -Be $true

        $line = Get-Content -LiteralPath $logPath -Raw
        $parsed = $line.Trim() | ConvertFrom-Json
        $parsed.type | Should -Be 'checkpoint'
        $parsed.issue | Should -Be 874
        $parsed.commit_sha | Should -Be 'abc1234'
    }

    It 'refuses to write (Success = $false) a schema-invalid entry -- a checkpoint missing commit_sha' {
        $result = Add-GoalRunLogEntry -WorktreePath $script:WorktreePath -Issue 874 -EntryType 'checkpoint' `
            -Data @{ summary = 'missing commit_sha' } -RepoRoot $script:RepoRoot

        $result.Success | Should -Be $false
        $result.Reason | Should -Be 'schema-invalid'
        $logPath = Get-GoalRunLogPath -WorktreePath $script:WorktreePath
        (Test-Path -LiteralPath $logPath) | Should -Be $false
    }

    It 'appends multiple entries as separate JSONL lines, never overwriting the prior line' {
        Add-GoalRunLogEntry -WorktreePath $script:WorktreePath -Issue 874 -EntryType 'checkpoint' `
            -Data @{ commit_sha = 'aaa1111'; summary = 'first' } -RepoRoot $script:RepoRoot | Out-Null
        Add-GoalRunLogEntry -WorktreePath $script:WorktreePath -Issue 874 -EntryType 'checkpoint' `
            -Data @{ commit_sha = 'bbb2222'; summary = 'second' } -RepoRoot $script:RepoRoot | Out-Null

        $logPath = Get-GoalRunLogPath -WorktreePath $script:WorktreePath
        $lines = @(Get-Content -LiteralPath $logPath)
        $lines.Count | Should -Be 2
    }

    It 'Test-GoalRunLogHasCheckpoint returns $false when the log file does not exist yet' {
        (Test-GoalRunLogHasCheckpoint -WorktreePath $script:WorktreePath) | Should -Be $false
    }

    It 'Test-GoalRunLogHasCheckpoint returns $true once a checkpoint entry has been written' {
        Add-GoalRunLogEntry -WorktreePath $script:WorktreePath -Issue 874 -EntryType 'checkpoint' `
            -Data @{ commit_sha = 'abc1234'; summary = 'stage 1: entering' } -RepoRoot $script:RepoRoot | Out-Null

        (Test-GoalRunLogHasCheckpoint -WorktreePath $script:WorktreePath) | Should -Be $true
    }

    It 'Test-GoalRunLogHasCheckpoint returns $true for a deviation or experience-observation entry too' {
        Add-GoalRunLogEntry -WorktreePath $script:WorktreePath -Issue 874 -EntryType 'deviation' `
            -Data @{ summary = 'skipped optional field'; rationale = 'not needed' } -RepoRoot $script:RepoRoot | Out-Null

        (Test-GoalRunLogHasCheckpoint -WorktreePath $script:WorktreePath) | Should -Be $true
    }

    It 'Test-GoalRunLogHasCheckpoint returns $false when only a halt-claim entry exists -- an executor assertion is not evidence the loop reached a genuine checkpoint' {
        Add-GoalRunLogEntry -WorktreePath $script:WorktreePath -Issue 874 -EntryType 'halt-claim' `
            -Data @{ summary = 'executor believes target unachievable' } -RepoRoot $script:RepoRoot | Out-Null

        (Test-GoalRunLogHasCheckpoint -WorktreePath $script:WorktreePath) | Should -Be $false
    }

    It 'tolerates a malformed or partial mid-write tail line without throwing' {
        $logPath = Get-GoalRunLogPath -WorktreePath $script:WorktreePath
        $goodLine = '{"schema_version":1,"issue":874,"type":"checkpoint","timestamp":"2026-07-23T01:00:00Z","commit_sha":"abc1234","summary":"ok"}'
        $partialLine = '{"schema_version":1,"issue":874,"type":"check'
        Set-Content -LiteralPath $logPath -Value @($goodLine, $partialLine) -Encoding utf8

        { Test-GoalRunLogHasCheckpoint -WorktreePath $script:WorktreePath } | Should -Not -Throw
        (Test-GoalRunLogHasCheckpoint -WorktreePath $script:WorktreePath) | Should -Be $true
    }

    It 'rejects an out-of-enum EntryType before any schema round trip' {
        { Add-GoalRunLogEntry -WorktreePath $script:WorktreePath -Issue 874 -EntryType 'terminal' -Data @{} -RepoRoot $script:RepoRoot } | Should -Throw
    }
}
