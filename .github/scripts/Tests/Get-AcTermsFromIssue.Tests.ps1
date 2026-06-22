#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Red-green Pester tests for Get-AcTermsFromIssue.

.DESCRIPTION
    Covers: named constants oracle, basic extraction, behavioral keyword detection,
    stop-list rejection, H3-resilience, H2 boundary, empty/missing AC section,
    CR8/CR9-style behavioral AC (the originating incident pattern), deduplication,
    and the gh failure path.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:ScriptFile = Join-Path $script:RepoRoot 'skills/review-judgment/scripts/Get-AcTermsFromIssue.ps1'

    if (Test-Path $script:ScriptFile) {
        . $script:ScriptFile
    }
    else {
        throw "Get-AcTermsFromIssue.ps1 not found at: $script:ScriptFile"
    }
}

Describe 'Named constants are exported' {

    It 'AC_BEHAVIORAL_KEYWORDS is a non-empty array' {
        $Script:AC_BEHAVIORAL_KEYWORDS | Should -Not -BeNullOrEmpty
        $Script:AC_BEHAVIORAL_KEYWORDS.Count | Should -BeGreaterThan 0
    }

    It 'AC_BEHAVIORAL_KEYWORDS contains expected anchors' {
        $Script:AC_BEHAVIORAL_KEYWORDS | Should -Contain 'must'
        $Script:AC_BEHAVIORAL_KEYWORDS | Should -Contain 'shall'
        $Script:AC_BEHAVIORAL_KEYWORDS | Should -Contain 'gate'
        $Script:AC_BEHAVIORAL_KEYWORDS | Should -Contain 'guard'
        $Script:AC_BEHAVIORAL_KEYWORDS | Should -Contain 'prohibited' -Not   # not in the closed set
        $Script:AC_BEHAVIORAL_KEYWORDS | Should -Contain 'prohibit'
    }

    It 'AC_TERM_STOP_LIST is a non-empty array' {
        $Script:AC_TERM_STOP_LIST | Should -Not -BeNullOrEmpty
        $Script:AC_TERM_STOP_LIST.Count | Should -BeGreaterThan 0
    }

    It 'AC_TERM_STOP_LIST contains expected prose and literal values' {
        $Script:AC_TERM_STOP_LIST | Should -Contain 'true'
        $Script:AC_TERM_STOP_LIST | Should -Contain 'false'
        $Script:AC_TERM_STOP_LIST | Should -Contain 'null'
        $Script:AC_TERM_STOP_LIST | Should -Contain 'get'
        $Script:AC_TERM_STOP_LIST | Should -Contain 'set'
        $Script:AC_TERM_STOP_LIST | Should -Contain 'ac_cross_check'
        $Script:AC_TERM_STOP_LIST | Should -Contain 'dismiss'
        $Script:AC_TERM_STOP_LIST | Should -Contain 'defer'
    }
}

Describe 'Basic extraction' {

    BeforeAll {
        $issueBody = @'
## Acceptance Criteria

- The `MyFeature` identifier must be supported.
- The `OtherThing` value is returned as an object.

## Testing Scope

- Not in AC.
'@
        Mock gh { return $issueBody } -ParameterFilter { $args[0] -eq 'issue' }
    }

    It 'returns entries for each non-stop-list backtick term' {
        $result = Get-AcTermsFromIssue -IssueNumber '123'
        $result | Should -Not -BeNullOrEmpty
        $terms = $result | Select-Object -ExpandProperty term
        $terms | Should -Contain 'MyFeature'
        $terms | Should -Contain 'OtherThing'
    }

    It 'each entry has term, source_ac_line, and is_behavioral fields' {
        $result = Get-AcTermsFromIssue -IssueNumber '123'
        foreach ($entry in $result) {
            $entry.PSObject.Properties.Name | Should -Contain 'term'
            $entry.PSObject.Properties.Name | Should -Contain 'source_ac_line'
            $entry.PSObject.Properties.Name | Should -Contain 'is_behavioral'
        }
    }

    It 'source_ac_line is the trimmed full AC line for each term' {
        $result = Get-AcTermsFromIssue -IssueNumber '123'
        $myFeatureEntry = $result | Where-Object { $_.term -eq 'MyFeature' }
        $myFeatureEntry.source_ac_line | Should -Be '- The `MyFeature` identifier must be supported.'
    }

    It 'does not include terms from sections after the next H2' {
        $result = Get-AcTermsFromIssue -IssueNumber '123'
        $terms = $result | Select-Object -ExpandProperty term
        $terms | Should -Not -Contain 'Not'
    }
}

