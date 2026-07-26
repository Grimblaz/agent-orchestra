#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    #912 plan step 8: integration coverage for the resume/admission path
    that answers the plan stress-test's sharpest finding (M2/M5) -- the
    pre-revision draft's tests asserted only Resolve-GoalRunResumeStage's
    output in isolation, so every acceptance criterion could pass green
    while the flagship scenario (an interrupted run being admitted at all)
    failed at the invocation gate.
.DESCRIPTION
    Every fixture in this file starts at Resolve-GoalRunInvocationAction
    (the admission gate landed in #912 plan step 2/4) and only THEN, when
    admission allows it, proceeds to Resolve-GoalRunResumeStage and (where
    applicable) the loop-interrupted branch logic described in
    agents/Goal-Run.agent.md's "### loop-interrupted (resume without a
    transcript)" section -- as a single flow per fixture, built from
    constructed durable state (a comment corpus + a real goal-run-active.json
    file on disk) rather than by calling any single resolver directly with
    hand-picked parameters.

    IMPORTANT SHAPE NOTE (per dispatch instruction): there is no single
    callable "loop-interrupted stage" function to invoke directly. The
    branch logic described in Goal-Run.agent.md's loop-interrupted section
    is agent PROSE, not a function -- it composes Get-GoalRunActiveState,
    Invoke-GoalRunChainRevalidate, Test-GoalRunInflightAppearsDead,
    Set-GoalRunStageMarker, New-GoalRunChainHaltReport, and
    Invoke-GoalRunHaltEmit in a specific sequence. This file's two test
    helpers (script:Invoke-GRIAdmissionGate, script:Invoke-GRILoopInterrupted)
    are thin, test-local glue that call those REAL underlying functions in
    the exact sequence the prose describes -- they are not a fiction of a
    unified production entry point that does not exist, and they are not
    themselves the thing under test.

    Two genuine gaps this file's fixtures originally surfaced between the
    approved plan's I5/I10 wording and the actual shipped
    agents/Goal-Run.agent.md prose (I5: resolve-and-report-complete never
    resolved the held marker; I10: no guard against unparseable marker
    fields) have since been closed in the agent body -- the I5/I10
    Describe blocks below now assert the FIXED behavior rather than
    documenting the gap as still-open.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:StageLibPath = Join-Path $script:RepoRoot '.github/scripts/lib/goal-run-stage-core.ps1'
    $script:ChainLibPath = Join-Path $script:RepoRoot '.github/scripts/lib/goal-run-chain-core.ps1'
    . $script:StageLibPath
    . $script:ChainLibPath

    $script:GRIIssue = 912
    $script:GRIContractHash = ('a' * 64)

    function script:New-GRIWorktree {
        param([string]$Name = ([guid]::NewGuid().ToString('N')))
        $path = Join-Path $TestDrive "gri-$Name"
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        return $path
    }

    function script:Write-GRIActiveState {
        <#
        Writes a real goal-run-active.json file on disk (not mocked) so
        Get-GoalRunActiveState's own file-read/parse logic runs for real in
        every fixture -- this is the file I8/I9 delete/truncate later.
        #>
        param(
            [Parameter(Mandatory)][string]$WorktreePath,
            [string]$LaunchedAt,
            [string]$HeartbeatAt,
            [string]$ContractHash = $script:GRIContractHash,
            [switch]$Truncated
        )
        $statePath = Join-Path $WorktreePath 'goal-run-active.json'
        if ($Truncated) {
            # Deliberately invalid/incomplete JSON -- reproduces the
            # PRESENT-and-corrupt case Get-GoalRunActiveState's own
            # ConvertFrom-Json call throws on (unlike an absent file, which
            # it safely returns $null for).
            Set-Content -LiteralPath $statePath -Value '{"ceilings": {} , "baseline": {' -Encoding utf8 -NoNewline
            return
        }
        $state = [ordered]@{
            ceilings            = @{}
            baseline            = @{}
            arm                 = 'in-session'
            executor_session_id = 'sess-fixture'
            contract_hash       = $ContractHash
            launched_at         = $LaunchedAt
            heartbeat_at        = $HeartbeatAt
            teardown_deferred   = $false
        } | ConvertTo-Json -Depth 10
        Set-Content -LiteralPath $statePath -Value $state -Encoding utf8 -NoNewline
    }

    function script:New-GRICommentsCorpus {
        <#
        Builds a comment array in the Get-GoalRunIssueComments-normalized
        shape ({id; url; body; updatedAt}). Every reader in
        goal-run-stage-core.ps1 that this file exercises
        (Get-GoalRunInflightMarkers, Get-GoalRunStageMarker,
        Resolve-GoalRunInflightMarkerForResolution) is driven by mocking
        Get-GoalRunIssueComments to return exactly this corpus -- one
        constructed comment set answers every reader consistently, which is
        the "durable state" this step's requirement contract calls for,
        rather than hand-picked function arguments per reader.
        #>
        param(
            [string]$InflightBody,
            [string]$StageBody,
            [string]$HaltReportBody
        )
        $comments = [System.Collections.Generic.List[pscustomobject]]::new()
        $id = 100
        foreach ($body in @($InflightBody, $StageBody, $HaltReportBody)) {
            if ($body) {
                $comments.Add([pscustomobject]@{
                        id        = $id
                        url       = "https://github.com/o/r/issues/$($script:GRIIssue)#issuecomment-$id"
                        body      = $body
                        updatedAt = (Get-Date).ToUniversalTime().ToString('o')
                    }) | Out-Null
                $id++
            }
        }
        return $comments.ToArray()
    }

    function script:Invoke-GRIAdmissionGate {
        <#
        .SYNOPSIS
            Mirrors agents/Goal-Run.agent.md's Invocation Contract step 2
            EXACTLY: Get-GoalRunInflightMarkers -> (if any marker has
            Status: unresolved) guard the winning marker's fields via
            Resolve-GoalRunInflightMarkerForResolution -> read
            goal-run-active.json + halt-report/PR existence ->
            Test-GoalRunInflightAppearsDead -> Resolve-GoalRunInvocationAction
            -> on resolve-and-report-complete, resolve the held marker
            before reporting, reusing the guard's already-fetched result.
            Both marker-resolution gaps an earlier draft of this file
            flagged (I5, I10) are now wired into the prose and mirrored
            here.
        #>
        param(
            [Parameter(Mandatory)][string]$WorktreePath,
            [datetime]$Now = (Get-Date).ToUniversalTime(),
            [bool]$PrExists = $false,
            [bool]$ForceAdopt = $false
        )

        $markers = Get-GoalRunInflightMarkers -Issue $script:GRIIssue
        $unresolved = @($markers | Where-Object { $_.Status -eq 'unresolved' })
        if ($unresolved.Count -eq 0) {
            $action = Resolve-GoalRunInvocationAction -ExistingUnresolvedMarker $null -AppearsDead $false
            return [pscustomobject]@{ Action = $action.Action; Reason = $action.Reason; Marker = $null; Appears = $null; ForResolution = $null }
        }
        $marker = $unresolved | Select-Object -First 1

        # Guard (I10 fix): validate the winning unresolved marker's fields
        # BEFORE they reach Test-GoalRunInflightAppearsDead's Mandatory,
        # non-nullable [datetime] -LaunchedAt parameter. A marker whose
        # body parsed (Parsed: $true) but whose contract_hash/launched_at
        # came back $null (hand-edited or truncated body) used to reach
        # that parameter unguarded and throw a raw
        # ParameterBindingArgumentTransformationException.
        $forResolution = Resolve-GoalRunInflightMarkerForResolution -Issue $script:GRIIssue
        if ($forResolution.Reason -eq 'marker-fields-unparseable') {
            return [pscustomobject]@{ Action = 'refuse-unparseable-marker'; Reason = $forResolution.Reason; Marker = $marker; Appears = $null; ForResolution = $forResolution }
        }

        $haltMarker = "<!-- goal-halt-report-$($script:GRIIssue) -->"
        $comments = Get-GoalRunIssueComments -Issue $script:GRIIssue
        $haltReportExists = [bool](@($comments) | Where-Object { $_.body -and ($_.body -like "*$haltMarker*") })

        $activeState = $null
        try { $activeState = Get-GoalRunActiveState -WorktreePath $WorktreePath } catch { $activeState = $null }
        $heartbeatAt = if ($activeState -and $activeState.heartbeat_at) { $activeState.heartbeat_at } else { $null }

        $appears = Test-GoalRunInflightAppearsDead -MarkerStatus $marker.Status -LaunchedAt $marker.LaunchedAt `
            -HeartbeatAt $heartbeatAt -HaltReportExists $haltReportExists -PrExists $PrExists -Now $Now

        $action = Resolve-GoalRunInvocationAction -ExistingUnresolvedMarker $marker -AppearsDead $appears.AppearsDead `
            -TerminalOutcomePresent $appears.TerminalOutcomePresent -ForceAdopt:$ForceAdopt

        if ($action.Action -eq 'resolve-and-report-complete' -and $forResolution.Found) {
            # I5 fix: resolve the held marker before reporting, reusing the
            # guard's already-fetched result -- the same resolve-before-
            # report pattern the pre-loop launch-pin halt demonstrates.
            Set-GoalRunInflightMarkerResolved -CommentId $forResolution.CommentId -Issue $script:GRIIssue `
                -ContractHash $forResolution.ContractHash -LaunchedAt $forResolution.LaunchedAt -ResolvedReason 'stale-terminal-outcome' | Out-Null
        }

        return [pscustomobject]@{ Action = $action.Action; Reason = $action.Reason; Marker = $marker; Appears = $appears; ForResolution = $forResolution }
    }

    function script:Invoke-GRILoopInterrupted {
        <#
        .SYNOPSIS
            Composes the underlying functions in the EXACT sequence
            agents/Goal-Run.agent.md's "### loop-interrupted (resume
            without a transcript)" section describes (guard the
            active-state read -> Invoke-GoalRunChainRevalidate -> branch on
            Disposition). See this file's header .DESCRIPTION for why there
            is no single production function this could call instead.
        #>
        param(
            [Parameter(Mandatory)][string]$WorktreePath,
            [Parameter(Mandatory)][string]$LaunchPinnedHash,
            [scriptblock]$PinCheck,
            [scriptblock]$ValidatorInvoker,
            [datetime]$Now = (Get-Date).ToUniversalTime(),
            [int]$StaleThresholdMinutes = 60
        )

        # Step 1: guard the active-state read (Goal-Run.agent.md line 102).
        $activeState = $null
        $readThrew = $false
        try {
            $activeState = Get-GoalRunActiveState -WorktreePath $WorktreePath
        }
        catch {
            $readThrew = $true
        }
        if ($readThrew -or $null -eq $activeState) {
            Resolve-GoalRunInflightMarkerForResolution -Issue $script:GRIIssue | Out-Null
            $report = New-GoalRunChainHaltReport -Issue $script:GRIIssue -HaltReason 'chain-stage-failure' -Stage 'loop' `
                -PlanRemediation 'goal-run-active.json could not be read from the provisioned worktree, so the launch-pinned contract hash and heartbeat are unavailable. Investigate the worktree state directly.' `
                -Evidence @('goal-run-active-state-unreadable')
            $haltResult = Invoke-GoalRunHaltEmit -Report $report -Issue $script:GRIIssue -RepoRoot $script:RepoRoot
            return [pscustomobject]@{ Outcome = 'halted'; HaltReason = 'chain-stage-failure'; ReadThrew = $readThrew; HaltResult = $haltResult; Revalidate = $null }
        }

        # Step 2: re-validate BEFORE any chain-stage-boundary housekeeping.
        $revalidate = Invoke-GoalRunChainRevalidate -Issue $script:GRIIssue -RepoRoot $WorktreePath -LaunchPinnedHash $LaunchPinnedHash `
            -PinCheck $PinCheck -ValidatorInvoker $ValidatorInvoker

        if ($revalidate.Disposition -eq 'satisfied') {
            Set-GoalRunStageMarker -Issue $script:GRIIssue -Stage 'loop-released' -ContractHash $LaunchPinnedHash -WorktreePath $WorktreePath | Out-Null
            return [pscustomobject]@{ Outcome = 'loop-released'; Revalidate = $revalidate }
        }

        $treeStateRefusal = [bool](@($revalidate.Refusals) | Where-Object { $_ -match 'uncommitted-changes|no-run-diff' })

        if ($revalidate.Disposition -eq 'not-satisfied' -or ($revalidate.Disposition -eq 'halt' -and $treeStateRefusal)) {
            # Re-check liveness before concluding the loop is genuinely gone
            # -- the SAME elapsed-time math Test-GoalRunInflightAppearsDead
            # uses, re-run against a FRESH read of goal-run-active.json.
            $reread = Get-GoalRunActiveState -WorktreePath $WorktreePath
            $liveness = Test-GoalRunInflightAppearsDead -MarkerStatus 'unresolved' -LaunchedAt $reread.launched_at `
                -HeartbeatAt $reread.heartbeat_at -HaltReportExists $false -PrExists $false -Now $Now -StaleThresholdMinutes $StaleThresholdMinutes

            if ($liveness.AppearsDead) {
                Set-GoalRunStageMarker -Issue $script:GRIIssue -Stage 'loop-launched' -ContractHash $LaunchPinnedHash -WorktreePath $WorktreePath | Out-Null
                return [pscustomobject]@{ Outcome = 'relaunch'; Revalidate = $revalidate; Liveness = $liveness }
            }
            return [pscustomobject]@{ Outcome = 'reported-live-under-different-session'; Revalidate = $revalidate; Liveness = $liveness }
        }

        if ($revalidate.Disposition -eq 'halt' -and $revalidate.Reason -match '^contract-(comment|block)-unresolvable') {
            $report = New-GoalRunChainHaltReport -Issue $script:GRIIssue -HaltReason 'chain-stage-failure' -Stage 'loop' `
                -PlanRemediation 'The launch-pinned contract could not be read back for re-validation.' -Evidence @([string]$revalidate.Reason)
            $haltResult = Invoke-GoalRunHaltEmit -Report $report -Issue $script:GRIIssue -RepoRoot $script:RepoRoot
            return [pscustomobject]@{ Outcome = 'halted'; HaltReason = 'chain-stage-failure'; HaltResult = $haltResult; Revalidate = $revalidate }
        }

        # Any other halt: genuine invariant-conflict, infra-error, or an
        # unrecognized exit code -- emit exactly as returned.
        Resolve-GoalRunInflightMarkerForResolution -Issue $script:GRIIssue | Out-Null
        $report = New-GoalRunChainHaltReport -Issue $script:GRIIssue -HaltReason $revalidate.HaltReason -Stage 'loop' `
            -PlanRemediation 'Chain re-validation halted on resume.' -Evidence @([string]$revalidate.Reason)
        $haltResult = Invoke-GoalRunHaltEmit -Report $report -Issue $script:GRIIssue -RepoRoot $script:RepoRoot
        return [pscustomobject]@{ Outcome = 'halted'; HaltReason = $revalidate.HaltReason; HaltResult = $haltResult; Revalidate = $revalidate }
    }

    $script:GRISatisfiedPinCheck = { param($Issue, $LaunchPinnedHash, $Marker, $RepoRoot, $Repo, $GhCliPath, $GitCliPath) [pscustomobject]@{ Pinned = $true; Reason = $null; LiveHash = $LaunchPinnedHash } }
}

Describe 'goal-run-resume-integration.ps1: libs resolve' -Tag 'unit' {
    It 'both underlying libs exist' {
        (Test-Path -LiteralPath $script:StageLibPath) | Should -Be $true
        (Test-Path -LiteralPath $script:ChainLibPath) | Should -Be $true
    }
}

Describe '#912 s8 I1: loop-launched marker + stale heartbeat + satisfying work -> admitted, then satisfied -> loop-released' -Tag 'unit' {
    It 'starts at Resolve-GoalRunInvocationAction and only proceeds to the resolver once admission allows it' {
        $wt = script:New-GRIWorktree -Name 'i1'
        $now = (Get-Date).ToUniversalTime()
        $launchedAt = $now.AddHours(-3).ToString('o')
        $staleHeartbeat = $now.AddHours(-2).ToString('o')
        script:Write-GRIActiveState -WorktreePath $wt -LaunchedAt $launchedAt -HeartbeatAt $staleHeartbeat

        $inflightBody = New-GoalRunInflightMarkerBody -Issue $script:GRIIssue -ContractHash $script:GRIContractHash -LaunchedAt $launchedAt -Status 'unresolved'
        $stageBody = New-GoalRunStageMarkerBody -Issue $script:GRIIssue -Stage 'loop-launched' -ContractHash $script:GRIContractHash -UpdatedAt $launchedAt -WorktreePath $wt
        Mock -CommandName Get-GoalRunIssueComments -MockWith { script:New-GRICommentsCorpus -InflightBody $inflightBody -StageBody $stageBody }
        Mock -CommandName Set-GoalRunInflightMarkerAdopted -MockWith { [pscustomobject]@{ Success = $true; Verified = $true; Reason = 'adopted-and-verified'; AdoptedBySessionId = 'sess-fixture' } }
        $script:i1SetStageCalls = [System.Collections.Generic.List[string]]::new()
        Mock -CommandName Set-GoalRunStageMarker -MockWith {
            param($Issue, $Stage, $ContractHash, $WorktreePath, $Owner, $Repo)
            $script:i1SetStageCalls.Add($Stage) | Out-Null
            [pscustomobject]@{ Success = $true; Url = 'https://example/x'; Stage = $Stage; UpdatedAt = (Get-Date).ToString('o'); WorktreePath = $WorktreePath }
        }

        # --- Admission gate (Invocation Contract step 2) ---
        $admission = script:Invoke-GRIAdmissionGate -WorktreePath $wt -Now $now
        $admission.Action | Should -Be 'adopt-and-resume'
        Set-GoalRunInflightMarkerAdopted -CommentId $admission.Marker.CommentId -Issue $script:GRIIssue `
            -ContractHash $script:GRIContractHash -LaunchedAt $launchedAt -SessionId 'sess-fixture' | Out-Null

        # --- Resolve resume stage (Invocation Contract step 3) ---
        $stageMarker = Get-GoalRunStageMarker -Issue $script:GRIIssue
        $resume = Resolve-GoalRunResumeStage -ContractHashVerified $true -InflightMarkerPresent $true `
            -ActiveStatePresent $true -RunLogHasCheckpoint $false -ExplicitStageMarker $stageMarker.Stage
        $resume.ResumeStage | Should -Be 'loop-interrupted'

        # --- loop-interrupted branch: satisfying work ---
        $validator = { param($Issue, $RepoRoot, $PwshCliPath, $ValidatorScriptPath) [pscustomobject]@{ ExitCode = 0; Reason = $null } }
        $result = script:Invoke-GRILoopInterrupted -WorktreePath $wt -LaunchPinnedHash $script:GRIContractHash `
            -PinCheck $script:GRISatisfiedPinCheck -ValidatorInvoker $validator -Now $now

        $result.Outcome | Should -Be 'loop-released'
        $result.Revalidate.Disposition | Should -Be 'satisfied'
        $script:i1SetStageCalls | Should -Contain 'loop-released'
    }
}

