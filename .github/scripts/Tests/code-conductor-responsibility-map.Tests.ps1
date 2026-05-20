#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:ResponsibilityMapPath = Join-Path $script:RepoRoot 'Documents/Design/code-conductor-responsibility-map.md'
    $script:Issue557CoverageTargetFixture = @'
### Coverage target

Integration test 1: The body covers Code Conductor Agent, Ownership Principles, D-rules D1-D14, Model-Switch Checkpoint (Authorized Hub-Mode Pause), Review Workflow Interruption Budget (Balanced Policy), Continuation Contract (Mandatory), Overview, Usage Examples, Plan Creation Strategy, Process, Step protocols Step 0-5, Core Workflow, Issue Transition Step 0, Hub Mode + Smart Resume, Non-hub-mode invocation (slash-command path), Scope Classification Gate, Downstream Ownership Boundary, D9 Model-Switch Checkpoint (Hub Mode Only), Branch Authority Gate, Multi-Issue Bundling, Hub Execution Workflow, Locate Plan & Context, D12 Commit policy detection, Determine Resume Point & Validate Plan, D13 Step commit reconciliation, D10 Capacity check, Execute Each Step, Create PR Step 4, Report Completion Step 5, Build-Test Orchestration, Property-Based Testing (PBT) Rollout Policy, Agent Selection, Review Reconciliation Loop (Mandatory), Skill Mapping, Validation Ladder (Mandatory), Validation Ladder tiers, Customer Experience Gate (CE Gate), PR Body Pipeline Metrics, Pipeline Metrics, Pipeline-Entry Credit Harvest (SMC-17), Deferred Port Credit Rows, Post-PR Credit Row (D10 category 3), Refactoring Phase is MANDATORY, Tactical Adaptation, Subagent Call Resilience (R5), Error Handling, Context Management for Long Sessions, Handoff to User, and Best Practices. Each is in scope for the responsibility map.
'@

    function script:Test-CCRMLiveGitHubOptIn {
        return [string]::Equals($env:PESTER_LIVE_GH, '1', [System.StringComparison]::Ordinal)
    }

    function script:Get-CCRMIssueBody {
        if (-not (script:Test-CCRMLiveGitHubOptIn)) {
            return $script:Issue557CoverageTargetFixture
        }

        $body = & gh issue view 557 --json body --jq .body 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to fetch issue #557 body via 'gh issue view 557 --json body --jq .body': $($body -join [Environment]::NewLine)"
        }

        return ($body -join "`n")
    }

    function script:Get-CCRMCoverageTarget {
        param(
            [Parameter(Mandatory)]
            [string]$IssueBody
        )

        $coverageSectionMatch = [regex]::Match($IssueBody, '(?ms)^### Coverage target\s*(?<section>.*?)(?=^###\s|\z)')
        if (-not $coverageSectionMatch.Success) {
            throw "Issue #557 body does not contain a '### Coverage target' section."
        }

        $coverageSection = $coverageSectionMatch.Groups['section'].Value
        $targetListMatch = [regex]::Match(
            $coverageSection,
            '(?ms)\bbody covers\s+(?<targets>.*?)\.\s+Each is in scope'
        )

        if (-not $targetListMatch.Success) {
            $targetListMatch = [regex]::Match(
                $coverageSection,
                '(?ms)Integration test 1.*?For each named section enumerated in\s+`### Coverage target`\s*\((?<targets>.*?)\)\s*,\s*assert'
            )
        }

        if (-not $targetListMatch.Success) {
            throw "Could not extract the coverage-target section list from issue #557."
        }

        return @(
            $targetListMatch.Groups['targets'].Value -split ',' |
                ForEach-Object { ($_ -replace '^\s*and\s+(the\s+)?', '' -replace '\s+section\s*$', '').Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }

    function script:ConvertTo-CCRMComparableText {
        param(
            [AllowNull()]
            [string]$Text
        )

        if ([string]::IsNullOrWhiteSpace($Text)) {
            return ''
        }

        $mojibakeDash = [string]([char]0x0393) + [string]([char]0x00C7) + [string]([char]0x00F4)
        return (($Text -replace '[\u2010-\u2015]', '-' -replace [regex]::Escape($mojibakeDash), '-' -replace '\s*[+&]\s*', ' and ') -replace '\s+', ' ').Trim()
    }

    function script:Get-CCRMExpectedSourceAlias {
        param(
            [Parameter(Mandatory)]
            [string]$ExpectedSection
        )

        $normalizedExpectedSection = script:ConvertTo-CCRMComparableText -Text $ExpectedSection
        if ([string]::Equals($normalizedExpectedSection, 'Agent Selection', [System.StringComparison]::OrdinalIgnoreCase)) {
            return @($ExpectedSection, 'Agent Selection table')
        }

        if ([string]::Equals($normalizedExpectedSection, 'Non-hub-mode invocation (slash-command path)', [System.StringComparison]::OrdinalIgnoreCase)) {
            return @($ExpectedSection, 'Non-hub-mode invocation')
        }

        return @($ExpectedSection)
    }

    function script:Test-CCRMSourceCoversSection {
        param(
            [Parameter(Mandatory)]
            [string]$Source,

            [Parameter(Mandatory)]
            [string]$ExpectedSection
        )

        $sourceSegments = @(
            $Source -split '\s*/\s*' |
                ForEach-Object { script:ConvertTo-CCRMComparableText -Text $_ } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )

        $expectedSegments = @(
            script:Get-CCRMExpectedSourceAlias -ExpectedSection $ExpectedSection |
                ForEach-Object { script:ConvertTo-CCRMComparableText -Text $_ }
        )

        foreach ($expectedSegment in $expectedSegments) {
            foreach ($sourceSegment in $sourceSegments) {
                if ([string]::Equals($sourceSegment, $expectedSegment, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $true
                }
            }
        }

        return $false
    }

    function script:ConvertTo-CCRMRowValueText {
        param(
            [AllowNull()]
            [object]$Value
        )

        if ($null -eq $Value) {
            return ''
        }

        if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
            $normalizedItems = @(
                foreach ($item in $Value) {
                    [string]$item
                }
            )

            return [string]::Join("`n", $normalizedItems)
        }

        return [string]$Value
    }

    function script:Get-CCRMRowValue {
        param(
            [Parameter(Mandatory)]
            [object]$Row,

            [Parameter(Mandatory)]
            [string]$Name
        )

        if ($Row -is [System.Collections.IDictionary]) {
            if ($Row.Contains($Name)) {
                return script:ConvertTo-CCRMRowValueText -Value $Row[$Name]
            }

            return ''
        }

        $property = $Row.PSObject.Properties[$Name]
        if ($null -eq $property) {
            return ''
        }

        return script:ConvertTo-CCRMRowValueText -Value $property.Value
    }

    function script:Test-CCRMRowKey {
        param(
            [Parameter(Mandatory)]
            [object]$Row,

            [Parameter(Mandatory)]
            [string]$Name
        )

        if ($Row -is [System.Collections.IDictionary]) {
            return $Row.Contains($Name)
        }

        return $null -ne $Row.PSObject.Properties[$Name]
    }

    function script:Get-CCRMRowText {
        param(
            [Parameter(Mandatory)]
            [object]$Row
        )

        if ($Row -is [System.Collections.IDictionary]) {
            $rowValues = @(
                foreach ($key in $Row.Keys) {
                    script:Get-CCRMRowValue -Row $Row -Name ([string]$key)
                }
            )

            return [string]::Join(' ', $rowValues)
        }

        $propertyValues = @(
            foreach ($property in $Row.PSObject.Properties) {
                script:Get-CCRMRowValue -Row $Row -Name $property.Name
            }
        )

        return [string]::Join(' ', $propertyValues)
    }

    function script:Get-CCRMRowSource {
        param(
            [Parameter(Mandatory)]
            [object]$Row
        )

        return script:Get-CCRMRowValue -Row $Row -Name 'source'
    }

    function script:ConvertFrom-CCRMResponsibilityYaml {
        param(
            [Parameter(Mandatory)]
            [string]$Yaml
        )

        $rows = [System.Collections.Generic.List[object]]::new()
        $currentRow = $null
        $currentSequenceKey = $null
        $lineNumber = 0

        foreach ($rawLine in ($Yaml -split '\r?\n')) {
            $lineNumber++

            if ([string]::IsNullOrWhiteSpace($rawLine)) {
                continue
            }

            if ($rawLine -match '^#') {
                continue
            }

            $rowMatch = [regex]::Match($rawLine, '^-[ ]*(?<content>.*)$')
            if ($rowMatch.Success) {
                if ($null -ne $currentRow) {
                    $rows.Add($currentRow)
                }

                $currentRow = [ordered]@{}
                $currentSequenceKey = $null
                $rowContent = $rowMatch.Groups['content'].Value.Trim()

                if (-not [string]::IsNullOrWhiteSpace($rowContent)) {
                    $propertyMatch = [regex]::Match($rowContent, '^(?<key>[A-Za-z0-9_-]+):(?<value>.*)$')
                    if (-not $propertyMatch.Success) {
                        throw ('Unsupported responsibility-map YAML row start at line {0}: {1}' -f $lineNumber, $rawLine)
                    }

                    $propertyName = $propertyMatch.Groups['key'].Value
                    $currentRow[$propertyName] = script:ConvertFrom-CCRMYamlScalar -Value $propertyMatch.Groups['value'].Value
                }

                continue
            }

            if ($null -eq $currentRow) {
                throw ('Responsibility-map YAML property appeared before the first row at line {0}: {1}' -f $lineNumber, $rawLine)
            }

            $propertyLineMatch = [regex]::Match($rawLine, '^[ ]{2}(?<key>[A-Za-z0-9_-]+):(?<value>.*)$')
            if ($propertyLineMatch.Success) {
                $propertyName = $propertyLineMatch.Groups['key'].Value
                $propertyValue = $propertyLineMatch.Groups['value'].Value
                $currentSequenceKey = $null

                if ([string]::IsNullOrWhiteSpace($propertyValue)) {
                    $currentRow[$propertyName] = @()
                    $currentSequenceKey = $propertyName
                } else {
                    $currentRow[$propertyName] = script:ConvertFrom-CCRMYamlScalar -Value $propertyValue
                }

                continue
            }

            $sequenceItemMatch = [regex]::Match($rawLine, '^[ ]{4}-[ ]*(?<value>.*)$')
            if ($sequenceItemMatch.Success -and -not [string]::IsNullOrWhiteSpace($currentSequenceKey)) {
                $sequenceValue = script:ConvertFrom-CCRMYamlScalar -Value $sequenceItemMatch.Groups['value'].Value
                $currentRow[$currentSequenceKey] = @($currentRow[$currentSequenceKey]) + $sequenceValue
                continue
            }

            throw ('Unsupported responsibility-map YAML shape at line {0}: {1}' -f $lineNumber, $rawLine)
        }

        if ($null -ne $currentRow) {
            $rows.Add($currentRow)
        }

        foreach ($row in $rows) {
            $row
        }
    }

    function script:ConvertFrom-CCRMYamlScalar {
        param(
            [AllowNull()]
            [string]$Value
        )

        if ($null -eq $Value) {
            return ''
        }

        $trimmedValue = $Value.Trim()
        if ($trimmedValue -eq '""') {
            return ''
        }

        $doubleQuotedMatch = [regex]::Match($trimmedValue, '^"(?<value>.*)"$')
        if ($doubleQuotedMatch.Success) {
            return $doubleQuotedMatch.Groups['value'].Value.Replace('\"', '"')
        }

        $singleQuotedMatch = [regex]::Match($trimmedValue, "^'(?<value>.*)'$")
        if ($singleQuotedMatch.Success) {
            return $singleQuotedMatch.Groups['value'].Value.Replace("''", "'")
        }

        return $trimmedValue
    }

    function script:Get-CCRMResponsibilityRow {
        param(
            [Parameter(Mandatory)]
            [string]$MapPath
        )

        $content = Get-Content -Path $MapPath -Raw -ErrorAction Stop
        $yamlMatch = [regex]::Match($content, '(?ms)^## Responsibilities\s*\r?\n\r?\n```yaml\r?\n(?<yaml>.*?)\r?\n```')
        if (-not $yamlMatch.Success) {
            throw "Could not find the fenced YAML block under '## Responsibilities' in $MapPath."
        }

        try {
            $parsedRows = @(script:ConvertFrom-CCRMResponsibilityYaml -Yaml $yamlMatch.Groups['yaml'].Value)
        } catch {
            throw "Could not parse responsibility-map YAML: $($_.Exception.Message)"
        }

        foreach ($row in $parsedRows) {
            $row
        }
    }

    function script:Get-CCRMCurrentCodeConductorSha {
        $sha = & git -C $script:RepoRoot log -1 --format=%H -- agents/Code-Conductor.agent.md 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to read current Code-Conductor commit SHA via git log: $($sha -join [Environment]::NewLine)"
        }

        return [string]($sha | Select-Object -First 1).Trim()
    }

    function script:Invoke-CCRMGhScalar {
        param(
            [Parameter(Mandatory)]
            [string[]]$Arguments,

            [Parameter(Mandatory)]
            [string]$Context
        )

        $output = & gh @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning ("defer-stewardship warn-only: could not evaluate {0}: {1}" -f $Context, ($output -join [Environment]::NewLine))
            return $null
        }

        return ($output -join "`n").Trim()
    }

    function script:Invoke-CCRMStaleAnchorScan {
        $currentSha = script:Get-CCRMCurrentCodeConductorSha
        $rows = @(script:Get-CCRMResponsibilityRow -MapPath $script:ResponsibilityMapPath)

        foreach ($row in $rows) {
            $status = script:Get-CCRMRowValue -Row $row -Name 'verification_status'
            $verifiedAgainstSha = script:Get-CCRMRowValue -Row $row -Name 'verified-against-sha'

            if ($status -ine 'verified' -or [string]::IsNullOrWhiteSpace($verifiedAgainstSha)) {
                continue
            }

            if (-not [string]::Equals($verifiedAgainstSha, $currentSha, [System.StringComparison]::OrdinalIgnoreCase)) {
                Write-Warning ("stale-anchor warn-only: verified row '{0}' is pinned to {1}, but current Code-Conductor SHA is {2}." -f (script:Get-CCRMRowSource -Row $row), $verifiedAgainstSha, $currentSha)
            }
        }
    }

    function script:Invoke-CCRMDeferStewardshipScan {
        param(
            [object[]]$Rows
        )

        if ($null -eq $Rows) {
            $Rows = @(script:Get-CCRMResponsibilityRow -MapPath $script:ResponsibilityMapPath)
        }

        foreach ($row in $Rows) {
            $disposition = script:Get-CCRMRowValue -Row $row -Name 'disposition'
            if ($disposition -ine 'defer') {
                continue
            }

            $trigger = script:Get-CCRMRowValue -Row $row -Name 'revisit-trigger'
            if ([string]::IsNullOrWhiteSpace($trigger)) {
                Write-Warning ("defer-stewardship warn-only: defer row '{0}' has no revisit-trigger." -f (script:Get-CCRMRowSource -Row $row))
                continue
            }

            $triggerMatch = [regex]::Match($trigger.Trim(), '^(?<kind>issue|pr|file|event):(?<target>.+)$')
            if (-not $triggerMatch.Success) {
                Write-Warning ("defer-stewardship warn-only: defer row '{0}' has unsupported revisit-trigger '{1}'." -f (script:Get-CCRMRowSource -Row $row), $trigger)
                continue
            }

            $kind = $triggerMatch.Groups['kind'].Value
            $target = $triggerMatch.Groups['target'].Value.Trim()

            switch ($kind) {
                'issue' {
                    $numberMatch = [regex]::Match($target, '^#(?<number>\d+)$')
                    if (-not $numberMatch.Success) {
                        Write-Warning ("defer-stewardship warn-only: issue trigger '{0}' is not shaped as issue:#N." -f $trigger)
                        break
                    }

                    $issueNumber = $numberMatch.Groups['number'].Value
                    if (-not (script:Test-CCRMLiveGitHubOptIn)) {
                        break
                    }

                    $issueState = script:Invoke-CCRMGhScalar -Arguments @('issue', 'view', $issueNumber, '--json', 'state', '--jq', '.state') -Context "issue #$issueNumber"
                    if ($issueState -ieq 'CLOSED') {
                        Write-Warning ("defer-stewardship warn-only: revisit trigger fired for row '{0}'; issue #{1} is closed." -f (script:Get-CCRMRowSource -Row $row), $issueNumber)
                    }

                    break
                }

                'pr' {
                    $numberMatch = [regex]::Match($target, '^#(?<number>\d+)$')
                    if (-not $numberMatch.Success) {
                        Write-Warning ("defer-stewardship warn-only: PR trigger '{0}' is not shaped as pr:#N." -f $trigger)
                        break
                    }

                    $prNumber = $numberMatch.Groups['number'].Value
                    if (-not (script:Test-CCRMLiveGitHubOptIn)) {
                        break
                    }

                    $mergedAt = script:Invoke-CCRMGhScalar -Arguments @('pr', 'view', $prNumber, '--json', 'mergedAt', '--jq', '.mergedAt') -Context "PR #$prNumber"
                    if (-not [string]::IsNullOrWhiteSpace($mergedAt) -and $mergedAt -ine 'null') {
                        Write-Warning ("defer-stewardship warn-only: revisit trigger fired for row '{0}'; PR #{1} was merged at {2}." -f (script:Get-CCRMRowSource -Row $row), $prNumber, $mergedAt)
                    }

                    break
                }

                'file' {
                    $filePath = $target
                    if (-not [System.IO.Path]::IsPathRooted($filePath)) {
                        $filePath = Join-Path $script:RepoRoot $filePath
                    }

                    if (-not (Test-Path -LiteralPath $filePath)) {
                        Write-Warning ("defer-stewardship warn-only: revisit trigger fired for row '{0}'; file '{1}' is missing." -f (script:Get-CCRMRowSource -Row $row), $target)
                    }

                    break
                }

                'event' {
                    Write-Warning ("defer-stewardship warn-only: event trigger '{0}' for row '{1}' has no deterministic local auto-evaluation." -f $target, (script:Get-CCRMRowSource -Row $row))
                    break
                }
            }
        }
    }

    function script:Invoke-CCRMDispositionBiasScan {
        param(
            [object[]]$Rows
        )

        if ($null -eq $Rows) {
            $Rows = @(script:Get-CCRMResponsibilityRow -MapPath $script:ResponsibilityMapPath)
        }

        if ($Rows.Count -eq 0) {
            Write-Warning 'disposition-bias warn-only: responsibility map contains no rows to analyze.'
            return
        }

        $countsByDisposition = @{}
        foreach ($row in $Rows) {
            $disposition = script:Get-CCRMRowValue -Row $row -Name 'disposition'
            if ([string]::IsNullOrWhiteSpace($disposition)) {
                $disposition = '<missing>'
            }

            if (-not $countsByDisposition.ContainsKey($disposition)) {
                $countsByDisposition[$disposition] = 0
            }

            $countsByDisposition[$disposition]++
        }

        foreach ($disposition in $countsByDisposition.Keys) {
            $count = $countsByDisposition[$disposition]
            $ratio = $count / $Rows.Count
            if ($ratio -gt 0.5) {
                Write-Warning ("disposition-bias warn-only: disposition '{0}' is {1:P1} of rows ({2}/{3}), above the >50% advisory threshold." -f $disposition, $ratio, $count, $Rows.Count)
            }
        }

        $deferCount = 0
        if ($countsByDisposition.ContainsKey('defer')) {
            $deferCount = $countsByDisposition['defer']
        }

        $deferRatio = $deferCount / $Rows.Count
        if ($deferRatio -gt 0.25) {
            Write-Warning ("disposition-bias warn-only: disposition 'defer' is {0:P1} of rows ({1}/{2}), above the >25% advisory threshold." -f $deferRatio, $deferCount, $Rows.Count)
        }
    }
}

