#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    RED-phase Pester suite for the not-yet-implemented persist-marker-core
    helper (issue #893, plan slice s3). Implementation lands at
    skills/session-memory-contract/scripts/persist-marker-core.ps1,
    exporting Invoke-PersistMarkerWrite, Get-MarkerFamilyRegistry, and
    ConvertTo-MarkerNormalizedText.

.DESCRIPTION
    Dot-sources the REAL, already-shipped s2 transport primitives
    (.github/scripts/lib/marker-transport-core.ps1) and mocks only the true
    external seam (`gh`), matching the convention already established by
    marker-transport-core.Tests.ps1 and persist-phase-ledger.Tests.ps1. Per
    that same convention: when the core file does not exist yet, a
    CommandNotFoundException at the Act line is itself the sanctioned RED
    signal.

    Covers the slice s3 Requirement Contract (ac-refs AC1, AC3, AC11):
    both write shapes end-to-end, normalization convergence (CRLF vs LF),
    latest-vs-earliest selection under multiple matches, normalized-equality
    read-back rejecting a corrupted round-trip (a same-length mojibake
    substitution that the old >=50%-length-only guard would have accepted),
    and surface-mismatch refusal.
#>

BeforeDiscovery {
    $script:CoreLibPath = Join-Path $PSScriptRoot '../../../skills/session-memory-contract/scripts/persist-marker-core.ps1'
}

Describe 'persist-marker-core' {
    BeforeAll {
        $script:CoreLibPath = Join-Path $PSScriptRoot '../../../skills/session-memory-contract/scripts/persist-marker-core.ps1'
        $script:MarkerTransportLibPath = Join-Path $PSScriptRoot '../lib/marker-transport-core.ps1'
        $script:Owner = 'Grimblaz'
        $script:Repo = 'agent-orchestra'
        $script:IssueNumber = 893
    }

    BeforeEach {
        # --- Simulated GitHub comment store (mutable across gh calls). ---
        $script:mockComments = [System.Collections.Generic.List[object]]::new()
        $script:NextCommentId = 90000
        $script:ghCallLog = [System.Collections.Generic.List[string]]::new()
        $script:PatchLog = [System.Collections.Generic.List[object]]::new()
        $script:PostLog = [System.Collections.Generic.List[object]]::new()
        $script:simulatePaginateFailure = $false
        $script:simulatePatchFailure = @()
        $script:simulateGetFailure = @()
        $script:CorruptReadBackIds = [System.Collections.Generic.HashSet[long]]::new()

        function script:Add-MockComment {
            param([Parameter(Mandatory)][long]$Id, [Parameter(Mandatory)][string]$Body)
            $url = "https://github.com/$script:Owner/$script:Repo/issues/$script:IssueNumber#issuecomment-$Id"
            $script:mockComments.Add([PSCustomObject]@{ Id = $Id; body = $Body; url = $url })
        }

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $script:ghCallLog.Add($joined)

            # Paginated full-list: gh api --paginate repos/<o>/<r>/issues/<n>/comments
            if ($joined -match '^api --paginate repos/[^/]+/[^/]+/issues/\d+/comments$') {
                if ($script:simulatePaginateFailure) { $global:LASTEXITCODE = 1; return '' }
                $payload = @($script:mockComments | ForEach-Object {
                        @{ id = $_.Id; body = $_.body; url = $_.url }
                    }) | ConvertTo-Json -Depth 8
                $global:LASTEXITCODE = 0
                return $payload
            }

            # GET by numeric id (no -X): gh api repos/<o>/<r>/issues/comments/<id>
            if ($Args.Count -ge 2 -and $Args[0] -eq 'api' -and $Args[1] -match '^repos/[^/]+/[^/]+/issues/comments/(\d+)$' -and ($Args -notcontains '-X')) {
                $id = [long]$Matches[1]
                if ($script:simulateGetFailure -contains $id) { $global:LASTEXITCODE = 1; return '' }
                $c = $script:mockComments | Where-Object { $_.Id -eq $id }
                if (-not $c) { $global:LASTEXITCODE = 1; return '' }
                $global:LASTEXITCODE = 0
                $returnedBody = $c.body
                if ($script:CorruptReadBackIds.Contains($id)) {
                    # Same-length homoglyph substitution: proves normalized
                    # equality is doing real rejection work that the old
                    # >=50%-length truncation guard alone would have missed
                    # (mojibake corruption LENGTHENS/holds length, never
                    # shortens it).
                    $returnedBody = $returnedBody -replace 'e', "ë"
                }
                return (@{ id = $c.Id; body = $returnedBody; url = $c.url } | ConvertTo-Json -Depth 8)
            }

            # PATCH: gh api -X PATCH repos/<o>/<r>/issues/comments/<id> --input <file>
            if ($joined -match '^api -X PATCH repos/[^/]+/[^/]+/issues/comments/(\d+) --input') {
                $id = [long]$Matches[1]
                if ($script:simulatePatchFailure -contains $id) { $global:LASTEXITCODE = 1; return '' }
                $inputIdx = [Array]::IndexOf($Args, '--input')
                $filePath = $Args[$inputIdx + 1]
                $payloadObj = Get-Content -LiteralPath $filePath -Raw | ConvertFrom-Json
                $newBody = [string]$payloadObj.body
                $existing = $script:mockComments | Where-Object { $_.Id -eq $id }
                if ($existing) { $existing.body = $newBody } else { Add-MockComment -Id $id -Body $newBody }
                $script:PatchLog.Add([PSCustomObject]@{ CommentId = $id; Body = $newBody })
                $global:LASTEXITCODE = 0
                return (@{ html_url = "https://github.com/$script:Owner/$script:Repo/issues/$script:IssueNumber#issuecomment-$id" } | ConvertTo-Json)
            }

            # POST: gh issue comment <N> --body <text>  (or gh pr comment)
            if ($joined -match '^(issue|pr) comment \d+ --body') {
                $newId = $script:NextCommentId
                $script:NextCommentId++
                $bodyIdx = [Array]::IndexOf($Args, '--body')
                $bodyText = $Args[$bodyIdx + 1]
                Add-MockComment -Id $newId -Body $bodyText
                $script:PostLog.Add([PSCustomObject]@{ Body = $bodyText })
                $global:LASTEXITCODE = 0
                return "https://github.com/$script:Owner/$script:Repo/issues/$script:IssueNumber#issuecomment-$newId"
            }

            $global:LASTEXITCODE = 0
            return ''
        }

        # Real s2 primitives first (so persist-marker-core's unqualified
        # calls to Find-AllCommentsByExactMarker / New-MarkerComment /
        # Get-CommentIdFromUrl / Get-CommentBodyById / Set-CommentBodyDirect
        # resolve to the genuine, already-shipped implementations), then the
        # core itself.
        if (Test-Path $script:MarkerTransportLibPath) { . $script:MarkerTransportLibPath }
        if (Test-Path $script:CoreLibPath) { . $script:CoreLibPath }

        # Computed here (per-test, after dot-sourcing above) rather than in
        # a Context-level BeforeAll: Pester runs every container's BeforeAll
        # blocks before any BeforeEach, so a Context-level BeforeAll calling
        # Get-MarkerFamilyRegistry would fire before this BeforeEach has
        # dot-sourced the core file that defines it.
        if (Test-Path $script:CoreLibPath) {
            $script:PostNewFamily = @(Get-MarkerFamilyRegistry | Where-Object { $_.WriteShape -eq 'post-new' -and $_.TargetSurface -eq 'issue' })[0]
            $script:UpsertFamily = @(Get-MarkerFamilyRegistry | Where-Object { $_.WriteShape -eq 'upsert' -and $_.TargetSurface -eq 'issue' })[0]
        }
    }

    AfterEach {
        Remove-Item Function:gh -ErrorAction SilentlyContinue
    }

    Context 'Get-MarkerFamilyRegistry: declarative schema' {
        It 'returns rows carrying Family, MarkerTemplate, TargetSurface, WriteShape, ValidatorAdapter, and PostStep fields' {
            $rows = Get-MarkerFamilyRegistry

            $rows.Count | Should -BeGreaterThan 0
            foreach ($row in $rows) {
                $row.PSObject.Properties.Name | Should -Contain 'Family'
                $row.PSObject.Properties.Name | Should -Contain 'MarkerTemplate'
                $row.PSObject.Properties.Name | Should -Contain 'TargetSurface'
                $row.PSObject.Properties.Name | Should -Contain 'WriteShape'
                $row.PSObject.Properties.Name | Should -Contain 'ValidatorAdapter'
                $row.PSObject.Properties.Name | Should -Contain 'PostStep'
                @('issue', 'pull-request') | Should -Contain $row.TargetSurface
                @('post-new', 'upsert') | Should -Contain $row.WriteShape
            }
        }

        It 'includes at least one post-new family and one upsert family' {
            $rows = Get-MarkerFamilyRegistry

            @($rows | Where-Object { $_.WriteShape -eq 'post-new' }).Count | Should -BeGreaterThan 0
            @($rows | Where-Object { $_.WriteShape -eq 'upsert' }).Count | Should -BeGreaterThan 0
        }
    }

    Context 'ConvertTo-MarkerNormalizedText: the one shared normalization function' {
        It 'converges CRLF and LF variants of the same content to an identical normalized string' {
            $crlf = "<!-- marker -->`r`nLine one.`r`nLine two.`r`n"
            $lf = "<!-- marker -->`nLine one.`nLine two.`n"

            (ConvertTo-MarkerNormalizedText -Text $crlf) | Should -Be (ConvertTo-MarkerNormalizedText -Text $lf)
        }

        It 'strips per-line trailing whitespace and outer whitespace only, leaving interior content untouched' {
            $raw = "  `n<!-- marker -->  `nBody line.   `n  "

            (ConvertTo-MarkerNormalizedText -Text $raw) | Should -Be "<!-- marker -->`nBody line."
        }
    }

    Context 'post-new write shape: end-to-end' {
        It 'posts a brand-new comment when no prior match exists, and the read-back confirms it verbatim' {
            $marker = $script:PostNewFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $body = "$marker`n`nFresh payload with non-ASCII: café."

            $result = Invoke-PersistMarkerWrite -Family $script:PostNewFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $body

            $result.Success | Should -Be $true
            $result.Action | Should -Be 'posted'
            $script:PostLog.Count | Should -Be 1
            $result.CommentId | Should -Not -BeNullOrEmpty
            $escapedFamily = [regex]::Escape($script:PostNewFamily.Family)
            $result.Confirmation | Should -Match $escapedFamily
            $result.Confirmation | Should -Match "$($result.CommentId)"
        }

        It 'is a no-op when the payload already matches the LATEST marker match, comparing against latest only' {
            $marker = $script:PostNewFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $supersededBody = "$marker`n`nSuperseded payload."
            $latestBody = "$marker`n`nCurrent payload."
            Add-MockComment -Id 100 -Body $supersededBody
            Add-MockComment -Id 200 -Body $latestBody

            $result = Invoke-PersistMarkerWrite -Family $script:PostNewFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $latestBody

            $result.Success | Should -Be $true
            $result.Action | Should -Be 'no-op'
            $result.CommentId | Should -Be 200
            $script:PostLog.Count | Should -Be 0
        }

        It 'still posts when the payload matches a SUPERSEDED earlier comment but differs from the latest' {
            $marker = $script:PostNewFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $supersededBody = "$marker`n`nSuperseded payload, matches the new candidate."
            $latestBody = "$marker`n`nSomething else entirely, the current latest."
            Add-MockComment -Id 100 -Body $supersededBody
            Add-MockComment -Id 200 -Body $latestBody

            # Candidate matches the SUPERSEDED (id 100) comment, not the
            # latest (id 200) — must still post, never treated as a no-op.
            $result = Invoke-PersistMarkerWrite -Family $script:PostNewFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $supersededBody

            $result.Success | Should -Be $true
            $result.Action | Should -Be 'posted'
            $script:PostLog.Count | Should -Be 1
        }

        It 'converges CRLF-bodied stored comment vs LF payload to a no-op' {
            $marker = $script:PostNewFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $crlfStored = "$marker`r`n`r`nSame content.`r`n"
            $lfPayload = "$marker`n`nSame content."
            Add-MockComment -Id 100 -Body $crlfStored

            $result = Invoke-PersistMarkerWrite -Family $script:PostNewFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $lfPayload

            $result.Success | Should -Be $true
            $result.Action | Should -Be 'no-op'
            $script:PostLog.Count | Should -Be 0
        }

        It 'reports failure (never Success=$true) when the read-back is corrupted by a same-length substitution the old length-guard would have missed' {
            $marker = $script:PostNewFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $body = "$marker`n`nA sentence with several letter e characters in it."

            # New-MarkerComment's mock POST assigns $script:NextCommentId (90000
            # on first use in this test) — corrupt exactly that id's GET response.
            $script:CorruptReadBackIds.Add($script:NextCommentId) | Out-Null

            $result = Invoke-PersistMarkerWrite -Family $script:PostNewFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $body

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)read-back|normalized'
        }
    }

    Context 'upsert write shape: end-to-end' {
        It 'creates a new comment on first write when no prior match exists' {
            $marker = $script:UpsertFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $body = "$marker`n`nFirst-ever body."

            $result = Invoke-PersistMarkerWrite -Family $script:UpsertFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $body

            $result.Success | Should -Be $true
            $result.Action | Should -Be 'created'
            $script:PostLog.Count | Should -Be 1
        }

        It 'PATCHes the EARLIEST (canonical) match, never the latest, when multiple matches exist' {
            $marker = $script:UpsertFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            Add-MockComment -Id 100 -Body "$marker`n`nOld canonical body."
            Add-MockComment -Id 200 -Body "$marker`n`nA later decoy/duplicate."
            $newBody = "$marker`n`nUpdated body."

            $result = Invoke-PersistMarkerWrite -Family $script:UpsertFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $newBody

            $result.Success | Should -Be $true
            $result.Action | Should -Be 'updated'
            $result.CommentId | Should -Be 100
            $script:PatchLog.Count | Should -Be 1
            $script:PatchLog[0].CommentId | Should -Be 100
        }

        It 'never invokes --edit-last and always targets a numeric REST comment id' {
            $marker = $script:UpsertFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            Add-MockComment -Id 100 -Body "$marker`n`nOld body."
            $newBody = "$marker`n`nUpdated body."

            $null = Invoke-PersistMarkerWrite -Family $script:UpsertFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $newBody

            @($script:ghCallLog | Where-Object { $_ -match '--edit-last' }) | Should -BeNullOrEmpty
            $script:PatchLog[0].CommentId | Should -BeOfType [long]
        }

        It 'is a no-op when the payload already matches the canonical (earliest) comment' {
            $marker = $script:UpsertFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $body = "$marker`n`nUnchanged body."
            Add-MockComment -Id 100 -Body $body

            $result = Invoke-PersistMarkerWrite -Family $script:UpsertFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $body

            $result.Success | Should -Be $true
            $result.Action | Should -Be 'no-op'
            $script:PatchLog.Count | Should -Be 0
        }

        It 'converges CRLF-bodied stored comment vs LF payload to a no-op' {
            $marker = $script:UpsertFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            $crlfStored = "$marker`r`n`r`nSame content.`r`n"
            $lfPayload = "$marker`n`nSame content."
            Add-MockComment -Id 100 -Body $crlfStored

            $result = Invoke-PersistMarkerWrite -Family $script:UpsertFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $lfPayload

            $result.Success | Should -Be $true
            $result.Action | Should -Be 'no-op'
            $script:PatchLog.Count | Should -Be 0
        }

        It 'reports failure (never Success=$true) when the post-PATCH read-back is corrupted by a same-length substitution' {
            $marker = $script:UpsertFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber"
            Add-MockComment -Id 100 -Body "$marker`n`nOld body with several letter e characters."
            $newBody = "$marker`n`nUpdated body with several letter e characters."
            $script:CorruptReadBackIds.Add(100) | Out-Null

            $result = Invoke-PersistMarkerWrite -Family $script:UpsertFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -TargetSurface 'issue' -Marker $marker -Body $newBody

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)read-back|normalized'
        }
    }

    Context 'surface-mismatch refusal' {
        It 'refuses pre-write, naming the mismatch, when the declared TargetSurface does not match the registry row, without issuing any gh calls' {
            $issueOnlyFamily = @(Get-MarkerFamilyRegistry | Where-Object { $_.TargetSurface -eq 'issue' })[0]
            $marker = $issueOnlyFamily.MarkerTemplate -replace '\{ID\}', '999'
            $body = "$marker`n`nBody."

            $result = Invoke-PersistMarkerWrite -Family $issueOnlyFamily.Family -Owner $script:Owner -Repo $script:Repo -Number 999 -TargetSurface 'pull-request' -Marker $marker -Body $body

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)surface'
            $escapedFamily = [regex]::Escape($issueOnlyFamily.Family)
            $result.Reason | Should -Match $escapedFamily
            $script:ghCallLog.Count | Should -Be 0
        }

        It 'refuses an unknown marker family before issuing any gh calls' {
            $result = Invoke-PersistMarkerWrite -Family 'not-a-real-family' -Owner $script:Owner -Repo $script:Repo -Number 999 -TargetSurface 'issue' -Marker '<!-- not-a-real-family-999 -->' -Body 'x'

            $result.Success | Should -Be $false
            $result.Reason | Should -Match '(?i)unknown|registry'
            $script:ghCallLog.Count | Should -Be 0
        }
    }
}