Describe '#912 s8 I2: loop-launched marker + stale heartbeat + non-satisfying work -> admitted, then not-satisfied + stale liveness -> relaunch' -Tag 'unit' {
    It 'starts at Resolve-GoalRunInvocationAction, resolves loop-interrupted, and relaunches once not-satisfied is confirmed AND the loop still appears dead' {
        $wt = script:New-GRIWorktree -Name 'i2'
        $now = (Get-Date).ToUniversalTime()
        $launchedAt = $now.AddHours(-3).ToString('o')
        $staleHeartbeat = $now.AddHours(-2).ToString('o')
        script:Write-GRIActiveState -WorktreePath $wt -LaunchedAt $launchedAt -HeartbeatAt $staleHeartbeat

        $inflightBody = New-GoalRunInflightMarkerBody -Issue $script:GRIIssue -ContractHash $script:GRIContractHash -LaunchedAt $launchedAt -Status 'unresolved'
        $stageBody = New-GoalRunStageMarkerBody -Issue $script:GRIIssue -Stage 'loop-launched' -ContractHash $script:GRIContractHash -UpdatedAt $launchedAt -WorktreePath $wt
        Mock -CommandName Get-GoalRunIssueComments -MockWith { script:New-GRICommentsCorpus -InflightBody $inflightBody -StageBody $stageBody }
        Mock -CommandName Set-GoalRunInflightMarkerAdopted -MockWith { [pscustomobject]@{ Success = $true; Verified = $true; Reason = 'adopted-and-verified'; AdoptedBySessionId = 'sess-fixture' } }
        $script:i2SetStageCalls = [System.Collections.Generic.List[string]]::new()
        Mock -CommandName Set-GoalRunStageMarker -MockWith {
            param($Issue, $Stage, $ContractHash, $WorktreePath, $Owner, $Repo)
            $script:i2SetStageCalls.Add($Stage) | Out-Null
            [pscustomobject]@{ Success = $true; Url = 'https://example/x'; Stage = $Stage; UpdatedAt = (Get-Date).ToString('o'); WorktreePath = $WorktreePath }
        }

        $admission = script:Invoke-GRIAdmissionGate -WorktreePath $wt -Now $now
        $admission.Action | Should -Be 'adopt-and-resume'
        Set-GoalRunInflightMarkerAdopted -CommentId $admission.Marker.CommentId -Issue $script:GRIIssue `
            -ContractHash $script:GRIContractHash -LaunchedAt $launchedAt -SessionId 'sess-fixture' | Out-Null

        $stageMarker = Get-GoalRunStageMarker -Issue $script:GRIIssue
        $resume = Resolve-GoalRunResumeStage -ContractHashVerified $true -InflightMarkerPresent $true `
            -ActiveStatePresent $true -RunLogHasCheckpoint $false -ExplicitStageMarker $stageMarker.Stage
        $resume.ResumeStage | Should -Be 'loop-interrupted'

        $validator = { param($Issue, $RepoRoot, $PwshCliPath, $ValidatorScriptPath) [pscustomobject]@{ ExitCode = 1; Reason = $null } }
        $result = script:Invoke-GRILoopInterrupted -WorktreePath $wt -LaunchPinnedHash $script:GRIContractHash `
            -PinCheck $script:GRISatisfiedPinCheck -ValidatorInvoker $validator -Now $now

        $result.Outcome | Should -Be 'relaunch'
        $result.Revalidate.Disposition | Should -Be 'not-satisfied'
        $result.Liveness.AppearsDead | Should -Be $true
        $script:i2SetStageCalls | Should -Contain 'loop-launched'
    }
}

Describe '#912 s8 I3: loop-launched marker + FRESH heartbeat -> refused as live at the ADMISSION GATE, never reaches the resolver' -Tag 'unit' {
    It 'the admission gate refuses explicitly on the returned Action; Resolve-GoalRunResumeStage is provably never invoked' {
        $wt = script:New-GRIWorktree -Name 'i3'
        $now = (Get-Date).ToUniversalTime()
        $launchedAt = $now.AddHours(-3).ToString('o')
        $freshHeartbeat = $now.AddMinutes(-2).ToString('o')
        script:Write-GRIActiveState -WorktreePath $wt -LaunchedAt $launchedAt -HeartbeatAt $freshHeartbeat

        $inflightBody = New-GoalRunInflightMarkerBody -Issue $script:GRIIssue -ContractHash $script:GRIContractHash -LaunchedAt $launchedAt -Status 'unresolved'
        $stageBody = New-GoalRunStageMarkerBody -Issue $script:GRIIssue -Stage 'loop-launched' -ContractHash $script:GRIContractHash -UpdatedAt $launchedAt -WorktreePath $wt
        Mock -CommandName Get-GoalRunIssueComments -MockWith { script:New-GRICommentsCorpus -InflightBody $inflightBody -StageBody $stageBody }
        # Defense-in-depth only -- the load-bearing assertion below is the
        # explicit Action check, not this mock's call count (per the
        # dispatch instruction: never infer a refusal from absence alone).
        Mock -CommandName Resolve-GoalRunResumeStage -MockWith { throw 'must not reach the resolver -- a fresh heartbeat refuses at the admission gate' }

        $admission = script:Invoke-GRIAdmissionGate -WorktreePath $wt -Now $now

        $admission.Action | Should -Be 'refuse-resume-existing' -Because 'a fresh heartbeat is live-run protection, checked on the returned Action explicitly'
        $admission.Appears.AppearsDead | Should -Be $false
        Should -Invoke -CommandName Resolve-GoalRunResumeStage -Times 0
    }
}

Describe '#912 s8 I4: unresolved marker + halt report + FRESH heartbeat -> refused as live (critical live-run-protection regression case)' -Tag 'unit' {
    It 'a terminal outcome already existing does NOT override a fresh heartbeat -- the admission gate still refuses explicitly' {
        $wt = script:New-GRIWorktree -Name 'i4'
        $now = (Get-Date).ToUniversalTime()
        $launchedAt = $now.AddHours(-3).ToString('o')
        $freshHeartbeat = $now.AddMinutes(-2).ToString('o')
        script:Write-GRIActiveState -WorktreePath $wt -LaunchedAt $launchedAt -HeartbeatAt $freshHeartbeat

        $inflightBody = New-GoalRunInflightMarkerBody -Issue $script:GRIIssue -ContractHash $script:GRIContractHash -LaunchedAt $launchedAt -Status 'unresolved'
        $haltReportBody = "<!-- goal-halt-report-$($script:GRIIssue) -->`n## Goal-run halt report`n`nfixture halt report"
        Mock -CommandName Get-GoalRunIssueComments -MockWith { script:New-GRICommentsCorpus -InflightBody $inflightBody -HaltReportBody $haltReportBody }
        Mock -CommandName Resolve-GoalRunResumeStage -MockWith { throw 'must not reach the resolver -- a fresh heartbeat refuses at the admission gate even with a terminal outcome present' }

        $admission = script:Invoke-GRIAdmissionGate -WorktreePath $wt -Now $now

        $admission.Action | Should -Be 'refuse-resume-existing' -Because 'the live-run protection is never inferred from an absent side effect -- it is asserted directly here'
        $admission.Appears.AppearsDead | Should -Be $false
        $admission.Appears.TerminalOutcomePresent | Should -Be $true -Because 'a halt report exists -- this is the exact co-occurrence the design challenge flagged as the regression risk'
        Should -Invoke -CommandName Resolve-GoalRunResumeStage -Times 0
    }
}