Describe 'Code-Conductor responsibility map - coverage completeness' {
    It 'lists every issue-declared coverage target as a responsibility-map source' {
        $issueBody = script:Get-CCRMIssueBody
        $expectedSections = script:Get-CCRMCoverageTarget -IssueBody $issueBody
        $rows = script:Get-CCRMResponsibilityRow -MapPath $script:ResponsibilityMapPath

        $expectedSections | Should -Not -BeNullOrEmpty -Because 'issue #557 must declare the expected coverage targets in its Coverage target section'
        $rows | Should -Not -BeNullOrEmpty -Because 'the responsibility map must expose YAML responsibility rows'
        $rows.Count | Should -BeGreaterThan $expectedSections.Count -Because 'the responsibility map must parse as individual responsibility rows, not as one collection wrapper that member-enumerates source values'

        $sources = @(
            $rows |
                ForEach-Object { script:Get-CCRMRowSource -Row $_ } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )

        $missingSections = @(
            foreach ($section in $expectedSections) {
                $matchingSource = $sources | Where-Object { script:Test-CCRMSourceCoversSection -Source $_ -ExpectedSection $section } | Select-Object -First 1

                if (-not $matchingSource) {
                    $section
                }
            }
        )

        $missingSections | Should -BeNullOrEmpty -Because "each section named in issue #557's Coverage target Integration test 1 list must appear as a source value in the responsibility map"
    }

    It 'matches coverage targets only against exact normalized source segments or explicit aliases' {
        script:Test-CCRMSourceCoversSection -Source 'Hub Mode & Smart Resume' -ExpectedSection 'Hub Mode + Smart Resume' | Should -BeTrue -Because 'the issue target intentionally used plus where the Code-Conductor heading uses ampersand'
        script:Test-CCRMSourceCoversSection -Source 'Agent Selection table' -ExpectedSection 'Agent Selection' | Should -BeTrue -Because 'the map names the table source explicitly for that section'
        script:Test-CCRMSourceCoversSection -Source 'Archived Hub Mode & Smart Resume Notes' -ExpectedSection 'Hub Mode + Smart Resume' | Should -BeFalse -Because 'substring collisions must not satisfy coverage completeness'
    }
}