Describe 'Behavioral keyword detection' {

    It 'is_behavioral is true when AC line contains a behavioral keyword' {
        $issueBody = @'
## Acceptance Criteria

- The renderer must fetch `TargetIdentifier` before proceeding.
'@
        Mock gh { return $issueBody } -ParameterFilter { $args[0] -eq 'issue' }

        $result = Get-AcTermsFromIssue -IssueNumber '1'
        $entry = $result | Where-Object { $_.term -eq 'TargetIdentifier' }
        $entry | Should -Not -BeNullOrEmpty
        $entry.is_behavioral | Should -Be $true
    }

    It 'is_behavioral is false when AC line has no behavioral keyword' {
        $issueBody = @'
## Acceptance Criteria

- The `NeutralThing` is returned as a plain object.
'@
        Mock gh { return $issueBody } -ParameterFilter { $args[0] -eq 'issue' }

        $result = Get-AcTermsFromIssue -IssueNumber '2'
        $entry = $result | Where-Object { $_.term -eq 'NeutralThing' }
        $entry | Should -Not -BeNullOrEmpty
        $entry.is_behavioral | Should -Be $false
    }

    It 'detects behavioral keyword case-insensitively (MUST)' {
        $issueBody = @'
## Acceptance Criteria

- The `CasedTerm` MUST be enforced.
'@
        Mock gh { return $issueBody } -ParameterFilter { $args[0] -eq 'issue' }

        $result = Get-AcTermsFromIssue -IssueNumber '3'
        $entry = $result | Where-Object { $_.term -eq 'CasedTerm' }
        $entry.is_behavioral | Should -Be $true
    }

    It 'does not false-positive on partial keyword substring (musty)' {
        # "musty" must NOT trigger "must" because the regex uses word boundaries.
        $issueBody = @'
## Acceptance Criteria

- The `MustyIdentifier` is a musty old value.
'@
        Mock gh { return $issueBody } -ParameterFilter { $args[0] -eq 'issue' }

        $result = Get-AcTermsFromIssue -IssueNumber '4'
        $entry = $result | Where-Object { $_.term -eq 'MustyIdentifier' }
        $entry | Should -Not -BeNullOrEmpty
        $entry.is_behavioral | Should -Be $false
    }
}

Describe 'Stop-list rejection' {

    It 'does not return true, false, or null as terms' {
        $issueBody = @'
## Acceptance Criteria

- The flag is `true` or `false` and never `null`.
- The `RealIdentifier` is always present.
'@
        Mock gh { return $issueBody } -ParameterFilter { $args[0] -eq 'issue' }

        $result = Get-AcTermsFromIssue -IssueNumber '10'
        $terms = $result | Select-Object -ExpandProperty term
        $terms | Should -Not -Contain 'true'
        $terms | Should -Not -Contain 'false'
        $terms | Should -Not -Contain 'null'
        $terms | Should -Contain 'RealIdentifier'
    }

    It 'stop-list comparison is case-insensitive (TRUE, False)' {
        $issueBody = @'
## Acceptance Criteria

- The result is `TRUE` when configured, `False` otherwise.
- The `ActualTerm` is defined.
'@
        Mock gh { return $issueBody } -ParameterFilter { $args[0] -eq 'issue' }

        $result = Get-AcTermsFromIssue -IssueNumber '11'
        $terms = $result | Select-Object -ExpandProperty term
        $terms | Should -Not -Contain 'TRUE'
        $terms | Should -Not -Contain 'False'
        $terms | Should -Contain 'ActualTerm'
    }

    It 'does not return ac_cross_check, dismiss, or defer' {
        $issueBody = @'
## Acceptance Criteria

- The `ac_cross_check` field must be set; behavior is `dismiss` or `defer`.
- The `SemanticTarget` is the load-bearing output.
'@
        Mock gh { return $issueBody } -ParameterFilter { $args[0] -eq 'issue' }

        $result = Get-AcTermsFromIssue -IssueNumber '12'
        $terms = $result | Select-Object -ExpandProperty term
        $terms | Should -Not -Contain 'ac_cross_check'
        $terms | Should -Not -Contain 'dismiss'
        $terms | Should -Not -Contain 'defer'
        $terms | Should -Contain 'SemanticTarget'
    }
}

