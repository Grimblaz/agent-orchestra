#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    RED-phase Pester suite for the not-yet-implemented persist-phase-ledger
    helper (issue #878, plan slice s4). Implementation lands in s5 at
    skills/session-memory-contract/scripts/persist-phase-ledger-core.ps1,
    exporting Invoke-PersistPhaseLedger.

.DESCRIPTION
    This suite pins the parameter surface and observable behavior of
    Invoke-PersistPhaseLedger BEFORE it exists (s4 does not implement it —
    that is s5's job). Every test dot-sources the two REAL, already-shipped
    primitives it composes — find-or-upsert-comment.ps1 and
    phase-containment-emission-check-core.ps1 — for real, and mocks only the
    true external seam (`gh`), so these are genuine integration tests per
    skills/test-driven-development/SKILL.md's Critical Integration Rule: they
    exercise the actual primitive contracts (Find-OrUpsertComment's $null
    failure mode; Add-CommentBlocks'/Add-JudgeRulingsBlock's
    {Success;Reason} failure mode; Add-JudgeRulingsBlock's append-only
    nature; Add-CommentBlocks' schema preflight) rather than a synthetic
    stand-in that could stay green while the real wiring is missing.

    Each Context below maps to one load-bearing invariant the issue #878
    five-pass stress-test found the ORIGINAL design would have violated
    (see plan-issue-878 comment 5013462111, Challenges M1-M34). A test
    asserting `$null` against an Add-* return is itself the defect class
    this suite exists to prevent (M5) — Find-OrUpsertComment and the two
    Add-* primitives have DIFFERENT failure contracts and are asserted on
    differently throughout.

    Fixture shapes (marker text, pointer line, judge-rulings bare-head form,
    phase-containment paired-block fields, zero-findings placeholder) are
    taken verbatim from skills/plan-authoring/SKILL.md:204,227-254 — the
    authoritative writer contract — not invented ad hoc.
#>

BeforeDiscovery {
    $script:CoreLibPath = Join-Path $PSScriptRoot '../../../skills/session-memory-contract/scripts/persist-phase-ledger-core.ps1'
}

Describe 'Invoke-PersistPhaseLedger' {
    BeforeAll {
        $script:CoreLibPath = Join-Path $PSScriptRoot '../../../skills/session-memory-contract/scripts/persist-phase-ledger-core.ps1'
        $script:FindOrUpsertLibPath = Join-Path $PSScriptRoot '../lib/find-or-upsert-comment.ps1'
        $script:EmissionCoreLibPath = Join-Path $PSScriptRoot '../lib/phase-containment-emission-check-core.ps1'

        $script:Owner = 'Grimblaz'
        $script:Repo = 'agent-orchestra'
        $script:IssueNumber = 878
        $script:PlanMarker = '<!-- plan-issue-878 -->'
        $script:LedgerMarker = '<!-- phase-containment-ledger-878 -->'

        # Builds one schema-valid <!-- phase-containment-878 -->...<!-- /phase-containment-878 -->
        # block. Field set mirrors the proven fixture already in
        # phase-containment-emission-check-core.Tests.ps1 (New-ValidPhaseContainmentBlockText),
        # re-derived here rather than cross-imported since Pester test files
        # in this repo are standalone.
        function script:New-LedgerBlockText {
            param(
                [Parameter(Mandatory)][string]$FindingSuffix,
                [string]$Severity = 'low',
                [string]$CatchablePhase = 'implementation',
                [string]$CaughtStage = 'code-review',
                [int]$EscapeDistance = 0
            )
            $findingKey = "plan-stress-test:878:$FindingSuffix"
            $lines = @(
                '<!-- phase-containment-878 -->'
                "finding_key: $findingKey"
                "introduced_phase: $CatchablePhase"
                "catchable_phase: $CatchablePhase"
                "caught_stage: $CaughtStage"
                "escape_distance: $EscapeDistance"
                "severity: $Severity"
                'systemic_fix_type: none'
                'category: pattern'
                'apparatus_meta: false'
                '<!-- /phase-containment-878 -->'
            )
            return ($lines -join "`n")
        }

        # Builds a bare-head judge-rulings block per plan-authoring/SKILL.md:227-234.
        function script:New-JudgeRulingsText {
            param([Parameter(Mandatory)][hashtable[]]$Entries)
            $lines = @('<!-- judge-rulings')
            foreach ($e in $Entries) {
                $lines += "- finding_id: $($e.FindingId)"
                $lines += "  judge_ruling: $($e.Ruling)"
            }
            $lines += '-->'
            return ($lines -join "`n")
        }

        # plan-authoring/SKILL.md:244-251 pinned placeholder shape.
        $script:ZeroFindingsJudgeRulings = New-JudgeRulingsText -Entries @(
            @{ FindingId = 'none'; Ruling = 'defense-sustained' }
        )
    }

    BeforeEach {
        # --- Simulated GitHub comment store (mutable across gh calls). ---
        $script:mockComments = [System.Collections.Generic.List[object]]::new()
        $script:NextCommentId = 90000
        $script:ghCallLog = [System.Collections.Generic.List[string]]::new()
        $script:PatchLog = [System.Collections.Generic.List[object]]::new()
        $script:PostLog = [System.Collections.Generic.List[object]]::new()
        $script:simulateListFailure = $false
        $script:simulatePostFailure = $false
        $script:simulatePatchFailure = @()
        $script:simulateGetFailure = @()

        function script:Add-MockComment {
            param([Parameter(Mandatory)][long]$Id, [Parameter(Mandatory)][string]$Body)
            $url = "https://github.com/$script:Owner/$script:Repo/issues/$script:IssueNumber#issuecomment-$Id"
            $script:mockComments.Add([PSCustomObject]@{ Id = $Id; NodeId = "IC_fake_$Id"; body = $Body; url = $url })
        }

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $joined = $Args -join ' '
            $script:ghCallLog.Add($joined)

            # LIST: gh issue view <N> --json comments [-R <owner>/<repo>]
            # M15 fix (issue #878 judge-sustained review): Find-PPLCommentIdByExactMarker
            # now passes -R explicitly, so this mock must match with or
            # without the trailing -R argument.
            if ($joined -match '^issue view \d+ --json comments(\s|$)') {
                if ($script:simulateListFailure) { $global:LASTEXITCODE = 1; return '' }
                $payload = @{
                    comments = @($script:mockComments | ForEach-Object {
                            @{ id = $_.NodeId; body = $_.body; url = $_.url }
                        })
                } | ConvertTo-Json -Depth 8
                $global:LASTEXITCODE = 0
                return $payload
            }

            # Repo probe (Find-OrUpsertComment internal): gh api repos/<o>/<r> --jq .full_name
            if ($Args.Count -ge 2 -and $Args[0] -eq 'api' -and $Args[1] -match '^repos/[^/]+/[^/]+$' -and ($Args -contains '--jq')) {
                $global:LASTEXITCODE = 0
                return "$script:Owner/$script:Repo"
            }

            # GET by numeric id (no -X): gh api repos/<o>/<r>/issues/comments/<id>
            if ($Args.Count -ge 2 -and $Args[0] -eq 'api' -and $Args[1] -match '^repos/[^/]+/[^/]+/issues/comments/(\d+)$' -and ($Args -notcontains '-X')) {
                $id = [long]$Matches[1]
                if ($script:simulateGetFailure -contains $id) { $global:LASTEXITCODE = 1; return '' }
                $c = $script:mockComments | Where-Object { $_.Id -eq $id }
                if (-not $c) { $global:LASTEXITCODE = 1; return '' }
                $global:LASTEXITCODE = 0
                return (@{ id = $c.Id; body = $c.body; url = $c.url } | ConvertTo-Json -Depth 8)
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
                if ($script:simulatePostFailure) { $global:LASTEXITCODE = 1; return '' }
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

        # Real primitives first (so the core's unqualified calls to
        # Find-OrUpsertComment / Add-CommentBlocks / Add-JudgeRulingsBlock
        # resolve to the genuine, already-shipped implementations — never a
        # synthetic stand-in), then the core itself. Per the established
        # convention in find-or-upsert-comment.Tests.ps1: when the core file
        # does not exist yet, a CommandNotFoundException at the Act line
        # below is itself the sanctioned RED signal.
        if (Test-Path $script:FindOrUpsertLibPath) { . $script:FindOrUpsertLibPath }
        if (Test-Path $script:EmissionCoreLibPath) { . $script:EmissionCoreLibPath }
        if (Test-Path $script:CoreLibPath) { . $script:CoreLibPath }
    }

    AfterEach {
        Remove-Item Function:gh -ErrorAction SilentlyContinue
    }

    Context 'Per-primitive failure contract (M5): Find-OrUpsertComment $null vs Add-* {Success;Reason}' {
        It 'reports failure (not a silent Success=$true) when the ledger sibling cannot be created — Find-OrUpsertComment''s $null contract (find-or-upsert-comment.ps1:111,176,201)' {
            Add-MockComment -Id 111222333 -Body "$script:PlanMarker`n`nRealistic plan body with no pointer yet."
            $script:simulatePostFailure = $true

            $judgeContent = New-JudgeRulingsText -Entries @(@{ FindingId = 'F1'; Ruling = 'sustained' })
            $result = Invoke-PersistPhaseLedger -Owner $script:Owner -Repo $script:Repo -Mode plan `
                -IssueNumber $script:IssueNumber -JudgeRulingsContent $judgeContent `
                -PhaseContainmentBlocks @((New-LedgerBlockText -FindingSuffix 'F1'))

            $result.Success | Should -Be $false
            $result.Reason | Should -Not -BeNullOrEmpty
        }

        It 'reads .Success/.Reason (never a $null check) on Add-JudgeRulingsBlock''s refusal — a non-null PSCustomObject with Success=$false must not read as success (phase-containment-emission-check-core.ps1:3358-3360)' {
            # First-ever persist: the sibling does not exist yet. Per
            # plan-authoring/SKILL.md:105's own ExpectedMarker reasoning
            # ("not the docstring's judge-rulings example, which does not
            # exist on a first persist"), the only shape consistent with that
            # constraint is create-marker-only-then-append: the sibling is
            # created carrying just the identity marker, and
            # Add-JudgeRulingsBlock is the (unambiguous, not a routing
            # choice) mechanism that appends the actual judge-rulings content
            # onto it. $script:NextCommentId's starting value (90000, set in
            # BeforeEach) is what the freshly created sibling will be
            # assigned, since no other POST happens earlier in this test.
            Add-MockComment -Id 111222333 -Body "$script:PlanMarker`n`nRealistic plan body with no pointer yet."
            $script:simulatePatchFailure = @(90000)

            $judgeContent = New-JudgeRulingsText -Entries @(@{ FindingId = 'F1'; Ruling = 'sustained' })
            $result = Invoke-PersistPhaseLedger -Owner $script:Owner -Repo $script:Repo -Mode plan `
                -IssueNumber $script:IssueNumber -JudgeRulingsContent $judgeContent `
                -PhaseContainmentBlocks @((New-LedgerBlockText -FindingSuffix 'F1'))

            $result.Success | Should -Be $false
            $result.Reason | Should -Match 'PATCH failed'
        }
    }

    Context 'Existing-sibling preservation (M1/M17): a sibling already carrying blocks is never body-replaced' {
        It 'preserves a pre-existing phase-containment block byte-identical when a new finding is added to the same sibling' {
            $siblingId = 700002
            $existingBlock = New-LedgerBlockText -FindingSuffix 'A'
            $existingJudge = New-JudgeRulingsText -Entries @(@{ FindingId = 'A'; Ruling = 'sustained' })
            $siblingBody = "$script:LedgerMarker`n`n$existingJudge`n`n$existingBlock"
            Add-MockComment -Id 111222333 -Body "$script:PlanMarker`n`n<!-- phase-containment-ledger-ref: $siblingId -->`n`nRealistic plan body."
            Add-MockComment -Id $siblingId -Body $siblingBody

            $newBlock = New-LedgerBlockText -FindingSuffix 'B'
            $newJudge = New-JudgeRulingsText -Entries @(
                @{ FindingId = 'A'; Ruling = 'sustained' }
                @{ FindingId = 'B'; Ruling = 'sustained' }
            )
            $result = Invoke-PersistPhaseLedger -Owner $script:Owner -Repo $script:Repo -Mode plan `
                -IssueNumber $script:IssueNumber -JudgeRulingsContent $newJudge `
                -PhaseContainmentBlocks @($newBlock)

            $result.Success | Should -Be $true
            $finalSibling = ($script:mockComments | Where-Object { $_.Id -eq $siblingId }).body
            $finalSibling | Should -Match ([regex]::Escape($existingBlock))
            # No PATCH ever sent to the sibling with a body missing the original block.
            foreach ($p in ($script:PatchLog | Where-Object { $_.CommentId -eq $siblingId })) {
                $p.Body | Should -Match ([regex]::Escape('finding_key: plan-stress-test:878:A'))
            }
        }

        It 'reuses a pre-existing ledger sibling and preserves its content when the plan comment''s pointer line is missing (M1 guard: pointer-absent path must not wipe the sibling)' {
            # This is the scenario the M1 guard (persist-phase-ledger-core.ps1,
            # Invoke-PPLPersistPhaseLedgerPlanMode's $existingSibling check) exists
            # to protect, and the ONE that the sibling It block above does not
            # reach: here the plan comment carries NO
            # phase-containment-ledger-ref pointer, yet the ledger sibling
            # already exists on the issue with real accumulated content. A
            # neutralized guard falls straight through to
            # Find-OrUpsertComment's create-or-PATCH path, which would PATCH
            # the existing sibling's body down to just $ledgerMarker before
            # judge-rulings/phase-containment ever get a chance to write
            # anything -- silently destroying $existingBlock below.
            $siblingId = 700006
            $existingBlock = New-LedgerBlockText -FindingSuffix 'PRE'
            $existingJudge = New-JudgeRulingsText -Entries @(@{ FindingId = 'PRE'; Ruling = 'sustained' })
            $siblingBody = "$script:LedgerMarker`n`n$existingJudge`n`n$existingBlock"
            Add-MockComment -Id 111222333 -Body "$script:PlanMarker`n`nRealistic plan body with no pointer yet."
            Add-MockComment -Id $siblingId -Body $siblingBody

            $newBlock = New-LedgerBlockText -FindingSuffix 'NEW'
            $newJudge = New-JudgeRulingsText -Entries @(
                @{ FindingId = 'PRE'; Ruling = 'sustained' }
                @{ FindingId = 'NEW'; Ruling = 'sustained' }
            )
            $result = Invoke-PersistPhaseLedger -Owner $script:Owner -Repo $script:Repo -Mode plan `
                -IssueNumber $script:IssueNumber -JudgeRulingsContent $newJudge `
                -PhaseContainmentBlocks @($newBlock)

            $result.Success | Should -Be $true
            $result.Artifacts.Sibling | Should -Be 'reused'

            # No new sibling comment was ever created -- the only legal way a
            # new comment lands is via a POST, and a correctly-guarded run
            # must never issue one here: the sibling already exists and the
            # M1 guard must find it before ever falling through to
            # Find-OrUpsertComment's create path.
            $script:PostLog | Should -BeNullOrEmpty
            ($script:mockComments | Where-Object { $_.body -match [regex]::Escape($script:LedgerMarker) }).Count | Should -Be 1

            # The core anti-wipe assertion: the pre-existing block survives
            # byte-identical, and the new finding's block also lands.
            $finalSibling = ($script:mockComments | Where-Object { $_.Id -eq $siblingId }).body
            $finalSibling | Should -Match ([regex]::Escape($existingBlock))
            $finalSibling | Should -Match ([regex]::Escape('finding_key: plan-stress-test:878:NEW'))

            # The pointer gets (re-)inserted into the plan comment, pointing
            # at the REUSED sibling's id (not a newly created one).
            $finalPlanBody = ($script:mockComments | Where-Object { $_.Id -eq 111222333 }).body
            $finalPlanBody | Should -Match "<!-- phase-containment-ledger-ref: $siblingId -->"
        }
    }

    Context 'Plan-comment body survival (M2): pointer insertion leaves the rest of the plan body byte-identical' {
        It 'inserts the pointer line immediately after the plan-issue marker and reproduces the original body exactly once the pointer is stripped back out' {
            $originalBody = "$script:PlanMarker`n`n---`nstatus: pending`npriority: p2`nissue_id: 878`n---`n`n## Plan: Persistence-burst integrity`n`nSome realistic multi-paragraph plan prose that must survive untouched.`n`n**Plan Stress-Test**`n- Challenge M1 - sustained"
            Add-MockComment -Id 111222333 -Body $originalBody
            # No sibling yet -> first persist creates one.

            $judgeContent = New-JudgeRulingsText -Entries @(@{ FindingId = 'F1'; Ruling = 'sustained' })
            $result = Invoke-PersistPhaseLedger -Owner $script:Owner -Repo $script:Repo -Mode plan `
                -IssueNumber $script:IssueNumber -JudgeRulingsContent $judgeContent `
                -PhaseContainmentBlocks @((New-LedgerBlockText -FindingSuffix 'F1'))

            $result.Success | Should -Be $true
            $finalPlanBody = ($script:mockComments | Where-Object { $_.Id -eq 111222333 }).body
            $finalPlanBody | Should -Match '^<!-- plan-issue-878 -->\r?\n\r?\n<!-- phase-containment-ledger-ref: \d+ -->\r?\n'

            # Strip exactly the inserted pointer line (plus its own blank-line
            # spacer) back out and assert byte-identical recovery of the
            # original body — proves nothing else in the body was touched.
            $stripped = $finalPlanBody -replace '(?m)^<!-- phase-containment-ledger-ref: \d+ -->\r?\n\r?\n', ''
            $stripped | Should -Be $originalBody
        }
    }

    Context 'Wrong-comment targeting incl. the prose-mention variant (M2/M7): earliest-REST-id tie-break must not select a prose mention' {
        It 'never selects an earlier comment that only quotes the plan marker in prose, even though it has the lowest REST id' {
            # Posted BEFORE the real plan comment -> lowest id -> would win a
            # naive earliest-id -like tie-break.
            Add-MockComment -Id 50 -Body 'Note: this plan uses the `<!-- plan-issue-878 -->` marker for tracking status. See the linked issue for context.'
            Add-MockComment -Id 111222333 -Body "$script:PlanMarker`n`n---`nstatus: pending`n---`n`nReal plan body."

            $judgeContent = New-JudgeRulingsText -Entries @(@{ FindingId = 'F1'; Ruling = 'sustained' })
            $result = Invoke-PersistPhaseLedger -Owner $script:Owner -Repo $script:Repo -Mode plan `
                -IssueNumber $script:IssueNumber -JudgeRulingsContent $judgeContent `
                -PhaseContainmentBlocks @((New-LedgerBlockText -FindingSuffix 'F1'))

            $result.Success | Should -Be $true
            $prosecomment = $script:mockComments | Where-Object { $_.Id -eq 50 }
            $prosecomment.body | Should -Be 'Note: this plan uses the `<!-- plan-issue-878 -->` marker for tracking status. See the linked issue for context.'
            $script:PatchLog | Where-Object { $_.CommentId -eq 50 } | Should -BeNullOrEmpty
            $script:PatchLog | Where-Object { $_.CommentId -eq 111222333 } | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Judge-rulings span replacement (M4): re-persist replaces the prior block in place, adjacent blocks survive' {
        It 'replaces the old judge-rulings entries without duplicating the head, while a neighboring phase-containment block survives byte-identical' {
            $siblingId = 700003
            $survivingBlock = New-LedgerBlockText -FindingSuffix 'SURVIVOR'
            $oldJudge = New-JudgeRulingsText -Entries @(@{ FindingId = 'OLD1'; Ruling = 'sustained' })
            $siblingBody = "$script:LedgerMarker`n`n$oldJudge`n`n$survivingBlock"
            Add-MockComment -Id 111222333 -Body "$script:PlanMarker`n`n<!-- phase-containment-ledger-ref: $siblingId -->`n`nplan body."
            Add-MockComment -Id $siblingId -Body $siblingBody

            $newJudge = New-JudgeRulingsText -Entries @(
                @{ FindingId = 'NEW1'; Ruling = 'sustained' }
                @{ FindingId = 'NEW2'; Ruling = 'defense-sustained' }
            )
            $result = Invoke-PersistPhaseLedger -Owner $script:Owner -Repo $script:Repo -Mode plan `
                -IssueNumber $script:IssueNumber -JudgeRulingsContent $newJudge -PhaseContainmentBlocks @()

            $result.Success | Should -Be $true
            $finalSibling = ($script:mockComments | Where-Object { $_.Id -eq $siblingId }).body
            $finalSibling | Should -Match 'finding_id: NEW1'
            $finalSibling | Should -Not -Match 'finding_id: OLD1'
            ([regex]::Matches($finalSibling, '<!--\s*judge-rulings')).Count | Should -Be 1
            $finalSibling | Should -Match ([regex]::Escape($survivingBlock))
        }
    }

    Context 'Id extraction (M6): the numeric REST id must be extracted from html_url before calling Add-*' {
        It 'extracts the numeric REST comment id from the found sibling''s url field rather than passing a GraphQL/string id to Add-*' {
            $siblingId = 700004
            # Deliberately GraphQL-shaped NodeId in the LIST payload (matches
            # Find-OrUpsertComment's own real Get-RestCommentId precedent at
            # find-or-upsert-comment.ps1:64-67) to prove extraction, not a
            # coincidental numeric id, drives the subsequent PATCH target.
            Add-MockComment -Id 111222333 -Body "$script:PlanMarker`n`n<!-- phase-containment-ledger-ref: $siblingId -->`n`nplan body."
            Add-MockComment -Id $siblingId -Body "$script:LedgerMarker`n`n$($script:ZeroFindingsJudgeRulings)"

            $judgeContent = New-JudgeRulingsText -Entries @(@{ FindingId = 'F1'; Ruling = 'sustained' })
            $result = Invoke-PersistPhaseLedger -Owner $script:Owner -Repo $script:Repo -Mode plan `
                -IssueNumber $script:IssueNumber -JudgeRulingsContent $judgeContent `
                -PhaseContainmentBlocks @((New-LedgerBlockText -FindingSuffix 'F1'))

            $result.Success | Should -Be $true
            $script:PatchLog | Where-Object { $_.CommentId -eq $siblingId } | Should -Not -BeNullOrEmpty
            # Every PATCH this run issued targeted a purely numeric comment id
            # (never the string NodeId "IC_fake_700004" or a raw html_url).
            foreach ($entry in $script:ghCallLog) {
                if ($entry -match 'issues/comments/([^ /]+)') {
                    $Matches[1] | Should -Match '^\d+$'
                }
            }
        }
    }

    Context 'Zero-sustained-findings legal clean path (M15): skips the phase-containment append, still writes the placeholder' {
        It 'reports success and writes only the pinned zero-findings placeholder when PhaseContainmentBlocks is empty' {
            Add-MockComment -Id 111222333 -Body "$script:PlanMarker`n`nplan body."
            # No sibling yet.

            $result = Invoke-PersistPhaseLedger -Owner $script:Owner -Repo $script:Repo -Mode plan `
                -IssueNumber $script:IssueNumber -JudgeRulingsContent $script:ZeroFindingsJudgeRulings `
                -PhaseContainmentBlocks @()

            $result.Success | Should -Be $true
            $result.Reason | Should -BeNullOrEmpty
            $sibling = $script:mockComments | Where-Object { $_.body -match [regex]::Escape($script:LedgerMarker) }
            $sibling | Should -Not -BeNullOrEmpty
            $sibling.body | Should -Match 'finding_id: none'
            $sibling.body | Should -Not -Match '<!-- phase-containment-878 -->'
        }
    }

    Context 'Re-run idempotency (M21/M28): re-running with identical inputs must not double-append' {
        It 'does not duplicate the phase-containment block, the judge-rulings head, or the pointer line on a second identical run' {
            Add-MockComment -Id 111222333 -Body "$script:PlanMarker`n`nplan body."
            $judgeContent = New-JudgeRulingsText -Entries @(@{ FindingId = 'F1'; Ruling = 'sustained' })
            $block = New-LedgerBlockText -FindingSuffix 'F1'

            $firstResult = Invoke-PersistPhaseLedger -Owner $script:Owner -Repo $script:Repo -Mode plan `
                -IssueNumber $script:IssueNumber -JudgeRulingsContent $judgeContent -PhaseContainmentBlocks @($block)
            $firstResult.Success | Should -Be $true

            $secondResult = Invoke-PersistPhaseLedger -Owner $script:Owner -Repo $script:Repo -Mode plan `
                -IssueNumber $script:IssueNumber -JudgeRulingsContent $judgeContent -PhaseContainmentBlocks @($block)
            $secondResult.Success | Should -Be $true

            $finalPlanBody = ($script:mockComments | Where-Object { $_.Id -eq 111222333 }).body
            ([regex]::Matches($finalPlanBody, '<!-- phase-containment-ledger-ref: \d+ -->')).Count | Should -Be 1

            $sibling = $script:mockComments | Where-Object { $_.body -match [regex]::Escape($script:LedgerMarker) }
            ([regex]::Matches($sibling.body, '<!--\s*judge-rulings')).Count | Should -Be 1
            ([regex]::Matches($sibling.body, 'finding_key: plan-stress-test:878:F1')).Count | Should -Be 1
        }
    }

    Context 'Same-key/different-content replacement (M16): a corrected same-key finding replaces, never freezes stale content' {
        It 'replaces the stale severity/catchable_phase for an existing finding_key rather than skipping the update' {
            $siblingId = 700005
            $staleBlock = New-LedgerBlockText -FindingSuffix 'K' -Severity 'low' -CatchablePhase 'implementation'
            $judge = New-JudgeRulingsText -Entries @(@{ FindingId = 'K'; Ruling = 'sustained' })
            Add-MockComment -Id 111222333 -Body "$script:PlanMarker`n`n<!-- phase-containment-ledger-ref: $siblingId -->`n`nplan body."
            Add-MockComment -Id $siblingId -Body "$script:LedgerMarker`n`n$judge`n`n$staleBlock"

            # Only Severity varies here (not CatchablePhase/CaughtStage): those
            # two fields are ordinally coupled to escape_distance
            # (Test-PhaseContainmentEntry Rule 11, phase-containment-core.ps1)
            # — changing CatchablePhase without recomputing escape_distance
            # would make the "corrected" fixture itself schema-invalid, which
            # would fail Add-CommentBlocks' preflight for an unrelated reason
            # and mask the same-key/different-content invariant this test
            # exists to pin.
            $correctedBlock = New-LedgerBlockText -FindingSuffix 'K' -Severity 'high'
            $result = Invoke-PersistPhaseLedger -Owner $script:Owner -Repo $script:Repo -Mode plan `
                -IssueNumber $script:IssueNumber -JudgeRulingsContent $judge -PhaseContainmentBlocks @($correctedBlock)

            $result.Success | Should -Be $true
            $finalSibling = ($script:mockComments | Where-Object { $_.Id -eq $siblingId }).body
            ([regex]::Matches($finalSibling, 'finding_key: plan-stress-test:878:K')).Count | Should -Be 1
            $finalSibling | Should -Match 'severity: high'
            $finalSibling | Should -Not -Match 'severity: low'
        }
    }

    Context 'Replace-path write-time validation (F1, issue #878 CE Gate review): a same-finding_key replacement candidate must be validated before ever being spliced into the sibling body' {
        It 'refuses a same-finding_key replacement with a schema-invalid field and leaves the sibling body byte-identical' {
            $siblingId = 700007
            $staleBlock = New-LedgerBlockText -FindingSuffix 'K' -Severity 'low'
            $judge = New-JudgeRulingsText -Entries @(@{ FindingId = 'K'; Ruling = 'sustained' })
            Add-MockComment -Id 111222333 -Body "$script:PlanMarker`n`n<!-- phase-containment-ledger-ref: $siblingId -->`n`nplan body."
            Add-MockComment -Id $siblingId -Body "$script:LedgerMarker`n`n$judge`n`n$staleBlock"

            # Same finding_key ('K') as the pre-existing block above, but the
            # candidate's severity value is outside ValidSeverities
            # (phase-containment-core.ps1:40 -- critical|high|medium|low).
            # The append path routes every candidate through Add-CommentBlocks'
            # #842/s4 preflight (phase-containment-emission-check-core.ps1:
            # 3037-3088), which runs Test-PhaseContainmentEntry and refuses
            # BEFORE ever posting; the replace branch
            # (persist-phase-ledger-core.ps1:493-513) has no equivalent gate
            # today -- it only checks finding_key presence and opening-tag
            # recognizability, then splices unconditionally.
            $badBlock = New-LedgerBlockText -FindingSuffix 'K' -Severity 'catastrophic'
            $result = Invoke-PersistPhaseLedger -Owner $script:Owner -Repo $script:Repo -Mode plan `
                -IssueNumber $script:IssueNumber -JudgeRulingsContent $judge -PhaseContainmentBlocks @($badBlock)

            $result.Success | Should -Be $false
            $result.Reason | Should -Match ([regex]::Escape('plan-stress-test:878:K'))
            $result.Reason | Should -Match 'severity'

            $finalSibling = ($script:mockComments | Where-Object { $_.Id -eq $siblingId }).body
            $finalSibling | Should -Match ([regex]::Escape($staleBlock))
            $finalSibling | Should -Not -Match 'severity: catastrophic'
            foreach ($p in ($script:PatchLog | Where-Object { $_.CommentId -eq $siblingId })) {
                $p.Body | Should -Not -Match 'severity: catastrophic'
            }
        }

        It 'refuses a same-finding_key replacement candidate that is an unclosed block, without corrupting a different, valid neighboring block' {
            $siblingId = 700008
            $survivingBlock = New-LedgerBlockText -FindingSuffix 'SAFE'
            $targetBlock = New-LedgerBlockText -FindingSuffix 'UNCLOSED'
            $judge = New-JudgeRulingsText -Entries @(
                @{ FindingId = 'SAFE'; Ruling = 'sustained' }
                @{ FindingId = 'UNCLOSED'; Ruling = 'sustained' }
            )
            Add-MockComment -Id 111222333 -Body "$script:PlanMarker`n`n<!-- phase-containment-ledger-ref: $siblingId -->`n`nplan body."
            Add-MockComment -Id $siblingId -Body "$script:LedgerMarker`n`n$judge`n`n$survivingBlock`n`n$targetBlock"

            # Same finding_key ('UNCLOSED') as $targetBlock above, but with
            # the closing `<!-- /phase-containment-878 -->` tag stripped --
            # the unclosed-block class Add-CommentBlocks' preflight refuses
            # via SkippedCount (#772 D6, #863 M6) before ever posting.
            $unclosedBlock = ($targetBlock -split "`n" | Where-Object { $_ -ne '<!-- /phase-containment-878 -->' }) -join "`n"
            $result = Invoke-PersistPhaseLedger -Owner $script:Owner -Repo $script:Repo -Mode plan `
                -IssueNumber $script:IssueNumber -JudgeRulingsContent $judge -PhaseContainmentBlocks @($unclosedBlock)

            $result.Success | Should -Be $false

            $finalSibling = ($script:mockComments | Where-Object { $_.Id -eq $siblingId }).body
            # The unrelated, valid neighboring block must survive
            # byte-identical -- it must never be silently absorbed by a
            # malformed splice that is missing its own closing tag.
            $finalSibling | Should -Match ([regex]::Escape($survivingBlock))
            # Structural sanity: every opening phase-containment-878 tag
            # still has a matching closing tag. A refuse-before-splice
            # implementation leaves this pair-count untouched; the current
            # raw-splice replace path drops one closing tag -- an imbalance
            # that leaves the neighboring block's own boundary ambiguous to
            # any future parse of this same body.
            $openCount = ([regex]::Matches($finalSibling, '<!--\s*phase-containment-878\s*-->')).Count
            $closeCount = ([regex]::Matches($finalSibling, '<!--\s*/phase-containment-878\s*-->')).Count
            $closeCount | Should -Be $openCount
        }
    }

    Context 'Design-mode append (M22): straight append onto the design-completion comment, no sibling, no pointer' {
        It 'appends the phase-containment blocks directly onto the design completion comment with no plan-comment interaction and no sibling creation' {
            $designCommentId = 321321321
            $designMarker = '<!-- design-phase-complete-878 -->'
            Add-MockComment -Id $designCommentId -Body "$designMarker`n`nDesign completion summary."

            # Design-challenge review is prosecution-only (no judge stage --
            # skills/adversarial-review/adapters/design-challenge.md: "Defense
            # and judge stages are intentionally absent"), so a real caller
            # never has genuine judge-rulings data to supply here. This test
            # deliberately still passes a populated -JudgeRulingsContent (the
            # value the parameter's Mandatory attribute forces every caller
            # to supply regardless of -Mode) specifically to prove design
            # mode ignores it rather than merely happening not to receive it.
            $judgeContent = New-JudgeRulingsText -Entries @(@{ FindingId = 'D1'; Ruling = 'sustained' })
            $block = New-LedgerBlockText -FindingSuffix 'D1'
            $result = Invoke-PersistPhaseLedger -Owner $script:Owner -Repo $script:Repo -Mode design `
                -DesignCommentId $designCommentId -JudgeRulingsContent $judgeContent -PhaseContainmentBlocks @($block)

            $result.Success | Should -Be $true
            ($script:ghCallLog | Where-Object { $_ -match '^issue view' }) | Should -BeNullOrEmpty
            ($script:PostLog) | Should -BeNullOrEmpty
            $script:PatchLog | ForEach-Object { $_.CommentId | Should -Be $designCommentId }
            $finalBody = ($script:mockComments | Where-Object { $_.Id -eq $designCommentId }).body
            $finalBody | Should -Match ([regex]::Escape($designMarker))
            # The phase-containment block DOES land on the design comment
            # (Add-CommentBlocks stamps its own appended_at:, so match on the
            # finding_key identity line rather than the literal input block).
            $finalBody | Should -Match ([regex]::Escape('finding_key: plan-stress-test:878:D1'))
            # ...but a judge-rulings block must never be written to the
            # design surface, even though -JudgeRulingsContent carried a
            # real, populated block with finding_id: D1. Assert both the
            # head pattern is absent and no PATCH body sent for this comment
            # ever contained a judge-rulings block.
            $finalBody | Should -Not -Match '<!--\s*judge-rulings'
            foreach ($p in ($script:PatchLog | Where-Object { $_.CommentId -eq $designCommentId })) {
                $p.Body | Should -Not -Match '<!--\s*judge-rulings'
            }
        }

        It 'never writes a judge-rulings block even when PhaseContainmentBlocks is empty (zero-findings design path)' {
            $designCommentId = 321321322
            $designMarker = '<!-- design-phase-complete-878 -->'
            Add-MockComment -Id $designCommentId -Body "$designMarker`n`nDesign completion summary."

            $judgeContent = New-JudgeRulingsText -Entries @(@{ FindingId = 'D2'; Ruling = 'sustained' })
            $result = Invoke-PersistPhaseLedger -Owner $script:Owner -Repo $script:Repo -Mode design `
                -DesignCommentId $designCommentId -JudgeRulingsContent $judgeContent -PhaseContainmentBlocks @()

            $result.Success | Should -Be $true
            # No blocks to write and no judge-rulings step -- nothing should
            # touch the design comment at all.
            $script:PatchLog | Where-Object { $_.CommentId -eq $designCommentId } | Should -BeNullOrEmpty
            $finalBody = ($script:mockComments | Where-Object { $_.Id -eq $designCommentId }).body
            $finalBody | Should -Not -Match '<!--\s*judge-rulings'
            $finalBody | Should -Not -Match 'finding_id: D2'
        }
    }
}