Describe 'Code-Conductor responsibility map - row invariants' {
    It 'normalizes PSObject collection values for scalar lookup and aggregate row text' {
        $row = [pscustomobject]@{
            source = @('Synthetic PSObject source A', 'Synthetic PSObject source B')
            action = @('Synthetic PSObject action A', 'Synthetic PSObject action B')
            disposition = 'defer'
        }

        $source = script:Get-CCRMRowValue -Row $row -Name 'source'
        $rowText = script:Get-CCRMRowText -Row $row

        $source | Should -Be "Synthetic PSObject source A`nSynthetic PSObject source B" -Because 'collection-valued PSObject properties must be normalized the same way as dictionary sequence values'
        $rowText | Should -Match ([regex]::Escape("Synthetic PSObject source A`nSynthetic PSObject source B")) -Because 'aggregate row text must include normalized collection values'
        $rowText | Should -Match ([regex]::Escape("Synthetic PSObject action A`nSynthetic PSObject action B")) -Because 'aggregate row text must normalize every collection-valued property'
        $rowText | Should -Not -Match 'System\.Object\[\]' -Because 'aggregate row text must not stringify collection-valued properties as their CLR type name'
    }

    It 'keeps every AC-critical responsibility row machine-checkable' {
        $rows = @(script:Get-CCRMResponsibilityRow -MapPath $script:ResponsibilityMapPath)
        $requiredValueKeys = @('source', 'responsibility', 'disposition', 'action', 'verification_status')
        $requiredDeclaredKeys = @('verified-against-sha', 'verified-via-pr-sha')
        $allowedDispositions = @('planner-should-absorb', 'spine-runner-keeps', 'adapter-handles', 'not-applicable', 'defer')
        $allowedVerificationStatuses = @('verified', 'unverified', 'replay-pending-merged-pr')
        $revisitTriggerPattern = '^(issue|pr):#\d+$|^file:[^\s]+$|^event:[A-Za-z0-9_.-]+$'
        $githubIssueUrlPattern = 'https://github\.com/[^/\s]+/[^/\s]+/issues/\d+'
        $replayNeedPattern = '(?i)(replay|live verification|live-verification|real-run|real run)'
        $rowNumber = 0

        $rows | Should -Not -BeNullOrEmpty -Because 'the responsibility map must expose responsibility rows before row invariants can be meaningful'

        foreach ($row in $rows) {
            $rowNumber++
            $rowLabel = "row $rowNumber '$((script:Get-CCRMRowSource -Row $row))'"

            foreach ($requiredValueKey in $requiredValueKeys) {
                script:Get-CCRMRowValue -Row $row -Name $requiredValueKey | Should -Not -BeNullOrEmpty -Because "$rowLabel must declare a non-empty $requiredValueKey value"
            }

            foreach ($requiredDeclaredKey in $requiredDeclaredKeys) {
                script:Test-CCRMRowKey -Row $row -Name $requiredDeclaredKey | Should -BeTrue -Because "$rowLabel must declare $requiredDeclaredKey even when the value is empty"
            }

            $disposition = script:Get-CCRMRowValue -Row $row -Name 'disposition'
            $verificationStatus = script:Get-CCRMRowValue -Row $row -Name 'verification_status'
            $action = script:Get-CCRMRowValue -Row $row -Name 'action'
            $verifiedAgainstSha = script:Get-CCRMRowValue -Row $row -Name 'verified-against-sha'
            $verifiedViaPrSha = script:Get-CCRMRowValue -Row $row -Name 'verified-via-pr-sha'

            $allowedDispositions | Should -Contain $disposition -Because "$rowLabel must use a known disposition enum value"
            $allowedVerificationStatuses | Should -Contain $verificationStatus -Because "$rowLabel must use a known verification_status enum value"
            script:Get-CCRMRowText -Row $row | Should -Not -Match 'TODO\(#\)' -Because "$rowLabel must not retain unresolved TODO issue placeholders"

            if ($verificationStatus -eq 'verified') {
                $verifiedAgainstSha | Should -Not -BeNullOrEmpty -Because "$rowLabel is verified and must name the Code-Conductor SHA it was checked against"
            }

            if ($disposition -eq 'defer') {
                script:Get-CCRMRowValue -Row $row -Name 'revisit-trigger' | Should -Match $revisitTriggerPattern -Because "$rowLabel is deferred and must have a machine-checkable revisit-trigger"
            }

            if ($disposition -eq 'not-applicable') {
                script:Get-CCRMRowValue -Row $row -Name 'rationale' | Should -Not -BeNullOrEmpty -Because "$rowLabel is not-applicable and must explain the rationale"
            }

            if ($disposition -eq 'planner-should-absorb') {
                $action | Should -Match $githubIssueUrlPattern -Because "$rowLabel delegates absorption work and must link to a real GitHub issue URL"
            }

            if ($verificationStatus -eq 'replay-pending-merged-pr') {
                script:Get-CCRMRowValue -Row $row -Name 'reverification-trigger' | Should -Be 'issue:#592' -Because "$rowLabel has pending replay verification tracked by issue #592"
                $action | Should -Match $replayNeedPattern -Because "$rowLabel must explain the replay or live verification need"
            }

            if (-not [string]::IsNullOrWhiteSpace($verifiedViaPrSha)) {
                script:Get-CCRMRowValue -Row $row -Name 'replay-pr' | Should -Not -BeNullOrEmpty -Because "$rowLabel has verified-via-pr-sha and must name the replay PR"
                script:Get-CCRMRowValue -Row $row -Name 'replay-evidence' | Should -Not -BeNullOrEmpty -Because "$rowLabel has verified-via-pr-sha and must name replay evidence"
            }
        }
    }
}

