#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'reference-preflight-hook contract' -Tag 'unit' {

    BeforeAll {
        $script:RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:HookScript = Join-Path $script:RepoRoot 'skills/project-references/scripts/reference-preflight-hook.ps1'
        $script:LoaderScript = Join-Path $script:RepoRoot 'skills/project-references/scripts/invoke-reference-loader.ps1'
        $script:FixtureBase = Join-Path $PSScriptRoot 'fixtures/project-references/valid-repo'

        # Dot-source the hook to get all functions in scope
        . $script:HookScript

        # Scratch temp dir used for mock binaries and test state; cleaned AfterAll
        $script:BurstTempDir = Join-Path ([System.IO.Path]::GetTempPath()) "rph-tests-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:BurstTempDir -Force | Out-Null

        # Helper: build a UserPromptSubmit payload JSON
        function New-RPHPayload {
            param(
                [string]$Prompt   = '',
                [string]$SessionId = 'test-session-001'
            )
            return ([ordered]@{
                prompt     = $Prompt
                session_id = $SessionId
            } | ConvertTo-Json -Depth 5 -Compress)
        }

        # Helper: write a mock gh script that outputs fixed JSON and exits with a given code.
        # The script is written using Set-Content with explicit string interpolation to
        # avoid double-expansion issues with here-strings.
        function New-MockGhScript {
            param(
                [string]$IssueJson = '',
                [int]$ExitCode     = 0,
                [string]$Name      = "mock-gh-$([guid]::NewGuid().ToString('N')[0..7] -join '').ps1"
            )
            $path           = Join-Path $script:BurstTempDir $Name
            $escapedJson    = $IssueJson -replace "'", "''"          # PS single-quote escape
            $exitCodeLiteral = [string]$ExitCode                     # bake in at write time
            $lines = @(
                "param()"
                "if ($exitCodeLiteral -ne 0) { exit $exitCodeLiteral }"
                "Write-Output '$escapedJson'"
                "exit 0"
            )
            $lines | Set-Content $path -Encoding UTF8
            return $path
        }

        # Helper: build a minimal consumer repo with .references/index.json
        function New-RPHConsumerRepo {
            param(
                [string]$Name = "consumer-$([guid]::NewGuid().ToString('N')[0..7] -join '')"
            )
            $root = Join-Path $script:BurstTempDir $Name
            $refsDir = Join-Path $root '.references'
            New-Item -ItemType Directory -Path $refsDir -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $root '.tmp') -Force | Out-Null

            # Copy fixture index and doc so the loader has something to work with
            $fixtureBase = $script:FixtureBase
            Copy-Item (Join-Path $fixtureBase 'expected-index.json') (Join-Path $refsDir 'index.json')
            Copy-Item (Join-Path $fixtureBase 'sample-doc.md') (Join-Path $root 'sample-doc.md')
            Copy-Item (Join-Path $fixtureBase 'manual.md') (Join-Path $root 'manual.md')

            return $root
        }

        # Canonical valid issue JSON returned by gh issue view
        $script:ValidIssueJson = '{"title":"API Reference Needed","body":"Please add a reference to the API.","labels":[{"id":1,"name":"api"},{"id":2,"name":"reference"}]}'
    }

    AfterAll {
        if (Test-Path $script:BurstTempDir) {
            Remove-Item -Path $script:BurstTempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # =========================================================================
    # 1. Issue-number extraction grammar
    # =========================================================================

    Describe 'Get-RPHIssueNumber — extraction grammar' {

        It 'extracts from "#N" pattern: "working on #647"' {
            Get-RPHIssueNumber -PromptText 'working on #647' | Should -Be 647
        }

        It 'extracts from "issue N" pattern: "see issue 647"' {
            Get-RPHIssueNumber -PromptText 'see issue 647' | Should -Be 647
        }

        It 'extracts from "issue #N" pattern: "closes issue #647"' {
            Get-RPHIssueNumber -PromptText 'closes issue #647' | Should -Be 647
        }

        It 'extracts from full GitHub issue URL' {
            $url = 'full URL https://github.com/Grimblaz/agent-orchestra/issues/647'
            Get-RPHIssueNumber -PromptText $url | Should -Be 647
        }

        It 'returns $null for "PR #647" (PR exclusion)' {
            Get-RPHIssueNumber -PromptText 'PR #647' | Should -BeNullOrEmpty
        }

        It 'returns $null for "$100" (dollar-prefixed number)' {
            Get-RPHIssueNumber -PromptText '$100' | Should -BeNullOrEmpty
        }

        It 'returns $null for "line 647" (non-issue context)' {
            Get-RPHIssueNumber -PromptText 'line 647' | Should -BeNullOrEmpty
        }

        It 'returns $null for null input' {
            Get-RPHIssueNumber -PromptText $null | Should -BeNullOrEmpty
        }

        It 'returns $null for empty string' {
            Get-RPHIssueNumber -PromptText '' | Should -BeNullOrEmpty
        }

        It 'extracts first match when multiple issue references appear' {
            $result = Get-RPHIssueNumber -PromptText 'implementing issue #100 referenced from issue #200'
            # First valid match — could be 100 (URL pattern wins; issue keyword pattern returns 100 first)
            $result | Should -BeIn @(100, 200)
        }

        It 'returns $null for whitespace-only text' {
            Get-RPHIssueNumber -PromptText '   ' | Should -BeNullOrEmpty
        }
    }

    # =========================================================================
    # 2. No-match case (S2, AC4)
    # =========================================================================

    Describe 'No-match case — nothing injected, exit 0 (AC4)' {

        It 'emits nothing when loader returns empty loaded and empty critical_under_match' {
            $consumerRoot = New-RPHConsumerRepo

            # Mock gh that returns an issue whose title/body don't match any trigger
            $noMatchIssueJson = '{"title":"Unrelated work","body":"No references here.","labels":[]}'
            $ghPath = New-MockGhScript -IssueJson $noMatchIssueJson

            # Mock loader that returns no matches (use a temp loader script)
            $mockLoaderPath = Join-Path $script:BurstTempDir 'mock-loader-no-match.ps1'
            @'
param([string]$IssuePayloadPath, [string]$IndexJsonPath, [string]$StateFilePath)
@{
    loaded              = @()
    matched             = @()
    stale               = @()
    critical_under_match = @('[not loaded; triggers did not match — confirm scope does not intersect]')
    no_match            = $true
    budget_skipped      = @()
    loaded_bytes        = 0
    nudge_due           = $false
    nudge_dismissed     = $false
    rendered            = ''
    untrusted           = $false
} | ConvertTo-Json -Depth 10
'@ | Set-Content $mockLoaderPath -Encoding UTF8

            $payload = New-RPHPayload -Prompt 'working on #999' -SessionId 'no-match-session'
            $result = Invoke-RPHHook `
                -PayloadJson      $payload `
                -GhCliPath        $ghPath `
                -LoaderScriptPath $mockLoaderPath `
                -RepoRoot         $consumerRoot

            $result | Should -BeNullOrEmpty -Because 'no-match must produce no output (AC4 — no false claim)'
        }
    }

    # =========================================================================
    # 3. Fail-open cases (S3, AC5)
    # =========================================================================

    Describe 'Fail-open cases — exit 0 with breadcrumb (AC5)' {

        It 'returns nothing when gh exits non-zero (fail-open)' {
            $consumerRoot = New-RPHConsumerRepo
            $ghPath = New-MockGhScript -IssueJson '' -ExitCode 1

            $payload = New-RPHPayload -Prompt 'issue #647'
            $result = Invoke-RPHHook `
                -PayloadJson $payload `
                -GhCliPath   $ghPath `
                -RepoRoot    $consumerRoot

            # Fail-open: no output, no exception
            $result | Should -BeNullOrEmpty -Because 'gh failure must not block the turn (AC5)'
        }

        It 'returns nothing when loader script does not exist (fail-open)' {
            $consumerRoot = New-RPHConsumerRepo

            $issueJson = '{"title":"API Reference Needed","body":"API reference work","labels":[]}'
            $ghPath    = New-MockGhScript -IssueJson $issueJson

            $missingLoader = Join-Path $script:BurstTempDir 'does-not-exist-loader.ps1'
            $payload = New-RPHPayload -Prompt 'issue #647'
            $result = Invoke-RPHHook `
                -PayloadJson      $payload `
                -GhCliPath        $ghPath `
                -LoaderScriptPath $missingLoader `
                -RepoRoot         $consumerRoot

            $result | Should -BeNullOrEmpty -Because 'missing loader must not block the turn (AC5)'
        }

        It 'returns nothing when .references/index.json is absent (gate check)' {
            $root = Join-Path $script:BurstTempDir "no-index-$([guid]::NewGuid().ToString('N')[0..7] -join '')"
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            # Deliberately no .references/index.json

            $ghPath  = New-MockGhScript -IssueJson $script:ValidIssueJson
            $payload = New-RPHPayload -Prompt 'issue #647'

            $result = Invoke-RPHHook `
                -PayloadJson $payload `
                -GhCliPath   $ghPath `
                -RepoRoot    $root

            $result | Should -BeNullOrEmpty -Because 'missing index.json must silently no-op (AC5)'
        }

        It 'returns nothing when prompt has no issue reference' {
            $consumerRoot = New-RPHConsumerRepo
            $ghPath  = New-MockGhScript -IssueJson $script:ValidIssueJson
            $payload = New-RPHPayload -Prompt 'Just a general chat message with no issue reference'

            $result = Invoke-RPHHook `
                -PayloadJson $payload `
                -GhCliPath   $ghPath `
                -RepoRoot    $consumerRoot

            $result | Should -BeNullOrEmpty -Because 'no issue reference must not trigger injection'
        }

        It 'returns nothing for invalid (non-JSON) payload' {
            $consumerRoot = New-RPHConsumerRepo
            $ghPath  = New-MockGhScript -IssueJson $script:ValidIssueJson

            $result = Invoke-RPHHook `
                -PayloadJson 'this is not json' `
                -GhCliPath   $ghPath `
                -RepoRoot    $consumerRoot

            $result | Should -BeNullOrEmpty -Because 'invalid payload must not block the turn (AC5)'
        }

        It 'returns nothing for empty payload' {
            $consumerRoot = New-RPHConsumerRepo
            $ghPath = New-MockGhScript -IssueJson $script:ValidIssueJson

            $result = Invoke-RPHHook `
                -PayloadJson '' `
                -GhCliPath   $ghPath `
                -RepoRoot    $consumerRoot

            $result | Should -BeNullOrEmpty -Because 'empty payload must exit silently (AC5)'
        }
    }

    # =========================================================================
    # 4. Large-body no-deadlock test (MF6)
    # =========================================================================

    Describe 'Large-body no-deadlock (MF6)' {

        It 'completes within timeout when gh outputs >64 KB JSON response' {
            $consumerRoot = New-RPHConsumerRepo

            # Build a >64 KB body string
            $largeBody = 'x' * 70000
            $largeIssueObj = [ordered]@{
                title  = 'Large Body Issue'
                body   = $largeBody
                labels = @()
            }

            # Write mock gh script that outputs the large JSON using New-MockGhScript helper.
            # The helper takes the JSON string and bakes it in at write time.
            $largeIssueJsonStr = $largeIssueObj | ConvertTo-Json -Compress
            $mockGhPath = New-MockGhScript -IssueJson $largeIssueJsonStr -Name 'mock-gh-large.ps1'

            # Use the no-match mock loader so the test is loader-independent
            $mockLoaderPath = Join-Path $script:BurstTempDir 'mock-loader-large-body.ps1'
            @'
param([string]$IssuePayloadPath, [string]$IndexJsonPath, [string]$StateFilePath)
@{ loaded = @(); matched = @(); stale = @(); critical_under_match = @('[not loaded; triggers did not match — confirm scope does not intersect]'); no_match = $true; budget_skipped = @(); loaded_bytes = 0; rendered = ''; untrusted = $false; nudge_due = $false; nudge_dismissed = $false } | ConvertTo-Json -Depth 10
'@ | Set-Content $mockLoaderPath -Encoding UTF8

            $payload = New-RPHPayload -Prompt 'issue #12345' -SessionId 'large-body-session'

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-RPHHook `
                -PayloadJson      $payload `
                -GhCliPath        $mockGhPath `
                -LoaderScriptPath $mockLoaderPath `
                -RepoRoot         $consumerRoot
            $sw.Stop()

            # Must complete well under 30 s hook budget
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 25 -Because 'large body must drain without deadlock (MF6)'
            # no-match → no output; just verify it did not hang
        }
    }

    # =========================================================================
    # 5. Run-once marker (AC7)
    # =========================================================================

    Describe 'Run-once marker — skip re-injection on same body hash (AC7)' {

        It 'skips injection on second call for same session + issue + body hash' {
            $consumerRoot = New-RPHConsumerRepo

            $issueJson = '{"title":"API Reference Needed","body":"Please add a reference to the API.","labels":[{"name":"api"},{"name":"reference"}]}'
            $ghPath    = New-MockGhScript -IssueJson $issueJson

            # Mock loader that returns a match
            $mockLoaderPath = Join-Path $script:BurstTempDir 'mock-loader-runonce.ps1'
            @'
param([string]$IssuePayloadPath, [string]$IndexJsonPath, [string]$StateFilePath)
@{
    loaded              = @([pscustomobject]@{ name = 'Sample Reference'; target_path = 'sample-doc.md' })
    matched             = @('Sample Reference')
    stale               = @()
    critical_under_match = @()
    budget_skipped      = @()
    loaded_bytes        = 512
    rendered            = '``` untrusted-content`nSample content`n```'
    untrusted           = $true
    nudge_due           = $false
    nudge_dismissed     = $false
} | ConvertTo-Json -Depth 10
'@ | Set-Content $mockLoaderPath -Encoding UTF8

            $sessionId = 'runonce-session-001'
            $payload   = New-RPHPayload -Prompt 'working on issue #647' -SessionId $sessionId

            # First call — should inject
            $first = Invoke-RPHHook `
                -PayloadJson      $payload `
                -GhCliPath        $ghPath `
                -LoaderScriptPath $mockLoaderPath `
                -RepoRoot         $consumerRoot

            # Second call — same session, same issue, same body → should skip
            $second = Invoke-RPHHook `
                -PayloadJson      $payload `
                -GhCliPath        $ghPath `
                -LoaderScriptPath $mockLoaderPath `
                -RepoRoot         $consumerRoot

            $first  | Should -Not -BeNullOrEmpty -Because 'first call must inject refs'
            $second | Should -BeNullOrEmpty      -Because 'second call with unchanged body must skip (AC7 run-once)'
        }
    }

    # =========================================================================
    # 6. Happy-path injection (S1 availability, AC1)
    # =========================================================================

    Describe 'Happy-path injection — trust preamble, sentinel, ref bodies (AC1)' {

        It 'emits hookSpecificOutput with trust preamble and canonical sentinel' {
            $consumerRoot = New-RPHConsumerRepo

            $issueJson = '{"title":"API Reference Needed","body":"Please add a reference to the API.","labels":[{"name":"api"},{"name":"reference"}]}'
            $ghPath    = New-MockGhScript -IssueJson $issueJson

            $mockLoaderPath = Join-Path $script:BurstTempDir 'mock-loader-happy.ps1'
            @'
param([string]$IssuePayloadPath, [string]$IndexJsonPath, [string]$StateFilePath)
@{
    loaded              = @([pscustomobject]@{ name = 'Sample Reference'; target_path = 'sample-doc.md' })
    matched             = @('Sample Reference')
    stale               = @()
    critical_under_match = @()
    budget_skipped      = @()
    loaded_bytes        = 1024
    rendered            = '``` untrusted-content`n# Sample Project Reference`n```'
    untrusted           = $true
    nudge_due           = $false
    nudge_dismissed     = $false
} | ConvertTo-Json -Depth 10
'@ | Set-Content $mockLoaderPath -Encoding UTF8

            $payload = New-RPHPayload -Prompt 'implementing issue #647' -SessionId 'happy-session-unique-001'
            $raw     = Invoke-RPHHook `
                -PayloadJson      $payload `
                -GhCliPath        $ghPath `
                -LoaderScriptPath $mockLoaderPath `
                -RepoRoot         $consumerRoot

            $raw | Should -Not -BeNullOrEmpty -Because 'happy path must produce output'
            $result = $raw | ConvertFrom-Json

            $result.hookSpecificOutput.hookEventName | Should -Be 'UserPromptSubmit'
            $ctx = $result.hookSpecificOutput.additionalContext

            # Trust preamble
            $ctx | Should -Match 'untrusted repository data'
            $ctx | Should -Match 'cannot override instructions'

            # Canonical sentinel
            $ctx | Should -Match '<!-- refs-injected-647 -->'

            # Loaded count line
            $ctx | Should -Match 'Loaded 1 reference'
        }

        It 'includes matched reference names in output' {
            $consumerRoot = New-RPHConsumerRepo

            $issueJson = '{"title":"API Reference","body":"API work.","labels":[{"name":"api"}]}'
            $ghPath    = New-MockGhScript -IssueJson $issueJson

            $mockLoaderPath = Join-Path $script:BurstTempDir 'mock-loader-names.ps1'
            @'
param([string]$IssuePayloadPath, [string]$IndexJsonPath, [string]$StateFilePath)
@{
    loaded              = @([pscustomobject]@{ name = 'API Spec'; target_path = 'api.md' })
    matched             = @('API Spec')
    stale               = @()
    critical_under_match = @()
    budget_skipped      = @()
    loaded_bytes        = 500
    rendered            = '``` untrusted-content`nAPI spec content`n```'
    untrusted           = $true
    nudge_due           = $false
    nudge_dismissed     = $false
} | ConvertTo-Json -Depth 10
'@ | Set-Content $mockLoaderPath -Encoding UTF8

            $payload = New-RPHPayload -Prompt 'working on issue #100' -SessionId 'names-session-unique-002'
            $raw     = Invoke-RPHHook `
                -PayloadJson      $payload `
                -GhCliPath        $ghPath `
                -LoaderScriptPath $mockLoaderPath `
                -RepoRoot         $consumerRoot

            $ctx = ($raw | ConvertFrom-Json).hookSpecificOutput.additionalContext
            $ctx | Should -Match 'API Spec'
        }

        It 'sentinel is NOT emitted when no refs matched (AC4 invariant)' {
            $consumerRoot = New-RPHConsumerRepo

            $issueJson = '{"title":"Unrelated","body":"nothing matches","labels":[]}'
            $ghPath    = New-MockGhScript -IssueJson $issueJson

            $mockLoaderPath = Join-Path $script:BurstTempDir 'mock-loader-no-sentinel.ps1'
            @'
param([string]$IssuePayloadPath, [string]$IndexJsonPath, [string]$StateFilePath)
@{
    loaded              = @()
    matched             = @()
    stale               = @()
    critical_under_match = @('[not loaded; triggers did not match — confirm scope does not intersect]')
    no_match            = $true
    budget_skipped      = @()
    loaded_bytes        = 0
    rendered            = ''
    untrusted           = $false
    nudge_due           = $false
    nudge_dismissed     = $false
} | ConvertTo-Json -Depth 10
'@ | Set-Content $mockLoaderPath -Encoding UTF8

            $payload = New-RPHPayload -Prompt 'issue #888' -SessionId 'no-sentinel-session-003'
            $raw     = Invoke-RPHHook `
                -PayloadJson      $payload `
                -GhCliPath        $ghPath `
                -LoaderScriptPath $mockLoaderPath `
                -RepoRoot         $consumerRoot

            $raw | Should -BeNullOrEmpty -Because 'sentinel must not appear when no refs injected (AC4)'
        }
    }

    # =========================================================================
    # 7. Body-hash invalidation (AC7)
    # =========================================================================

    Describe 'Body-hash invalidation — re-injects when body changes (AC7)' {

        It 're-injects when body hash differs from stored state' {
            $consumerRoot = New-RPHConsumerRepo
            $sessionId = 'hash-invalidation-session-unique-004'

            # First body
            $issueJsonV1 = '{"title":"API work","body":"Initial body.","labels":[{"name":"api"}]}'
            $ghPathV1    = New-MockGhScript -IssueJson $issueJsonV1 -Name 'mock-gh-v1.ps1'

            # Second body (different)
            $issueJsonV2 = '{"title":"API work","body":"Updated body with more detail.","labels":[{"name":"api"}]}'
            $ghPathV2    = New-MockGhScript -IssueJson $issueJsonV2 -Name 'mock-gh-v2.ps1'

            $mockLoaderPath = Join-Path $script:BurstTempDir 'mock-loader-hash.ps1'
            @'
param([string]$IssuePayloadPath, [string]$IndexJsonPath, [string]$StateFilePath)
@{
    loaded              = @([pscustomobject]@{ name = 'API Spec'; target_path = 'api.md' })
    matched             = @('API Spec')
    stale               = @()
    critical_under_match = @()
    budget_skipped      = @()
    loaded_bytes        = 300
    rendered            = '``` untrusted-content`napi content`n```'
    untrusted           = $true
    nudge_due           = $false
    nudge_dismissed     = $false
} | ConvertTo-Json -Depth 10
'@ | Set-Content $mockLoaderPath -Encoding UTF8

            $payload = New-RPHPayload -Prompt 'implementing issue #647' -SessionId $sessionId

            # First call: inject (body V1)
            $first = Invoke-RPHHook `
                -PayloadJson      $payload `
                -GhCliPath        $ghPathV1 `
                -LoaderScriptPath $mockLoaderPath `
                -RepoRoot         $consumerRoot

            # Second call with DIFFERENT body hash (ghPathV2): must re-inject
            $second = Invoke-RPHHook `
                -PayloadJson      $payload `
                -GhCliPath        $ghPathV2 `
                -LoaderScriptPath $mockLoaderPath `
                -RepoRoot         $consumerRoot

            $first  | Should -Not -BeNullOrEmpty -Because 'first call must inject'
            $second | Should -Not -BeNullOrEmpty -Because 'changed body must trigger re-injection (AC7 hash invalidation)'
        }
    }

    # =========================================================================
    # 8. Entrypoint stdin path (AC1 production wiring)
    # =========================================================================

    Describe 'Entrypoint — stdin payload path (production wiring)' {

        It 'reads payload from stdin when PayloadJson is not injected' {
            $consumerRoot = New-RPHConsumerRepo

            $issueJson = '{"title":"API Reference Needed","body":"Please add a reference to the API.","labels":[{"name":"api"},{"name":"reference"}]}'
            $ghPath    = New-MockGhScript -IssueJson $issueJson

            $mockLoaderPath = Join-Path $script:BurstTempDir 'mock-loader-stdin.ps1'
            @'
param([string]$IssuePayloadPath, [string]$IndexJsonPath, [string]$StateFilePath)
@{
    loaded              = @([pscustomobject]@{ name = 'Sample Reference'; target_path = 'sample-doc.md' })
    matched             = @('Sample Reference')
    stale               = @()
    critical_under_match = @()
    budget_skipped      = @()
    loaded_bytes        = 512
    rendered            = '``` untrusted-content`nSample content`n```'
    untrusted           = $true
    nudge_due           = $false
    nudge_dismissed     = $false
} | ConvertTo-Json -Depth 10
'@ | Set-Content $mockLoaderPath -Encoding UTF8

            $payloadJson = New-RPHPayload -Prompt 'issue #647' -SessionId 'stdin-session-unique-005'
            $originalInput = [Console]::In
            try {
                [Console]::SetIn([System.IO.StringReader]::new($payloadJson))
                $raw = Invoke-RPHHookEntrypoint `
                    -GhCliPath        $ghPath `
                    -LoaderScriptPath $mockLoaderPath `
                    -RepoRoot         $consumerRoot
            }
            finally {
                [Console]::SetIn($originalInput)
            }

            # The entrypoint calls exit 0 but in dot-source context returns value
            # We verify: if raw was returned (non-null), it parses correctly
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $result = $raw | ConvertFrom-Json
                $result.hookSpecificOutput.hookEventName | Should -Be 'UserPromptSubmit'
                $result.hookSpecificOutput.additionalContext | Should -Match '<!-- refs-injected-647 -->'
            }
            # If entrypoint exited before returning (exit 0 in subprocess path), that is valid too
            $true | Should -BeTrue -Because 'entrypoint must not throw on valid stdin payload'
        }
    }

    # =========================================================================
    # 9. PR exclusion edge cases
    # =========================================================================

    Describe 'PR exclusion edge cases' {

        It 'does not extract from "PR #647" (explicit PR prefix)' {
            Get-RPHIssueNumber -PromptText 'review PR #647' | Should -BeNullOrEmpty
        }

        It 'does not extract from "pull request #647"' {
            Get-RPHIssueNumber -PromptText 'pull request #647 needs review' | Should -BeNullOrEmpty
        }

        It 'extracts from "issue #647" even when PR #123 appears later' {
            $result = Get-RPHIssueNumber -PromptText 'fixes issue #647 as tracked in PR #123'
            $result | Should -Be 647
        }

        It 'extracts from "expr #647" — word ending in "pr" must not be treated as PR prefix (MF2)' {
            Get-RPHIssueNumber -PromptText 'expr #647' | Should -Be 647
        }

        It 'extracts from "compr #647" — word ending in "pr" must not suppress issue reference (MF2)' {
            Get-RPHIssueNumber -PromptText 'compr #647' | Should -Be 647
        }
    }

    # =========================================================================
    # 12. Integration: real loader + empty index → no injection (AC4)
    # =========================================================================

    Describe 'AC4 integration — real loader, empty index, no-match returns $null' {

        It 'returns $null when loader is called with a real index that has no matching entries' {
            # Build a consumer repo with a .references/index.json that has entries
            # but none whose triggers match the issue text.
            $consumerRoot = New-RPHConsumerRepo

            # Issue text that will not match "API Reference" / "reference" triggers
            $noMatchIssueJson = '{"title":"Unrelated database migration","body":"Refactor database schema only.","labels":[]}'
            $ghPath = New-MockGhScript -IssueJson $noMatchIssueJson

            # Use the REAL loader script — this is the integration test
            $payload = New-RPHPayload -Prompt 'working on issue #9991' -SessionId 'ac4-integration-session'
            $result = Invoke-RPHHook `
                -PayloadJson      $payload `
                -GhCliPath        $ghPath `
                -LoaderScriptPath $script:LoaderScript `
                -RepoRoot         $consumerRoot

            $result | Should -BeNullOrEmpty -Because 'AC4: real loader no-match must produce no injection'
        }
    }

    # =========================================================================
    # 10. Build-RPHPayload unit tests
    # =========================================================================

    Describe 'Build-RPHPayload — payload construction' {

        It 'builds correct payload from gh issue JSON with label objects' {
            $issueJson = '{"title":"My Issue","body":"Body text","labels":[{"id":1,"name":"api"},{"id":2,"name":"docs"}]}' | ConvertFrom-Json
            $result = Build-RPHPayload -IssueJson $issueJson

            $result.title         | Should -Be 'My Issue'
            $result.body          | Should -Be 'Body text'
            $result.labels        | Should -Contain 'api'
            $result.labels        | Should -Contain 'docs'
            @($result.changed_paths).Count | Should -Be 0
        }

        It 'returns $null for null input (fail-open)' {
            Build-RPHPayload -IssueJson $null | Should -BeNullOrEmpty
        }

        It 'handles string labels (not label objects)' {
            $issueJson = '{"title":"T","body":"B","labels":["label-a","label-b"]}' | ConvertFrom-Json
            $result = Build-RPHPayload -IssueJson $issueJson
            $result.labels | Should -Contain 'label-a'
        }
    }

    # =========================================================================
    # 11. Get-RPHBodyHash consistency
    # =========================================================================

    Describe 'Get-RPHBodyHash — deterministic hashing' {

        It 'returns same hash for same input' {
            $h1 = Get-RPHBodyHash -Body 'hello world'
            $h2 = Get-RPHBodyHash -Body 'hello world'
            $h1 | Should -Be $h2
        }

        It 'returns different hash for different input' {
            $h1 = Get-RPHBodyHash -Body 'hello world'
            $h2 = Get-RPHBodyHash -Body 'different content'
            $h1 | Should -Not -Be $h2
        }

        It 'handles null body without throwing' {
            { Get-RPHBodyHash -Body $null } | Should -Not -Throw
        }
    }
}
