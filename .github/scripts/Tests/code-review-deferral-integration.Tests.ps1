#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Code-Review-Deferral-Integration' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:CriteriaScript = Join-Path $script:RepoRoot 'skills/review-judgment/scripts/Test-DeferralCriteria.ps1'
        $script:SafeOpsScript = Join-Path $script:RepoRoot 'skills/safe-operations/scripts/Add-FollowUpIssue.ps1'

        # Dot-source both if available
        if (Test-Path $script:CriteriaScript) {
            . $script:CriteriaScript
        }
        if (Test-Path $script:SafeOpsScript) {
            . $script:SafeOpsScript
        }

        # Shared mock state for AC8 sentinel-write tests
        $script:CapturedCreateBody = $null
        $script:CapturedEditBody = $null

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$RemainingArgs)
            $joined = $RemainingArgs -join ' '

            if ($joined -match 'issue\s+create') {
                $idx = [array]::IndexOf($RemainingArgs, '--body')
                if ($idx -ge 0 -and $idx + 1 -lt $RemainingArgs.Count) {
                    $script:CapturedCreateBody = $RemainingArgs[$idx + 1]
                }
                $global:LASTEXITCODE = 0
                return 'https://github.com/Grimblaz/agent-orchestra/issues/999'
            }
            if ($joined -match 'issue\s+edit') {
                $idx = [array]::IndexOf($RemainingArgs, '--body')
                if ($idx -ge 0 -and $idx + 1 -lt $RemainingArgs.Count) {
                    $script:CapturedEditBody = $RemainingArgs[$idx + 1]
                }
                $global:LASTEXITCODE = 0
                return ''
            }
            if ($joined -match 'issue\s+view') {
                $global:LASTEXITCODE = 0
                return 'I_node_id'
            }
            if ($joined -match 'api\s+graphql') {
                $global:LASTEXITCODE = 0
                return '{"data":{"addSubIssue":{"issue":{"title":"Child"}}}}'
            }
            return ''
        }
    }

    BeforeEach {
        $script:CapturedCreateBody = $null
        $script:CapturedEditBody = $null
        $global:LASTEXITCODE = 0
    }

    AfterAll {
        if (Get-Command gh -ErrorAction SilentlyContinue) {
            Remove-Item Function:\gh -ErrorAction SilentlyContinue
        }
    }

    Context 'AC Cross-Check Precedence (AC2 behavioral)' {
        It 'ensures findings matching explicit issue ACs are forced to ACCEPT even if they touch S-cross-cutting' {
            $Finding = @{
                id    = "F_ac_behavioral"
                text  = "Requires refactoring files in agents, skills, commands, and hooks."
                files = @(
                    "agents/Code-Conductor.agent.md",
                    "skills/routing-tables/SKILL.md",
                    "commands/plan.md",
                    "hooks/pre-commit.ps1"
                )
            }
            $PrFileSet = @("agents/Code-Conductor.agent.md")

            # Scenario A: No AC match -> should be DEFERRED-SIGNIFICANT
            $ResultNoAc = Get-StructuralVerdict -Finding $Finding -PrFileSet $PrFileSet -AcRefs @()
            $ResultNoAc.verdict | Should -Be 'DEFERRED-SIGNIFICANT (structural)'

            # Scenario B: Mapped to AC -> should be ACCEPT (fix inline)
            $ResultWithAc = Get-StructuralVerdict -Finding $Finding -PrFileSet $PrFileSet -AcRefs @("hooks/pre-commit.ps1")
            $ResultWithAc.verdict | Should -Be 'ACCEPT (fix inline)'
        }

        # M12: AC precedence override must preserve matched_criteria for D7 calibration.
        It 'preserves matched_criteria when AC precedence overrides the structural verdict (M12)' {
            $Finding = @{
                id    = "F_ac_preserve"
                text  = "Requires refactoring files in agents, skills, commands, and hooks."
                files = @(
                    "agents/Code-Conductor.agent.md",
                    "skills/routing-tables/SKILL.md",
                    "commands/plan.md",
                    "hooks/pre-commit.ps1"
                )
            }
            $PrFileSet = @("agents/Code-Conductor.agent.md")
            # Map one file to an AC ref so precedence fires
            $AcRefs = @("hooks/pre-commit.ps1")

            $Result = Get-StructuralVerdict -Finding $Finding -PrFileSet $PrFileSet -AcRefs $AcRefs

            $Result.verdict | Should -Be 'ACCEPT (fix inline)'
            $Result.ac_precedence | Should -Be $true
            # The finding still tripped S-cross-cutting (4 modules); calibration must see it.
            $Result.matched_criteria | Should -Contain 'S-cross-cutting'
        }
    }

    Context 'Safe-Ops §2c Dedup Chain & Title Canonicalization (AC7)' {
        It 'produces deterministic canonical titles for both adversarial and bot reviews' {
            $Title1 = ConvertTo-CanonicalFollowupTitle -FindingSubject "Locale-stable sort" -CriterionIds @("S-cross-cutting")
            $Title2 = ConvertTo-CanonicalFollowupTitle -FindingSubject "  Locale-stable sort.  " -CriterionIds @("S-cross-cutting")

            $Title1 | Should -Be "[Structural] S-cross-cutting: Locale-stable sort"
            $Title2 | Should -Be $Title1
        }
    }

    Context 'D7 Instrumentation Markers (AC8)' {
        # M2: replace tautological literal-non-empty assertion with a real sentinel-write
        # exercise that invokes Add-FollowUpIssue against the gh mock and inspects the
        # body actually passed to `gh issue create`.

        It 'writes the code-conductor-filed-followup sentinel with matched criterion_ids and originating PR into the issue body' {
            $result = Add-FollowUpIssue `
                -ParentIssue 610 `
                -Title 'AC8 sentinel test' `
                -Body 'caller body content' `
                -Labels @('priority: medium', 'filed-by: code-conductor') `
                -CriterionIds @('S-cross-cutting', 'S-new-abstraction') `
                -OriginatingPr '350'

            $result | Should -Be 'https://github.com/Grimblaz/agent-orchestra/issues/999'
            $script:CapturedCreateBody | Should -Not -BeNullOrEmpty
            $script:CapturedCreateBody | Should -Match '<!-- code-conductor-filed-followup'
            $script:CapturedCreateBody | Should -Match 'criterion_ids:\s*\[S-cross-cutting,\s*S-new-abstraction\]'
            $script:CapturedCreateBody | Should -Match 'originating_pr:\s*350'
            # Parent text reference is the M13 fallback contract — always present.
            $script:CapturedCreateBody | Should -Match 'Parent:\s+#610'
        }

        It 'writes the sentinel with an empty criterion_ids list and omits originating_pr when those inputs are absent' {
            $result = Add-FollowUpIssue `
                -ParentIssue 610 `
                -Title 'AC8 sentinel - empty inputs' `
                -Body 'caller body content' `
                -Labels @('priority: medium')

            $result | Should -Be 'https://github.com/Grimblaz/agent-orchestra/issues/999'
            $script:CapturedCreateBody | Should -Match '<!-- code-conductor-filed-followup'
            $script:CapturedCreateBody | Should -Match 'criterion_ids:\s*\[\]'
            $script:CapturedCreateBody | Should -Not -Match 'originating_pr'
        }
    }

    Context 'Synthetic Finding Corpus (AC9)' {
        $FixturesDir = Join-Path $PSScriptRoot 'fixtures/deferral-criteria'
        $Fixtures = @()
        if (Test-Path $FixturesDir) {
            $Fixtures = Get-ChildItem -Path $FixturesDir -Filter '*.json' | ForEach-Object {
                $data = Get-Content -Raw $_.FullName | ConvertFrom-Json -AsHashtable
                $data['basename'] = $_.BaseName
                $data
            }
        }

        It 'correctly executes all synthetic corpus cases and matches expected verdicts' -ForEach $Fixtures {
            $Fixture = $_
            $Finding = @{
                id    = $Fixture['finding_id']
                text  = $Fixture['finding_text']
                files = $Fixture['finding_file_set']
            }
            $PrFileSet = [string[]]$Fixture['pr_file_set']
            $AcRefs = [string[]]$Fixture['ac_refs']

            $Result = Get-StructuralVerdict -Finding $Finding -PrFileSet $PrFileSet -AcRefs $AcRefs

            $Result.verdict | Should -Be $Fixture['expected_verdict']
        }
    }

    Context 'Copilot Parity (AC10)' {
        It 'produces at least 1 positive hit for Code-Review-Response reference in prompts' {
            $PromptFiles = Get-ChildItem -Path (Join-Path $script:RepoRoot '.github/prompts') -Filter 'review*.prompt.md'
            $Matched = $false
            foreach ($File in $PromptFiles) {
                $Content = Get-Content -Raw $File.FullName
                if ($Content -match 'Code-Review-Response\.agent\.md') {
                    $Matched = $true
                    break
                }
            }
            $Matched | Should -Be $true -Because 'At least one review prompt must reference the shared Code-Review-Response.agent.md body'
        }

        It 'contains zero hits for effort estimates [less than 1 day or greater than 1 day] in prompts' {
            $PromptFiles = Get-ChildItem -Path (Join-Path $script:RepoRoot '.github/prompts') -Filter 'review*.prompt.md'
            foreach ($File in $PromptFiles) {
                $Content = Get-Content -Raw $File.FullName
                $Content | Should -Not -Match '(<1 day|>1 day)' -Because 'Effort estimates must be absent from prompts'
            }
        }

        # M21: extend negative-grep across dependent agent bodies, skill, and design docs.
        # Code-review.md is excluded because it retains explicit rename-rationale text per Doc-Keeper M18.
        It 'contains zero hits for effort estimates in dependent agent bodies, skills, and design docs (M21)' {
            $TargetFiles = @(
                'agents/Code-Review-Response.agent.md',
                'agents/Code-Conductor.agent.md',
                'skills/safe-operations/SKILL.md',
                'Documents/Design/safe-operations.md',
                'Documents/Design/setup-wizard.md',
                'skills/validation-methodology/references/review-reconciliation.md'
            )
            foreach ($Rel in $TargetFiles) {
                $Full = Join-Path $script:RepoRoot $Rel
                $Full | Should -Exist -Because "M21 target file must exist: $Rel"
                $Content = Get-Content -Raw $Full
                $Content | Should -Not -Match '(<1 day|>1 day)' -Because "Effort estimates must be absent from $Rel"
            }
        }

        # M21: positive grep — the Copilot-visible contract for the rename is that the
        # shared agent body and intake skill referenced from the review prompts carry the
        # renamed verdict labels. Prompts themselves are intentionally thin shells, so the
        # assertion targets the bodies/skills they delegate to. This is the transitive
        # Copilot-parity contract: prompt -> referenced body -> renamed labels.
        It 'canonical categorization sources carry both renamed verdict labels (M21)' {
            # Canonical label authors: the judge body (Code-Review-Response) and the
            # GitHub-intake skill. Code-Conductor consumes the categorization for routing
            # and only references (structural); it intentionally does not re-author both
            # labels, so it is excluded from this assertion.
            $LabelSources = @(
                'agents/Code-Review-Response.agent.md',
                'skills/code-review-intake/SKILL.md'
            )
            foreach ($Rel in $LabelSources) {
                $Full = Join-Path $script:RepoRoot $Rel
                $Full | Should -Exist -Because "Label-source file must exist: $Rel"
                $Content = Get-Content -Raw $Full
                $Content | Should -Match '\(fix inline\)' -Because "$Rel must reference the renamed ACCEPT label '(fix inline)'"
                $Content | Should -Match '\(structural\)' -Because "$Rel must reference the renamed DEFERRED-SIGNIFICANT label '(structural)'"
            }
            # Code-Conductor must reference at least (structural) since it auto-tracks deferred items.
            $ConductorContent = Get-Content -Raw (Join-Path $script:RepoRoot 'agents/Code-Conductor.agent.md')
            $ConductorContent | Should -Match '\(structural\)' -Because 'Code-Conductor must reference the renamed DEFERRED-SIGNIFICANT label it auto-tracks'
        }

        It 'contains the D6 / D7 dispatcher model and shared body load citation in design docs' {
            $ArchDoc = Join-Path $script:RepoRoot 'Documents/Design/agent-body-architecture.md'
            $ArchDoc | Should -Exist
            $Content = Get-Content -Raw $ArchDoc

            $Content | Should -Match 'D7' -Because 'Must cite the dispatcher model / inline command command-front-end routing'
            $Content | Should -Match 'D8' -Because 'Must cite the thin shells over canonical shared bodies'
        }
    }

    Context 'ARM 2 behavioral-term cross-check (AC1/AC5)' {

        It 'produces ac_cross_check.result=matched-high when a behavioral AC term appears in finding text' {
            $Finding = @{
                id    = "F_term_behavioral"
                text  = "The triage-labeled issues fetch is missing from the renderer."
                files = @("skills/review-judgment/SKILL.md")
            }
            $AcTerms = @(
                [PSCustomObject]@{
                    term           = 'triage'
                    source_ac_line = '- the renderer must fetch `triage`-labeled issues'
                    is_behavioral  = $true
                }
            )
            $Result = Get-StructuralVerdict -Finding $Finding -PrFileSet @() -AcRefs @() -AcTerms $AcTerms

            $Result.ac_cross_check           | Should -Not -BeNullOrEmpty
            $Result.ac_cross_check.term_arm  | Should -Be $true
            $Result.ac_cross_check.result    | Should -Be 'matched-high'
            $Result.ac_cross_check.routed    | Should -Be 'force-accept'
        }

        It 'produces ac_cross_check.result=matched-ambiguous when a non-behavioral AC term matches' {
            $Finding = @{
                id    = "F_term_ambiguous"
                text  = "The PortfolioTracker component is not wired."
                files = @("skills/review-judgment/SKILL.md")
            }
            $AcTerms = @(
                [PSCustomObject]@{
                    term           = 'PortfolioTracker'
                    source_ac_line = '- The `PortfolioTracker` is the output component.'
                    is_behavioral  = $false
                }
            )
            $Result = Get-StructuralVerdict -Finding $Finding -PrFileSet @() -AcRefs @() -AcTerms $AcTerms

            $Result.ac_cross_check           | Should -Not -BeNullOrEmpty
            $Result.ac_cross_check.term_arm  | Should -Be $true
            $Result.ac_cross_check.result    | Should -Be 'matched-ambiguous'
            $Result.ac_cross_check.routed    | Should -Be 'disposition-gate'
        }

        It 'produces ac_cross_check.result=no-match when no AC terms appear in finding text' {
            $Finding = @{
                id    = "F_term_nomatch"
                text  = "Consider adding logging."
                files = @("skills/review-judgment/SKILL.md")
            }
            $AcTerms = @(
                [PSCustomObject]@{
                    term           = 'triage'
                    source_ac_line = '- the renderer must fetch `triage`-labeled issues'
                    is_behavioral  = $true
                }
            )
            $Result = Get-StructuralVerdict -Finding $Finding -PrFileSet @() -AcRefs @() -AcTerms $AcTerms

            $Result.ac_cross_check           | Should -Not -BeNullOrEmpty
            $Result.ac_cross_check.term_arm  | Should -Be $false
            $Result.ac_cross_check.result    | Should -Be 'no-match'
            $Result.ac_cross_check.routed    | Should -Be 'defer'
        }

        It 'file ARM takes precedence: ac_cross_check.result=matched-high when file_arm is true even without term match' {
            $Finding = @{
                id    = "F_file_arm"
                text  = "Logging gap with no AC term."
                files = @("skills/review-judgment/SKILL.md")
            }
            $AcTerms = @()  # no AC terms
            $AcRefs  = @("skills/review-judgment/SKILL.md")  # file ARM matches
            $Result = Get-StructuralVerdict -Finding $Finding -PrFileSet @("skills/review-judgment/SKILL.md") -AcRefs $AcRefs -AcTerms $AcTerms

            $Result.verdict                  | Should -Be 'ACCEPT (fix inline)'
            $Result.ac_cross_check           | Should -Not -BeNullOrEmpty
            $Result.ac_cross_check.file_arm  | Should -Be $true
            $Result.ac_cross_check.result    | Should -Be 'matched-high'
            $Result.ac_cross_check.routed    | Should -Be 'force-accept'
        }

        It 'backward compat: ac_cross_check is populated even when -AcTerms is omitted (ARM 2 = not run)' {
            $Finding = @{
                id    = "F_compat"
                text  = "Some finding."
                files = @("skills/review-judgment/SKILL.md")
            }
            # Call without -AcTerms (default @())
            $Result = Get-StructuralVerdict -Finding $Finding -PrFileSet @() -AcRefs @()

            # ac_cross_check should still be present (all fields at their default values)
            $Result.ac_cross_check           | Should -Not -BeNullOrEmpty
            $Result.ac_cross_check.term_arm  | Should -Be $false
            $Result.ac_cross_check.file_arm  | Should -Be $false
        }
    }

    Context 'Add-FollowUpIssue -AcCrossCheck parameter (M16/AC4)' {

        It 'appends ac_cross_check YAML block to body when -AcCrossCheck is provided' {
            $result = Add-FollowUpIssue `
                -ParentIssue 709 `
                -Title '[Structural] no-match: triage fetch missing' `
                -Body 'Finding: triage fetch not implemented.' `
                -Labels @('priority: medium', 'filed-by: code-conductor') `
                -CriterionIds @('S-cross-cutting') `
                -OriginatingPr '750' `
                -AcCrossCheck @{
                    file_arm = $false
                    term_arm = $false
                    result   = 'no-match'
                    source   = 'issue'
                    routed   = 'defer'
                }

            $result | Should -Be 'https://github.com/Grimblaz/agent-orchestra/issues/999'
            $script:CapturedCreateBody | Should -Match 'AC Cross-Check'
            $script:CapturedCreateBody | Should -Match 'result:\s*no-match'
            $script:CapturedCreateBody | Should -Match 'routed:\s*defer'
            $script:CapturedCreateBody | Should -Match 'file_arm:\s*false'
        }

        It 'does NOT append ac_cross_check block when -AcCrossCheck is absent' {
            $result = Add-FollowUpIssue `
                -ParentIssue 709 `
                -Title '[Structural] S-cross-cutting: some finding' `
                -Body 'Caller body without ac cross check.' `
                -Labels @('priority: medium', 'filed-by: code-conductor')

            $result | Should -Be 'https://github.com/Grimblaz/agent-orchestra/issues/999'
            $script:CapturedCreateBody | Should -Not -Match 'ac_cross_check'
        }
    }

    Context 'Autonomous path — CR8/CR9 originating incident (AC1)' {

        BeforeAll {
            # Dot-source Get-AcTermsFromIssue if not already loaded
            $script:AcTermsScript = Join-Path $script:RepoRoot 'skills/review-judgment/scripts/Get-AcTermsFromIssue.ps1'
            if (Test-Path $script:AcTermsScript) {
                . $script:AcTermsScript
            }

            # Save the current global gh function and override it so that
            # 'gh issue view <num> --json body --jq .body' returns a markdown
            # body containing a behavioral AC section. The outer global:gh mock
            # returns 'I_node_id' for all issue view calls, which is not a valid
            # issue body for Get-AcTermsFromIssue. We replace it here and restore
            # in AfterAll so the other contexts are unaffected.
            $script:OriginalGhFunction = (Get-Item Function:\gh -ErrorAction SilentlyContinue)
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)]$RemainingArgs)
                $joined = $RemainingArgs -join ' '

                if ($joined -match 'issue\s+view' -and $joined -match '--json\s+body') {
                    $global:LASTEXITCODE = 0
                    return @'
## Acceptance Criteria

- the renderer must fetch `triage`-labeled issues repo-wide
- the `portfolio-tracker` label is applied unconditionally to all new portfolio issues
'@
                }
                if ($joined -match 'issue\s+create') {
                    $idx = [array]::IndexOf($RemainingArgs, '--body')
                    if ($idx -ge 0 -and $idx + 1 -lt $RemainingArgs.Count) {
                        $script:CapturedCreateBody = $RemainingArgs[$idx + 1]
                    }
                    $global:LASTEXITCODE = 0
                    return 'https://github.com/Grimblaz/agent-orchestra/issues/999'
                }
                if ($joined -match 'issue\s+edit') {
                    $global:LASTEXITCODE = 0
                    return ''
                }
                if ($joined -match 'issue\s+view') {
                    $global:LASTEXITCODE = 0
                    return 'I_node_id'
                }
                if ($joined -match 'api\s+graphql') {
                    $global:LASTEXITCODE = 0
                    return '{"data":{"addSubIssue":{"issue":{"title":"Child"}}}}'
                }
                return ''
            }
        }

        AfterAll {
            # Restore the outer global:gh function defined by the Describe BeforeAll.
            # Re-define it with the original implementation rather than trying to
            # copy the function object (which is not reliably cloneable in PS7).
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)]$RemainingArgs)
                $joined = $RemainingArgs -join ' '

                if ($joined -match 'issue\s+create') {
                    $idx = [array]::IndexOf($RemainingArgs, '--body')
                    if ($idx -ge 0 -and $idx + 1 -lt $RemainingArgs.Count) {
                        $script:CapturedCreateBody = $RemainingArgs[$idx + 1]
                    }
                    $global:LASTEXITCODE = 0
                    return 'https://github.com/Grimblaz/agent-orchestra/issues/999'
                }
                if ($joined -match 'issue\s+edit') {
                    $idx = [array]::IndexOf($RemainingArgs, '--body')
                    if ($idx -ge 0 -and $idx + 1 -lt $RemainingArgs.Count) {
                        $script:CapturedEditBody = $RemainingArgs[$idx + 1]
                    }
                    $global:LASTEXITCODE = 0
                    return ''
                }
                if ($joined -match 'issue\s+view') {
                    $global:LASTEXITCODE = 0
                    return 'I_node_id'
                }
                if ($joined -match 'api\s+graphql') {
                    $global:LASTEXITCODE = 0
                    return '{"data":{"addSubIssue":{"issue":{"title":"Child"}}}}'
                }
                return ''
            }
        }

        It 'full autonomous path: Get-AcTermsFromIssue feeds Get-StructuralVerdict and routes force-accept for behavioral AC term in finding' {
            # Step 1: extract AC terms from the mock issue
            $acTerms = Get-AcTermsFromIssue -IssueNumber '709'
            $acTerms | Should -Not -BeNullOrEmpty
            ($acTerms | Select-Object -ExpandProperty term) | Should -Contain 'triage'

            # Step 2: feed AC terms into Get-StructuralVerdict for a finding that mentions 'triage'
            $Finding = @{
                id    = "F_cr8_cr9"
                text  = "The triage-labeled issue fetch is not wired in the renderer."
                files = @("skills/portfolio-tracker/SKILL.md")
            }

            $Result = Get-StructuralVerdict `
                -Finding   $Finding `
                -PrFileSet @() `
                -AcRefs    @() `
                -RepoRoot  $script:RepoRoot `
                -AcTerms   $acTerms

            $Result.ac_cross_check           | Should -Not -BeNullOrEmpty
            $Result.ac_cross_check.term_arm  | Should -Be $true
            $Result.ac_cross_check.result    | Should -Be 'matched-high'
            $Result.ac_cross_check.routed    | Should -Be 'force-accept'
        }
    }
}