Describe 'Code-Conductor responsibility map - stale-anchor warn-only' {
    It 'emits advisory warnings for verified rows anchored to older Code-Conductor commits without failing the build' {
        { script:Invoke-CCRMStaleAnchorScan } | Should -Not -Throw -Because 'stale anchor findings are advisory warnings, not build failures'
    }
}

Describe 'Code-Conductor responsibility map - defer-stewardship warn-only' {
    It 'emits a deterministic warning when a local file revisit trigger has fired' {
        $rows = @(
            [ordered]@{
                source = 'Synthetic deferred file row'
                disposition = 'defer'
                'revisit-trigger' = 'file:__ccrm_missing_fixture__/trigger.txt'
            }
        )

        $warnings = @(script:Invoke-CCRMDeferStewardshipScan -Rows $rows 3>&1)
        $warningText = [string]::Join("`n", @($warnings | ForEach-Object { $_.ToString() }))

        $warningText | Should -Match 'defer-stewardship warn-only: revisit trigger fired' -Because 'a fired defer trigger must emit an advisory warning'
        $warningText | Should -Match 'Synthetic deferred file row' -Because 'the warning must identify the deferred row that needs stewardship'
    }

    It 'emits advisory warnings for fired defer revisit triggers without failing the build' {
        { script:Invoke-CCRMDeferStewardshipScan } | Should -Not -Throw -Because 'fired defer triggers are stewardship warnings, not build failures'
    }
}

