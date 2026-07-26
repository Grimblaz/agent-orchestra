#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    RED-phase Pester suite for the net-new surfaces of
    .github/scripts/lib/marker-transport-core.ps1 (issue #893, plan slice
    s2): the paginated full-enumeration selector
    (Find-AllCommentsByExactMarker) and the create-only POST primitive
    (New-MarkerComment). Neither existed anywhere in the repo before this
    slice.

.DESCRIPTION
    The five promoted, byte-identical-behavior helpers (Find-CommentIdByExactMarker,
    Get-CommentBodyById, Set-CommentBodyDirect, Get-CommentIdFromUrl,
    Set-PointerLineAfterMarker) already have full behavioral coverage via
    .github/scripts/Tests/persist-phase-ledger.Tests.ps1, which exercises
    them indirectly through persist-phase-ledger-core.ps1's one-line
    PPL-prefixed delegators. That suite staying 100% green with zero
    assertion changes IS this slice's regression evidence for AC8 (the
    zero-behavior-change guarantee); it is not duplicated here.

    This suite mocks only the true external seam (`gh`), matching the
    existing convention in persist-phase-ledger.Tests.ps1.
#>

BeforeDiscovery {
    $script:CoreLibPath = Join-Path $PSScriptRoot '../lib/marker-transport-core.ps1'
}

