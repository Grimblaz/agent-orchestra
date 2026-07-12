#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Add-FollowUpIssue' {

    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        $script:ScriptFile = Join-Path $script:RepoRoot 'skills/safe-operations/scripts/Add-FollowUpIssue.ps1'

        # Load the script
        if (Test-Path $script:ScriptFile) {
            . $script:ScriptFile
        }

        # Create temporary directory for physical logs
        $script:TempDir = Join-Path ([System.IO.Path]::GetTempPath()) "gh-mock-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null

        $script:LogFile = Join-Path $script:TempDir 'gh-call.log'

        # Per-test mock-state knobs are set on $script:* in BeforeEach and read inside the mock.
        $script:GraphqlAttempt = 0
        $script:GraphqlFailFirst = $false
        $script:GraphqlFailAll = $false
        $script:CapturedCreateBody = $null
        $script:CapturedEditBody = $null

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$RemainingArgs)
            $joined = $RemainingArgs -join ' '
            $joined | Out-File -FilePath $script:LogFile -Append -Encoding UTF8

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
            if ($joined -match 'issue\s+view\s+\d+\s+--json\s+id\s+--jq\s+\.id') {
                $global:LASTEXITCODE = 0
                if ($joined -match 'view\s+610') {
                    return 'I_parent_610'
                }
                return 'I_child_999'
            }
            if ($joined -match 'api\s+graphql') {
                $script:GraphqlAttempt++
                if ($script:GraphqlFailAll) {
                    $global:LASTEXITCODE = 1
                    return $null
                }
                if ($script:GraphqlFailFirst -and $script:GraphqlAttempt -eq 1) {
                    $global:LASTEXITCODE = 1
                    return $null
                }
                $global:LASTEXITCODE = 0
                return '{"data":{"addSubIssue":{"issue":{"title":"Child"}}}}'
            }
            return ''
        }
    }

    BeforeEach {
        if (Test-Path $script:LogFile) { Remove-Item $script:LogFile -Force }
        $script:GraphqlAttempt = 0
        $script:GraphqlFailFirst = $false
        $script:GraphqlFailAll = $false
        $script:CapturedCreateBody = $null
        $script:CapturedEditBody = $null
        $global:LASTEXITCODE = 0
    }

    AfterAll {
        if (Get-Command gh -ErrorAction SilentlyContinue) {
            Remove-Item Function:\gh -ErrorAction SilentlyContinue
        }
        if (Test-Path $script:TempDir) {
            Remove-Item -Recurse -Force $script:TempDir -ErrorAction SilentlyContinue
        }
    }

    Context 'Happy Path' {
        It 'successfully creates a follow-up issue with GraphQL parent linkage' {
            $Result = Add-FollowUpIssue -ParentIssue 610 -Title "Test Title" -Body "Test Body" -Labels @("priority: medium", "filed-by: code-conductor") -FilingProvenance 'gate-approved'

            $Result | Should -Be "https://github.com/Grimblaz/agent-orchestra/issues/999"

            # Verify issue create command carried both labels
            $log = Get-Content $script:LogFile -Raw
            $log | Should -Match 'issue create'
            $log | Should -Match 'priority: medium'
            $log | Should -Match 'filed-by: code-conductor'

            # M13: successful GraphQL path writes the graphql parent-link-mode marker in the
            # follow-up `gh issue edit` body.
            $script:CapturedEditBody | Should -Not -BeNullOrEmpty
            $script:CapturedEditBody | Should -Match '<!-- parent-link-mode: graphql -->'
        }
    }

    Context 'Retry & Fallback' {

        # M14 rewrite: separate "retry recovers on attempt 2" from "both attempts fail ->
        # text-fallback". The prior single test asserted only that the URL came back, which
        # is captured from `gh issue create` and is independent of the GraphQL outcome.

        It 'retries once on first-attempt GraphQL failure and succeeds when the second attempt passes' {
            $script:GraphqlFailFirst = $true

            $warnings = @()
            $Result = Add-FollowUpIssue `
                -ParentIssue 610 `
                -Title 'Retry recovers' `
                -Body 'Test Body' `
                -Labels @('priority: medium') `
                -FilingProvenance 'gate-approved' `
                -WarningVariable warnings -WarningAction SilentlyContinue

            $Result | Should -Be 'https://github.com/Grimblaz/agent-orchestra/issues/999'
            # Exactly two graphql calls — one failed, one succeeded.
            $script:GraphqlAttempt | Should -Be 2

            $logLines = Get-Content $script:LogFile
            $graphqlCalls = $logLines | Where-Object { $_ -match 'api graphql' }
            $graphqlCalls.Count | Should -Be 2

            # Recovery on attempt 2 means parent-link-mode marker is `graphql`, not `text-fallback`.
            $script:CapturedEditBody | Should -Match '<!-- parent-link-mode: graphql -->'
            $script:CapturedEditBody | Should -Not -Match 'parent-link-mode: text-fallback'

            # No "Failed to link" warning when the second attempt succeeds.
            ($warnings | Where-Object { $_ -match 'Failed to link' }).Count | Should -Be 0
        }

        It 'falls back to text-fallback parent-link-mode and emits a warning when both GraphQL attempts fail' {
            $script:GraphqlFailAll = $true

            $warnings = @()
            $Result = Add-FollowUpIssue `
                -ParentIssue 610 `
                -Title 'Fallback path' `
                -Body 'Test Body' `
                -Labels @('priority: medium') `
                -FilingProvenance 'gate-approved' `
                -WarningVariable warnings -WarningAction SilentlyContinue

            # gh issue create still returned the URL; that part is independent of GraphQL.
            $Result | Should -Be 'https://github.com/Grimblaz/agent-orchestra/issues/999'
            $script:GraphqlAttempt | Should -Be 2

            # M13: failure path writes `text-fallback` marker.
            $script:CapturedEditBody | Should -Not -BeNullOrEmpty
            $script:CapturedEditBody | Should -Match '<!-- parent-link-mode: text-fallback -->'
            $script:CapturedEditBody | Should -Not -Match 'parent-link-mode: graphql -->'

            # Caller is warned about the link failure.
            ($warnings | Where-Object { $_ -match 'Failed to link' }).Count | Should -BeGreaterThan 0
        }
    }

    Context 'Title Canonicalization' {
        It 'produces a deterministic title format' {
            $Title = ConvertTo-CanonicalFollowupTitle -FindingSubject "Refactor locales" -CriterionIds @("S-cross-cutting")
            $Title | Should -Be "[Structural] S-cross-cutting: Refactor locales"
        }

        It 'trims spaces and trailing periods/colons' {
            $Title = ConvertTo-CanonicalFollowupTitle -FindingSubject "  Refactor locales. : " -CriterionIds @("S-design-decision")
            $Title | Should -Be "[Structural] S-design-decision: Refactor locales"
        }
    }

    Context '-FilingProvenance parameter (#837 DD7)' {
        # PF20: never invoke with a missing mandatory param - that can prompt-hang
        # a non-interactive host. Assert mandatory-ness via Get-Command metadata.
        It 'is declared as a mandatory parameter' {
            $cmd = Get-Command Add-FollowUpIssue
            $attr = $cmd.Parameters['FilingProvenance'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }
            $attr.Mandatory | Should -Be $true
        }

        It 'declares the five-member ValidateSet enum authoritative for #837 DD7' {
            $cmd = Get-Command Add-FollowUpIssue
            $validateSet = $cmd.Parameters['FilingProvenance'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
            $validateSet.ValidValues | Should -Be @('gate-approved', 'gate-modified', 'queue-consumed', 'direct-request', 'pre-gate-legacy')
        }

        It 'rejects a value outside the five-member ValidateSet enum' {
            {
                Add-FollowUpIssue -ParentIssue 610 -Title 'Bad provenance' -Body 'Test Body' -Labels @('priority: medium') -FilingProvenance 'not-a-real-value' -ErrorAction Stop
            } | Should -Throw
        }

        It 'stamps the provenance value into the composed issue body beside the sentinel' {
            $Result = Add-FollowUpIssue -ParentIssue 610 -Title 'Provenance stamp test' -Body 'Test Body' -Labels @('priority: medium') -FilingProvenance 'queue-consumed'

            $Result | Should -Be 'https://github.com/Grimblaz/agent-orchestra/issues/999'
            $script:CapturedCreateBody | Should -Not -BeNullOrEmpty
            $script:CapturedCreateBody | Should -Match '<!-- filing-provenance: queue-consumed -->'
        }
    }
}