Describe '#912 s8 I5: unresolved marker + verified PR emissions + STALE heartbeat -> resolve-and-report-complete' -Tag 'unit' {
    It 'the admission gate reports resolve-and-report-complete AND resolves the held marker before reporting' {
        <#
        FIXED (was HONEST GAP): agents/Goal-Run.agent.md's
        resolve-and-report-complete bullet previously said "Report the
        terminal outcome found and stop" without calling a marker-
        resolution primitive, unlike every OTHER halt/completion point in
        that file (the pre-loop launch-pin halt, the loop-interrupted
        guard, every chain-boundary halt, the Stage 1 halts, and Stage 5
        completion all explicitly resolve the held inflight marker
        before/at that point). It now follows the exact same
        resolve-before-report pattern the pre-loop launch-pin halt
        demonstrates: on `Found: $true` it calls
        Set-GoalRunInflightMarkerResolved with
        -ResolvedReason 'stale-terminal-outcome'. This test asserts the
        FIXED admission gate (script:Invoke-GRIAdmissionGate, mirroring
        the updated prose) actually performs that resolution as part of
        its own composition, not merely that the primitive pair composes
        cleanly when called by hand.
        #>
        $wt = script:New-GRIWorktree -Name 'i5'
        $now = (Get-Date).ToUniversalTime()
        $launchedAt = $now.AddHours(-3).ToString('o')
        $staleHeartbeat = $now.AddHours(-2).ToString('o')
        script:Write-GRIActiveState -WorktreePath $wt -LaunchedAt $launchedAt -HeartbeatAt $staleHeartbeat

        $inflightBody = New-GoalRunInflightMarkerBody -Issue $script:GRIIssue -ContractHash $script:GRIContractHash -LaunchedAt $launchedAt -Status 'unresolved'
        Mock -CommandName Get-GoalRunIssueComments -MockWith { script:New-GRICommentsCorpus -InflightBody $inflightBody }

        $script:i5ResolvedCalls = [System.Collections.Generic.List[pscustomobject]]::new()
        Mock -CommandName Set-GoalRunInflightMarkerResolved -MockWith {
            param($CommentId, $Issue, $ContractHash, $LaunchedAt, $ResolvedReason, $Owner, $Repo)
            $script:i5ResolvedCalls.Add([pscustomobject]@{ CommentId = $CommentId; ContractHash = $ContractHash; LaunchedAt = $LaunchedAt; ResolvedReason = $ResolvedReason }) | Out-Null
            $true
        }

        # PrExists is supplied directly: PR-existence detection is a live
        # `gh pr list` check with no dedicated library primitive in this
        # file's scope -- the admission-gate prose itself (Goal-Run.agent.md
        # line 47) just says "check ... an open/merged PR", naming no
        # specific function, mirroring how Test-GoalRunPrEmissionsVerified
        # elsewhere in this codebase already takes an injectable -PrReader
        # for the same live-check reason.
        $admission = script:Invoke-GRIAdmissionGate -WorktreePath $wt -Now $now -PrExists $true

        $admission.Action | Should -Be 'resolve-and-report-complete'
        $admission.Appears.AppearsDead | Should -Be $true
        $admission.Appears.TerminalOutcomePresent | Should -Be $true

        $script:i5ResolvedCalls.Count | Should -Be 1 -Because 'the fixed resolve-and-report-complete branch resolves the held marker exactly once before reporting'
        $script:i5ResolvedCalls[0].CommentId | Should -Be $admission.Marker.CommentId
        $script:i5ResolvedCalls[0].ResolvedReason | Should -Be 'stale-terminal-outcome'
    }
}

