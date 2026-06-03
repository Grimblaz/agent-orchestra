#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester 5 tests for the gate-reconciliation L2 core logic.

.DESCRIPTION
    Tests gate-reconciliation-core.ps1 using in-memory fixtures — no real gh calls.
    The lib is invoked as a script with -EventLogPath pointing to temp JSONL fixtures
    and -InMemoryMarkers for engagement records.

    Covers:
      - AC2a: thin recorded decision (load-bearing 'asked', no recorded decision) -> 'findings'
      - AC2b: matching recorded decision -> 'clean'
      - S4 negative: routine classification -> 'clean'
      - S4 negative: gate-fails outcome -> 'clean' + lawful_skips >= 1
      - S4 negative: same-decision-resume -> 'clean' + lawful_skips >= 1
      - AC3: window_position 'disposition' is not excluded -> 'findings'
#>

Describe 'gate-reconciliation L2 — core logic' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:LibPath  = Join-Path $script:RepoRoot '.github/scripts/lib/gate-reconciliation-core.ps1'
        # Do NOT dot-source the lib here — the tests call it as a script with params
    }

    BeforeEach {
        # Create a fresh temp JSONL file for each test
        $script:TempJsonlPath = Join-Path $TestDrive "gate-events-$(New-Guid).jsonl"
    }

    AfterEach {
        if (Test-Path $script:TempJsonlPath) {
            Remove-Item $script:TempJsonlPath -Force -ErrorAction SilentlyContinue
        }
    }

    It 'lib script exists' {
        $script:LibPath | Should -Exist
    }

    It 'AC2a — thin recorded decision raises a warning finding' {
        # Arrange: write one load-bearing 'asked' token, no recorded decisions
        $token = @{
            decision_id     = 'd-test'
            phase           = 'design'
            outcome         = 'asked'
            classification  = 'load-bearing'
            window_position = 'pre-ask'
            timestamp       = '2026-06-02T00:00:00Z'
            session_key     = 'test'
        } | ConvertTo-Json -Compress
        Set-Content -Path $script:TempJsonlPath -Value $token -Encoding UTF8

        # Act: invoke lib with no recorded decisions
        $result = & $script:LibPath `
            -IssueNumber 999 `
            -EventLogPath $script:TempJsonlPath `
            -InMemoryMarkers @()

        # Assert
        $result.status          | Should -Be 'findings'
        $result.findings.Count  | Should -BeGreaterOrEqual 1
    }

    It 'AC2b — matching recorded decision yields clean result' {
        # Arrange: same load-bearing 'asked' token
        $token = @{
            decision_id     = 'd-test'
            phase           = 'design'
            outcome         = 'asked'
            classification  = 'load-bearing'
            window_position = 'pre-ask'
            timestamp       = '2026-06-02T00:00:00Z'
            session_key     = 'test'
        } | ConvertTo-Json -Compress
        Set-Content -Path $script:TempJsonlPath -Value $token -Encoding UTF8

        # Engagement-record marker with matching decision_id (schema_version 1, valid slug).
        # decision_id 'd-test' satisfies the slug regex: ^[a-z][a-z0-9-]{0,62}[a-z0-9]\z
        # Build marker via string interpolation to avoid heredoc backtick-escaping pitfalls.
        $fence = '```'
        $yaml = @"
schema_version: 1
phase: design
capture_session: test-session
load_bearing_decisions:
  - decision_id: d-test
    classification: load-bearing
    audit_rationale: Test rationale
    engineer_choice: Test choice
    teaching_paragraph_excerpt: Test excerpt
    articulation_text: Test articulation
    articulation_status: complete
"@
        $engagementMarker = "<!-- engagement-record-design-999 -->`n${fence}yaml`n$yaml`n${fence}"

        # Act
        $result = & $script:LibPath `
            -IssueNumber 999 `
            -EventLogPath $script:TempJsonlPath `
            -InMemoryMarkers @($engagementMarker)

        # Assert
        $result.status         | Should -Be 'clean'
        $result.findings.Count | Should -Be 0
    }

    It 'S4 negative — routine token does NOT raise a finding' {
        # Arrange: routine classification -> never flag
        $token = @{
            decision_id     = 'd-routine'
            phase           = 'design'
            outcome         = 'asked'
            classification  = 'routine'
            window_position = 'pre-ask'
            timestamp       = '2026-06-02T00:00:00Z'
            session_key     = 'test'
        } | ConvertTo-Json -Compress
        Set-Content -Path $script:TempJsonlPath -Value $token -Encoding UTF8

        # Act: no recorded decisions
        $result = & $script:LibPath `
            -IssueNumber 999 `
            -EventLogPath $script:TempJsonlPath `
            -InMemoryMarkers @()

        # Assert
        $result.status | Should -Be 'clean'
    }

    It 'S4 negative — gate-fails outcome does NOT raise a finding and increments lawful_skips' {
        # Arrange: gate-fails is a lawful skip
        $token = @{
            decision_id     = 'd-gf'
            phase           = 'design'
            outcome         = 'gate-fails'
            classification  = 'not-applicable'
            window_position = 'pre-ask'
            timestamp       = '2026-06-02T00:00:00Z'
            session_key     = 'test'
        } | ConvertTo-Json -Compress
        Set-Content -Path $script:TempJsonlPath -Value $token -Encoding UTF8

        # Act
        $result = & $script:LibPath `
            -IssueNumber 999 `
            -EventLogPath $script:TempJsonlPath `
            -InMemoryMarkers @()

        # Assert
        $result.status       | Should -Be 'clean'
        $result.lawful_skips | Should -BeGreaterOrEqual 1
    }

    It 'S4 negative — same-decision-resume token does NOT raise a finding and increments lawful_skips' {
        # Arrange: same-decision-resume is a lawful skip regardless of classification
        $token = @{
            decision_id     = 'd-sdr'
            phase           = 'design'
            outcome         = 'same-decision-resume'
            classification  = 'load-bearing'
            window_position = 'pre-ask'
            timestamp       = '2026-06-02T00:00:00Z'
            session_key     = 'test'
        } | ConvertTo-Json -Compress
        Set-Content -Path $script:TempJsonlPath -Value $token -Encoding UTF8

        # Act
        $result = & $script:LibPath `
            -IssueNumber 999 `
            -EventLogPath $script:TempJsonlPath `
            -InMemoryMarkers @()

        # Assert
        $result.status       | Should -Be 'clean'
        $result.lawful_skips | Should -BeGreaterOrEqual 1
    }

    It 'AC3 — window_position disposition is not excluded and raises a finding' {
        # Arrange: disposition window position is not a lawful skip
        $token = @{
            decision_id     = 'f1'
            phase           = 'design'
            outcome         = 'asked'
            classification  = 'load-bearing'
            window_position = 'disposition'
            timestamp       = '2026-06-02T00:00:00Z'
            session_key     = 'test'
        } | ConvertTo-Json -Compress
        Set-Content -Path $script:TempJsonlPath -Value $token -Encoding UTF8

        # Act: no recorded decisions
        $result = & $script:LibPath `
            -IssueNumber 999 `
            -EventLogPath $script:TempJsonlPath `
            -InMemoryMarkers @()

        # Assert: disposition tokens are not filtered — they should raise findings
        $result.findings.Count | Should -BeGreaterOrEqual 1
    }
}