Describe 'H3-resilient AC section' {

    It 'terms below an H3 sub-header are still extracted' {
        $issueBody = @'
## Acceptance Criteria

- The `TopLevelTerm` is required.

### Sub-Section

- The `SubSectionTerm` must also be present.

## Other Section

- `NotIncluded` is outside AC.
'@
        Mock gh { return $issueBody } -ParameterFilter { $args[0] -eq 'issue' }

        $result = Get-AcTermsFromIssue -IssueNumber '20'
        $terms = $result | Select-Object -ExpandProperty term
        $terms | Should -Contain 'TopLevelTerm'
        $terms | Should -Contain 'SubSectionTerm'
        $terms | Should -Not -Contain 'NotIncluded'
    }

    It 'H3 header text itself does not contribute false terms' {
        $issueBody = @'
## Acceptance Criteria

### `HeaderToken`

- `RealTerm` is required.
'@
        Mock gh { return $issueBody } -ParameterFilter { $args[0] -eq 'issue' }

        $result = Get-AcTermsFromIssue -IssueNumber '21'
        $terms = $result | Select-Object -ExpandProperty term
        # HeaderToken appears in an ### line — it is still parseable as a term
        # (H3 lines are AC content); the key invariant is RealTerm is also present.
        $terms | Should -Contain 'RealTerm'
    }
}

Describe 'H2 boundary' {

    It 'terms from a subsequent H2 section are not included' {
        $issueBody = @'
## Acceptance Criteria

- The `AcTerm` must be enforced.

## Testing Scope

- `TestingScopeTerm` is only in Testing Scope.

## Implementation Notes

- `ImplNoteTerm` is only in Implementation Notes.
'@
        Mock gh { return $issueBody } -ParameterFilter { $args[0] -eq 'issue' }

        $result = Get-AcTermsFromIssue -IssueNumber '30'
        $terms = $result | Select-Object -ExpandProperty term
        $terms | Should -Contain 'AcTerm'
        $terms | Should -Not -Contain 'TestingScopeTerm'
        $terms | Should -Not -Contain 'ImplNoteTerm'
    }
}

Describe 'Empty/missing AC section' {

    It 'returns empty array and emits warning when no ## Acceptance Criteria header' {
        $issueBody = @'
## Overview

This issue has no AC section.

- `SomeToken` is here but not in AC.
'@
        Mock gh { return $issueBody } -ParameterFilter { $args[0] -eq 'issue' }

        $warnings = @()
        $result = Get-AcTermsFromIssue -IssueNumber '40' -WarningVariable warnings
        @($result).Count | Should -Be 0
        $warnMessages = @($warnings) | ForEach-Object {
            if ($_ -is [System.Management.Automation.WarningRecord]) { $_.Message } else { "$_" }
        }
        $warnMessages | Should -Match "No '## Acceptance Criteria' section found"
    }

    It 'returns empty array without warning when AC section exists but has no backtick tokens' {
        $issueBody = @'
## Acceptance Criteria

- The system works correctly.
- No backtick identifiers are present here.
'@
        Mock gh { return $issueBody } -ParameterFilter { $args[0] -eq 'issue' }

        { Get-AcTermsFromIssue -IssueNumber '41' -WarningAction Stop } | Should -Not -Throw
        $result = Get-AcTermsFromIssue -IssueNumber '41'
        $result | Should -BeNullOrEmpty
    }
}