Describe '#912 s8 I6: uncommitted-changes tree-state refusal -> relaunch under the same liveness re-check as I2' -Tag 'unit' {
    It 'admitted, resolves loop-interrupted, and a substring-matched uncommitted-changes refusal relaunches rather than halting' {
        $wt = script:New-GRIWorktree -Name 'i6'
        $now = (Get-Date).ToUniversalTime()
        $launchedAt = $now.AddHours(-3).ToString('o')
        $staleHeartbeat = $now.AddHours(-2).ToString('o')
        script:Write-GRIActiveState -WorktreePath $wt -LaunchedAt $launchedAt -HeartbeatAt $staleHeartbeat

        $inflightBody = New-GoalRunInflightMarkerBody -Issue $script:GRIIssue -ContractHash $script:GRIContractHash -LaunchedAt $launchedAt -Status 'unresolved'
        $stageBody = New-GoalRunStageMarkerBody -Issue $script:GRIIssue -Stage 'loop-launched' -ContractHash $script:GRIContractHash -UpdatedAt $launchedAt -WorktreePath $wt
        Mock -CommandName Get-GoalRunIssueComments -MockWith { script:New-GRICommentsCorpus -InflightBody $inflightBody -StageBody $stageBody }
        Mock -CommandName Set-GoalRunInflightMarkerAdopted -MockWith { [pscustomobject]@{ Success = $true; Verified = $true; Reason = 'adopted-and-verified'; AdoptedBySessionId = 'sess-fixture' } }
        $script:i6SetStageCalls = [System.Collections.Generic.List[string]]::new()
        Mock -CommandName Set-GoalRunStageMarker -MockWith {
            param($Issue, $Stage, $ContractHash, $WorktreePath, $Owner, $Repo)
            $script:i6SetStageCalls.Add($Stage) | Out-Null
            [pscustomobject]@{ Success = $true; Url = 'https://example/x'; Stage = $Stage; UpdatedAt = (Get-Date).ToString('o'); WorktreePath = $WorktreePath }
        }

        $admission = script:Invoke-GRIAdmissionGate -WorktreePath $wt -Now $now
        $admission.Action | Should -Be 'adopt-and-resume'
        Set-GoalRunInflightMarkerAdopted -CommentId $admission.Marker.CommentId -Issue $script:GRIIssue `
            -ContractHash $script:GRIContractHash -LaunchedAt $launchedAt -SessionId 'sess-fixture' | Out-Null

        $stageMarker = Get-GoalRunStageMarker -Issue $script:GRIIssue
        $resume = Resolve-GoalRunResumeStage -ContractHashVerified $true -InflightMarkerPresent $true `
            -ActiveStatePresent $true -RunLogHasCheckpoint $false -ExplicitStageMarker $stageMarker.Stage
        $resume.ResumeStage | Should -Be 'loop-interrupted'

        $validator = { param($Issue, $RepoRoot, $PwshCliPath, $ValidatorScriptPath) [pscustomobject]@{ ExitCode = 2; Reason = $null; Refusals = @('refused: uncommitted-changes') } }
        $result = script:Invoke-GRILoopInterrupted -WorktreePath $wt -LaunchPinnedHash $script:GRIContractHash `
            -PinCheck $script:GRISatisfiedPinCheck -ValidatorInvoker $validator -Now $now

        $result.Outcome | Should -Be 'relaunch'
        $result.Revalidate.Disposition | Should -Be 'halt'
        $result.Revalidate.Refusals[0] | Should -Match 'uncommitted-changes'
        $script:i6SetStageCalls | Should -Contain 'loop-launched'
    }
}

Describe '#912 s8 I7: no-run-diff tree-state refusal -> relaunch under the same liveness re-check' -Tag 'unit' {
    It 'admitted, resolves loop-interrupted, and a substring-matched no-run-diff refusal (with embedded shas) relaunches rather than halting' {
        $wt = script:New-GRIWorktree -Name 'i7'
        $now = (Get-Date).ToUniversalTime()
        $launchedAt = $now.AddHours(-3).ToString('o')
        $staleHeartbeat = $now.AddHours(-2).ToString('o')
        script:Write-GRIActiveState -WorktreePath $wt -LaunchedAt $launchedAt -HeartbeatAt $staleHeartbeat

        $inflightBody = New-GoalRunInflightMarkerBody -Issue $script:GRIIssue -ContractHash $script:GRIContractHash -LaunchedAt $launchedAt -Status 'unresolved'
        $stageBody = New-GoalRunStageMarkerBody -Issue $script:GRIIssue -Stage 'loop-launched' -ContractHash $script:GRIContractHash -UpdatedAt $launchedAt -WorktreePath $wt
        Mock -CommandName Get-GoalRunIssueComments -MockWith { script:New-GRICommentsCorpus -InflightBody $inflightBody -StageBody $stageBody }
        Mock -CommandName Set-GoalRunInflightMarkerAdopted -MockWith { [pscustomobject]@{ Success = $true; Verified = $true; Reason = 'adopted-and-verified'; AdoptedBySessionId = 'sess-fixture' } }
        $script:i7SetStageCalls = [System.Collections.Generic.List[string]]::new()
        Mock -CommandName Set-GoalRunStageMarker -MockWith {
            param($Issue, $Stage, $ContractHash, $WorktreePath, $Owner, $Repo)
            $script:i7SetStageCalls.Add($Stage) | Out-Null
            [pscustomobject]@{ Success = $true; Url = 'https://example/x'; Stage = $Stage; UpdatedAt = (Get-Date).ToString('o'); WorktreePath = $WorktreePath }
        }

        $admission = script:Invoke-GRIAdmissionGate -WorktreePath $wt -Now $now
        $admission.Action | Should -Be 'adopt-and-resume'
        Set-GoalRunInflightMarkerAdopted -CommentId $admission.Marker.CommentId -Issue $script:GRIIssue `
            -ContractHash $script:GRIContractHash -LaunchedAt $launchedAt -SessionId 'sess-fixture' | Out-Null

        $stageMarker = Get-GoalRunStageMarker -Issue $script:GRIIssue
        $resume = Resolve-GoalRunResumeStage -ContractHashVerified $true -InflightMarkerPresent $true `
            -ActiveStatePresent $true -RunLogHasCheckpoint $false -ExplicitStageMarker $stageMarker.Stage
        $resume.ResumeStage | Should -Be 'loop-interrupted'

        $validator = { param($Issue, $RepoRoot, $PwshCliPath, $ValidatorScriptPath) [pscustomobject]@{ ExitCode = 2; Reason = $null; Refusals = @('refused: no-run-diff: abc1234..def5678') } }
        $result = script:Invoke-GRILoopInterrupted -WorktreePath $wt -LaunchPinnedHash $script:GRIContractHash `
            -PinCheck $script:GRISatisfiedPinCheck -ValidatorInvoker $validator -Now $now

        $result.Outcome | Should -Be 'relaunch'
        $result.Revalidate.Disposition | Should -Be 'halt'
        $result.Revalidate.Refusals[0] | Should -Match 'no-run-diff'
        $script:i7SetStageCalls | Should -Contain 'loop-launched'
    }
}

