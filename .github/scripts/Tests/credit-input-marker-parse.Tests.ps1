#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Round-trip parse stability tests for the credit-input deferred-emission marker (issue #442, Step 7).
#
# The SMC-17 marker shape is:
#   <!-- credit-input-{port}-{ID} -->
#   ```yaml
#   port: {port}
#   adapter: {adapter}
#   evidence: "{evidence}"
#   ```
#
# Tests verify: canonical parse, cross-tool whitespace variants, missing fields,
# unknown port, and multi-marker extraction from a multi-comment body.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

    $script:LedgerCoreLib = Join-Path $script:RepoRoot '.github/scripts/lib/frame-credit-ledger-core.ps1'
    if (Test-Path $script:LedgerCoreLib) {
        . $script:LedgerCoreLib
    }

    # Parse a single credit-input marker block from raw text.
    # Returns a hashtable @{ port, adapter, evidence } or $null on failure.
    function script:Parse-CreditInputMarker {
        param([string]$Text)

        if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

        # Extract yaml fenced block
        if ($Text -notmatch '```yaml\s*([\s\S]*?)```') { return $null }
        $yaml = $Matches[1].Trim()

        $result = @{}
        foreach ($line in ($yaml -split '\r?\n')) {
            if ($line -match '^\s*(\w+)\s*:\s*"?(.*?)"?\s*$') {
                $result[$Matches[1]] = $Matches[2].Trim('"').Trim()
            }
        }

        if (-not $result.ContainsKey('port') -or [string]::IsNullOrWhiteSpace($result['port'])) {
            return $null
        }

        return $result
    }

    # Extract all credit-input markers from a multi-comment body string.
    # Returns array of hashtables.
    function script:Get-AllCreditInputMarkers {
        param([string]$Body, [string]$IssueId)

        $pattern = "<!-- credit-input-[^-]+-$([regex]::Escape($IssueId)) -->([\s\S]*?)(?=<!-- credit-input-|$)"
        $results = @()
        foreach ($m in [regex]::Matches($Body, $pattern)) {
            $parsed = script:Parse-CreditInputMarker -Text $m.Value
            if ($null -ne $parsed) { $results += $parsed }
        }
        return $results
    }
}

# ---------------------------------------------------------------------------
# Canonical marker shape
# ---------------------------------------------------------------------------

Describe 'credit-input marker round-trip: canonical shape (SMC-17)' {

    It 'parses a well-formed experience marker' {
        $text = @"
<!-- credit-input-experience-442 -->
``````yaml
port: experience
adapter: work-adapter
evidence: "issue #442; experience-owner-complete marker posted"
``````
"@
        $result = script:Parse-CreditInputMarker -Text $text
        $result | Should -Not -BeNullOrEmpty
        $result['port']     | Should -Be 'experience'
        $result['adapter']  | Should -Be 'work-adapter'
        $result['evidence'] | Should -Match 'experience-owner-complete'
    }

    It 'parses a well-formed design marker' {
        $text = @"
<!-- credit-input-design-442 -->
``````yaml
port: design
adapter: work-adapter
evidence: "issue #442; design-phase-complete marker posted"
``````
"@
        $result = script:Parse-CreditInputMarker -Text $text
        $result | Should -Not -BeNullOrEmpty
        $result['port']    | Should -Be 'design'
        $result['adapter'] | Should -Be 'work-adapter'
    }

    It 'parses a well-formed plan marker' {
        $text = @"
<!-- credit-input-plan-442 -->
``````yaml
port: plan
adapter: work-adapter
evidence: "issue #442; plan-issue marker posted"
``````
"@
        $result = script:Parse-CreditInputMarker -Text $text
        $result | Should -Not -BeNullOrEmpty
        $result['port'] | Should -Be 'plan'
    }
}

# ---------------------------------------------------------------------------
# Cross-tool whitespace variants
# ---------------------------------------------------------------------------

Describe 'credit-input marker round-trip: cross-tool whitespace variants (SMC-17)' {

    It 'parses Copilot-style marker with leading spaces in YAML values' {
        $text = @"
<!-- credit-input-experience-442 -->
``````yaml
port:  experience
adapter:  work-adapter
evidence:  "issue #442; experience-owner-complete"
``````
"@
        $result = script:Parse-CreditInputMarker -Text $text
        $result | Should -Not -BeNullOrEmpty
        $result['port'] | Should -Be 'experience'
    }

    It 'parses Claude-style marker with CRLF line endings' {
        $text = "<!-- credit-input-design-442 -->`r`n``````yaml`r`nport: design`r`nadapter: work-adapter`r`nevidence: `"issue #442`"`r`n``````"
        $result = script:Parse-CreditInputMarker -Text $text
        $result | Should -Not -BeNullOrEmpty
        $result['port'] | Should -Be 'design'
    }

    It 'parses marker when yaml block has extra blank lines' {
        $text = @"
<!-- credit-input-plan-442 -->
``````yaml

port: plan
adapter: work-adapter

evidence: "issue #442; plan-issue"

``````
"@
        $result = script:Parse-CreditInputMarker -Text $text
        $result | Should -Not -BeNullOrEmpty
        $result['port'] | Should -Be 'plan'
    }
}

# ---------------------------------------------------------------------------
# Malformed / missing field cases
# ---------------------------------------------------------------------------

Describe 'credit-input marker round-trip: malformed input (SMC-17)' {

    It 'returns null when no yaml fenced block is present' {
        $text = '<!-- credit-input-experience-442 --> port: experience adapter: work-adapter'
        $result = script:Parse-CreditInputMarker -Text $text
        $result | Should -BeNullOrEmpty
    }

    It 'returns null when port field is absent' {
        $text = @"
<!-- credit-input-experience-442 -->
``````yaml
adapter: work-adapter
evidence: "no port field"
``````
"@
        $result = script:Parse-CreditInputMarker -Text $text
        $result | Should -BeNullOrEmpty
    }

    It 'returns null when text is empty' {
        $result = script:Parse-CreditInputMarker -Text ''
        $result | Should -BeNullOrEmpty
    }

    It 'returns null when text is null' {
        $result = script:Parse-CreditInputMarker -Text $null
        $result | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# Multi-marker extraction
# ---------------------------------------------------------------------------

Describe 'credit-input marker round-trip: multi-marker extraction (SMC-17)' {

    It 'extracts all three pipeline-entry port markers from a combined body' {
        $body = @"
Some comment text.

<!-- credit-input-experience-442 -->
``````yaml
port: experience
adapter: work-adapter
evidence: "issue #442"
``````

More text.

<!-- credit-input-design-442 -->
``````yaml
port: design
adapter: work-adapter
evidence: "issue #442"
``````

<!-- credit-input-plan-442 -->
``````yaml
port: plan
adapter: work-adapter
evidence: "issue #442"
``````
"@
        $markers = script:Get-AllCreditInputMarkers -Body $body -IssueId '442'
        $markers.Count | Should -BeGreaterOrEqual 3
        ($markers | ForEach-Object { $_['port'] }) | Should -Contain 'experience'
        ($markers | ForEach-Object { $_['port'] }) | Should -Contain 'design'
        ($markers | ForEach-Object { $_['port'] }) | Should -Contain 'plan'
    }
}
