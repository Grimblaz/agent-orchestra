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

            # GET by numeric id (no -X): gh api repos/<o>/<r>/issues/comments/<id>
            if ($Args.Count -ge 2 -and $Args[0] -eq 'api' -and $Args[1] -match '^repos/[^/]+/[^/]+/issues/comments/(\d+)$' -and ($Args -notcontains '-X')) {
                $id = [long]$Matches[1]
                $c = $script:mockComments | Where-Object { $_.Id -eq $id }
                if (-not $c) {
                    Write-Error 'gh: Not Found (HTTP 404)'
                    $global:LASTEXITCODE = 1
                    return ''
                }
                $global:LASTEXITCODE = 0
                return (@{ id = $c.Id; body = $c.body; url = $c.url } | ConvertTo-Json -Depth 8)
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

    Context 'Get-CommentBodyByIdWithStatus: distinguishes confirmed-404 from a transient failure (M19, issue #893 s11)' {
        It 'returns Status=ok with the body on a successful GET' {
            Add-MockComment -Id 500 -Body "$script:Marker`n`nSibling content."

            $result = Get-CommentBodyByIdWithStatus -Owner $script:Owner -Repo $script:Repo -CommentId 500

            $result.Status | Should -Be 'ok'
            $result.Body | Should -Match ([regex]::Escape($script:Marker))
            $result.ErrorMessage | Should -BeNullOrEmpty
        }

        It 'returns Status=not-found (never error/throw) on a confirmed HTTP 404' {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)]$Args)
                Write-Error 'gh: Not Found (HTTP 404)'
                $global:LASTEXITCODE = 1
                return ''
            }

            $result = Get-CommentBodyByIdWithStatus -Owner $script:Owner -Repo $script:Repo -CommentId 999999

            $result.Status | Should -Be 'not-found'
            $result.Body | Should -BeNullOrEmpty
        }

        It 'returns Status=error (distinct from not-found) on a transient failure whose message carries no HTTP 404' {
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)]$Args)
                Write-Error 'gh: unexpected error connecting to api.github.com'
                $global:LASTEXITCODE = 1
                return ''
            }

            $result = Get-CommentBodyByIdWithStatus -Owner $script:Owner -Repo $script:Repo -CommentId 500

            $result.Status | Should -Be 'error'
            $result.Body | Should -BeNullOrEmpty
            $result.ErrorMessage | Should -Not -BeNullOrEmpty
        }
    }

    Context 'gh launch failure -- fail-open per each function''s own documented contract (F2, issue #893 PR #917 review)' {
        <#
        A real repro of the launch-failure class F2 fixes: `gh` absent from
        PATH entirely (never a mocked non-zero $LASTEXITCODE) raises a
        terminating CommandNotFoundException at the `& gh` call itself,
        BEFORE $LASTEXITCODE is ever checked -- bypassing every function's
        documented fail-open contract. The in-process `function global:gh`
        mock used elsewhere in this file would swallow that class entirely
        (a PowerShell function is always resolved before an external
        command, so it can never reproduce a launch failure); each It below
        removes that mock and points PATH at a directory with no `gh`
        binary so `& gh` genuinely cannot resolve to anything.
        #>
        BeforeEach {
            $script:GhLaunchFailureSavedPath = $env:PATH
            Remove-Item Function:gh -ErrorAction SilentlyContinue
            $script:NoGhDir = Join-Path $TestDrive "no-gh-here-$([guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $script:NoGhDir -Force | Out-Null
            $env:PATH = $script:NoGhDir
        }

        AfterEach {
            $env:PATH = $script:GhLaunchFailureSavedPath
        }

        It 'Get-CommentBodyById returns $null (its documented any-failure contract) rather than an uncaught exception' {
            { $script:result = Get-CommentBodyById -Owner $script:Owner -Repo $script:Repo -CommentId 500 } | Should -Not -Throw
            $script:result | Should -BeNullOrEmpty
        }

        It 'Get-CommentBodyByIdWithStatus returns Status=error (its documented failure shape) rather than an uncaught exception' {
            { $script:result = Get-CommentBodyByIdWithStatus -Owner $script:Owner -Repo $script:Repo -CommentId 500 } | Should -Not -Throw
            $script:result.Status | Should -Be 'error'
            $script:result.Body | Should -BeNullOrEmpty
            $script:result.ErrorMessage | Should -Not -BeNullOrEmpty
        }

        It 'Set-CommentBodyDirect returns Success=$false with a Reason (its documented failure shape) rather than an uncaught exception, for a launch failure on the PATCH call' {
            { $script:result = Set-CommentBodyDirect -Owner $script:Owner -Repo $script:Repo -CommentId 500 -NewBody 'new body' } | Should -Not -Throw
            $script:result.Success | Should -Be $false
            $script:result.Reason | Should -Not -BeNullOrEmpty
        }

        It 'Find-CommentIdByExactMarker returns $null (its documented no-match/failure contract) rather than an uncaught exception' {
            { $script:result = Find-CommentIdByExactMarker -Owner $script:Owner -Repo $script:Repo -IssueNumber $script:IssueNumber -Marker $script:Marker } | Should -Not -Throw
            $script:result | Should -BeNullOrEmpty
        }

        It 'Find-AllCommentsByExactMarker throws a deterministic error naming the apiPath (its documented throw-on-failure contract), not an uncaught CommandNotFoundException' {
            $thrown = $null
            try {
                Find-AllCommentsByExactMarker -Owner $script:Owner -Repo $script:Repo -IssueNumber $script:IssueNumber -Marker $script:Marker
            }
            catch {
                $thrown = $_
            }

            $thrown | Should -Not -BeNullOrEmpty
            $thrown.Exception.Message | Should -Match ([regex]::Escape("repos/$script:Owner/$script:Repo/issues/$script:IssueNumber/comments"))
        }

        It 'Find-AllCommentsByExactMarker preserves the original exception as InnerException rather than a bare-string rethrow (P7, issue #893 PR #917 post-fix)' {
            $thrown = $null
            try {
                Find-AllCommentsByExactMarker -Owner $script:Owner -Repo $script:Repo -IssueNumber $script:IssueNumber -Marker $script:Marker
            }
            catch {
                $thrown = $_
            }

            $thrown | Should -Not -BeNullOrEmpty
            $thrown.Exception.InnerException | Should -Not -BeNullOrEmpty
            $thrown.Exception.InnerException | Should -BeOfType ([System.Management.Automation.CommandNotFoundException])
        }
    }

    Context 'gh non-zero exit under PSNativeCommandUseErrorActionPreference=$true -- must not be mislabeled as a launch failure (P4, issue #893 PR #917 post-fix)' -Skip:(-not $IsWindows) {
        <#
        Windows-only real external-process seam (mirrors the M2 large-body
        Context's own real `.cmd` fixture rationale above): a
        `function global:gh` mock is an in-process function call and can
        NEVER raise a NativeCommandExitException regardless of
        $PSNativeCommandUseErrorActionPreference -- that preference only
        converts a REAL external process's non-zero exit into a
        terminating error. Only a genuinely-spawned `.cmd` process
        reproduces the defense's own live repro shape (EAP=Stop +
        PSNativeCommandUseErrorActionPreference=$true, both supported real
        configs) that re-collapsed the exit-code/stderr 404 classification
        the six F2 catch blocks sit above.
        #>
        BeforeAll {
            $script:P4SavedPath = $env:PATH

            # Defined in BeforeAll (Run phase), not directly in the Context
            # body (Discovery phase only) -- a function defined at
            # Discovery time does not survive into the Run-phase scope each
            # It executes in.
            function script:New-P4GhStub {
                param([Parameter(Mandatory)][string]$StderrText, [int]$ExitCode = 1)
                $stubLines = @('@echo off', "1>&2 echo $StderrText", "exit /b $ExitCode")
                Set-Content -LiteralPath (Join-Path $script:P4MockDir 'gh.cmd') -Value $stubLines -Encoding ASCII
                $env:PATH = "$script:P4MockDir$([System.IO.Path]::PathSeparator)$script:P4SavedPath"
            }
        }

        AfterAll {
            $env:PATH = $script:P4SavedPath
        }

        BeforeEach {
            Remove-Item Function:gh -ErrorAction SilentlyContinue
            $script:P4MockDir = Join-Path $TestDrive "gh-p4-mock-$([guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $script:P4MockDir -Force | Out-Null
        }

        AfterEach {
            $env:PATH = $script:P4SavedPath
            . ([scriptblock]::Create('function global:gh {}'))
        }

        It 'Get-CommentBodyByIdWithStatus still classifies a genuine confirmed-404 as Status=not-found (not Status=error) when the non-zero exit surfaces as a terminating NativeCommandExitException' {
            script:New-P4GhStub -StderrText 'Not Found (HTTP 404)'
            $PSNativeCommandUseErrorActionPreference = $true
            $ErrorActionPreference = 'Stop'

            $result = Get-CommentBodyByIdWithStatus -Owner $script:Owner -Repo $script:Repo -CommentId 999999

            $result.Status | Should -Be 'not-found'
        }

        It 'Get-CommentBodyByIdWithStatus reports Status=error for a genuine non-404 gh exit without mislabeling it a native-process launch failure' {
            script:New-P4GhStub -StderrText 'gh: unexpected error connecting to api.github.com'
            $PSNativeCommandUseErrorActionPreference = $true
            $ErrorActionPreference = 'Stop'

            $result = Get-CommentBodyByIdWithStatus -Owner $script:Owner -Repo $script:Repo -CommentId 500

            $result.Status | Should -Be 'error'
            $result.ErrorMessage | Should -Not -Match '(?i)launch failure'
        }

        It 'Get-CommentBodyById does not mislabel a genuine non-zero gh exit as a launch failure and still returns $null (its documented any-failure contract)' {
            script:New-P4GhStub -StderrText 'gh: unexpected error connecting to api.github.com'
            $PSNativeCommandUseErrorActionPreference = $true
            $ErrorActionPreference = 'Stop'

            $result = $null
            { $result = Get-CommentBodyById -Owner $script:Owner -Repo $script:Repo -CommentId 500 } | Should -Not -Throw
            $result | Should -BeNullOrEmpty
        }

        It 'Find-CommentIdByExactMarker does not mislabel a genuine non-zero gh exit as a launch failure and still returns $null (its documented no-match/failure contract)' {
            script:New-P4GhStub -StderrText 'gh: unexpected error connecting to api.github.com'
            $PSNativeCommandUseErrorActionPreference = $true
            $ErrorActionPreference = 'Stop'

            $result = $null
            { $result = Find-CommentIdByExactMarker -Owner $script:Owner -Repo $script:Repo -IssueNumber $script:IssueNumber -Marker $script:Marker } | Should -Not -Throw
            $result | Should -BeNullOrEmpty
        }

        It 'Find-AllCommentsByExactMarker throws without mislabeling a genuine non-zero gh exit as a launch failure, and preserves the original exception as InnerException (P4 + P7)' {
            script:New-P4GhStub -StderrText 'gh: rate limit exceeded'
            $PSNativeCommandUseErrorActionPreference = $true
            $ErrorActionPreference = 'Stop'

            $thrown = $null
            try {
                Find-AllCommentsByExactMarker -Owner $script:Owner -Repo $script:Repo -IssueNumber $script:IssueNumber -Marker $script:Marker
            }
            catch {
                $thrown = $_
            }

            $thrown | Should -Not -BeNullOrEmpty
            $thrown.Exception.Message | Should -Not -Match '(?i)launch failure'
            $thrown.Exception.InnerException | Should -Not -BeNullOrEmpty
            $thrown.Exception.InnerException | Should -BeOfType ([System.Management.Automation.NativeCommandExitException])
        }
    }

    Context 'New-MarkerComment: large-body native invocation (M2, issue #893 s11)' -Skip:(-not $IsWindows) {
        # Windows-only OS primitive: the fixture below is a `.cmd` batch
        # file (`@echo off` / `exit /b 0`), a Windows-specific external-
        # process shape with no Linux equivalent. This suite WAS quarantined out
        # of pester.yml (class unclassified, issue #993) when the guard below was
        # written, which made it a latent guard against a hypothetical future
        # Linux run. It is not latent any more: #1035 measured the suite on Linux,
        # #1036 promoted it, and pester.yml now selects it on every pull request.
        # The -Skip:(-not $IsWindows) guard is what keeps this Context off the
        # Linux runner, and it is now load-bearing rather than anticipatory.
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

    Context 'Console.OutputEncoding UTF-8 pin (CE Gate #893 live-run fix, S1/S3(a))' -Skip:(-not $IsWindows) {
        # Windows-only OS primitive: the fixture below is a `.cmd` batch
        # file (`@echo off` / `type` / `exit /b 0`), a Windows-specific
        # external-process shape with no Linux equivalent. None of this
        # suite's Describe blocks are selected by pester.yml today (this
        # suite is quarantined out of it), so this is a latent guard, not an active fix.
        BeforeAll {
            $script:EncodingSavedPath = $env:PATH
        }

        AfterAll {
            $env:PATH = $script:EncodingSavedPath
        }

        It 'decodes non-ASCII gh api stdout correctly even when the host console encoding starts as a legacy non-UTF8 code page' {
            # Real external-command seam (a .cmd batch file spawned as a
            # genuine child OS process, `type`-ing a pre-written UTF-8
            # no-BOM fixture file to stdout byte-for-byte) -- never the
            # `function global:gh` mock used elsewhere in this file, which
            # hands back an in-memory .NET string and never exercises
            # [Console]::OutputEncoding-governed native-stdout byte
            # decoding at all (the same reason the CE Gate's live defect
            # never showed up against the mocked suite despite 384/384
            # green).
            $mockDir = Join-Path $TestDrive 'gh-encoding-mock'
            New-Item -ItemType Directory -Path $mockDir -Force | Out-Null

            # Mixed non-ASCII payload matching the CE Gate S1 live-run
            # fixture shape: accented character, em-dash, emoji, homoglyph.
            # Built via direct string concatenation (never ConvertTo-Json)
            # so the fixture file's on-disk bytes are the genuine
            # multi-byte UTF-8 sequences (e.g. the em-dash's E2 80 94) --
            # ConvertTo-Json's default \uXXXX escaping would silently
            # collapse every non-ASCII character back down to plain ASCII
            # digits/letters, which decodes identically under every
            # single-byte code page and would make this test pass even
            # with the pin missing entirely (a false-negative RED gap).
            $nonAsciiBody = "caf`u{00E9} `u{2014} `u{1F389} `u{00EB}"
            $payload = '{"body":"' + $nonAsciiBody + '"}'
            $fixturePath = Join-Path $mockDir 'response.json'
            [System.IO.File]::WriteAllText($fixturePath, $payload, [System.Text.UTF8Encoding]::new($false))

            $ghMockContent = @"
@echo off
type "$fixturePath"
exit /b 0
"@
            Set-Content -LiteralPath (Join-Path $mockDir 'gh.cmd') -Value $ghMockContent -Encoding ASCII

            Remove-Item Function:gh -ErrorAction SilentlyContinue
            $env:PATH = "$mockDir$([System.IO.Path]::PathSeparator)$script:EncodingSavedPath"

            $originalEncoding = [Console]::OutputEncoding
            try {
                # Force the exact host state the CE Gate live-run defect
                # surfaced under: a legacy OEM/DOS code page (CP437 on
                # Windows), set BEFORE this file is (re-)dot-sourced, so
                # this test proves the library's OWN pin -- not test
                # ordering elsewhere in the suite -- is what corrects it.
                [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(437)

                # Re-dot-source the library now, with the console still
                # pinned to CP437: this is the exact moment the fix must
                # fire (marker-transport-core.ps1's first top-level
                # statement).
                . $script:CoreLibPath

                [Console]::OutputEncoding.WebName | Should -Be 'utf-8' -Because 'marker-transport-core.ps1 must pin Console.OutputEncoding to UTF-8 at dot-source time, before any of its functions run'

                $actualBody = $null
                try {
                    $actualBody = Get-CommentBodyById -Owner $script:Owner -Repo $script:Repo -CommentId 999
                }
                finally {
                    # Restore the in-process mock immediately so no later
                    # test in this Describe accidentally spawns a real
                    # process.
                    . ([scriptblock]::Create('function global:gh {}'))
                }

                $actualBody | Should -Be $nonAsciiBody -Because 'a real native gh process emitting genuine UTF-8 stdout must decode correctly once the pin has fired -- CP437-decoded mojibake would corrupt every multi-byte UTF-8 sequence (e.g. the em-dash''s E2 80 94 bytes) instead, exactly the corruption that failed CE Gate S1 (verbatim persistence) and, via the same broken read-back never matching the write candidate, S3(a) (double-run convergence)'
            }
            finally {
                [Console]::OutputEncoding = $originalEncoding
            }
        }
    }
}