Describe '#912 s8 I8: active-state file deleted (between admission and the loop-interrupted guarded read) -> typed halt, no exception' -Tag 'unit' {
    It 'the null-safety case: Get-GoalRunActiveState returns $null (never throws) on an absent file, and the guarded flow still emits a typed halt' {
        $wt = script:New-GRIWorktree -Name 'i8'
        $now = (Get-Date).ToUniversalTime()
        $launchedAt = $now.AddHours(-3).ToString('o')
        $staleHeartbeat = $now.AddHours(-2).ToString('o')
        script:Write-GRIActiveState -WorktreePath $wt -LaunchedAt $launchedAt -HeartbeatAt $staleHeartbeat

        $inflightBody = New-GoalRunInflightMarkerBody -Issue $script:GRIIssue -ContractHash $script:GRIContractHash -LaunchedAt $launchedAt -Status 'unresolved'
        $stageBody = New-GoalRunStageMarkerBody -Issue $script:GRIIssue -Stage 'loop-launched' -ContractHash $script:GRIContractHash -UpdatedAt $launchedAt -WorktreePath $wt
        Mock -CommandName Get-GoalRunIssueComments -MockWith { script:New-GRICommentsCorpus -InflightBody $inflightBody -StageBody $stageBody }
        Mock -CommandName Set-GoalRunInflightMarkerAdopted -MockWith { [pscustomobject]@{ Success = $true; Verified = $true; Reason = 'adopted-and-verified'; AdoptedBySessionId = 'sess-fixture' } }

        $admission = script:Invoke-GRIAdmissionGate -WorktreePath $wt -Now $now
        $admission.Action | Should -Be 'adopt-and-resume'
        Set-GoalRunInflightMarkerAdopted -CommentId $admission.Marker.CommentId -Issue $script:GRIIssue `
            -ContractHash $script:GRIContractHash -LaunchedAt $launchedAt -SessionId 'sess-fixture' | Out-Null

        $stageMarker = Get-GoalRunStageMarker -Issue $script:GRIIssue
        $resume = Resolve-GoalRunResumeStage -ContractHashVerified $true -InflightMarkerPresent $true `
            -ActiveStatePresent $true -RunLogHasCheckpoint $false -ExplicitStageMarker $stageMarker.Stage
        $resume.ResumeStage | Should -Be 'loop-interrupted'

        # Simulate the file vanishing between admission's read and
        # loop-interrupted's own guarded read.
        Remove-Item -LiteralPath (Join-Path $wt 'goal-run-active.json') -Force
        (Test-Path -LiteralPath (Join-Path $wt 'goal-run-active.json')) | Should -Be $false

        $script:i8CapturedReport = $null
        Mock -CommandName Invoke-GoalRunHaltEmit -MockWith {
            param($Report, $Issue, $RepoRoot, $Owner, $Repo)
            $script:i8CapturedReport = $Report
            [pscustomobject]@{ Success = $true; Url = 'https://example/halt'; Body = 'fake' }
        }

        $threw = $false
        $result = $null
        try {
            $result = script:Invoke-GRILoopInterrupted -WorktreePath $wt -LaunchPinnedHash $script:GRIContractHash `
                -PinCheck $script:GRISatisfiedPinCheck -ValidatorInvoker $null -Now $now
        }
        catch {
            $threw = $true
        }

        $threw | Should -Be $false -Because 'I8 is the null-safety case: a deleted active-state file must not throw'
        $result.Outcome | Should -Be 'halted'
        $result.ReadThrew | Should -Be $false
        $script:i8CapturedReport.halt_reason | Should -Be 'chain-stage-failure'
        $script:i8CapturedReport.stage | Should -Be 'loop'
        $script:i8CapturedReport.evidence | Should -Contain 'goal-run-active-state-unreadable'
    }
}

Describe '#912 s8 I9: active-state file TRUNCATED -> typed halt, no exception (the throw-safety case, distinct from I8''s null-safety case)' -Tag 'unit' {
    It 'Get-GoalRunActiveState genuinely throws on the truncated file when called unguarded, but the guarded flow still contains it and emits the same typed halt' {
        $wt = script:New-GRIWorktree -Name 'i9'
        $now = (Get-Date).ToUniversalTime()
        $launchedAt = $now.AddHours(-3).ToString('o')
        $staleHeartbeat = $now.AddHours(-2).ToString('o')
        script:Write-GRIActiveState -WorktreePath $wt -LaunchedAt $launchedAt -HeartbeatAt $staleHeartbeat

        $inflightBody = New-GoalRunInflightMarkerBody -Issue $script:GRIIssue -ContractHash $script:GRIContractHash -LaunchedAt $launchedAt -Status 'unresolved'
        $stageBody = New-GoalRunStageMarkerBody -Issue $script:GRIIssue -Stage 'loop-launched' -ContractHash $script:GRIContractHash -UpdatedAt $launchedAt -WorktreePath $wt
        Mock -CommandName Get-GoalRunIssueComments -MockWith { script:New-GRICommentsCorpus -InflightBody $inflightBody -StageBody $stageBody }
        Mock -CommandName Set-GoalRunInflightMarkerAdopted -MockWith { [pscustomobject]@{ Success = $true; Verified = $true; Reason = 'adopted-and-verified'; AdoptedBySessionId = 'sess-fixture' } }

        $admission = script:Invoke-GRIAdmissionGate -WorktreePath $wt -Now $now
        $admission.Action | Should -Be 'adopt-and-resume'
        Set-GoalRunInflightMarkerAdopted -CommentId $admission.Marker.CommentId -Issue $script:GRIIssue `
            -ContractHash $script:GRIContractHash -LaunchedAt $launchedAt -SessionId 'sess-fixture' | Out-Null

        $stageMarker = Get-GoalRunStageMarker -Issue $script:GRIIssue
        $resume = Resolve-GoalRunResumeStage -ContractHashVerified $true -InflightMarkerPresent $true `
            -ActiveStatePresent $true -RunLogHasCheckpoint $false -ExplicitStageMarker $stageMarker.Stage
        $resume.ResumeStage | Should -Be 'loop-interrupted'

        # Corrupt the file between admission's read and loop-interrupted's
        # own guarded read.
        script:Write-GRIActiveState -WorktreePath $wt -Truncated

        # Sanity check first: prove the RAW, unguarded call really does
        # throw on this file (matching Goal-Run.agent.md line 102's own
        # characterization) -- this is the property that makes I9 distinct
        # from I8's null-return case.
        { Get-GoalRunActiveState -WorktreePath $wt } | Should -Throw

        $script:i9CapturedReport = $null
        Mock -CommandName Invoke-GoalRunHaltEmit -MockWith {
            param($Report, $Issue, $RepoRoot, $Owner, $Repo)
            $script:i9CapturedReport = $Report
            [pscustomobject]@{ Success = $true; Url = 'https://example/halt'; Body = 'fake' }
        }

        $threw = $false
        $result = $null
        try {
            $result = script:Invoke-GRILoopInterrupted -WorktreePath $wt -LaunchPinnedHash $script:GRIContractHash `
                -PinCheck $script:GRISatisfiedPinCheck -ValidatorInvoker $null -Now $now
        }
        catch {
            $threw = $true
        }

        $threw | Should -Be $false -Because 'the guarded flow''s own try/catch around the active-state read must contain the internal ConvertFrom-Json throw'
        $result.Outcome | Should -Be 'halted'
        $result.ReadThrew | Should -Be $true -Because 'I9 is the throw-safety case: the read genuinely threw internally, unlike I8''s null-safety case'
        $script:i9CapturedReport.halt_reason | Should -Be 'chain-stage-failure'
        $script:i9CapturedReport.evidence | Should -Contain 'goal-run-active-state-unreadable'
    }
}

