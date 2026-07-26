#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    GREEN-phase Pester suite for the s7 requirement contract (issue #893,
    plan slice s7): coverage the s2-s6 implementation and the s9 doc rewrite
    both already ship, but that no existing test file locks. s2-s9 are
    already complete and committed; this file adds no production-code
    changes (test-only, per s7's NON-GOAL).

.DESCRIPTION
    Five requirement-contract items (ac-refs AC3, AC10, AC13):

    1. AST structural test (Context 'wrapper param() shape'): asserts no
       public parameter of skills/session-memory-contract/scripts/persist-marker.ps1
       is array-typed, parsed via the real PowerShell AST -- never a regex
       over the file text, which a comment or string literal could spoof.
       This is the wrapper's own pinned invariant (see its header): a
       `pwsh -File` invocation cannot reliably bind an array parameter (the
       recorded #866 flattening trap).

    2. Child-script-shape integration tests (Context 'dual invocation
       shape'): exercises BOTH legal entry points the wrapper's header
       documents -- a real child `pwsh -File persist-marker.ps1 ...` process,
       and the in-process call-operator `& persist-marker.ps1 ...` form
       (same OS process, invoked directly inside this suite's own runspace;
       verified safe because the wrapper's top-level `exit 0`/`exit 1`
       statements only unwind THAT nested script invocation, not the
       calling Pester session, when invoked via `&` rather than as the
       process's own top-level entry point). Both forms are pointed at a
       real `gh` mock resolved via a PATHEXT `.PS1` shim on `$env:PATH`
       (never a global PowerShell function -- neither invocation form would
       see one, since a spawned subprocess and an in-process `&` call each
       get a fresh/unrelated function table), so both shapes are proven to
       compose the same candidate and land the same write via the real
       external-command seam.

    3. Registry-parameterized refusal-diagnostics test (Context
       'registry-parameterized refusal diagnostics'): iterates
       `Get-MarkerFamilyRegistry | Where-Object ValidatorAdapter` (never a
       hardcoded family-name list -- computed once in `BeforeDiscovery` so
       Pester's `-ForEach` generates one It per row) and asserts each
       validator-adapter-bearing family refuses a malformed candidate with a
       diagnosable "persist-marker: REFUSED (...)" message before any
       network write. Sentinel families with no adapter are excluded BY THE
       `Where-Object ValidatorAdapter` FILTER ITSELF, not by an omission
       list this file maintains by hand -- a family added to the registry
       later with a validator adapter is automatically picked up here; a
       family added with an adapter name this file has no fixture for fails
       loud (`$generator | Should -Not -BeNullOrEmpty`) rather than being
       silently skipped.

    4. Temp-file lifetime test (Context 'temp-file lifetime on an
       abnormal-exit PATCH'): marker-transport-core.ps1's
       Set-CommentBodyDirect wraps its `--input` scratch file
       ([System.IO.Path]::GetTempFileName()) in a try/finally. This context
       proves that invariant empirically -- the mocked `gh` PATCH call
       throws a genuine terminating error mid-write (simulating an abnormal
       interruption, not a clean non-zero exit), and the test asserts the
       captured temp-file path no longer exists afterward, then proves a
       clean retry immediately succeeds (no leaked lock/corruption from the
       interrupted attempt).

    5. CONTRACT DRIFT-GUARD (Context 'prose/contract drift guard'): extracts
       PINNED claims from the five prose surfaces s9 rewrote -- the three
       upstream agent bodies, handoff-markers.md, and
       engagement-record-write-discipline.md -- and asserts each one
       against the SCRIPT'S OWN live source (never a re-typed copy): the
       wrapper path exists; every `-Param` name quoted in a persist-marker.ps1
       invocation snippet is a real AST-extracted parameter; every
       `family \`...\`` attribution names a real Get-MarkerFamilyRegistry
       row; the burst-manifest required-field list matches
       persist-marker-core.ps1's own $requiredFields array byte-for-byte;
       the three agent bodies' per-phase credit-input `port:` values are
       all legal per $script:CreditInputPortEnum; the slug regex quoted in
       four of the five surfaces matches frame-engagement-record-core.ps1's
       own $script:DecisionIdSlugRegex byte-for-byte; and every surface
       still frames persist-marker.ps1 as the "ONLY documented write path".
       Per this slice's NON-GOAL, if any of these fail, that is a real s9
       drift to report to Code-Conductor -- this file must never loosen an
       assertion to make a genuine drift pass.
#>

BeforeDiscovery {
    $script:RepoRootForDiscovery = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:CoreLibPathForDiscovery = Join-Path $script:RepoRootForDiscovery 'skills/session-memory-contract/scripts/persist-marker-core.ps1'
    $script:ValidatorAdapterFamilies = @()
    if (Test-Path -LiteralPath $script:CoreLibPathForDiscovery) {
        . $script:CoreLibPathForDiscovery
        if (Get-Command -Name Get-MarkerFamilyRegistry -ErrorAction SilentlyContinue) {
            $script:ValidatorAdapterFamilies = @(Get-MarkerFamilyRegistry | Where-Object { -not [string]::IsNullOrWhiteSpace($_.ValidatorAdapter) })
        }
    }
}

Describe 'persist-marker.ps1 wrapper contract (s7): AST param shape + dual invocation shape' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:WrapperPath = Join-Path $script:RepoRoot 'skills/session-memory-contract/scripts/persist-marker.ps1'
        $script:SavedPath = $env:PATH
        $script:SavedPathExt = $env:PATHEXT

        function script:New-GhMockDir {
            <#
            .SYNOPSIS
                Builds a real external `gh` seam: a `gh.ps1` script resolved
                by adding '.PS1' to $env:PATHEXT so a bare `gh` command
                dispatches to it -- exercised identically by a spawned
                subprocess (Test 2a) and by an in-process `&` call (Test
                2b), because command resolution consults process-level
                $env:PATH/$env:PATHEXT regardless of which runspace issues
                the call. A JSON-backed store on disk (not an in-memory
                mock) is required because each `& gh ...` invocation this
                mock serves is itself a fresh dispatch of gh.ps1 -- state
                must survive across those calls within one wrapper run.
            #>
            param([Parameter(Mandatory)][string]$MockDir)
            New-Item -ItemType Directory -Path $MockDir -Force | Out-Null
            $ghMockContent = @'
param()
$storePath = Join-Path $PSScriptRoot 'store.json'
$callLogPath = Join-Path $PSScriptRoot 'calls.log'
$counterPath = Join-Path $PSScriptRoot 'counter.txt'
($args -join ' ') | Add-Content -LiteralPath $callLogPath -Encoding UTF8

function Read-MockStore {
    if (Test-Path -LiteralPath $storePath) {
        $raw = Get-Content -LiteralPath $storePath -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        return @($raw | ConvertFrom-Json)
    }
    return @()
}
function Write-MockStore($items) {
    (ConvertTo-Json -InputObject @($items) -Depth 8 -AsArray) | Set-Content -LiteralPath $storePath -Encoding UTF8
}

$a = $args

if ($a.Count -ge 3 -and $a[0] -eq 'api' -and $a[1] -eq '--paginate' -and $a[2] -match '^repos/[^/]+/[^/]+/issues/\d+/comments$') {
    $items = @(Read-MockStore)
    $payload = @($items | ForEach-Object { @{ id = $_.id; body = $_.body; url = $_.url } })
    Write-Output (ConvertTo-Json -InputObject $payload -Depth 8 -AsArray)
    exit 0
}

if ($a.Count -ge 2 -and $a[0] -eq 'api' -and $a[1] -match '^repos/[^/]+/[^/]+/issues/comments/(\d+)$' -and ($a -notcontains '-X')) {
    $id = [long]$Matches[1]
    $items = @(Read-MockStore)
    $c = $items | Where-Object { $_.id -eq $id }
    if (-not $c) { exit 1 }
    Write-Output (@{ id = $c.id; body = $c.body; url = $c.url } | ConvertTo-Json -Depth 8)
    exit 0
}

if ($a.Count -ge 2 -and $a[0] -eq 'api' -and ($a -contains '-X') -and ($a -contains 'PATCH')) {
    $joined = $a -join ' '
    $m = [regex]::Match($joined, 'issues/comments/(\d+)')
    $id = [long]$m.Groups[1].Value
    $inputIdx = [Array]::IndexOf([string[]]$a, '--input')
    $filePath = $a[$inputIdx + 1]
    $payloadObj = Get-Content -LiteralPath $filePath -Raw | ConvertFrom-Json
    $newBody = [string]$payloadObj.body
    $items = @(Read-MockStore)
    $existing = $items | Where-Object { $_.id -eq $id }
    if ($existing) {
        $existing.body = $newBody
    }
    else {
        $items = @($items) + [PSCustomObject]@{ id = $id; body = $newBody; url = "https://github.com/mock/mock/issues/1#issuecomment-$id" }
    }
    Write-MockStore $items
    Write-Output (@{ html_url = "https://github.com/mock/mock/issues/1#issuecomment-$id" } | ConvertTo-Json)
    exit 0
}

if ($a.Count -ge 4 -and ($a[0] -eq 'issue' -or $a[0] -eq 'pr') -and $a[1] -eq 'comment') {
    $bodyFileIdx = [Array]::IndexOf([string[]]$a, '--body-file')
    $bodyText = Get-Content -LiteralPath $a[$bodyFileIdx + 1] -Raw
    $nextId = 91000
    if (Test-Path -LiteralPath $counterPath) { $nextId = [int](Get-Content -LiteralPath $counterPath -Raw) }
    Set-Content -LiteralPath $counterPath -Value ($nextId + 1) -NoNewline
    $items = @(Read-MockStore) + [PSCustomObject]@{ id = $nextId; body = $bodyText; url = "https://github.com/mock/mock/issues/1#issuecomment-$nextId" }
    Write-MockStore $items
    Write-Output "https://github.com/mock/mock/issues/1#issuecomment-$nextId"
    exit 0
}

exit 0
'@
            Set-Content -LiteralPath (Join-Path $MockDir 'gh.ps1') -Value $ghMockContent -Encoding UTF8
        }
    }

    Context 'wrapper param() shape (AST, not regex)' {
        It 'no public parameter of persist-marker.ps1 is array-typed' {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:WrapperPath, [ref]$null, [ref]$null)
            $paramBlock = $ast.ParamBlock
            $paramBlock | Should -Not -BeNullOrEmpty -Because 'persist-marker.ps1 must declare a top-level param() block'

            $arrayTypedParams = [System.Collections.Generic.List[string]]::new()
            foreach ($param in $paramBlock.Parameters) {
                foreach ($attr in $param.Attributes) {
                    if ($attr -is [System.Management.Automation.Language.TypeConstraintAst] -and $attr.TypeName -is [System.Management.Automation.Language.ArrayTypeName]) {
                        $arrayTypedParams.Add($param.Name.VariablePath.UserPath) | Out-Null
                    }
                }
            }

            $arrayTypedParams.Count | Should -Be 0 -Because "a pwsh -File invocation cannot reliably bind an array parameter (#866 flattening trap) -- found array-typed param(s): $($arrayTypedParams -join ', ')"
        }
    }

    Context 'dual invocation shape: pwsh -File AND in-process &' {
        It 'invokes cleanly via a real child "pwsh -File" process and posts the composed candidate through the mocked gh' {
            $workDir = Join-Path $TestDrive 'pwsh-file-shape'
            $scratchRoot = Join-Path $workDir '.tmp'
            New-Item -ItemType Directory -Path $scratchRoot -Force | Out-Null
            $mockDir = Join-Path $workDir 'ghmock'
            script:New-GhMockDir -MockDir $mockDir

            $marker = '<!-- experience-owner-complete-77001 -->'
            $bodyPath = Join-Path $scratchRoot 'body.md'
            [System.IO.File]::WriteAllText($bodyPath, "$marker`n`nPwsh -File invocation shape body.")

            Push-Location -LiteralPath $workDir
            try {
                $env:PATH = "$mockDir$([System.IO.Path]::PathSeparator)$script:SavedPath"
                $env:PATHEXT = ".PS1;$script:SavedPathExt"

                $output = & pwsh -NoProfile -NonInteractive -File $script:WrapperPath `
                    -Owner 'Grimblaz' -Repo 'agent-orchestra' -Family 'experience-owner-complete' `
                    -Number 77001 -TargetSurface 'issue' -Marker $marker -BodyFile $bodyPath 2>&1
                $exitCode = $LASTEXITCODE
            }
            finally {
                $env:PATH = $script:SavedPath
                $env:PATHEXT = $script:SavedPathExt
                Pop-Location
            }

            $outputText = ($output | Out-String)
            $exitCode | Should -Be 0 -Because $outputText
            $outputText | Should -Match 'persist-marker \(family=experience-owner-complete\):.*posted'

            $callLogPath = Join-Path $mockDir 'calls.log'
            (Test-Path -LiteralPath $callLogPath) | Should -Be $true
            (Get-Content -LiteralPath $callLogPath -Raw) | Should -Match 'issue comment 77001'
        }

        It 'invokes cleanly via the in-process call operator (&), producing the same landed-write outcome as the pwsh -File shape' {
            $workDir = Join-Path $TestDrive 'in-process-call-shape'
            $scratchRoot = Join-Path $workDir '.tmp'
            New-Item -ItemType Directory -Path $scratchRoot -Force | Out-Null
            $mockDir = Join-Path $workDir 'ghmock'
            script:New-GhMockDir -MockDir $mockDir

            $marker = '<!-- experience-owner-complete-77002 -->'
            $bodyPath = Join-Path $scratchRoot 'body.md'
            [System.IO.File]::WriteAllText($bodyPath, "$marker`n`nIn-process call-operator invocation shape body.")

            Push-Location -LiteralPath $workDir
            try {
                $env:PATH = "$mockDir$([System.IO.Path]::PathSeparator)$script:SavedPath"
                $env:PATHEXT = ".PS1;$script:SavedPathExt"

                # Literal in-process call-operator invocation -- NOT a
                # dot-source (`.`), so persist-marker.ps1's own dot-sourced
                # dependencies land in ITS OWN script scope, not this
                # Describe's. The wrapper's top-level `exit 0` only unwinds
                # this nested `&` invocation (verified empirically: exit
                # inside a script invoked via `&` from a non-top-level
                # caller terminates only that script's own scope, setting
                # $LASTEXITCODE, and returns control to the caller) -- it
                # does not terminate this Pester session.
                $output = & $script:WrapperPath -Owner 'Grimblaz' -Repo 'agent-orchestra' -Family 'experience-owner-complete' `
                    -Number 77002 -TargetSurface 'issue' -Marker $marker -BodyFile $bodyPath
                $exitCode = $LASTEXITCODE
            }
            finally {
                $env:PATH = $script:SavedPath
                $env:PATHEXT = $script:SavedPathExt
                Pop-Location
            }

            $outputText = ($output | Out-String)
            $exitCode | Should -Be 0 -Because $outputText
            $outputText | Should -Match 'persist-marker \(family=experience-owner-complete\):.*posted'

            $callLogPath = Join-Path $mockDir 'calls.log'
            (Test-Path -LiteralPath $callLogPath) | Should -Be $true
            (Get-Content -LiteralPath $callLogPath -Raw) | Should -Match 'issue comment 77002'
        }
    }
}

Describe 'persist-marker-core: registry-parameterized refusal diagnostics + temp-file lifetime (s7)' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:CoreLibPath = Join-Path $script:RepoRoot 'skills/session-memory-contract/scripts/persist-marker-core.ps1'
        $script:MarkerTransportLibPath = Join-Path $script:RepoRoot '.github/scripts/lib/marker-transport-core.ps1'
        $script:EngagementRecordLibPath = Join-Path $script:RepoRoot '.github/scripts/lib/frame-engagement-record-core.ps1'
        $script:FrameSpineLibPath = Join-Path $script:RepoRoot '.github/scripts/lib/frame-spine-core.ps1'
        $script:Owner = 'Grimblaz'
        $script:Repo = 'agent-orchestra'
        $script:IssueNumber = 88001

        function script:New-FencedYamlBody {
            param([Parameter(Mandatory)][string]$Marker, [Parameter(Mandatory)][string]$Yaml)
            $fence = '```'
            return "$Marker`n`n${fence}yaml`n$Yaml`n$fence"
        }

        # Bad-payload generators keyed by ValidatorAdapter name (not by
        # family name) -- the adapter, not the family literal, decides the
        # payload shape a refusal needs, and multiple families could in
        # principle share one adapter.
        $script:BadPayloadByAdapter = @{
            'sentinel-empty'      = {
                param($Marker)
                "$Marker`n`nThis sentinel family must carry no content, but here is unexpected prose."
            }
            'engagement-record'   = {
                param($Marker)
                $yaml = @'
schema_version: 2
phase: plan
capture_session: "s7-drift-fixture"
load_bearing_decisions:
  - decision_id: Not_A_Valid_Slug
    classification: load-bearing
    articulation_status: complete
'@
                script:New-FencedYamlBody -Marker $Marker -Yaml $yaml
            }
            'review-dispositions' = {
                param($Marker)
                $yaml = @'
schema_version: 1
passes_run: [1]
entries:
  - stable_finding_key: "src/example.ts:10:sample-finding"
    pass: 1
    disposition: dismiss
    classification: routine
'@
                script:New-FencedYamlBody -Marker $Marker -Yaml $yaml
            }
            'credit-input'        = {
                param($Marker)
                $yaml = @'
port: bogus-port
adapter: skills/plan-authoring/adapters/plan-adapter.md
evidence: "malformed-port-fixture"
'@
                script:New-FencedYamlBody -Marker $Marker -Yaml $yaml
            }
        }
    }

    BeforeEach {
        # --- Simulated GitHub comment store, mirroring the established
        # convention in persist-marker-core.Tests.ps1 / persist-marker.Tests.ps1,
        # plus a new $script:SimulatePatchThrowIds hook (Context 4). ---
        $script:mockComments = [System.Collections.Generic.List[object]]::new()
        $script:NextCommentId = 90000
        $script:PatchLog = [System.Collections.Generic.List[object]]::new()
        $script:PostLog = [System.Collections.Generic.List[object]]::new()
        $script:SimulatePatchThrowIds = [System.Collections.Generic.HashSet[long]]::new()
        $script:CapturedPatchTempFile = $null

        function script:Add-MockComment {
            param([Parameter(Mandatory)][long]$Id, [Parameter(Mandatory)][string]$Body)
            $url = "https://github.com/$script:Owner/$script:Repo/issues/$script:IssueNumber#issuecomment-$Id"
            $script:mockComments.Add([PSCustomObject]@{ Id = $Id; body = $Body; url = $url })
        }

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '

            if ($joined -match '^api --paginate repos/[^/]+/[^/]+/issues/\d+/comments$') {
                $payload = @($script:mockComments | ForEach-Object { @{ id = $_.Id; body = $_.body; url = $_.url } }) | ConvertTo-Json -Depth 8
                $global:LASTEXITCODE = 0
                return $payload
            }

            if ($Args.Count -ge 2 -and $Args[0] -eq 'api' -and $Args[1] -match '^repos/[^/]+/[^/]+/issues/comments/(\d+)$' -and ($Args -notcontains '-X')) {
                $id = [long]$Matches[1]
                $c = $script:mockComments | Where-Object { $_.Id -eq $id }
                if (-not $c) { $global:LASTEXITCODE = 1; return '' }
                $global:LASTEXITCODE = 0
                return (@{ id = $c.Id; body = $c.body; url = $c.url } | ConvertTo-Json -Depth 8)
            }

            if ($joined -match '^api -X PATCH repos/[^/]+/[^/]+/issues/comments/(\d+) --input') {
                $id = [long]$Matches[1]
                $inputIdx = [Array]::IndexOf($Args, '--input')
                $filePath = $Args[$inputIdx + 1]
                if ($script:SimulatePatchThrowIds.Contains($id)) {
                    # Simulate an abnormal mid-write termination (a genuine
                    # terminating error, never a clean non-zero exit) --
                    # capture the --input temp file path BEFORE throwing so
                    # Context 4 can prove Set-CommentBodyDirect's
                    # try/finally removed it despite the throw.
                    $script:CapturedPatchTempFile = $filePath
                    throw [System.InvalidOperationException]::new('simulated abnormal termination mid-PATCH')
                }
                $payloadObj = Get-Content -LiteralPath $filePath -Raw | ConvertFrom-Json
                $newBody = [string]$payloadObj.body
                $existing = $script:mockComments | Where-Object { $_.Id -eq $id }
                if ($existing) { $existing.body = $newBody } else { Add-MockComment -Id $id -Body $newBody }
                $script:PatchLog.Add([PSCustomObject]@{ CommentId = $id; Body = $newBody })
                $global:LASTEXITCODE = 0
                return (@{ html_url = "https://github.com/$script:Owner/$script:Repo/issues/$script:IssueNumber#issuecomment-$id" } | ConvertTo-Json)
            }

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

        if (Test-Path $script:MarkerTransportLibPath) { . $script:MarkerTransportLibPath }
        if (Test-Path $script:EngagementRecordLibPath) { . $script:EngagementRecordLibPath }
        if (Test-Path $script:FrameSpineLibPath) { . $script:FrameSpineLibPath }
        if (Test-Path $script:CoreLibPath) { . $script:CoreLibPath }
    }

    AfterEach {
        Remove-Item Function:gh -ErrorAction SilentlyContinue
    }

    Context 'Invoke-PersistMarkerWrite: registry-parameterized refusal diagnostics (every ValidatorAdapter family refuses a bad payload)' {
        It 'family <_.Family> (ValidatorAdapter=<_.ValidatorAdapter>) refuses a malformed candidate with a diagnosable message' -ForEach $script:ValidatorAdapterFamilies {
            $family = $_
            $generator = $script:BadPayloadByAdapter[$family.ValidatorAdapter]
            $generator | Should -Not -BeNullOrEmpty -Because "every ValidatorAdapter the live registry names must have a bad-payload fixture wired into this test -- '$($family.ValidatorAdapter)' (family '$($family.Family)') has none; a new adapter type must fail this test loud, never be silently sampled out"

            $marker = ($family.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber" -replace '\{PR\}', "$script:IssueNumber" -replace '\{phase\}', 'plan' -replace '\{port\}', 'plan')
            $badBody = & $generator $marker

            $result = Invoke-PersistMarkerWrite -Family $family.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber `
                -TargetSurface $family.TargetSurface -Marker $marker -Body $badBody

            $result.Success | Should -Be $false -Because "family '$($family.Family)' must refuse this malformed candidate before any network write"
            $result.Reason | Should -Not -BeNullOrEmpty -Because 'a refusal must always carry a diagnosable Reason (893-D6)'
            $result.Reason | Should -Match '(?i)REFUSED' -Because 'the 893-D6 refusal message shape is "persist-marker: REFUSED (...)"'
            $script:PostLog.Count | Should -Be 0 -Because 'a preflight/validator refusal must happen before any network write'
            $script:PatchLog.Count | Should -Be 0 -Because 'a preflight/validator refusal must happen before any network write'
        }

        It 'confirms this suite is registry-parameterized, not a hardcoded family-name list (structural self-check)' {
            # Recomputed here at RUN phase (BeforeEach already dot-sourced
            # the core above) rather than reusing the BeforeDiscovery-phase
            # $script:ValidatorAdapterFamilies driving the -ForEach test
            # above -- Pester's Discovery-phase script-scoped state is not
            # guaranteed to carry into Run-phase Its, so this is an
            # independent, Run-phase re-derivation of the same registry
            # query, not a reuse of Discovery's own computed value.
            $runPhaseValidatorAdapterFamilies = @(Get-MarkerFamilyRegistry | Where-Object { -not [string]::IsNullOrWhiteSpace($_.ValidatorAdapter) })
            $runPhaseValidatorAdapterFamilies.Count | Should -BeGreaterThan 0 -Because 'the live registry must carry at least one ValidatorAdapter-bearing family for the -ForEach test above to be meaningful'
            ($runPhaseValidatorAdapterFamilies | ForEach-Object { $_.Family }) | Should -Contain 'credit-input'
            ($runPhaseValidatorAdapterFamilies | ForEach-Object { $_.Family }) | Should -Contain 'engagement-record'
        }
    }

    Context 'Set-CommentBodyDirect: temp-file lifetime on an abnormal-exit PATCH' {
        It 'removes its --input temp file even when the gh PATCH call itself throws mid-write' {
            # M9 (issue #893 s11): 'design-phase-complete' is now a post-new
            # family (matching the catalog's documented append-only
            # history), so it no longer exercises a PATCH at all -- this
            # test's actual subject is Set-CommentBodyDirect's PATCH
            # temp-file lifetime, which requires an UPSERT family. 'plan-issue'
            # is the vehicle now: its write-back-preserve pre-write post-step
            # is a genuine no-op here (a bare marker + prose body carries no
            # frame-spine block and no ledger pointer to preserve).
            $designFamily = @(Get-MarkerFamilyRegistry | Where-Object { $_.Family -eq 'plan-issue' })[0]
            $marker = ($designFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber")
            Add-MockComment -Id 92500 -Body "$marker`n`nOriginal body."
            $script:SimulatePatchThrowIds.Add(92500) | Out-Null

            {
                Invoke-PersistMarkerWrite -Family $designFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber `
                    -TargetSurface $designFamily.TargetSurface -Marker $marker -Body "$marker`n`nChanged body, must trigger a PATCH."
            } | Should -Throw -Because 'the simulated abnormal PATCH termination must propagate, not be silently swallowed'

            $script:CapturedPatchTempFile | Should -Not -BeNullOrEmpty -Because 'the PATCH call must actually have been reached for this test to be meaningful'
            (Test-Path -LiteralPath $script:CapturedPatchTempFile) | Should -Be $false -Because "Set-CommentBodyDirect's try/finally must remove its --input temp file even when the gh call itself throws mid-write -- an abnormal termination must never leak a scratch file"
        }

        It 'a clean retry after the abnormal-exit write succeeds normally, proving no leaked lock/state corrupts the next run' {
            # M9 (issue #893 s11): 'design-phase-complete' is now a post-new
            # family (matching the catalog's documented append-only
            # history), so it no longer exercises a PATCH at all -- this
            # test's actual subject is Set-CommentBodyDirect's PATCH
            # temp-file lifetime, which requires an UPSERT family. 'plan-issue'
            # is the vehicle now: its write-back-preserve pre-write post-step
            # is a genuine no-op here (a bare marker + prose body carries no
            # frame-spine block and no ledger pointer to preserve).
            $designFamily = @(Get-MarkerFamilyRegistry | Where-Object { $_.Family -eq 'plan-issue' })[0]
            $marker = ($designFamily.MarkerTemplate -replace '\{ID\}', "$script:IssueNumber")
            Add-MockComment -Id 92600 -Body "$marker`n`nOriginal body."
            $script:SimulatePatchThrowIds.Add(92600) | Out-Null

            {
                Invoke-PersistMarkerWrite -Family $designFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber `
                    -TargetSurface $designFamily.TargetSurface -Marker $marker -Body "$marker`n`nFirst attempt, aborts mid-write."
            } | Should -Throw

            # Re-run WITHOUT the simulated throw: a clean retry after an
            # abnormal termination must succeed, proving the interrupted
            # attempt left no corrupting state behind (at minimum, does not
            # silently corrupt a later run -- s7 requirement contract rule
            # 4's floor).
            $script:SimulatePatchThrowIds.Clear()
            $result = Invoke-PersistMarkerWrite -Family $designFamily.Family -Owner $script:Owner -Repo $script:Repo -Number $script:IssueNumber `
                -TargetSurface $designFamily.TargetSurface -Marker $marker -Body "$marker`n`nRetried body after the abnormal termination."

            $result.Success | Should -Be $true -Because 'a clean retry after an abnormal mid-write termination must succeed, not be blocked by a corrupted or leaked temp-file/lock state'
            $result.Action | Should -Be 'updated'
        }
    }
}

Describe 'persist-marker s9 prose/contract drift guard (s7 requirement contract rule 5)' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:WrapperPath = Join-Path $script:RepoRoot 'skills/session-memory-contract/scripts/persist-marker.ps1'
        $script:CoreLibPath = Join-Path $script:RepoRoot 'skills/session-memory-contract/scripts/persist-marker-core.ps1'
        $script:EngagementRecordLibPath = Join-Path $script:RepoRoot '.github/scripts/lib/frame-engagement-record-core.ps1'

        $script:CoreText = Get-Content -LiteralPath $script:CoreLibPath -Raw
        $script:EngagementRecordCoreText = Get-Content -LiteralPath $script:EngagementRecordLibPath -Raw

        $script:RewrittenDocs = @(
            (Join-Path $script:RepoRoot 'agents/Experience-Owner.agent.md'),
            (Join-Path $script:RepoRoot 'agents/Solution-Designer.agent.md'),
            (Join-Path $script:RepoRoot 'agents/Issue-Planner.agent.md'),
            (Join-Path $script:RepoRoot 'skills/session-memory-contract/references/handoff-markers.md'),
            (Join-Path $script:RepoRoot 'Documents/Design/engagement-record-write-discipline.md')
        )
        $script:AgentBodies = $script:RewrittenDocs[0..2]

        $script:RewrittenDocsText = @{}
        foreach ($p in $script:RewrittenDocs) {
            $script:RewrittenDocsText[$p] = Get-Content -LiteralPath $p -Raw
        }

        # Live AST-extracted parameter names -- reused, never re-typed, so
        # this guard can never itself drift from Context 1's own extraction.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:WrapperPath, [ref]$null, [ref]$null)
        $script:LiveWrapperParamNames = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })

        # Live registry family names -- dot-sourcing persist-marker-core.ps1
        # alone is safe here: Get-MarkerFamilyRegistry is a pure data
        # function with no gh call and no dependency on the transport libs
        # at load time.
        . $script:CoreLibPath
        $script:LiveFamilyNames = @(Get-MarkerFamilyRegistry | ForEach-Object { $_.Family })
    }

    It 'the wrapper path every rewritten prose surface cites actually exists' {
        (Test-Path -LiteralPath $script:WrapperPath) | Should -Be $true
        foreach ($p in $script:RewrittenDocs) {
            $script:RewrittenDocsText[$p] | Should -Match ([regex]::Escape('skills/session-memory-contract/scripts/persist-marker.ps1')) -Because "$p must cite the real wrapper path"
        }
    }

    It 'every -Param name quoted inside a persist-marker.ps1 invocation code-span across the 5 rewritten surfaces is a REAL parameter on the live wrapper' {
        $quotedParamNames = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($p in $script:RewrittenDocs) {
            $text = $script:RewrittenDocsText[$p]
            # Scoped to the SAME backtick code span that mentions
            # persist-marker.ps1 -- not the rest of the markdown line, which
            # can carry unrelated backtick-quoted identifiers (e.g.
            # `-InMemoryMarkers`, a DOWNSTREAM consumer's parameter, not the
            # wrapper's own).
            $spanMatches = [regex]::Matches($text, '`([^`]*persist-marker\.ps1[^`]*)`')
            foreach ($span in $spanMatches) {
                # Whitespace-anchored: a real CLI flag is always preceded by
                # a space (or starts the span) -- without this anchor, a
                # hyphenated path SEGMENT inside the same code span (e.g.
                # the literal '-memory-' inside
                # 'skills/session-memory-contract/scripts/persist-marker.ps1')
                # would falsely match as if it were a `-Param` flag.
                $paramMatches = [regex]::Matches($span.Groups[1].Value, '(?:^|\s)-([A-Za-z]+)\b')
                foreach ($pm in $paramMatches) {
                    $null = $quotedParamNames.Add($pm.Groups[1].Value)
                }
            }
        }

        $quotedParamNames.Count | Should -BeGreaterThan 0 -Because 'at least one invocation code-span naming persist-marker.ps1 parameters must exist across the 5 rewritten surfaces for this guard to be meaningful'
        foreach ($name in $quotedParamNames) {
            $script:LiveWrapperParamNames | Should -Contain $name -Because "the rewritten prose quotes '-$name' as a persist-marker.ps1 parameter, but the wrapper's real param() block does not declare it -- this is exactly the s9 drift class this guard exists to catch"
        }
    }

    It 'every marker family the rewritten prose attributes to persist-marker.ps1 (family `...`) is a REAL row in the live Get-MarkerFamilyRegistry' {
        $quotedFamilyNames = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($p in $script:RewrittenDocs) {
            $text = $script:RewrittenDocsText[$p]
            $familyMatches = [regex]::Matches($text, 'family\s+`([a-z][a-z-]*)`')
            foreach ($m in $familyMatches) {
                $null = $quotedFamilyNames.Add($m.Groups[1].Value)
            }
        }

        $quotedFamilyNames.Count | Should -BeGreaterThan 0 -Because 'at least one family attribution must exist across the 5 rewritten surfaces for this guard to be meaningful'
        foreach ($name in $quotedFamilyNames) {
            $script:LiveFamilyNames | Should -Contain $name -Because "the rewritten prose attributes family '$name' to persist-marker.ps1, but the live Get-MarkerFamilyRegistry carries no such row"
        }
    }

    It 'the burst-manifest required-field list quoted identically across the three agent bodies matches persist-marker-core.ps1''s own $requiredFields array, byte-for-byte' {
        $coreRequiredFieldsMatch = [regex]::Match($script:CoreText, '(?s)\$requiredFields\s*=\s*@\((.*?)\)')
        $coreRequiredFieldsMatch.Success | Should -Be $true -Because 'persist-marker-core.ps1 must declare its own $requiredFields array for this guard to compare against'
        $liveRequiredFields = @([regex]::Matches($coreRequiredFieldsMatch.Groups[1].Value, "'([a-zA-Z]+)'") | ForEach-Object { $_.Groups[1].Value })
        $liveRequiredFieldsJoined = $liveRequiredFields -join '/'

        $expectedProseLiteral = 'naming its `family`/`number`/`targetSurface`/`marker`/`bodyFile`'
        foreach ($p in $script:AgentBodies) {
            $text = $script:RewrittenDocsText[$p]
            $text.Contains($expectedProseLiteral) | Should -Be $true -Because "$p must quote the required-field literal list this guard extracts from the live source; if the prose ever paraphrases this list, this assertion must be updated deliberately alongside it, never silently"
        }

        $liveRequiredFieldsJoined | Should -Be 'family/number/targetSurface/marker/bodyFile' -Because 'the prose-quoted list above is pinned to this exact literal order; a live-source drift must fail this test loud'
    }

    It 'the credit-input port enum values quoted per-phase across the three agent bodies (experience/design/plan) all appear in the live $script:CreditInputPortEnum' {
        $enumMatch = [regex]::Match($script:CoreText, "\`$script:CreditInputPortEnum\s*=\s*@\(([^)]*)\)")
        $enumMatch.Success | Should -Be $true -Because 'persist-marker-core.ps1 must declare its own $script:CreditInputPortEnum array for this guard to compare against'
        $liveEnum = @([regex]::Matches($enumMatch.Groups[1].Value, "'([a-z]+)'") | ForEach-Object { $_.Groups[1].Value })

        @('experience', 'design', 'plan') | ForEach-Object {
            $liveEnum | Should -Contain $_ -Because "the corresponding agent body emits 'port: $_' inside its credit-input payload; the live enum must accept it"
        }
    }

    It 'the Test-EngagementRecordSlug regex quoted identically across the three agent bodies and the design doc matches $script:DecisionIdSlugRegex, byte-for-byte' {
        $liveRegexMatch = [regex]::Match($script:EngagementRecordCoreText, "\`$script:DecisionIdSlugRegex\s*=\s*'([^']+)'")
        $liveRegexMatch.Success | Should -Be $true -Because 'frame-engagement-record-core.ps1 must declare $script:DecisionIdSlugRegex for this guard to compare against'
        $liveRegex = $liveRegexMatch.Groups[1].Value

        $docsWithSlugRegex = @($script:AgentBodies) + (Join-Path $script:RepoRoot 'Documents/Design/engagement-record-write-discipline.md')
        foreach ($p in $docsWithSlugRegex) {
            $text = $script:RewrittenDocsText[$p]
            $text.Contains($liveRegex) | Should -Be $true -Because "$p must quote the live Test-EngagementRecordSlug regex verbatim, read from source, not retyped -- a drift here silently breaks slug-validation guidance"
        }
    }

    It 'every rewritten surface still frames persist-marker.ps1 as the ONLY documented write path' {
        foreach ($p in $script:RewrittenDocs) {
            $script:RewrittenDocsText[$p] | Should -Match '(?i)ONLY documented write path' -Because "$p must preserve the 'ONLY documented write path' framing -- this is the exact claim s9 was tasked with establishing"
        }
    }

    It 'every [persist-marker]-attributed family row in handoff-markers.md''s catalog matches the live registry''s WriteShape and TargetSurface (M9 drift guard, issue #893 s11)' {
        # M9 (issue #893 s11): design-phase-complete's WriteShape drifted
        # from the catalog (registry said upsert; catalog said post-new)
        # while every OTHER existing AC13 assertion above stayed green --
        # none of them check WriteShape/TargetSurface at all, only family
        # NAMES and quoted params/literals. This extension closes that
        # blind spot generically: parsed straight from the catalog's own
        # '(family `X`, `Y`)' attribution shape, never a hardcoded
        # family-by-family list, so a family added later with a drifted
        # WriteShape/TargetSurface fails this test loud too.
        $catalogPath = Join-Path $script:RepoRoot 'skills/session-memory-contract/references/handoff-markers.md'
        $catalogText = $script:RewrittenDocsText[$catalogPath]

        # Matches one catalog bullet line at a time: a marker literal ending
        # '-{ID}' or '-{PR}' immediately before the closing '-->', tagged
        # **[persist-marker]**, followed by '(family `name`, `write-shape`'.
        # Every non-review-phase engagement-record row and every other
        # persist-marker row ends its marker literal in '-{ID}'; only
        # review-dispositions and review-judge-produced end in '-{PR}' --
        # the review-phase engagement-record row is deliberately excluded
        # (tagged **[hand-authored -- known v1 registry gap]**, not
        # **[persist-marker]**), matching the registry's own documented
        # scope gap.
        $catalogRowPattern = '(?m)^-\s+`<!--.*?-\{(ID|PR)\}\s*-->`\s+\*\*\[persist-marker\]\*\*\s*\(family\s+`([a-z][a-z-]*)`,\s*`([a-z][a-z-]*)`'
        $catalogRows = @([regex]::Matches($catalogText, $catalogRowPattern))
        $catalogRows.Count | Should -BeGreaterThan 0 -Because 'at least one [persist-marker] catalog row must exist for this guard to be meaningful'

        $liveRegistryByFamily = @{}
        foreach ($row in (Get-MarkerFamilyRegistry)) { $liveRegistryByFamily[$row.Family] = $row }

        foreach ($m in $catalogRows) {
            $placeholderToken = $m.Groups[1].Value
            $family = $m.Groups[2].Value
            $catalogWriteShapeToken = $m.Groups[3].Value
            $expectedWriteShape = if ($catalogWriteShapeToken -eq 'upsert-in-place') { 'upsert' } else { $catalogWriteShapeToken }
            $expectedSurface = if ($placeholderToken -eq 'PR') { 'pull-request' } else { 'issue' }

            $liveRegistryByFamily.ContainsKey($family) | Should -Be $true -Because "handoff-markers.md attributes family '$family' to persist-marker.ps1 but no live Get-MarkerFamilyRegistry row exists"
            $liveRow = $liveRegistryByFamily[$family]
            $liveRow.WriteShape | Should -Be $expectedWriteShape -Because "handoff-markers.md documents family '$family' as '$catalogWriteShapeToken' but the live registry declares WriteShape='$($liveRow.WriteShape)' -- this is exactly the M9 drift class (issue #893 s11)"
            $liveRow.TargetSurface | Should -Be $expectedSurface -Because "handoff-markers.md's '$family' marker template implies TargetSurface='$expectedSurface' (from its '-{$placeholderToken}' placeholder) but the live registry declares TargetSurface='$($liveRow.TargetSurface)'"
        }
    }

    It 'M30 (issue #893 s11): no rewritten surface carries a NEW, non-negated `gh (issue|pr) comment` invocation near a migrated family''s marker literal, excluding the documented [hand-authored] exceptions' {
        # M30 fix: the prior AC13 guards above only ever check that the
        # pinned "ONLY documented write path" phrase is STILL PRESENT
        # somewhere in each rewritten surface -- none of them detect a NEW
        # hand-composed write instruction added ELSEWHERE in an
        # already-covered file that would directly contradict that framing
        # (e.g. a later paragraph telling the agent to just run `gh issue
        # comment` for a marker family this repo migrated to
        # persist-marker.ps1). This scans every migrated family's marker
        # literal for a nearby `gh (issue|pr) comment` invocation that is
        # NOT preceded, within the same proximity window, by an explicit
        # negation/prohibition cue ("never", "not", "no longer", "stays
        # hand-authored", etc.) -- excluding the two s9-carved-out
        # [hand-authored] exceptions (engagement-record-review-{PR},
        # design-issue-{ID}), which legitimately still document a direct
        # `gh pr comment` call.
        $negationPattern = '(?i)(never|\bnot\b|no longer|isn''t|doesn''t|won''t|stays hand-authored)'
        $ghCommandPattern = '`gh (issue|pr) comment'
        $proximityWindow = 300
        $excludedLiteralPattern = 'engagement-record-review-|design-issue-'

        # Prose docs always cite a family's MarkerTemplate in its abstract
        # placeholder form (literal `{ID}`/`{PR}` text), never a substituted
        # concrete number -- match the template LITERALLY (escaped, no
        # wildcarding): the wildcarded form ConvertTo-MarkerFamilyLineStartPattern
        # uses is for scanning LIVE comment bodies with a real substituted
        # id, which is not what these prose surfaces ever contain.
        $migratedFamilyPatterns = @(Get-MarkerFamilyRegistry | ForEach-Object {
                [regex]::Escape($_.MarkerTemplate)
            })

        $violations = [System.Collections.Generic.List[string]]::new()
        foreach ($p in $script:RewrittenDocs) {
            $text = $script:RewrittenDocsText[$p]
            $ghMatches = [regex]::Matches($text, $ghCommandPattern)
            foreach ($ghMatch in $ghMatches) {
                $windowStart = [Math]::Max(0, $ghMatch.Index - $proximityWindow)
                $windowLength = [Math]::Min($text.Length, $ghMatch.Index + $proximityWindow) - $windowStart
                $window = $text.Substring($windowStart, $windowLength)

                $nearMigratedMarker = $false
                foreach ($fp in $migratedFamilyPatterns) {
                    if ($window -match $fp) { $nearMigratedMarker = $true; break }
                }
                if (-not $nearMigratedMarker) { continue }
                if ($window -match $excludedLiteralPattern) { continue }

                # Negation must appear BEFORE the gh-command match (within
                # the window) to count as a genuine prohibition rather than
                # an unrelated negation word elsewhere in the same window.
                $beforeText = $text.Substring($windowStart, $ghMatch.Index - $windowStart)
                if ($beforeText -match $negationPattern) { continue }

                $violations.Add("$p (offset $($ghMatch.Index)): ...$($window.Substring([Math]::Max(0, $ghMatch.Index - $windowStart - 40), [Math]::Min(80, $window.Length)))...") | Out-Null
            }
        }

        $violations | Should -BeNullOrEmpty -Because "a gh (issue|pr) comment invocation was found near a migrated family's marker literal without an explicit negation/prohibition nearby and without being one of the documented [hand-authored] exceptions -- this is exactly the M30 (issue #893 s11) contradicting-instruction class: $($violations -join '; ')"
    }
}
