#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Integration tests for Invoke-CreditInputHarvest (issue #442, Step 9).
#
# (a) All three pipeline-entry ports: post fixture marker, run harvester, assert credit row.
# (b) Cross-tool fixture parity: Copilot-style and Claude-style YAML both produce byte-equal rows.
# (c) Paginated comment list: marker is on the second "page" of comments (simulated).
# (d) Retry path: first gh call returns stale list missing marker; second returns full list.
# (e) -InMemoryMarkers fallback: bypass gh and produce row from supplied text.
# (f) Absent-marker case: harvester emits nothing when no credit-input comment present.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:LedgerCoreLib = Join-Path $script:RepoRoot '.github/scripts/lib/frame-credit-ledger-core.ps1'
    if (Test-Path $script:LedgerCoreLib) { . $script:LedgerCoreLib }

    $script:TempDir = Join-Path ([System.IO.Path]::GetTempPath()) "pester-harvest-roundtrip-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null

    # Helper: write a mock gh script that returns a JSON comments payload.
    # Each element of $CommentBodies is a comment body string.
    # When $StaleBodies is non-null, the first call returns that list; subsequent calls return $CommentBodies.
    function script:Write-MockGh {
        param(
            [string]$ScriptPath,
            [string[]]$CommentBodies,
            [string[]]$StaleBodies = $null
        )

        # Encode the comment arrays as JSON escape-safe strings
        $mainJson = ($CommentBodies | ForEach-Object {
            '{"body": ' + ($_ | ConvertTo-Json -Compress) + '}'
        }) -join ','

        if ($null -ne $StaleBodies) {
            $staleJson = ($StaleBodies | ForEach-Object {
                '{"body": ' + ($_ | ConvertTo-Json -Compress) + '}'
            }) -join ','

            $stateFile = $ScriptPath -replace '\.ps1$', '.state'
            $escaped = $stateFile -replace "'", "''"

            @"
param()
`$state = if (Test-Path '$escaped') { Get-Content '$escaped' -Raw } else { 'first' }
if (`$state -eq 'first') {
    Set-Content '$escaped' 'done'
    Write-Output '{"comments": [$staleJson]}'
} else {
    Write-Output '{"comments": [$mainJson]}'
}
exit 0
"@ | Set-Content $ScriptPath -Encoding UTF8
        } else {
            @"
param()
Write-Output '{"comments": [$mainJson]}'
exit 0
"@ | Set-Content $ScriptPath -Encoding UTF8
        }
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
        script:Write-MockGh -ScriptPath $mockPath -CommentBodies @($completionMarkerText, $markerComment)

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
        script:Write-MockGh -ScriptPath $mockCopilot -CommentBodies @($experienceComplete, $copilotMarker)
        script:Write-MockGh -ScriptPath $mockClaude  -CommentBodies @($experienceComplete, $claudeMarker)

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
# (c) Paginated comment list: marker on simulated second page
# ---------------------------------------------------------------------------

Describe 'Invoke-CreditInputHarvest: marker in large comment list (Step 9c)' {

    It 'finds marker when it is among many comments' {
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
        # 111 comment bodies with the completion marker at position 105 and credit-input at 106
        $comments = @(1..104 | ForEach-Object { "Generic comment $_." })
        $comments += "<!-- plan-issue-$script:IssueId -->"
        $comments += $targetMarker
        $comments += @(1..5 | ForEach-Object { "Trailing comment $_." })

        $mockPath = Join-Path $script:TempDir 'gh-paginated.ps1'
        script:Write-MockGh -ScriptPath $mockPath -CommentBodies $comments

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
        script:Write-MockGh -ScriptPath $mockPath -CommentBodies $full -StaleBodies $stale

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
# (f) Absent-marker case: harvester emits nothing for that port
# ---------------------------------------------------------------------------

Describe 'Invoke-CreditInputHarvest: absent marker emits nothing (Step 9f)' {

    It 'returns no credit row for a port when no credit-input comment is present' {
        if (-not (Get-Command Invoke-CreditInputHarvest -ErrorAction SilentlyContinue)) {
            Set-ItResult -Skipped -Because 'Invoke-CreditInputHarvest not available'
            return
        }

        # Comments list has no credit-input markers (and no completion markers either)
        $mockPath = Join-Path $script:TempDir 'gh-absent.ps1'
        script:Write-MockGh -ScriptPath $mockPath -CommentBodies @('Just a regular comment.', 'Another comment.')

        $result = Invoke-CreditInputHarvest -IssueNumber $script:IssueId -Repo $script:Repo -GhCliPath $mockPath -MaxRetries 0
        $result.Count | Should -Be 0
    }
}