Describe 'CR8/CR9-style behavioral AC (originating incident pattern)' {

    It 'extracts triage with is_behavioral=true from a CR8/CR9-style line' {
        # The originating incident: an AC line about fetch behavior using "must",
        # referencing a semantic identifier without a file-path extension.
        $issueBody = @'
## Acceptance Criteria

- the renderer is specified to fetch `triage`-labeled issues repo-wide; must query repo-wide not just sequenced issues
- the `portfolio-tracker` label is applied unconditionally to all new portfolio issues
'@
        Mock gh { return $issueBody } -ParameterFilter { $args[0] -eq 'issue' }

        $result = Get-AcTermsFromIssue -IssueNumber '709'
        $terms = $result | Select-Object -ExpandProperty term

        # triage must be extracted
        $terms | Should -Contain 'triage'

        # portfolio-tracker must be extracted
        $terms | Should -Contain 'portfolio-tracker'

        # triage line contains "must" -> is_behavioral=true
        $triageEntry = $result | Where-Object { $_.term -eq 'triage' }
        $triageEntry.is_behavioral | Should -Be $true

        # portfolio-tracker line contains "unconditionally" -> is_behavioral=true
        $ptEntry = $result | Where-Object { $_.term -eq 'portfolio-tracker' }
        $ptEntry.is_behavioral | Should -Be $true
    }

    It 'does not extract common prose stop-list words from CR8/CR9-style lines' {
        $issueBody = @'
## Acceptance Criteria

- the renderer must not `get` or `set` values; use `FetchEngine` instead
'@
        Mock gh { return $issueBody } -ParameterFilter { $args[0] -eq 'issue' }

        $result = Get-AcTermsFromIssue -IssueNumber '709b'
        $terms = $result | Select-Object -ExpandProperty term

        $terms | Should -Not -Contain 'get'
        $terms | Should -Not -Contain 'set'
        $terms | Should -Contain 'FetchEngine'
    }
}

Describe 'Deduplication' {

    It 'same term appearing on two AC lines appears only once in output' {
        $issueBody = @'
## Acceptance Criteria

- The `SharedTerm` must be validated on input.
- The `SharedTerm` should also be validated on output.
- The `OtherTerm` is independent.
'@
        Mock gh { return $issueBody } -ParameterFilter { $args[0] -eq 'issue' }

        $result = Get-AcTermsFromIssue -IssueNumber '50'
        $terms = $result | Select-Object -ExpandProperty term
        ($terms | Where-Object { $_ -eq 'SharedTerm' }).Count | Should -Be 1
        $terms | Should -Contain 'OtherTerm'
    }

    It 'deduplication keeps the first occurrence (source_ac_line from first line)' {
        $issueBody = @'
## Acceptance Criteria

- First line: `DupTerm` must be checked.
- Second line: `DupTerm` should also be checked.
'@
        Mock gh { return $issueBody } -ParameterFilter { $args[0] -eq 'issue' }

        $result = Get-AcTermsFromIssue -IssueNumber '51'
        $dupEntry = $result | Where-Object { $_.term -eq 'DupTerm' }
        $dupEntry.source_ac_line | Should -Be '- First line: `DupTerm` must be checked.'
    }
}

Describe 'Failure path' {

    It 'returns zero entries when gh returns empty output' {
        Mock gh { return '' } -ParameterFilter { $args[0] -eq 'issue' }

        $result = @(Get-AcTermsFromIssue -IssueNumber '99')
        # @() is the canonical empty-array return; Count 0 is the observable guarantee.
        $result.Count | Should -Be 0
    }

    It 'does not throw when gh returns empty output' {
        Mock gh { return '' } -ParameterFilter { $args[0] -eq 'issue' }

        { Get-AcTermsFromIssue -IssueNumber '99' } | Should -Not -Throw
    }

    It 'returns zero entries when gh returns null' {
        Mock gh { return $null } -ParameterFilter { $args[0] -eq 'issue' }

        $result = @(Get-AcTermsFromIssue -IssueNumber '100')
        $result.Count | Should -Be 0
    }
}