Describe 'marker-transport-core' {
    BeforeAll {
        $script:CoreLibPath = Join-Path $PSScriptRoot '../lib/marker-transport-core.ps1'
        $script:Owner = 'Grimblaz'
        $script:Repo = 'agent-orchestra'
        $script:IssueNumber = 893
        $script:Marker = '<!-- marker-transport-test-893 -->'
    }

    BeforeEach {
        # --- Simulated GitHub comment store (mutable across gh calls). ---
        $script:mockComments = [System.Collections.Generic.List[object]]::new()
        $script:NextCommentId = 90000
        $script:ghCallLog = [System.Collections.Generic.List[string]]::new()
        $script:PostLog = [System.Collections.Generic.List[object]]::new()
        $script:simulatePaginateFailure = $false

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
            # This is the unified REST endpoint -- its `id` field is already
            # the numeric REST id (unlike `gh issue view --json comments`'s
            # GraphQL node id), matching real `gh api` REST responses.
            if ($joined -match '^api --paginate repos/[^/]+/[^/]+/issues/\d+/comments$') {
                if ($script:simulatePaginateFailure) { $global:LASTEXITCODE = 1; return '' }
                $payload = @($script:mockComments | ForEach-Object {
                        @{ id = $_.Id; body = $_.body; url = $_.url }
                    }) | ConvertTo-Json -Depth 8
                $global:LASTEXITCODE = 0
                return $payload
            }

            # POST: gh issue comment <N> --body <text> -R <owner>/<repo>
            if ($joined -match '^(issue|pr) comment \d+ --body-file') {
                $newId = $script:NextCommentId
                $script:NextCommentId++
                $bodyFileIdx = [Array]::IndexOf($Args, '--body-file')
                $bodyFilePath = $Args[$bodyFileIdx + 1]
                $bodyText = Get-Content -LiteralPath $bodyFilePath -Raw
                Add-MockComment -Id $newId -Body $bodyText
                $script:PostLog.Add([PSCustomObject]@{ Body = $bodyText })
                $global:LASTEXITCODE = 0
                return "https://github.com/$script:Owner/$script:Repo/issues/$script:IssueNumber#issuecomment-$newId"
            }

            $global:LASTEXITCODE = 0
            return ''
        }

        # Per the established convention in find-or-upsert-comment.Tests.ps1
        # and persist-phase-ledger.Tests.ps1: when the core file does not
        # exist yet, a CommandNotFoundException at the Act line below is
        # itself the sanctioned RED signal.
        if (Test-Path $script:CoreLibPath) { . $script:CoreLibPath }
    }

    AfterEach {
        Remove-Item Function:gh -ErrorAction SilentlyContinue
    }

    Context 'Find-AllCommentsByExactMarker: full enumeration' {
        It 'returns every comment whose body carries the marker as a whole line, ignoring a prose-only mention with the same lowest id' {
            Add-MockComment -Id 10 -Body "A prose mention of the marker $script:Marker inside a sentence, not on its own line."
            Add-MockComment -Id 20 -Body "$script:Marker`n`nFirst real match."
            Add-MockComment -Id 30 -Body 'Unrelated comment.'
            Add-MockComment -Id 40 -Body "$script:Marker`n`nSecond real match."

            $results = Find-AllCommentsByExactMarker -Owner $script:Owner -Repo $script:Repo -IssueNumber $script:IssueNumber -Marker $script:Marker

            $results.Count | Should -Be 2
            @($results | ForEach-Object { $_.Id }) | Should -Be @(20, 40)
        }

        It 'returns an empty array, never $null, when zero comments match' {
            Add-MockComment -Id 10 -Body 'Nothing relevant here.'

            $results = Find-AllCommentsByExactMarker -Owner $script:Owner -Repo $script:Repo -IssueNumber $script:IssueNumber -Marker $script:Marker

            # Piping an empty array into `Should -Not -Be $null` is a known
            # Pester pipeline-collapse trap (zero pipeline items reads as a
            # single $null item) -- compare directly instead so this
            # assertion cannot false-fail on a genuinely correct empty-array
            # return.
            ($null -eq $results) | Should -Be $false
            @($results).Count | Should -Be 0
        }
    }

    Context 'Find-AllCommentsByExactMarker: multi-page resolution' {
        It 'still finds a matching comment positioned well past a typical single-page (30-comment) GitHub listing' {
            1..75 | ForEach-Object {
                Add-MockComment -Id $_ -Body "Filler comment number $_."
            }
            Add-MockComment -Id 999 -Body "$script:Marker`n`nThe only real match, positioned after 75 filler comments."

            $results = Find-AllCommentsByExactMarker -Owner $script:Owner -Repo $script:Repo -IssueNumber $script:IssueNumber -Marker $script:Marker

            $results.Count | Should -Be 1
            $results[0].Id | Should -Be 999
            # Exactly one external call issued -- gh's own --paginate walk
            # (not this function) is responsible for following every page;
            # this function must never early-exit or cap pages itself.
            @($script:ghCallLog | Where-Object { $_ -match '^api --paginate' }).Count | Should -Be 1
        }
    }

    Context 'Find-AllCommentsByExactMarker: loud pagination failure' {
        It 'throws rather than returning an empty result when the paginated gh call fails mid-walk' {
            Add-MockComment -Id 999 -Body "$script:Marker`n`nWould have matched, had the call succeeded."
            $script:simulatePaginateFailure = $true

            { Find-AllCommentsByExactMarker -Owner $script:Owner -Repo $script:Repo -IssueNumber $script:IssueNumber -Marker $script:Marker } | Should -Throw
        }
    }

    Context 'New-MarkerComment: create-only, no search' {
        It 'POSTs a new comment directly without ever listing existing comments first' {
            $result = New-MarkerComment -Type issue -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -Body $script:Marker

            $result | Should -Not -BeNullOrEmpty
            $script:PostLog.Count | Should -Be 1
            $script:PostLog[0].Body | Should -Be $script:Marker
            @($script:ghCallLog | Where-Object { $_ -match '^api --paginate' }) | Should -BeNullOrEmpty
            @($script:ghCallLog | Where-Object { $_ -match '^issue view' }) | Should -BeNullOrEmpty
        }

        It 'returns $null (fail-open) rather than throwing when the POST fails' {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)]$Args)
                $global:LASTEXITCODE = 1
                return ''
            }

            $result = New-MarkerComment -Type issue -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -Body $script:Marker

            $result | Should -BeNullOrEmpty
        }
    }

    Context 'New-MarkerComment: large-body native invocation (M2, issue #893 s11)' {
        BeforeAll {
            $script:SavedPath = $env:PATH
        }

        AfterAll {
            $env:PATH = $script:SavedPath
        }

        It 'succeeds for a 50,000-char body against a REAL external gh process seam -- the Windows command-line length limit (well under 65,536, the size-cap band this defect lived in) previously crashed the native process launch uncaught when the body was passed as a raw argv element' {
            # Real external-command seam (a .cmd batch file, genuinely
            # spawned as a child OS process via Win32 CreateProcess) --
            # never the `function global:gh` mock used by every other test
            # in this file, which is an in-process function call and could
            # never reproduce an OS command-line-length crash regardless of
            # implementation. `.ps1`-resolved shims are ALSO unsuitable here
            # (PowerShell dispatches a resolved .ps1 command in-process, not
            # via CreateProcess) -- only a real external executable/batch
            # file goes through the OS argv-length-limited process launch
            # this defect actually lived in.
            $mockDir = Join-Path $TestDrive 'gh-real-process-mock'
            New-Item -ItemType Directory -Path $mockDir -Force | Out-Null
            $callLogPath = Join-Path $mockDir 'calls.log'
            $ghMockContent = @"
@echo off
echo %*>>"$callLogPath"
echo https://github.com/mock/mock/issues/1#issuecomment-95000
exit /b 0
"@
            Set-Content -LiteralPath (Join-Path $mockDir 'gh.cmd') -Value $ghMockContent -Encoding ASCII

            Remove-Item Function:gh -ErrorAction SilentlyContinue
            $env:PATH = "$mockDir$([System.IO.Path]::PathSeparator)$script:SavedPath"

            $largeBody = "$script:Marker`n`n" + ('x' * 50000)

            $result = $null
            try {
                $result = New-MarkerComment -Type issue -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber -Body $largeBody
            }
            finally {
                # Restore the in-process mock immediately so no later test
                # in this Describe accidentally spawns a real process.
                . ([scriptblock]::Create('function global:gh {}'))
            }

            $result | Should -Not -BeNullOrEmpty -Because 'a large body must succeed, not crash the native gh invocation uncaught'
            (Test-Path -LiteralPath $callLogPath) | Should -Be $true

            # Positive proof the FIX actually changed the invocation shape
            # (never a raw --body argv element for a body this size): the
            # logged argv line gh.cmd received must stay short (a
            # --body-file PATH, not the 50,000-char body inline).
            $loggedArgvLine = (Get-Content -LiteralPath $callLogPath -Raw).Trim()
            $loggedArgvLine.Length | Should -BeLessThan 1000 -Because "the real argv gh.cmd received was: $loggedArgvLine"
            $loggedArgvLine | Should -Match '--body-file'
        }
    }
}