Describe 'Code-Conductor responsibility map - disposition-bias warn-only' {
    It 'emits deterministic warnings when disposition distribution crosses advisory thresholds' {
        $rows = @(
            [ordered]@{ source = 'Synthetic defer row 1'; disposition = 'defer' },
            [ordered]@{ source = 'Synthetic defer row 2'; disposition = 'defer' },
            [ordered]@{ source = 'Synthetic keep row'; disposition = 'spine-runner-keeps' }
        )

        $warnings = @(script:Invoke-CCRMDispositionBiasScan -Rows $rows 3>&1)
        $warningText = [string]::Join("`n", @($warnings | ForEach-Object { $_.ToString() }))

        $warningText | Should -Match "disposition-bias warn-only: disposition 'defer' is" -Because 'a biased synthetic distribution must emit an advisory warning'
        $warningText | Should -Match 'above the >25% advisory threshold' -Because 'the defer-specific advisory threshold must remain observable'
    }

    It 'emits advisory warnings when disposition distribution crosses documented bias thresholds without failing the build' {
        # Advisory thresholds: warn when any disposition exceeds 50% of all rows, or when defer exceeds 25% of all rows.
        { script:Invoke-CCRMDispositionBiasScan } | Should -Not -Throw -Because 'disposition distribution findings are advisory warnings, not build failures'
    }
}