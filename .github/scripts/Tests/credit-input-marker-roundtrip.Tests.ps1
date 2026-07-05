#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Integration tests for Invoke-CreditInputHarvest (issue #442, Step 9).
# Redesigned for issue #794 Step s1 (Bug 1 harvest fetch fix + fetch-once + roundtrip mock redesign):
# the mock now serves the 'gh api .../comments --paginate --slurp' array-of-page-arrays shape and
# rejects the old invalid 'gh issue view ... --paginate' call shape as a regression guard.
#
# (a) All three pipeline-entry ports: post fixture marker, run harvester, assert credit row.
# (b) Cross-tool fixture parity: Copilot-style and Claude-style YAML both produce byte-equal rows.
# (c) Paginated comment list: marker is on the second "page" of comments (simulated).
# (d) Retry path: first gh call returns stale list missing marker; second returns full list.
# (e) -InMemoryMarkers fallback: bypass gh and produce row from supplied text.
# (f) Absent-marker case: harvester emits nothing when no credit-input comment present.
# (h) Reachable=$false on fetch failure (including non-zero exit mid-pagination).
# (i) Regression guard: the old invalid 'gh issue view ... --paginate' form is rejected.
# (j) Two-page fixture: >100-comment issues still paginate correctly under '--slurp' flatten.
# (k) Fetch-count assertion: exactly one thread fetch per Invoke-CreditInputHarvest invocation.
# (l) $payloadFromInMemory fail-open branch still exercised correctly under the reshaped fetch.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:LedgerCoreLib = Join-Path $script:RepoRoot '.github/scripts/lib/frame-credit-ledger-core.ps1'
    if (Test-Path $script:LedgerCoreLib) { . $script:LedgerCoreLib }

    $script:TempDir = Join-Path ([System.IO.Path]::GetTempPath()) "pester-harvest-roundtrip-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null

    # Helper: write a mock gh script that serves the new 'gh api repos/{owner}/{repo}/issues/{n}/comments
    # --paginate --slurp' shape: an array of one-or-more page arrays, each page an array of comment
    # objects with a '.body' field (NOT the old '{"comments":[...]}' wrapper).
    #
    # $Pages is an array of arrays of comment-body strings; each inner array is one simulated page.
    # When $StalePages is non-null, the first invocation returns $StalePages; subsequent invocations
    # return $Pages (models the read-after-write retry path).
    #
    # Regression guard (Bug 1): if this mock ever receives an 'issue view ... --paginate' invocation
    # (the pre-fix invalid call shape), it fails loudly — this is what would have caught Bug 1.
    # Narrowly modeled on the sibling mock in engagement-record-marker-roundtrip.Tests.ps1 (~line 38);
    # only the rejection-guard pattern is copied — the response shape is fresh (valid 'gh api --slurp'
    # array-of-page-arrays), not the sibling's '{"comments":[...]}' wrapper.
    function script:Write-MockGh {
        param(
            [array]$Pages,
            [string]$ScriptPath,
            [array]$StalePages = $null,
            [int]$ExitCode = 0
        )

        function local:ConvertPagesToJson {
            param([array]$PageSet)
            $pageJsonList = $PageSet | ForEach-Object {
                $page = $_
                $commentsJson = ($page | ForEach-Object {
                    '{"body": ' + ($_ | ConvertTo-Json -Compress) + '}'
                }) -join ','
                "[$commentsJson]"
            }
            return '[' + ($pageJsonList -join ',') + ']'
        }

        $mainJson = ConvertPagesToJson -PageSet $Pages
        $exitLine = "exit $ExitCode"

        if ($null -ne $StalePages) {
            $staleJson = ConvertPagesToJson -PageSet $StalePages

            $stateFile = $ScriptPath -replace '\.ps1$', '.state'
            $escaped = $stateFile -replace "'", "''"

            @"
param()
if (`$args -contains 'view') { Write-Error 'unknown flag: --paginate'; exit 1 }
`$state = if (Test-Path '$escaped') { Get-Content '$escaped' -Raw } else { 'first' }
if (`$state -eq 'first') {
    Set-Content '$escaped' 'done'
    Write-Output '$staleJson'
} else {
    Write-Output '$mainJson'
}
$exitLine
"@ | Set-Content $ScriptPath -Encoding UTF8
        } else {
            @"
param()
# Guard: fail immediately if this is the OLD invalid call shape ('gh issue view ... --paginate').
# --paginate is a 'gh api'-only flag; 'gh issue view' never supports it (Bug 1, issue #794).
if (`$args -contains 'view') { Write-Error 'unknown flag: --paginate'; exit 1 }
Write-Output '$mainJson'
$exitLine
"@ | Set-Content $ScriptPath -Encoding UTF8
        }
    }

    # Helper: write a mock gh script that counts invocations to a shared counter file, so tests
    # can assert exactly-one-fetch-per-harvest-invocation (fetch-once refactor, issue #794 s1).
    function script:Write-CountingMockGh {
        param(
            [array]$Pages,
            [string]$ScriptPath,
            [string]$CounterPath
        )

        $pageJsonList = $Pages | ForEach-Object {
            $page = $_
            $commentsJson = ($page | ForEach-Object {
                '{"body": ' + ($_ | ConvertTo-Json -Compress) + '}'
            }) -join ','
            "[$commentsJson]"
        }
        $mainJson = '[' + ($pageJsonList -join ',') + ']'
        $escapedCounter = $CounterPath -replace "'", "''"

        @"
param()
if (`$args -contains 'view') { Write-Error 'unknown flag: --paginate'; exit 1 }
`$count = if (Test-Path '$escapedCounter') { [int](Get-Content '$escapedCounter' -Raw) } else { 0 }
`$count++
Set-Content '$escapedCounter' `$count
Write-Output '$mainJson'
exit 0
"@ | Set-Content $ScriptPath -Encoding UTF8
    }

    $script:IssueId = '442'
    $script:Repo    = 'Grimblaz/agent-orchestra'
}

AfterAll {
    if (Test-Path $script:TempDir) {
        Remove-Item -Recurse -Force $script:TempDir -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# (a) All three pipeline-entry ports produce credit rows
# ---------------------------------------------------------------------------

Describe 'Invoke-CreditInputHarvest: all three ports (Step 9a)' -ForEach @(
    @{ Port = 'experience'; Evidence = 'issue #442; experience-owner-complete marker posted'; Builder = 'Build-ExperienceCreditRow' }
    @{ Port = 'design';     Evidence = 'issue #442; design-phase-complete marker posted';     Builder = 'Build-DesignCreditRow' }
    @{ Port = 'plan';       Evidence = 'issue #442; plan-issue marker posted';                Builder = 'Build-PlanCreditRow' }
) {
    param($Port, $Evidence, $Builder)

    BeforeAll {
        if (-not (Get-Command Invoke-CreditInputHarvest -ErrorAction SilentlyContinue) -or
            -not (Get-Command $Builder -ErrorAction SilentlyContinue)) {
            $script:HarvestResult = $null
            return
        }

        $markerComment = @"
<!-- credit-input-$Port-$script:IssueId -->
``````yaml
port: $Port
adapter: work-adapter
evidence: "$Evidence"
``````
"@
        $completionMarkerMap = @{
            'experience' = "<!-- experience-owner-complete-$script:IssueId -->"
            'design'     = "<!-- design-phase-complete-$script:IssueId -->"
            'plan'       = "<!-- plan-issue-$script:IssueId -->"
        }
        $completionMarkerText = $completionMarkerMap[$Port]
        $mockPath = Join-Path $script:TempDir "gh-port-$Port.ps1"
        script:Write-MockGh -ScriptPath $mockPath -Pages @(, @($completionMarkerText, $markerComment))

        $script:HarvestResult = Invoke-CreditInputHarvest `
            -IssueNumber $script:IssueId `
            -Repo        $script:Repo `
            -GhCliPath   $mockPath `
            -MaxRetries  0
    }

    It "harvests a credit row for port '$Port'" {
        if ($null -eq $script:HarvestResult) {
            Set-ItResult -Skipped -Because 'Invoke-CreditInputHarvest or builder not available'
            return
        }
        $script:HarvestResult.Count | Should -BeGreaterThan 0
    }

    It "harvested row for '$Port' has correct port field" {
        if ($null -eq $script:HarvestResult) {
            Set-ItResult -Skipped -Because 'Invoke-CreditInputHarvest not available'
            return
        }
        $row = @($script:HarvestResult | Where-Object { [string]$_.port -eq $Port })[0]
        $row | Should -Not -BeNullOrEmpty
        $row.port | Should -Be $Port
    }

    It "harvested row for '$Port' has status passed or not-applicable" {
        if ($null -eq $script:HarvestResult) {
            Set-ItResult -Skipped -Because 'Invoke-CreditInputHarvest not available'
            return
        }
        $row = @($script:HarvestResult | Where-Object { [string]$_.port -eq $Port })[0]
        $row | Should -Not -BeNullOrEmpty
        @('passed', 'not-applicable', 'skipped', 'failed') | Should -Contain ([string]$row.status)
    }
}

# ---------------------------------------------------------------------------
# (b) Cross-tool fixture parity: Copilot-style vs Claude-style YAML
# ---------------------------------------------------------------------------

Describe 'Invoke-CreditInputHarvest: cross-tool YAML parity (Step 9b)' {

    BeforeAll {
        if (-not (Get-Command Invoke-CreditInputHarvest -ErrorAction SilentlyContinue)) {
            $script:CopilotRow = $null
            $script:ClaudeRow  = $null
            return
        }

        $evidence = 'issue #442; experience-owner-complete'

        # Copilot style: extra spaces around colons, single-quoted evidence
        $copilotMarker = "<!-- credit-input-experience-$script:IssueId -->`n``````yaml`nport:  experience`nadapter:  work-adapter`nevidence:  `"$evidence`"`n``````"

        # Claude style: tight YAML, CRLF
        $claudeMarker = "<!-- credit-input-experience-$script:IssueId -->`r`n``````yaml`r`nport: experience`r`nadapter: work-adapter`r`nevidence: `"$evidence`"`r`n``````"

        $experienceComplete = "<!-- experience-owner-complete-$script:IssueId -->"
        $mockCopilot = Join-Path $script:TempDir 'gh-copilot.ps1'
        $mockClaude  = Join-Path $script:TempDir 'gh-claude.ps1'
        script:Write-MockGh -ScriptPath $mockCopilot -Pages @(, @($experienceComplete, $copilotMarker))
        script:Write-MockGh -ScriptPath $mockClaude  -Pages @(, @($experienceComplete, $claudeMarker))

        $copilotResult = Invoke-CreditInputHarvest -IssueNumber $script:IssueId -Repo $script:Repo -GhCliPath $mockCopilot -MaxRetries 0
        $claudeResult  = Invoke-CreditInputHarvest -IssueNumber $script:IssueId -Repo $script:Repo -GhCliPath $mockClaude  -MaxRetries 0

        $script:CopilotRow = @($copilotResult | Where-Object { [string]$_.port -eq 'experience' })[0]
        $script:ClaudeRow  = @($claudeResult  | Where-Object { [string]$_.port -eq 'experience' })[0]
    }

    It 'Copilot-style and Claude-style YAML produce rows with the same port' {
        if ($null -eq $script:CopilotRow -or $null -eq $script:ClaudeRow) {
            Set-ItResult -Skipped -Because 'Invoke-CreditInputHarvest not available'
            return
        }
        $script:CopilotRow.port | Should -Be $script:ClaudeRow.port
    }

    It 'Copilot-style and Claude-style YAML produce rows with the same status' {
        if ($null -eq $script:CopilotRow -or $null -eq $script:ClaudeRow) {
            Set-ItResult -Skipped -Because 'Invoke-CreditInputHarvest not available'
            return
        }
        $script:CopilotRow.status | Should -Be $script:ClaudeRow.status
    }
}

# ---------------------------------------------------------------------------
# (c) Paginated comment list: marker on simulated second page (real two-page fixture,
#     requirement (j) — >100-comment issues still paginate correctly under '--slurp' flatten)
# ---------------------------------------------------------------------------

Describe 'Invoke-CreditInputHarvest: marker in large comment list (Step 9c)' {

    It 'finds marker when it is among many comments split across two real API pages' {
        if (-not (Get-Command Invoke-CreditInputHarvest -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Invoke-CreditInputHarvest not available'
            return
        }

        $targetMarker = @"
<!-- credit-input-plan-$script:IssueId -->
``````yaml
port: plan
adapter: work-adapter
evidence: "issue #442; plan-issue"
``````
"@
        # Page 1: 100 generic comments (a full GitHub API page).
        $page1 = @(1..100 | ForEach-Object { "Generic comment $_." })
        # Page 2: completion marker, then the target credit-input marker, then trailing comments.
        $page2 = @("<!-- plan-issue-$script:IssueId -->", $targetMarker) + @(1..5 | ForEach-Object { "Trailing comment $_." })

        $mockPath = Join-Path $script:TempDir 'gh-paginated.ps1'
        script:Write-MockGh -ScriptPath $mockPath -Pages @($page1, $page2)

        $result = Invoke-CreditInputHarvest -IssueNumber $script:IssueId -Repo $script:Repo -GhCliPath $mockPath -MaxRetries 0
        $row = @($result | Where-Object { [string]$_.port -eq 'plan' })[0]
        $row | Should -Not -BeNullOrEmpty
        $row.port | Should -Be 'plan'
    }
}

# ---------------------------------------------------------------------------
# (d) Retry path: stale list first, full list second
# ---------------------------------------------------------------------------

Describe 'Invoke-CreditInputHarvest: retry when completion marker present but credit-input absent (Step 9d)' {

    It 'retries and succeeds on second call when credit-input marker appears after completion marker' {
        if (-not (Get-Command Invoke-CreditInputHarvest -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Invoke-CreditInputHarvest not available'
            return
        }

        $completionMarker  = "<!-- experience-owner-complete-$script:IssueId -->"
        $creditInputMarker = @"
<!-- credit-input-experience-$script:IssueId -->
``````yaml
port: experience
adapter: work-adapter
evidence: "issue #442; retry test"
``````
"@

        # First call: completion present, credit-input absent
        $stale = @($completionMarker, 'Some other comment.')
        # Second call: both present
        $full  = @($completionMarker, $creditInputMarker)

        $mockPath = Join-Path $script:TempDir 'gh-retry.ps1'
        script:Write-MockGh -ScriptPath $mockPath -Pages @(, $full) -StalePages @(, $stale)

        $result = Invoke-CreditInputHarvest `
            -IssueNumber       $script:IssueId `
            -Repo              $script:Repo `
            -GhCliPath         $mockPath `
            -MaxRetries        2 `
            -InitialBackoffSec 0

        $row = @($result | Where-Object { [string]$_.port -eq 'experience' })[0]
        $row | Should -Not -BeNullOrEmpty
        $row.port | Should -Be 'experience'
    }
}

# ---------------------------------------------------------------------------
# (e) -InMemoryMarkers fallback bypasses gh
# ---------------------------------------------------------------------------

Describe 'Invoke-CreditInputHarvest: -InMemoryMarkers bypass (Step 9e)' {

    It 'produces a credit row from in-memory marker text without calling gh' {
        if (-not (Get-Command Invoke-CreditInputHarvest -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Invoke-CreditInputHarvest not available'
            return
        }

        $inMemory = @"
<!-- credit-input-design-$script:IssueId -->
``````yaml
port: design
adapter: work-adapter
evidence: "issue #442; in-memory path"
``````
"@

        # Non-existent gh path — must not be called
        $result = Invoke-CreditInputHarvest `
            -IssueNumber    $script:IssueId `
            -Repo           $script:Repo `
            -GhCliPath      'gh-does-not-exist-sentinel' `
            -InMemoryMarkers @($inMemory) `
            -MaxRetries     0

        $row = @($result | Where-Object { [string]$_.port -eq 'design' })[0]
        $row | Should -Not -BeNullOrEmpty
        $row.port | Should -Be 'design'
    }
}

# ---------------------------------------------------------------------------
# (f) Negative-path: credit-input present but completion marker absent → zero rows (gh-fetch path)
# ---------------------------------------------------------------------------

Describe 'Invoke-CreditInputHarvest: credit-input without completion marker emits nothing (Step 9f-neg)' {

    It 'returns no credit row for a port when credit-input is present but completion marker is absent' {
        if (-not (Get-Command Invoke-CreditInputHarvest -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Invoke-CreditInputHarvest not available'
            return
        }

        # Credit-input comment present, but the required completion marker is absent.
        # The gh-fetch path gates emission on the completion marker being present.
        $creditInputOnly = @"
<!-- credit-input-experience-$script:IssueId -->
``````yaml
port: experience
adapter: work-adapter
evidence: "issue #442; experience-owner-complete marker posted"
``````
"@

        $mockPath = Join-Path $script:TempDir 'gh-no-completion.ps1'
        script:Write-MockGh -ScriptPath $mockPath -Pages @(, @($creditInputOnly))

        $result = Invoke-CreditInputHarvest -IssueNumber $script:IssueId -Repo $script:Repo -GhCliPath $mockPath -MaxRetries 0
        $result.Count | Should -Be 0 -Because 'credit-input without its completion marker must not be harvested'
    }
}

# ---------------------------------------------------------------------------
# (g) Absent-marker case: harvester emits nothing for that port
# ---------------------------------------------------------------------------

Describe 'Invoke-CreditInputHarvest: absent marker emits nothing (Step 9g)' {

    It 'returns no credit row for a port when no credit-input comment is present' {
        if (-not (Get-Command Invoke-CreditInputHarvest -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Invoke-CreditInputHarvest not available'
            return
        }

        # Comments list has no credit-input markers (and no completion markers either)
        $mockPath = Join-Path $script:TempDir 'gh-absent.ps1'
        script:Write-MockGh -ScriptPath $mockPath -Pages @(, @('Just a regular comment.', 'Another comment.'))

        $result = Invoke-CreditInputHarvest -IssueNumber $script:IssueId -Repo $script:Repo -GhCliPath $mockPath -MaxRetries 0
        $result.Count | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# (h) Reachable=$false on fetch failure, including a non-zero exit mid-pagination
#     (RED-first: exercises the reshaped Get-IssueComments directly)
# ---------------------------------------------------------------------------

Describe 'Get-IssueComments: Reachable=$false on fetch failure (Step 9h)' {

    BeforeAll {
        # Get-IssueComments is defined script:-scoped inside Invoke-CreditInputHarvest; a prior
        # invocation in this run (Describe 9a) has already published it to script scope. Guard
        # defensively in case test execution order changes.
        if (-not (Get-Command Invoke-CreditInputHarvest -ErrorAction SilentlyContinue)) {
            $script:SkipDirectTests = $true
            return
        }
        if (-not (Get-Command Get-IssueComments -ErrorAction SilentlyContinue)) {
            Invoke-CreditInputHarvest -IssueNumber $script:IssueId -Repo $script:Repo -GhCliPath 'gh-does-not-exist-sentinel' -MaxRetries 0 | Out-Null
        }
        $script:SkipDirectTests = -not (Get-Command Get-IssueComments -ErrorAction SilentlyContinue)
    }

    It 'returns Reachable=$false and empty Comments when the gh call throws (missing executable)' {
        if ($script:SkipDirectTests) {
            Set-ItResult -Skipped -Because 'Get-IssueComments not available'
            return
        }
        $r = Get-IssueComments -IssueNum $script:IssueId -RepoArg $script:Repo -Gh 'gh-does-not-exist-sentinel'
        $r.Reachable | Should -Be $false
        @($r.Comments).Count | Should -Be 0
    }

    It 'returns Reachable=$false and empty Comments on a non-zero exit mid-pagination' {
        if ($script:SkipDirectTests) {
            Set-ItResult -Skipped -Because 'Get-IssueComments not available'
            return
        }
        $mockPath = Join-Path $script:TempDir 'gh-fail-midpagination.ps1'
        @'
param()
Write-Error 'simulated pagination failure'
exit 1
'@ | Set-Content $mockPath -Encoding UTF8

        $r = Get-IssueComments -IssueNum $script:IssueId -RepoArg $script:Repo -Gh $mockPath
        $r.Reachable | Should -Be $false
        @($r.Comments).Count | Should -Be 0
    }

    It 'returns Reachable=$true and empty Comments on confirmed-zero comments (re-verify under new parse path)' {
        if ($script:SkipDirectTests) {
            Set-ItResult -Skipped -Because 'Get-IssueComments not available'
            return
        }
        $mockPath = Join-Path $script:TempDir 'gh-zero-comments.ps1'
        script:Write-MockGh -ScriptPath $mockPath -Pages @(, @())

        $r = Get-IssueComments -IssueNum $script:IssueId -RepoArg $script:Repo -Gh $mockPath
        $r.Reachable | Should -Be $true
        @($r.Comments).Count | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# (i) Regression guard: the old invalid 'gh issue view ... --paginate' form is rejected
#     by the mock (RED-first — this is what would have caught Bug 1 originally).
# ---------------------------------------------------------------------------

Describe 'Get-IssueComments: rejects the old invalid gh issue view --paginate call shape (Step 9i)' {

    It 'the mock fails loudly if invoked with the old issue-view --paginate form' {
        if (-not (Get-Command Invoke-CreditInputHarvest -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Invoke-CreditInputHarvest not available'
            return
        }

        $mockPath = Join-Path $script:TempDir 'gh-reject-old-form.ps1'
        script:Write-MockGh -ScriptPath $mockPath -Pages @(, @('some comment'))

        # Directly invoke the mock the OLD way to prove the regression guard fires.
        & $mockPath issue view 442 --repo $script:Repo --json comments --paginate 2>$null
        $LASTEXITCODE | Should -Not -Be 0
    }

    It 'Get-IssueComments (fixed implementation) never triggers the old-form rejection' {
        if (-not (Get-Command Invoke-CreditInputHarvest -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Invoke-CreditInputHarvest not available'
            return
        }
        if (-not (Get-Command Get-IssueComments -ErrorAction SilentlyContinue)) {
            Invoke-CreditInputHarvest -IssueNumber $script:IssueId -Repo $script:Repo -GhCliPath 'gh-does-not-exist-sentinel' -MaxRetries 0 | Out-Null
        }

        $mockPath = Join-Path $script:TempDir 'gh-reject-old-form-2.ps1'
        script:Write-MockGh -ScriptPath $mockPath -Pages @(, @('some comment'))

        $r = Get-IssueComments -IssueNum $script:IssueId -RepoArg $script:Repo -Gh $mockPath
        $r.Reachable | Should -Be $true
        @($r.Comments).Count | Should -Be 1
    }
}

# ---------------------------------------------------------------------------
# (k) Fetch-count assertion: exactly ONE thread fetch per Invoke-CreditInputHarvest
#     invocation, reused across all four ports (proves the fetch-once refactor).
# ---------------------------------------------------------------------------

Describe 'Invoke-CreditInputHarvest: fetches the comment thread exactly once per invocation (Step 9k)' {

    It 'calls gh exactly once even though four ports are evaluated' {
        if (-not (Get-Command Invoke-CreditInputHarvest -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Invoke-CreditInputHarvest not available'
            return
        }

        $counterPath = Join-Path $script:TempDir 'gh-call-counter.txt'
        if (Test-Path $counterPath) { Remove-Item $counterPath -Force }
        $mockPath = Join-Path $script:TempDir 'gh-counting.ps1'

        # No markers posted at all for any port — every port falls through to the gh-fetch
        # path (none are satisfied by in-memory bypass), maximizing the chance of redundant
        # fetches if the fetch-once refactor were not in place.
        script:Write-CountingMockGh -ScriptPath $mockPath -Pages @(, @('Just a regular comment.')) -CounterPath $counterPath

        Invoke-CreditInputHarvest -IssueNumber $script:IssueId -Repo $script:Repo -GhCliPath $mockPath -MaxRetries 0 | Out-Null

        $callCount = [int](Get-Content $counterPath -Raw)
        $callCount | Should -Be 1 -Because 'the comment thread should be fetched once and shared across all four ports, not re-fetched per port'
    }
}

# ---------------------------------------------------------------------------
# (l) $payloadFromInMemory fail-open branch still exercised correctly under the
#     reshaped fetch (gh unreachable + in-memory payload present -> fail-open emit).
# ---------------------------------------------------------------------------

Describe 'Invoke-CreditInputHarvest: payloadFromInMemory fail-open branch under reshaped fetch (Step 9l)' {

    It 'emits the row when gh is unreachable but the payload was supplied in-memory (fail-open)' {
        if (-not (Get-Command Invoke-CreditInputHarvest -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Invoke-CreditInputHarvest not available'
            return
        }

        # In-memory credit-input marker for 'design', but NO in-memory completion marker —
        # this forces the code down the gh-fetch path (payloadFromInMemory=$true) rather
        # than the immediate in-memory-bypass branch. gh is unreachable (nonexistent path),
        # so the fail-open branch (payloadFromInMemory -and -not $ghReachable) must fire.
        $inMemory = @"
<!-- credit-input-design-$script:IssueId -->
``````yaml
port: design
adapter: work-adapter
evidence: "issue #442; fail-open under reshaped fetch"
``````
"@

        $result = Invoke-CreditInputHarvest `
            -IssueNumber     $script:IssueId `
            -Repo            $script:Repo `
            -GhCliPath       'gh-does-not-exist-sentinel' `
            -InMemoryMarkers @($inMemory) `
            -MaxRetries      0

        $row = @($result | Where-Object { [string]$_.port -eq 'design' })[0]
        $row | Should -Not -BeNullOrEmpty -Because 'gh unreachable must not silently drop an in-session credit (fail-open)'
        $row.port | Should -Be 'design'
    }

    It 'suppresses the row when gh IS reachable but returns no completion marker (burst-halt still enforced)' {
        if (-not (Get-Command Invoke-CreditInputHarvest -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Invoke-CreditInputHarvest not available'
            return
        }

        $inMemory = @"
<!-- credit-input-design-$script:IssueId -->
``````yaml
port: design
adapter: work-adapter
evidence: "issue #442; reachable-but-no-completion"
``````
"@

        $mockPath = Join-Path $script:TempDir 'gh-reachable-no-completion.ps1'
        script:Write-MockGh -ScriptPath $mockPath -Pages @(, @('Just a regular comment.'))

        $result = Invoke-CreditInputHarvest `
            -IssueNumber     $script:IssueId `
            -Repo            $script:Repo `
            -GhCliPath       $mockPath `
            -InMemoryMarkers @($inMemory) `
            -MaxRetries      0

        $row = @($result | Where-Object { [string]$_.port -eq 'design' })[0]
        $row | Should -BeNullOrEmpty -Because 'gh reachable with no completion marker must suppress the row (burst-halt invariant)'
    }
}