Describe '#912 s8 I10: marker present with unparseable fields -> typed refusal, no binding throw' -Tag 'unit' {
    <#
    FIXED (was HONEST GAP): the admission-gate prose (Goal-Run.agent.md
    Invocation Contract step 2) now guards the winning unresolved
    marker's fields via Resolve-GoalRunInflightMarkerForResolution BEFORE
    they reach Test-GoalRunInflightAppearsDead's Mandatory [datetime]
    -LaunchedAt parameter -- a marker whose body parsed (Parsed: $true)
    but whose contract_hash/launched_at came back $null (a hand-edited or
    truncated marker body) used to reach that parameter unguarded and
    throw a raw ParameterBindingArgumentTransformationException. Part (a)
    below now asserts the FIXED admission gate
    (script:Invoke-GRIAdmissionGate, mirroring the updated prose) returns
    a typed refusal with no throw for exactly the same unparseable-marker
    fixture that used to reproduce that exception. Part (b) still
    exercises Resolve-GoalRunInflightMarkerForResolution -- the shipped
    primitive this guard wires in -- directly, to confirm the underlying
    primitive's contract in isolation.
    #>
    It 'part (a): the FIXED admission gate returns a typed refusal, no binding throw' {
        $wt = script:New-GRIWorktree -Name 'i10a'
        # Deliberately hand-built: status parses fine, but contract_hash and
        # launched_at are omitted entirely (an unparseable/hand-edited or
        # truncated marker body), so ConvertFrom-GoalRunInflightMarkerBody
        # reports Parsed=$true with Status='unresolved' but ContractHash/
        # LaunchedAt both $null.
        $unparseableInflightBody = @(
            "<!-- goal-run-inflight-$($script:GRIIssue) -->"
            '## Goal-run in-flight marker'
            ''
            '- **schema_version**: 1'
            "- **issue**: $($script:GRIIssue)"
            '- **status**: unresolved'
        ) -join "`n"
        Mock -CommandName Get-GoalRunIssueComments -MockWith { script:New-GRICommentsCorpus -InflightBody $unparseableInflightBody }

        $threw = $false
        $admission = $null
        try {
            $admission = script:Invoke-GRIAdmissionGate -WorktreePath $wt -Now (Get-Date).ToUniversalTime()
        }
        catch {
            $threw = $true
        }

        $threw | Should -Be $false -Because 'the fixed admission gate guards the marker fields before they reach Test-GoalRunInflightAppearsDead'
        $admission.Action | Should -Be 'refuse-unparseable-marker'
        $admission.ForResolution.Reason | Should -Be 'marker-fields-unparseable'
    }

    It 'part (b): Resolve-GoalRunInflightMarkerForResolution -- the shipped primitive this guard wires in -- returns a typed refusal with no throw' {
        $unparseableInflightBody = @(
            "<!-- goal-run-inflight-$($script:GRIIssue) -->"
            '## Goal-run in-flight marker'
            ''
            '- **schema_version**: 1'
            "- **issue**: $($script:GRIIssue)"
            '- **status**: unresolved'
        ) -join "`n"
        Mock -CommandName Get-GoalRunIssueComments -MockWith { script:New-GRICommentsCorpus -InflightBody $unparseableInflightBody }

        $threw = $false
        $result = $null
        try {
            $result = Resolve-GoalRunInflightMarkerForResolution -Issue $script:GRIIssue
        }
        catch {
            $threw = $true
        }

        $threw | Should -Be $false
        $result.Found | Should -Be $false
        $result.Reason | Should -Be 'marker-fields-unparseable'
    }
}

