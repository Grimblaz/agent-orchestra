#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#!
.SYNOPSIS
    Issue #968 AC2 — standing behavioural coverage for the SCRIPT-level
    branches of .github/scripts/migrate-brief-review-corpus.ps1.

.DESCRIPTION
    Before this file, `grep -rn "migrate-brief" .github/scripts/Tests/`
    returned nothing. The script's core library is well covered, but five PR
    #963 fixes added new code to the SCRIPT — line-anchored ledger-sibling
    selection, `gh` stderr capture, the compare-and-swap before the PATCH, the
    captured ShouldProcess decision, and the declined-confirmation refusal —
    and none of them is reachable from Convert-BRMLedgerBody. A revert of any
    one was silent. That gap already cost something concrete: an untested new
    branch turned a declined `-Confirm` from exit 1 into exit 0 under the
    banner "Migration complete and verified at verdict grain."

    ================== READ THIS BEFORE EDITING ==================
    NEVER DOT-SOURCE THE SCRIPT UNDER TEST. It has no dot-source guard —
    unlike frame-credit-ledger.ps1:1643 and
    phase-containment-emission-check.ps1:512, which both gate top-level
    execution on `$MyInvocation.InvocationName -eq '.'`. Dot-sourcing
    migrate-brief-review-corpus.ps1 runs the WHOLE migration body immediately;
    with -Issue omitted that means both live planned issues, real `gh` reads,
    ShouldProcess returning true with no -WhatIf or -Confirm, a live PATCH to
    the real #939 and #941 ledger siblings, and then a top-level `exit` that
    kills the test process. THE DESTRUCTIVE CONFIGURATION IS THE DEFAULT ONE.

    Every test here therefore runs the script as a CHILD PROCESS
    (`pwsh -File`), the shape goal-contract-validate-core.Tests.ps1:2820-2843
    uses for its own wrapper. Three independent things keep the live corpus
    out of reach:

      1. `gh` is a shim on the child's PATH. It is a .cmd wrapping a mock
         script, NOT a PowerShell function: the script sets
         $ErrorActionPreference = 'Stop', so a function-based `gh` signalling
         failure via Write-Error would raise a terminating error BEFORE the
         exit-code check the stderr-capture fix lives in — the test would then
         assert its own stand-in's exception and pass on a reverted tree. A
         native command is also the only thing that sets $LASTEXITCODE, which
         is the variable the fix reads.
      2. -RepoOwner / -RepoName are pointed at a repository that does not
         exist, so even a total shim failure cannot address the real corpus.
      3. The tests that depend on the shim having served the run assert its
         call log positively (`Should -Contain 'PATCH-INVOKED'`, `-Not
         -BeNullOrEmpty`, or a match on the recorded PATCH URL). Scoped
         deliberately: a bare `Should -Not -Contain 'PATCH-INVOKED'` is
         satisfied by an EMPTY log, so it is not evidence the mock served
         anything and is never relied on as such. In those cases the
         protection comes from the output assertions instead — a bypassed
         shim reaches the nonexistent repo, 404s, and throws, so the
         `ABORTED`/`DECLINED`/banner matches fail loudly.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $script:MigrateScript = Join-Path $script:RepoRoot '.github/scripts/migrate-brief-review-corpus.ps1'

    # Libraries only — see the header. The script itself is never loaded here.
    . (Join-Path $script:RepoRoot '.github/scripts/lib/phase-containment-core.ps1')
    . (Join-Path $script:RepoRoot '.github/scripts/lib/phase-containment-emission-check-core.ps1')
    . (Join-Path $script:RepoRoot '.github/scripts/lib/brief-review-migration-core.ps1')

    # A repository that does not exist. Belt and braces behind the shim.
    $script:FakeOwner = 'agent-orchestra-tests-968'
    $script:FakeRepo = 'no-such-repo'

    $script:Sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("brm968-" + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path $script:Sandbox -ErrorAction Stop | Out-Null

    # ---- the gh shim -----------------------------------------------------
    # FAIL CLOSED (finding P-M). Without -ErrorAction Stop a non-terminating
    # creation failure (read-only TEMP, quota, an antivirus lock) let BeforeAll
    # complete, PATH get a nonexistent directory prepended, and the child
    # resolve the REAL gh.exe. The fake owner and repo mean that 404s rather
    # than damaging anything, but detection is not prevention: refuse to run
    # at all rather than run unshimmed.
    $script:ShimDir = Join-Path $script:Sandbox 'shim'
    New-Item -ItemType Directory -Force -Path $script:ShimDir -ErrorAction Stop | Out-Null
    $script:GhShimPath = Join-Path $script:ShimDir 'gh.cmd'
    $script:GhMockPath = Join-Path $script:ShimDir 'gh-mock.ps1'

    # STDIN IS DELIBERATELY PASSED THROUGH (post-review fix, finding P-B). An
    # earlier revision redirected `< nul` here to protect the declined-
    # confirmation test, whose "N" answers the SCRIPT's own ShouldProcess
    # prompt. That also made the `--input -` PATCH payload structurally
    # unreachable, so a mutation writing the WRONG BODY to the comment passed
    # 14/14. Only the PATCH branch of the mock reads stdin, and no PATCH ever
    # happens on the decline path (ShouldProcess is evaluated first), so the
    # "N" still reaches the prompt untouched.
    Set-Content -LiteralPath $script:GhShimPath -Encoding ascii -Value @'
@echo off
pwsh -NoProfile -NoLogo -File "%GHMOCK_SCRIPT%" %*
exit /b %ERRORLEVEL%
'@

    Set-Content -LiteralPath $script:GhMockPath -Encoding utf8 -Value @'
$dir = $env:GHMOCK_DIR
$log = Join-Path $dir 'calls.log'
$line = ($args -join ' ')
Add-Content -LiteralPath $log -Value "CALL $line"

# PATCH first: its URL also matches the single-comment pattern below.
if ($line -match '-X PATCH') {
    Add-Content -LiteralPath $log -Value 'PATCH-INVOKED'
    # Capture WHAT was written, so a test can assert the payload rather than
    # merely that a PATCH happened (finding P-B). The URL is already in the
    # CALL line above, which is how a test observes WHERE it was written.
    $payload = [Console]::In.ReadToEnd()
    Set-Content -LiteralPath (Join-Path $dir 'patch-payload.json') -Value $payload -Encoding utf8
    Write-Output '{}'
    exit 0
}
if ($line -match '/issues/comments/') {
    if ($env:GHMOCK_FAIL_SINGLE -eq '1') {
        [Console]::Error.WriteLine('gh: HTTP 502 Bad Gateway reading single comment')
        exit 5
    }
    Get-Content -Raw -LiteralPath (Join-Path $dir 'single.json')
    exit 0
}
if ($line -match '/comments') {
    if ($env:GHMOCK_FAIL_LIST -eq '1') {
        [Console]::Error.WriteLine('gh: authentication token expired; run gh auth login to reauthenticate')
        exit 4
    }
    if ($env:GHMOCK_STDERR_ON_SUCCESS -eq '1') {
        # A warning on stderr with a ZERO exit — the shape the success-path
        # ErrorRecord strip exists for. Logged as well as emitted: the script
        # captures gh stderr with 2>&1 into its own variable, so the warning
        # never reaches the console and the log is the only way a test can
        # confirm the fixture actually fired.
        Add-Content -LiteralPath $log -Value 'STDERR-ON-SUCCESS-EMITTED'
        [Console]::Error.WriteLine('gh: warning: your authentication token has expiring scopes')
    }
    $after = Join-Path $dir 'comments-after.json'
    if ((Test-Path -LiteralPath $after) -and ((Get-Content -Raw -LiteralPath $log) -match 'PATCH-INVOKED')) {
        Get-Content -Raw -LiteralPath $after
        exit 0
    }
    Get-Content -Raw -LiteralPath (Join-Path $dir 'comments.json')
    exit 0
}
[Console]::Error.WriteLine("gh mock: unexpected invocation: $line")
exit 99
'@

    # Post-condition: both shim files must exist and be non-empty before any
    # test runs. Set-Content above is -ErrorAction Stop by way of this check
    # rather than by suppression, so the failure names what is missing.
    foreach ($required in @($script:GhShimPath, $script:GhMockPath)) {
        if (-not (Test-Path -LiteralPath $required)) {
            throw "gh shim was not created at $required — refusing to run: an unshimmed run would resolve the real gh."
        }
        if ((Get-Item -LiteralPath $required).Length -le 0) {
            throw "gh shim at $required is empty — refusing to run unshimmed."
        }
    }

    function script:Get-968InProcessLoadPattern {
        # Built from fragments for the same reason the positive control is:
        # written out whole, this pattern string would itself be a contiguous
        # literal in a file the scan reads. Matches a dot-source or a call
        # operator applied either to the script path or to the variable this
        # file stores it in, ignoring comment lines.
        $file = 'migrate-brief-review-corpus' + '\.ps1'
        $var = '\$(?:script:)?' + 'MigrateScript'
        return '(?m)^[^#\r\n]*(?<![-\w])[.&]\s+(?:[^\r\n]*' + $file + '|' + $var + ')'
    }

    # ---- fixtures --------------------------------------------------------
    # NOTE: New-968Contaminated below intentionally duplicates
    # script:New-ContaminatedForTail in phase-containment-brief-review.Tests.ps1.
    # The duplication is forced -- Pester test files are not dot-sourceable
    # libraries and .github/scripts/Tests has no shared helper module -- so the
    # two must be kept in step by hand. Both encode the corpus shape that
    # Convert-BRMLedgerBody and Test-BRMCorrectedVerdict consume; if one is
    # updated for a schema change, update the other (finding P-R).
    function script:New-968Contaminated {
        # Same shape as the corpus the migration actually targets: a judge
        # head plus $Rows judge-attributed phase-containment blocks. LF-joined,
        # because Get-PhaseContainmentBlock does not extract blocks from a CRLF
        # body and a CRLF fixture would make every block-grain assertion vacuous.
        param([int]$Issue, [int]$Rows, [string]$Prefix = 'N')
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("<!-- phase-containment-ledger-$Issue -->")
        $lines.Add('')
        $lines.Add('<!-- judge-rulings')
        for ($i = 1; $i -le $Rows; $i++) {
            $lines.Add("- finding_id: ${Prefix}$i")
            $lines.Add('  judge_ruling: sustained')
        }
        $lines.Add('-->')
        $lines.Add('')
        for ($i = 1; $i -le $Rows; $i++) {
            $lines.Add("<!-- phase-containment-$Issue -->")
            $lines.Add("finding_key: plan-stress-test:${Issue}:${Prefix}$i")
            $lines.Add('introduced_phase: design')
            $lines.Add('catchable_phase: plan')
            $lines.Add('caught_stage: plan-stress-test')
            $lines.Add('escape_distance: 0')
            $lines.Add('severity: medium')
            $lines.Add('systemic_fix_type: instruction')
            $lines.Add('category: pattern')
            $lines.Add("<!-- /phase-containment-$Issue -->")
        }
        return ($lines -join "`n") + "`n"
    }

    function script:New-968PlanComment {
        param([int]$Issue)
        "<!-- plan-issue-$Issue -->`n`n---`nspine-omitted: plan-too-small`n---`n`n**Plan Stress-Test**: three lenses.`n"
    }

    # The DECOY. It quotes the ledger marker mid-line, in prose, and sits
    # AHEAD of the real sibling in the corpus — the exact shape a substring
    # .Contains() check selects and a whole-line anchored match does not.
    function script:New-968Decoy {
        param([int]$Issue)
        "Discussion: the <!-- phase-containment-ledger-$Issue --> sibling is where these rows live.`n"
    }

    $script:RealSiblingId = 222
    $script:DecoyId = 111

    function script:New-968CommentsJson {
        param([string[]]$Bodies, [long[]]$Ids)
        $objs = for ($i = 0; $i -lt $Bodies.Count; $i++) { @{ id = $Ids[$i]; body = $Bodies[$i] } }
        return (ConvertTo-Json -InputObject @($objs) -Depth 5)
    }

    # ---- the runner ------------------------------------------------------
    function script:Invoke-Migration {
        param(
            [Parameter(Mandatory)][string]$CommentsJson,
            [string]$SingleJson = '',
            [string]$CommentsAfterJson = '',
            [string[]]$Arguments = @(),
            [hashtable]$MockEnv = @{},
            [string]$StdIn = ''
        )
        $ErrorActionPreference = 'Continue'

        $run = Join-Path $script:Sandbox ("run-" + [guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Force -Path $run | Out-Null
        Set-Content -LiteralPath (Join-Path $run 'comments.json') -Value $CommentsJson -Encoding utf8
        Set-Content -LiteralPath (Join-Path $run 'calls.log') -Value '' -Encoding utf8
        if ($SingleJson) { Set-Content -LiteralPath (Join-Path $run 'single.json') -Value $SingleJson -Encoding utf8 }
        if ($CommentsAfterJson) { Set-Content -LiteralPath (Join-Path $run 'comments-after.json') -Value $CommentsAfterJson -Encoding utf8 }

        $savedPath = $env:PATH
        $savedVars = @{}
        # The UNION of the names this function sets and whatever the caller
        # passes (finding P-O). A fixed enumeration silently leaked any future
        # -MockEnv key that was not on the list; the caller's keys are the ones
        # most likely to be new.
        $touched = @('GHMOCK_DIR', 'GHMOCK_SCRIPT', 'GHMOCK_FAIL_LIST', 'GHMOCK_FAIL_SINGLE', 'GHMOCK_STDERR_ON_SUCCESS') +
        @($MockEnv.Keys) | Select-Object -Unique
        foreach ($k in $touched) {
            $savedVars[$k] = [Environment]::GetEnvironmentVariable($k)
        }
        try {
            $env:PATH = $script:ShimDir + [System.IO.Path]::PathSeparator + $savedPath
            $env:GHMOCK_DIR = $run
            $env:GHMOCK_SCRIPT = $script:GhMockPath
            $env:GHMOCK_FAIL_LIST = ''
            $env:GHMOCK_FAIL_SINGLE = ''
            $env:GHMOCK_STDERR_ON_SUCCESS = ''
            foreach ($k in $MockEnv.Keys) { Set-Item -Path "env:$k" -Value $MockEnv[$k] }

            $pwshArgs = @('-NoProfile', '-NoLogo', '-File', $script:MigrateScript,
                '-RepoOwner', $script:FakeOwner, '-RepoName', $script:FakeRepo) + $Arguments

            # -NonInteractive is deliberately NOT passed: ShouldProcess throws
            # outright in that mode instead of prompting, so a declined
            # confirmation would be unreachable. Every call feeds stdin, so no
            # case can block on an unexpected prompt.
            $raw = ($StdIn + "`n") | & pwsh @pwshArgs 2>&1
            $code = $LASTEXITCODE
        }
        finally {
            $env:PATH = $savedPath
            foreach ($k in $savedVars.Keys) {
                if ($null -eq $savedVars[$k]) { Remove-Item -Path "env:$k" -ErrorAction SilentlyContinue }
                else { Set-Item -Path "env:$k" -Value $savedVars[$k] }
            }
        }

        $text = (@($raw) | ForEach-Object { $_.ToString() }) -join "`n"
        $calls = if (Test-Path -LiteralPath (Join-Path $run 'calls.log')) {
            @(Get-Content -LiteralPath (Join-Path $run 'calls.log'))
        }
        else { @() }
        # The body actually handed to the PATCH, or $null when none happened.
        $payloadPath = Join-Path $run 'patch-payload.json'
        $patchedBody = if (Test-Path -LiteralPath $payloadPath) {
            $payloadRaw = Get-Content -Raw -LiteralPath $payloadPath
            if ([string]::IsNullOrWhiteSpace($payloadRaw)) { '' }
            else { [string](($payloadRaw | ConvertFrom-Json).body) }
        }
        else { $null }

        return [PSCustomObject]@{
            ExitCode    = $code
            Output      = $text
            Calls       = $calls
            PatchedBody = $patchedBody
            RunDir      = $run
        }
    }

    # A #939 corpus: plan comment, decoy, real sibling. 29 rows, matching the
    # planned correction, so the verdict-grain verification passes on the
    # happy path and only the branch under test can move an assertion.
    $script:Corpus939 = script:New-968Contaminated -Issue 939 -Rows 29
    $script:CommentsJson939 = script:New-968CommentsJson `
        -Bodies @((script:New-968PlanComment -Issue 939), (script:New-968Decoy -Issue 939), $script:Corpus939) `
        -Ids @(1, $script:DecoyId, $script:RealSiblingId)
    $script:SingleJson939 = (ConvertTo-Json -InputObject @{ id = $script:RealSiblingId; body = $script:Corpus939 } -Depth 5)
}

AfterAll {
    if ($script:Sandbox -and (Test-Path -LiteralPath $script:Sandbox)) {
        Remove-Item -Recurse -Force -LiteralPath $script:Sandbox -ErrorAction SilentlyContinue
    }
}

Describe '#968 AC2: the harness reaches the script without reaching GitHub' {

    It 'gh resolves to the shim, not to a real gh on PATH' {
        # AC2's evidence obligation is that the run NAMES what `gh` resolved
        # to. Asserted rather than assumed: an accidental live run would
        # otherwise be indistinguishable from a shimmed one in the evidence.
        $savedPath = $env:PATH
        try {
            $env:PATH = $script:ShimDir + [System.IO.Path]::PathSeparator + $savedPath
            $resolved = & pwsh -NoProfile -NoLogo -NonInteractive -Command '(Get-Command gh).Source'
        }
        finally { $env:PATH = $savedPath }
        ([string]$resolved).Trim() | Should -BeExactly $script:GhShimPath
    }

    It 'no test file loads the script in-process, by any spelling' {
        # The one unrecoverable hazard in the chunk, pinned so a later edit
        # that "simplifies" the child-process harness into an in-process load
        # is caught here rather than by a live PATCH to #939 and #941.
        #
        # WIDENED after review (findings P-D and P-N). The first version
        # matched only a dot followed by the literal filename, and so missed
        # BOTH of the forms that are actually likely:
        #   - `. $script:MigrateScript` — the file defines that variable and
        #     spells every other reference through it, so the natural
        #     "simplification" was the one the guard could not see;
        #   - `& $script:MigrateScript` — WORSE than dot-sourcing, because a
        #     call-operator invocation runs the same top-level body in-process
        #     but its `exit 0` returns to the caller instead of killing the
        #     host, so a live PATCH would leave no process death to signal it
        #     and the suite would carry on green.
        # The script-safety-contract AST guard cannot cover either: it keys on
        # the command names `pwsh`/`powershell` and documents variable and
        # indirect invocation as out of scope.
        #
        # Scanning the whole Tests directory, not just this file: the
        # invariant is a property of the SCRIPT, not of one test file.
        $pattern = script:Get-968InProcessLoadPattern
        $offenders = @(
            Get-ChildItem -LiteralPath (Split-Path -Parent $PSCommandPath) -Filter '*.Tests.ps1' |
                Where-Object { [regex]::IsMatch((Get-Content -Raw -LiteralPath $_.FullName), $pattern) } |
                Select-Object -ExpandProperty Name
        )
        $offenders -join ', ' | Should -BeExactly ''
    }

    It 'POSITIVE CONTROL: that scan fires on each planted in-process load form' {
        # Absence claims ship their positive control (this file's own house
        # rule). Without it, a pattern that matched nothing at all would be
        # indistinguishable from a clean tree.
        #
        # EVERY PLANTED FORM IS ASSEMBLED FROM FRAGMENTS, never written as a
        # contiguous literal. Spelling them out would plant them in this very
        # file, which the scan above reads -- the test would then report its
        # own fixtures as offenders and fail. (Observed: it did exactly that.)
        $pattern = script:Get-968InProcessLoadPattern
        $f = 'migrate-brief-review-corpus' + '.ps1'
        $v = '$' + 'script:MigrateScript'
        $d = '.'
        $a = '&'
        foreach ($planted in @(
                "$d (Join-Path `$root '.github/scripts/$f')"
                "$d $v"
                "$a $v"
                "$a `$MigrateScript -WhatIf"
                "    $d $v -Issue 939"
                "$d `"`$PSScriptRoot/../$f`""
            )) {
            [regex]::IsMatch($planted, $pattern) | Should -BeTrue -Because "the guard must catch: $planted"
        }
        # And must NOT fire on the shapes this file legitimately contains.
        foreach ($benign in @(
                "$v = Join-Path `$script:RepoRoot '.github/scripts/$f'"
                "`$pwshArgs = @('-NoProfile', '-File', $v)"
                "# $d $v would be destructive"
                "Split-Path -Parent $v"
            )) {
            [regex]::IsMatch($benign, $pattern) | Should -BeFalse -Because "the guard must not fire on: $benign"
        }
    }
}

Describe '#968 AC2: line-anchored ledger-sibling selection' {

    # ONE child run shared by both assertions. Every invocation here spawns a
    # pwsh plus a gh shim process per API call, which is why this file carries
    # a documented entry in the script-safety-contract allowlist — so runs are
    # shared wherever two assertions read the same run, never duplicated to
    # make the test list look longer (the brief's falsifier 3).
    BeforeAll {
        $script:SelectionRun = script:Invoke-Migration -CommentsJson $script:CommentsJson939 `
            -Arguments @('-Issue', '939', '-WhatIf')
    }

    It 'a comment that merely QUOTES the marker in prose is not selected as the sibling' {
        # migrate-brief-review-corpus.ps1:176-177. The decoy sits ahead of the
        # real sibling in the corpus, so a substring .Contains() check selects
        # it first. -WhatIf, because the observable is which comment id the run
        # names — no write is needed to see it.
        # MUTATION RUN: reverting :177 to `$_.body.Contains($ledgerMarker)`
        # makes the run name the decoy instead.
        $r = $script:SelectionRun
        $r.Output | Should -Match "would rewrite comment $script:RealSiblingId"
        $r.Output | Should -Not -Match "would rewrite comment $script:DecoyId" -Because 'the decoy quotes the marker mid-line and must not win'
        $r.Output | Should -Not -Match 'no comment carrying .* found'
        $r.Calls | Should -Not -BeNullOrEmpty -Because 'the shim served this run — a live gh would have left no log'
    }

    It 'and the run it produces verifies at verdict grain' {
        # The positive control for the case above: without it, "the decoy was
        # not selected" would read the same against a run that selected
        # nothing and fell through.
        $script:SelectionRun.Output | Should -Match 'VERIFIED: renders the planned terminal verdict'
        $script:SelectionRun.ExitCode | Should -Be 0
    }
}

Describe '#968 AC2: a failing gh read surfaces gh''s own message' {

    BeforeAll {
        $script:GhFailRun = script:Invoke-Migration -CommentsJson $script:CommentsJson939 `
            -Arguments @('-Issue', '939', '-WhatIf') -MockEnv @{ GHMOCK_FAIL_LIST = '1' }
    }

    It 'the stderr text rides along in the error rather than a bare exit code' {
        # migrate-brief-review-corpus.ps1:105-109. The whole point of the fix
        # is that an operator does not have to re-run just to learn WHY.
        # MUTATION RUN: reverting `2>&1` to `2>$null` drops the message and
        # leaves only the exit code, turning the first assertion red.
        $r = $script:GhFailRun
        $r.Output | Should -Match 'authentication token expired' -Because "gh's own diagnosis must survive into the thrown error"
        $r.Output | Should -Match 'gh api failed reading comments for issue #939'
        $r.Output | Should -Match 'exit 4' -Because 'the exit code is kept alongside the message, not replaced by it'
        $r.ExitCode | Should -Not -Be 0
        $r.Calls | Should -Not -BeNullOrEmpty
    }

    It 'the message came out of the SCRIPT, not out of the stand-in''s own exception' {
        # Falsifier 8, pinned. A PowerShell-function `gh` signalling failure
        # with Write-Error would raise a terminating error under the script's
        # $ErrorActionPreference = 'Stop' BEFORE the exit-code check the fix
        # lives in — the test would then assert the stand-in's exception and
        # pass against a reverted tree. The script's own throw text is the
        # only proof the exit-code branch was the thing that fired.
        $script:GhFailRun.Output |
            Should -Match 'gh api failed reading comments for issue #939 \(exit 4\): .*authentication token expired'
    }
}

Describe '#968 AC2: every refusal path exits non-zero and withholds the banner' {

    # POST-REVIEW ADDITION (finding P-F). The declined-confirmation branch was
    # pinned; the script's OTHER two `$overallOk = $false` branches were not,
    # so deleting either left all 14 tests green while the run printed its
    # refusal and then exited 0 under "Migration complete and verified at
    # verdict grain." That is exactly the #963 M14 defect -- a refusal reading
    # as a completed migration -- one branch over from the one this chunk was
    # written to close.

    It 'an issue outside the sanctioned bound is REFUSED, not silently completed' {
        # migrate-brief-review-corpus.ps1:154-158. No gh call happens at all:
        # the planned-correction lookup precedes the comment read.
        $r = script:Invoke-Migration -CommentsJson $script:CommentsJson939 -Arguments @('-Issue', '777')

        $r.Output | Should -Match "REFUSED  #777: outside this one-time migration's sanctioned bound"
        $r.Output | Should -Not -Match 'Migration complete and verified at verdict grain'
        $r.Output | Should -Match 'Migration did NOT fully verify'
        $r.ExitCode | Should -Be 1
        $r.Calls | Should -Not -Contain 'PATCH-INVOKED'
    }

    It 'a corpus carrying no ledger sibling FAILS, not silently completes' {
        # migrate-brief-review-corpus.ps1:178-182. The decoy is present, so
        # this also re-confirms the decoy alone cannot satisfy the selection.
        $noSibling = script:New-968CommentsJson `
            -Bodies @((script:New-968PlanComment -Issue 939), (script:New-968Decoy -Issue 939)) `
            -Ids @(1, $script:DecoyId)

        $r = script:Invoke-Migration -CommentsJson $noSibling -Arguments @('-Issue', '939')

        $r.Output | Should -Match 'FAILED: no comment carrying <!-- phase-containment-ledger-939 --> found'
        $r.Output | Should -Not -Match 'Migration complete and verified at verdict grain'
        $r.ExitCode | Should -Be 1
        $r.Calls | Should -Not -Contain 'PATCH-INVOKED'
    }
}

Describe '#968 AC2: the compare-and-swap read surfaces its own gh failure' {

    # POST-REVIEW ADDITION (finding P-G). The item-11 stderr-capture fix has
    # three call sites; only Get-IssueComments was pinned. The mock already
    # carried a GHMOCK_FAIL_SINGLE knob for this and no test ever set it, so
    # reverting the `2>&1` on the compare-and-swap read was silent.

    It 'a failing single-comment re-fetch names gh''s message and the PATCH stage' {
        $r = script:Invoke-Migration -CommentsJson $script:CommentsJson939 -SingleJson $script:SingleJson939 `
            -Arguments @('-Issue', '939') -MockEnv @{ GHMOCK_FAIL_SINGLE = '1' }

        $r.Output | Should -Match 'gh api failed reading comment 222 immediately before PATCH \(exit 5\): .*HTTP 502 Bad Gateway'
        $r.Calls | Should -Not -Contain 'PATCH-INVOKED' -Because 'the compare-and-swap read failed, so nothing may be written'
        $r.ExitCode | Should -Not -Be 0
    }
}

Describe '#968 AC2: a stderr line on a SUCCESSFUL gh read does not break JSON parsing' {

    # The brief records this as a FIFTH observable that no acceptance
    # criterion reaches — reverting it is silent under AC2 as written.
    # Pinned anyway, because it is the same class of gap and costs one test.
    #
    # `2>&1` is what lets the failure path report gh's own message, but it
    # also merges stderr into the success path, where a stderr-on-zero-exit
    # line is prepended to the JSON text and makes ConvertFrom-Json throw a
    # parse error instead. The strip keeps the diagnostic and drops the hazard.
    # MUTATION RUN: removing the ErrorRecord filter at :116 makes this run
    # die on a JSON conversion error.

    It 'the corpus still parses when gh warns on stderr and exits zero' {
        $r = script:Invoke-Migration -CommentsJson $script:CommentsJson939 `
            -Arguments @('-Issue', '939', '-WhatIf') -MockEnv @{ GHMOCK_STDERR_ON_SUCCESS = '1' }

        # The warning is invisible in $r.Output BY DESIGN — the script captures
        # gh stderr into its own variable with 2>&1, which is the very
        # behaviour that creates the hazard. The call log is therefore the
        # positive control: without it, a fixture that silently failed to emit
        # anything would produce exactly this test's green.
        $r.Calls | Should -Contain 'STDERR-ON-SUCCESS-EMITTED' -Because 'the fixture must actually emit the warning, or this proves nothing'
        $r.Output | Should -Match 'VERIFIED: renders the planned terminal verdict'
        $r.Output | Should -Not -Match 'ConvertFrom-Json|Conversion from JSON|Invalid JSON'
        $r.ExitCode | Should -Be 0
    }
}

Describe '#968 AC2: the compare-and-swap immediately before the PATCH' {

    It 'a body that changed between the read and the write ABORTS without patching' {
        # migrate-brief-review-corpus.ps1:207-212. The single-comment re-fetch
        # returns a body carrying a concurrent append, which is the exact
        # window the header documents as "narrowed, not closed".
        # MUTATION RUN: deleting the compare-and-swap block lets the PATCH
        # proceed — PATCH-INVOKED appears in the call log and the run reports
        # "wrote comment 222".
        $concurrent = $script:Corpus939 + "`n<!-- a concurrent append landed here -->`n"
        $single = (ConvertTo-Json -InputObject @{ id = $script:RealSiblingId; body = $concurrent } -Depth 5)

        $r = script:Invoke-Migration -CommentsJson $script:CommentsJson939 -SingleJson $single `
            -Arguments @('-Issue', '939')

        $r.Output | Should -Match "ABORTED: comment $script:RealSiblingId changed since it was read"
        $r.Calls | Should -Not -Contain 'PATCH-INVOKED' -Because 'aborting means not writing'
        $r.Output | Should -Not -Match 'wrote comment'
        $r.Output | Should -Not -Match 'Migration complete and verified'
        $r.ExitCode | Should -Be 1 -Because 'a detected lost update is not a successful migration'
    }

    It 'a concurrent edit differing ONLY in letter case is still detected (ordinal -cne, not -ne)' {
        # PowerShell's `-ne` on strings is case-INSENSITIVE, so a case-only
        # concurrent edit compares EQUAL and sails through the one check whose
        # only job is detecting a lost update.
        # MUTATION RUN: changing `-cne` to `-ne` makes this run PATCH happily —
        # the abort assertion goes red while the test above stays green, which
        # is what separates the ordinal comparison from the check's existence.
        $caseOnly = $script:Corpus939 -replace 'introduced_phase: design', 'introduced_phase: DESIGN'
        $caseOnly | Should -Not -BeExactly $script:Corpus939 -Because 'the fixture must actually differ'
        $single = (ConvertTo-Json -InputObject @{ id = $script:RealSiblingId; body = $caseOnly } -Depth 5)

        $r = script:Invoke-Migration -CommentsJson $script:CommentsJson939 -SingleJson $single `
            -Arguments @('-Issue', '939')

        $r.Output | Should -Match "ABORTED: comment $script:RealSiblingId changed since it was read"
        $r.Calls | Should -Not -Contain 'PATCH-INVOKED'
        $r.ExitCode | Should -Be 1
    }

    It 'POSITIVE CONTROL: an unchanged body PATCHES the RIGHT comment with the RIGHT payload' {
        # Without this, every abort assertion above would read the same
        # against a script that never patched anything under any conditions.
        # This is also the only case that exercises the post-write RE-FETCH
        # branch, so the mock serves the corrected corpus once a PATCH lands.
        #
        # WHAT AND WHERE, NOT MERELY WHETHER (post-review fix, finding P-B).
        # Asserting `PATCH-INVOKED` alone left two mutations to the one
        # irreversible live write passing 14/14: sending the UNCORRECTED body
        # (`-Body ([string]$sibling.body)`) and patching the DECOY comment
        # (`-CommentId ([long]111)`). The run reports `wrote comment 222` and
        # `Migration complete` under both. This is falsifier 6's standard --
        # capture the body handed to the write helper -- applied to the
        # destructive path it matters most on.
        $corrected = (Convert-BRMLedgerBody -Body $script:Corpus939 -Issue 939).Body
        $after = script:New-968CommentsJson `
            -Bodies @((script:New-968PlanComment -Issue 939), (script:New-968Decoy -Issue 939), $corrected) `
            -Ids @(1, $script:DecoyId, $script:RealSiblingId)

        $r = script:Invoke-Migration -CommentsJson $script:CommentsJson939 -SingleJson $script:SingleJson939 `
            -CommentsAfterJson $after -Arguments @('-Issue', '939')

        $r.Output | Should -Match "wrote comment $script:RealSiblingId"
        $r.Calls | Should -Contain 'PATCH-INVOKED'

        # WHERE: the PATCH URL names the real sibling, not the decoy.
        $patchCall = @($r.Calls | Where-Object { $_ -match '-X PATCH' })
        $patchCall.Count | Should -Be 1 -Because 'exactly one write'
        $patchCall[0] | Should -Match "issues/comments/$script:RealSiblingId\b"
        $patchCall[0] | Should -Not -Match "issues/comments/$script:DecoyId\b"

        # WHAT: the payload is the CORRECTED body, byte-for-byte -- not the
        # body that was read, and not something merely brief-head-shaped.
        $r.PatchedBody | Should -BeExactly $corrected
        $r.PatchedBody | Should -Not -BeExactly $script:Corpus939 -Because 'writing back the uncorrected body must not read as success'

        $r.Output | Should -Match 'VERIFIED: renders the planned terminal verdict'
        $r.Output | Should -Match 'Migration complete and verified at verdict grain'
        $r.ExitCode | Should -Be 0
    }

    It 'the post-write verification FAILS when the corpus does not render the planned verdict' {
        # The negative case the verdict-grain re-parse never had (finding P-H,
        # merged into P-B). That re-parse is the script's stated reason for
        # existing -- it catches a write that landed in the wrong shape -- and
        # every other run in this file feeds it a corpus that is correct by
        # construction, so nothing showed it could fail at all.
        # Here the post-PATCH re-fetch serves the UNCORRECTED corpus, which is
        # what the tree would look like if the write had silently not landed.
        $stillContaminated = script:New-968CommentsJson `
            -Bodies @((script:New-968PlanComment -Issue 939), (script:New-968Decoy -Issue 939), $script:Corpus939) `
            -Ids @(1, $script:DecoyId, $script:RealSiblingId)

        $r = script:Invoke-Migration -CommentsJson $script:CommentsJson939 -SingleJson $script:SingleJson939 `
            -CommentsAfterJson $stillContaminated -Arguments @('-Issue', '939')

        $r.Calls | Should -Contain 'PATCH-INVOKED' -Because 'the write is attempted; it is the VERIFICATION that must fail'
        $r.Output | Should -Match 'VERIFICATION FAILED'
        $r.Output | Should -Not -Match 'VERIFIED: renders the planned terminal verdict'
        $r.Output | Should -Not -Match 'Migration complete and verified at verdict grain'
        $r.ExitCode | Should -Be 1
    }
}

Describe '#968 AC2: a declined confirmation is a refusal, not a dry run' {

    # THIS IS TWO FIXES, NOT ONE, and a test written to only one of them is
    # green on the other's reverted tree (the brief's falsifier 7):
    #   - the non-zero exit and the withheld banner are carried by the
    #     `$overallOk = $false` assignment at :238;
    #   - which corpus gets VERIFIED is carried by the `$didWrite` capture at
    #     :190 / :252.
    # Both are pinned below, separately, and each names which one it is.

    BeforeAll {
        $script:Declined = script:Invoke-Migration -CommentsJson $script:CommentsJson939 `
            -SingleJson $script:SingleJson939 -Arguments @('-Issue', '939', '-Confirm') -StdIn 'N'
    }

    It 'the prompt was actually reached and declined' {
        # Guards every assertion below: if ShouldProcess had never prompted,
        # or had thrown, the run would fail for reasons unrelated to the fixes.
        $script:Declined.Output | Should -Match 'DECLINED: the write to comment 222 was not confirmed'
        $script:Declined.Calls | Should -Not -Contain 'PATCH-INVOKED' -Because 'a decline must not write'
    }

    It 'the run exits non-zero and withholds the completion banner ($overallOk)' {
        # MUTATION RUN: deleting `$overallOk = $false` at :238 restores the
        # regression the fix removed — exit 0 under "Migration complete and
        # verified at verdict grain", which an automation wrapper keying on
        # $LASTEXITCODE reads as a completed migration.
        $script:Declined.ExitCode | Should -Be 1
        $script:Declined.Output | Should -Not -Match 'Migration complete and verified at verdict grain'
        $script:Declined.Output | Should -Match 'Migration did NOT fully verify'
    }

    It 'verification runs against the PROPOSED corpus, not a re-fetch ($didWrite)' {
        # The observable $didWrite ALONE moves. Nothing wrote, so the corrected
        # body exists only as a proposal; verifying it is what makes the run
        # report VERIFIED. MUTATION RUN: reverting :252 to the old
        # `$WhatIfPreference -or -not $result.Changed` inference sends a
        # decline down the re-fetch branch, which re-reads the UNCHANGED corpus
        # and renders VERIFICATION FAILED — while the exit code and the
        # withheld banner, which the test above pins, do not move at all.
        $script:Declined.Output | Should -Match 'VERIFIED: renders the planned terminal verdict'
        $script:Declined.Output | Should -Not -Match 'VERIFICATION FAILED'
    }

    It 'CONTRAST: a plain -WhatIf dry run is NOT a refusal — exit 0, banner present' {
        # $overallOk is set in the decline branch rather than in a shared else
        # precisely so this stays true. Without this contrast, the decline
        # assertions would also be satisfied by a script that failed every run.
        $r = script:Invoke-Migration -CommentsJson $script:CommentsJson939 -Arguments @('-Issue', '939', '-WhatIf')
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Migration complete and verified at verdict grain'
        $r.Output | Should -Not -Match 'DECLINED'
        $r.Calls | Should -Not -Contain 'PATCH-INVOKED'
    }
}
