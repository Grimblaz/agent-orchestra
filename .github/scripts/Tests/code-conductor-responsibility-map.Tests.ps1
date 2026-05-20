#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
    $script:ResponsibilityMapPath = Join-Path $script:RepoRoot 'Documents/Design/code-conductor-responsibility-map.md'

    function script:Get-CCRMIssueBody {
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

    function script:Get-CCRMRowValue {
        param(
            [Parameter(Mandatory)]
            [object]$Row,

            [Parameter(Mandatory)]
            [string]$Name
        )

        if ($Row -is [System.Collections.IDictionary]) {
            if ($Row.Contains($Name)) {
                $dictionaryValue = $Row[$Name]
                if ($null -eq $dictionaryValue) {
                    return ''
                }

                if ($dictionaryValue -is [System.Collections.IEnumerable] -and $dictionaryValue -isnot [string]) {
                    return [string]::Join("`n", @($dictionaryValue | ForEach-Object { [string]$_ }))
                }

                return [string]$dictionaryValue
            }

            return ''
        }

        $property = $Row.PSObject.Properties[$Name]
        if ($null -eq $property -or $null -eq $property.Value) {
            return ''
        }

        return [string]$property.Value
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
                if ($null -ne $property.Value) {
                    [string]$property.Value
                }
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
        $rows = @(script:Get-CCRMResponsibilityRow -MapPath $script:ResponsibilityMapPath)

        foreach ($row in $rows) {
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
        $rows = @(script:Get-CCRMResponsibilityRow -MapPath $script:ResponsibilityMapPath)
        if ($rows.Count -eq 0) {
            Write-Warning 'disposition-bias warn-only: responsibility map contains no rows to analyze.'
            return
        }

        $countsByDisposition = @{}
        foreach ($row in $rows) {
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
            $ratio = $count / $rows.Count
            if ($ratio -gt 0.5) {
                Write-Warning ("disposition-bias warn-only: disposition '{0}' is {1:P1} of rows ({2}/{3}), above the >50% advisory threshold." -f $disposition, $ratio, $count, $rows.Count)
            }
        }

        $deferCount = 0
        if ($countsByDisposition.ContainsKey('defer')) {
            $deferCount = $countsByDisposition['defer']
        }

        $deferRatio = $deferCount / $rows.Count
        if ($deferRatio -gt 0.25) {
            Write-Warning ("disposition-bias warn-only: disposition 'defer' is {0:P1} of rows ({1}/{2}), above the >25% advisory threshold." -f $deferRatio, $deferCount, $rows.Count)
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
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object { script:ConvertTo-CCRMComparableText -Text $_ }
        )

        $missingSections = @(
            foreach ($section in $expectedSections) {
                $expectedSection = script:ConvertTo-CCRMComparableText -Text $section
                $matchingSource = $sources | Where-Object { $_.IndexOf($expectedSection, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 } | Select-Object -First 1

                if (-not $matchingSource) {
                    $section
                }
            }
        )

        $missingSections | Should -BeNullOrEmpty -Because "each section named in issue #557's Coverage target Integration test 1 list must appear as a source value in the responsibility map"
    }
}

Describe 'Code-Conductor responsibility map - row invariants' {
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
    It 'emits advisory warnings for fired defer revisit triggers without failing the build' {
        { script:Invoke-CCRMDeferStewardshipScan } | Should -Not -Throw -Because 'fired defer triggers are stewardship warnings, not build failures'
    }
}

Describe 'Code-Conductor responsibility map - disposition-bias warn-only' {
    It 'emits advisory warnings when disposition distribution crosses documented bias thresholds without failing the build' {
        # Advisory thresholds: warn when any disposition exceeds 50% of all rows, or when defer exceeds 25% of all rows.
        { script:Invoke-CCRMDispositionBiasScan } | Should -Not -Throw -Because 'disposition distribution findings are advisory warnings, not build failures'
    }
}