Describe '#912 s8 I11: restart -- reused from step 5 coverage; documents that restart bypasses the normal admission gate entirely' -Tag 'unit' {
    It 'Invoke-GoalRunRestart completes its full outcome without ever calling the normal admission gate (Resolve-GoalRunInvocationAction)' {
        <#
        NOT DUPLICATED: goal-run-stage-core.Tests.ps1's "Invoke-GoalRunRestart
        (#912 D6, step 5...)" Describe block, It '#912 fixture (b)+(c):
        restart is refused on a fresh heartbeat, and once stale, clears both
        artifacts so the next invocation resolves pre-loop' already builds a
        real stage-marker + active-state fixture, refuses on a fresh
        heartbeat, restarts once stale, confirms BOTH artifacts are
        cleared, and confirms the next Resolve-GoalRunResumeStage call
        lands on 'pre-loop' with Reason 'fresh-launch'. That IS the "branch
        captured in the report before clear, both artifacts cleared, next
        invocation resolves pre-loop" contract this case describes;
        duplicating it here would not add coverage.

        What this Describe block adds instead: restart is entered ONLY via
        the operator's explicit 'restart' lever token
        (agents/Goal-Run.agent.md's "Operator Restart" section, entered
        only when the Invocation Contract's own lever token resolves to
        'restart') -- it never reaches Resolve-GoalRunInvocationAction, the
        admission gate every other case (I1-I10) in this file starts at.
        This proves that structurally rather than by prose assertion alone.
        #>
        Mock -CommandName Resolve-GoalRunInvocationAction -MockWith { throw 'restart must never call the normal admission gate' }
        Mock -CommandName New-GoalRunIssueComment -MockWith { [pscustomobject]@{ Success = $true; CommentId = 1; Url = 'https://example/1' } }
        Mock -CommandName Clear-GoalRunStageMarker -MockWith { [pscustomobject]@{ Success = $true; DeletedCommentIds = @(); FailedCommentIds = @() } }
        Mock -CommandName Clear-GoalRunActiveState -MockWith { $true }

        $now = (Get-Date).ToUniversalTime()
        $result = Invoke-GoalRunRestart -Issue $script:GRIIssue -WorktreePath 'C:\fake\gr-912-i11' -LaunchedAt $now.AddHours(-2) -Now $now

        $result.Outcome | Should -Be 'restarted'
        Should -Invoke -CommandName Resolve-GoalRunInvocationAction -Times 0
    }
}
