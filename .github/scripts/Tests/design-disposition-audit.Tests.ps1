#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
#Requires -Modules @{ ModuleName = 'powershell-yaml'; ModuleVersion = '0.4.0' }

BeforeAll {
    Import-Module powershell-yaml -MinimumVersion 0.4.0

    $script:FixtureRoot = Join-Path $PSScriptRoot 'fixtures/design-disposition-audit'
    $script:ValidFixtures = @(Get-ChildItem -Path $script:FixtureRoot -Filter 'valid-*.txt' | Sort-Object Name)
    $script:AllowedPasses = @(1, 2, 3)
    $script:AllowedDispositions = @('incorporate', 'dismiss', 'escalate')
    $script:AllowedClassifications = @('load-bearing', 'routine')

    function script:Test-YamlKey {
        param(
            [object]$Map,
            [string]$Key
        )

        if ($null -eq $Map) { return $false }

        if ($Map -is [System.Collections.IDictionary]) {
            return $Map.Contains($Key)
        }

        return $null -ne $Map.PSObject.Properties[$Key]
    }

    function script:Get-YamlValue {
        param(
            [object]$Map,
            [string]$Key
        )

        if (-not (script:Test-YamlKey -Map $Map -Key $Key)) { return $null }

        if ($Map -is [System.Collections.IDictionary]) {
            return $Map[$Key]
        }

        return $Map.PSObject.Properties[$Key].Value
    }

    function script:ConvertTo-ObjectArray {
        param([object]$Value)

        if ($null -eq $Value) { return @() }
        if ($Value -is [string]) { return @($Value) }
        if ($Value -is [System.Array]) { return @($Value) }
        if ($Value -is [System.Collections.IEnumerable]) { return @($Value) }

        return @($Value)
    }

    function script:Test-YamlListValue {
        param([object]$Value)

        if ($null -eq $Value) { return $false }
        if ($Value -is [string]) { return $false }
        if ($Value -is [System.Collections.IDictionary]) { return $false }

        return $Value -is [System.Collections.IEnumerable]
    }

    function script:Test-AlsoFlaggedByValue {
        param(
            [object]$Value,
            [int[]]$PassesRun,
            [object]$EntryPass
        )

        $alsoFlaggedBy = @(script:ConvertTo-ObjectArray -Value $Value)
        $alsoFlaggedPasses = @()
        $hasNonNumericPass = $false

        foreach ($alsoFlaggedPass in $alsoFlaggedBy) {
            try {
                $alsoFlaggedPasses += [int]$alsoFlaggedPass
            } catch {
                $hasNonNumericPass = $true
            }
        }

        return (
            (script:Test-YamlListValue -Value $Value) -and
            $alsoFlaggedPasses.Count -gt 0 -and
            -not $hasNonNumericPass -and
            @($alsoFlaggedPasses | Where-Object { $_ -notin $script:AllowedPasses }).Count -eq 0 -and
            @($alsoFlaggedPasses | Where-Object { $_ -notin $PassesRun }).Count -eq 0 -and
            ($null -eq $EntryPass -or $EntryPass -notin $alsoFlaggedPasses) -and
            @($alsoFlaggedPasses | Sort-Object -Unique).Count -eq $alsoFlaggedPasses.Count
        )
    }

    function script:Test-RoutineCitationRequired {
        param([object]$Entry)

        if ((script:Get-YamlValue -Map $Entry -Key 'classification') -ne 'routine') {
            return $false
        }

        if (-not (script:Test-YamlKey -Map $Entry -Key 'artifact_citation_required')) {
            return $false
        }

        $requiredValue = script:Get-YamlValue -Map $Entry -Key 'artifact_citation_required'
        $explicitlyRequired = if ($requiredValue -is [bool]) {
            $requiredValue
        } else {
            [string]$requiredValue -match '(?i)^true$'
        }

        return $explicitlyRequired
    }

    function script:Read-DesignDispositionFixture {
        param([string]$Path)

        $body = Get-Content -Path $Path -Raw
        $markerMatch = [regex]::Match($body, '<!--\s*(?<marker>[^>]+?)\s*-->')
        $yamlMatch = [regex]::Match($body, '```yaml\s*(?<yaml>[\s\S]*?)```')

        if (-not $yamlMatch.Success) {
            throw "Fixture $Path does not contain a yaml fenced block."
        }

        [pscustomobject]@{
            Path = $Path
            Name = Split-Path -Path $Path -Leaf
            Marker = if ($markerMatch.Success) { $markerMatch.Groups['marker'].Value.Trim() } else { '' }
            Body = $body
            Payload = ConvertFrom-Yaml -Yaml $yamlMatch.Groups['yaml'].Value
        }
    }

    function script:Get-FindingDispositionsBlock {
        param([object]$Fixture)

        return script:Get-YamlValue -Map $Fixture.Payload -Key 'finding_dispositions'
    }

    function script:Get-Entry {
        param([object]$Block)

        return @(script:ConvertTo-ObjectArray -Value (script:Get-YamlValue -Map $Block -Key 'entries'))
    }

    function script:Get-PassesRun {
        param([object]$Block)

        return @(script:ConvertTo-ObjectArray -Value (script:Get-YamlValue -Map $Block -Key 'passes_run') | ForEach-Object { [int]$_ })
    }

    function script:Test-DesignDispositionFixture {
        param([string]$Path)

        $fixture = script:Read-DesignDispositionFixture -Path $Path
        $errors = [System.Collections.Generic.List[string]]::new()

        if ($fixture.Marker -notmatch '^design-phase-complete-\d+$') {
            $errors.Add("finding_dispositions must appear inside a design-phase-complete marker body; found '$($fixture.Marker)'")
        }

        if (-not (script:Test-YamlKey -Map $fixture.Payload -Key 'finding_dispositions')) {
            $errors.Add('missing finding_dispositions')
            return $errors.ToArray()
        }

        $block = script:Get-FindingDispositionsBlock -Fixture $fixture

        if ((script:Get-YamlValue -Map $block -Key 'schema_version') -ne 1) {
            $errors.Add('invalid schema_version')
        }

        if (-not (script:Test-YamlKey -Map $block -Key 'passes_run')) {
            $errors.Add('missing passes_run')
            $passesRun = @()
        } else {
            $passesRun = @(script:Get-PassesRun -Block $block)
            if ($passesRun.Count -eq 0 -or @($passesRun | Where-Object { $_ -notin $script:AllowedPasses }).Count -gt 0) {
                $errors.Add('invalid passes_run: must be a non-empty subset of 1, 2, 3')
            }
        }

        if (-not (script:Test-YamlKey -Map $block -Key 'entries')) {
            $errors.Add('missing entries')
            $entries = @()
        } else {
            $entries = @(script:Get-Entry -Block $block)
        }

        $entryPasses = @()
        foreach ($entry in $entries) {
            $entryPass = $null

            if (-not (script:Test-YamlKey -Map $entry -Key 'finding_id')) {
                $errors.Add('missing finding_id')
            } elseif ((script:Get-YamlValue -Map $entry -Key 'finding_id') -notmatch '^F\d+$') {
                $errors.Add('invalid finding_id')
            }

            if (-not (script:Test-YamlKey -Map $entry -Key 'pass')) {
                $errors.Add('missing pass')
            } else {
                $pass = [int](script:Get-YamlValue -Map $entry -Key 'pass')
                $entryPass = $pass
                $entryPasses += $pass
                if ($pass -notin $script:AllowedPasses) {
                    $errors.Add('invalid pass')
                }
            }

            if (-not (script:Test-YamlKey -Map $entry -Key 'disposition')) {
                $errors.Add('missing disposition')
            } elseif ((script:Get-YamlValue -Map $entry -Key 'disposition') -notin $script:AllowedDispositions) {
                $errors.Add('invalid disposition')
            }

            if (-not (script:Test-YamlKey -Map $entry -Key 'classification')) {
                $errors.Add('missing classification')
            } elseif ((script:Get-YamlValue -Map $entry -Key 'classification') -notin $script:AllowedClassifications) {
                $errors.Add('invalid classification')
            }

            if (-not (script:Test-YamlKey -Map $entry -Key 'disposition_rationale')) {
                $errors.Add('missing disposition_rationale')
            } elseif ([string]::IsNullOrWhiteSpace([string](script:Get-YamlValue -Map $entry -Key 'disposition_rationale'))) {
                $errors.Add('invalid disposition_rationale')
            }

            $hasArtifactCitation = script:Test-YamlKey -Map $entry -Key 'artifact_citation'
            if (($hasArtifactCitation -or (script:Test-RoutineCitationRequired -Entry $entry)) -and [string]::IsNullOrWhiteSpace([string](script:Get-YamlValue -Map $entry -Key 'artifact_citation'))) {
                $errors.Add('invalid artifact_citation')
            }

            if (script:Test-YamlKey -Map $entry -Key 'also_flagged_by') {
                $alsoFlaggedByValue = script:Get-YamlValue -Map $entry -Key 'also_flagged_by'

                if (-not (script:Test-AlsoFlaggedByValue -Value $alsoFlaggedByValue -PassesRun $passesRun -EntryPass $entryPass)) {
                    $errors.Add('invalid also_flagged_by: every secondary pass must be present in passes_run')
                }
            }
        }

        if ($entries.Count -gt 0) {
            $entryPassSet = @($entryPasses | Sort-Object -Unique)
            $passesRunSet = @($passesRun | Sort-Object -Unique)
            if (@(Compare-Object -ReferenceObject $entryPassSet -DifferenceObject $passesRunSet).Count -gt 0) {
                $errors.Add('invalid passes_run: must match entries[].pass set')
            }
        }

        return $errors.ToArray()
    }

    function script:Get-ValidFixture {
        param([string]$Name)

        return $script:ValidFixtures | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    }
}

Describe 'design disposition marker payload schema' {
    It 'has the expected fixture set available' {
        (Test-Path -Path $script:FixtureRoot) | Should -BeTrue
        $script:ValidFixtures.Count | Should -BeGreaterOrEqual 4
    }

    It 'parses every well-formed marker body with schema_version 1' {
        foreach ($fixturePath in $script:ValidFixtures.FullName) {
            $fixture = script:Read-DesignDispositionFixture -Path $fixturePath
            $block = script:Get-FindingDispositionsBlock -Fixture $fixture

            $fixture.Marker | Should -Match '^design-phase-complete-\d+$'
            $block | Should -Not -BeNullOrEmpty
            (script:Get-YamlValue -Map $block -Key 'schema_version') | Should -Be 1
            (script:Test-DesignDispositionFixture -Path $fixturePath) | Should -BeNullOrEmpty
        }
    }

    It 'allows entries to be empty while preserving the entries array shape' {
        $fixturePath = (script:Get-ValidFixture -Name 'valid-empty-entries.txt').FullName
        $fixture = script:Read-DesignDispositionFixture -Path $fixturePath
        $entries = @(script:Get-Entry -Block (script:Get-FindingDispositionsBlock -Fixture $fixture))

        $entries.Count | Should -Be 0
        (script:Test-DesignDispositionFixture -Path $fixturePath) | Should -BeNullOrEmpty
    }

    It 'requires every populated entry to carry valid id, pass, disposition, classification, and rationale fields' {
        foreach ($fixturePath in ($script:ValidFixtures | Where-Object { $_.Name -ne 'valid-empty-entries.txt' }).FullName) {
            $fixture = script:Read-DesignDispositionFixture -Path $fixturePath
            $block = script:Get-FindingDispositionsBlock -Fixture $fixture

            foreach ($entry in (script:Get-Entry -Block $block)) {
                (script:Get-YamlValue -Map $entry -Key 'finding_id') | Should -Match '^F\d+$'
                (script:Get-YamlValue -Map $entry -Key 'pass') | Should -BeIn $script:AllowedPasses
                (script:Get-YamlValue -Map $entry -Key 'disposition') | Should -BeIn $script:AllowedDispositions
                (script:Get-YamlValue -Map $entry -Key 'classification') | Should -BeIn $script:AllowedClassifications
                (script:Get-YamlValue -Map $entry -Key 'disposition_rationale') | Should -Not -BeNullOrEmpty
            }
        }
    }

    It 'covers degraded single-pass disposition ledgers with only pass 1 entries' {
        $fixturePath = (script:Get-ValidFixture -Name 'valid-degraded-pass-1.txt').FullName
        $fixture = script:Read-DesignDispositionFixture -Path $fixturePath
        $block = script:Get-FindingDispositionsBlock -Fixture $fixture

        (script:Get-PassesRun -Block $block) | Should -Be @(1)
        (script:Get-Entry -Block $block | ForEach-Object { script:Get-YamlValue -Map $_ -Key 'pass' } | Sort-Object -Unique) | Should -Be @(1)
    }

    It 'covers multi-pass concurrence with also_flagged_by preserving secondary pass ids' {
        $fixturePath = (script:Get-ValidFixture -Name 'valid-multi-pass-concurrence.txt').FullName
        $fixture = script:Read-DesignDispositionFixture -Path $fixturePath
        $block = script:Get-FindingDispositionsBlock -Fixture $fixture
        $concurrentEntry = script:Get-Entry -Block $block | Where-Object { script:Test-YamlKey -Map $_ -Key 'also_flagged_by' } | Select-Object -First 1

        (script:Get-PassesRun -Block $block | Sort-Object) | Should -Be @(1, 2, 3)
        @(script:ConvertTo-ObjectArray -Value (script:Get-YamlValue -Map $concurrentEntry -Key 'also_flagged_by')) | Should -Be @(2, 3)
    }

    It 'keeps routine artifact citations non-empty when they are present' {
        $fixturePath = (script:Get-ValidFixture -Name 'valid-routine-artifact-citation.txt').FullName
        $fixture = script:Read-DesignDispositionFixture -Path $fixturePath
        $block = script:Get-FindingDispositionsBlock -Fixture $fixture
        $routineEntry = script:Get-Entry -Block $block | Where-Object { script:Get-YamlValue -Map $_ -Key 'classification' -eq 'routine' } | Select-Object -First 1

        (script:Get-YamlValue -Map $routineEntry -Key 'artifact_citation') | Should -Not -BeNullOrEmpty
        (script:Test-DesignDispositionFixture -Path $fixturePath) | Should -BeNullOrEmpty
    }

    It 'allows routine entries without citations when citation is not explicitly required' {
        $fixturePath = (script:Get-ValidFixture -Name 'valid-degraded-pass-1.txt').FullName
        $fixture = script:Read-DesignDispositionFixture -Path $fixturePath
        $block = script:Get-FindingDispositionsBlock -Fixture $fixture
        $routineEntry = script:Get-Entry -Block $block | Where-Object { script:Get-YamlValue -Map $_ -Key 'classification' -eq 'routine' } | Select-Object -First 1

        (script:Test-YamlKey -Map $routineEntry -Key 'artifact_citation') | Should -BeFalse
        (script:Test-DesignDispositionFixture -Path $fixturePath) | Should -BeNullOrEmpty
    }

    It 'allows negated inherited and citation-backed rationale language without artifact citations' {
        $fixturePath = (script:Get-ValidFixture -Name 'valid-routine-negated-citation-language.txt').FullName
        $fixture = script:Read-DesignDispositionFixture -Path $fixturePath
        $block = script:Get-FindingDispositionsBlock -Fixture $fixture
        $routineEntry = script:Get-Entry -Block $block | Select-Object -First 1

        (script:Get-YamlValue -Map $routineEntry -Key 'disposition_rationale') | Should -Match 'does not rely on inherited documentation'
        (script:Test-YamlKey -Map $routineEntry -Key 'artifact_citation') | Should -BeFalse
        (script:Test-DesignDispositionFixture -Path $fixturePath) | Should -BeNullOrEmpty
    }
}

Describe 'design disposition marker payload malformed fixtures' {
    It 'rejects malformed marker bodies with messages that name the invalid field' -ForEach @(
        @{ File = 'invalid-missing-disposition-rationale.txt'; ExpectedMessage = 'missing disposition_rationale' }
        @{ File = 'invalid-missing-finding-id.txt'; ExpectedMessage = 'missing finding_id' }
        @{ File = 'invalid-classification-enum.txt'; ExpectedMessage = 'invalid classification' }
        @{ File = 'invalid-credit-input-marker-body.txt'; ExpectedMessage = 'finding_dispositions must appear inside a design-phase-complete marker body' }
        @{ File = 'invalid-routine-cited-rationale-missing-citation.txt'; ExpectedMessage = 'invalid artifact_citation' }
        @{ File = 'invalid-routine-artifact-citation-required-missing-citation.txt'; ExpectedMessage = 'invalid artifact_citation' }
        @{ File = 'invalid-also-flagged-by-invalid-pass.txt'; ExpectedMessage = 'invalid also_flagged_by' }
        @{ File = 'invalid-also-flagged-by-self-reference.txt'; ExpectedMessage = 'invalid also_flagged_by' }
        @{ File = 'invalid-also-flagged-by-duplicate.txt'; ExpectedMessage = 'invalid also_flagged_by' }
        @{ File = 'invalid-also-flagged-by-pass-not-run.txt'; ExpectedMessage = 'invalid also_flagged_by: every secondary pass must be present in passes_run' }
    ) {
        $fixturePath = Join-Path $script:FixtureRoot $File
        $errors = @(script:Test-DesignDispositionFixture -Path $fixturePath)

        ($errors -join "`n") | Should -Match ([regex]::Escape($ExpectedMessage))
    }

    It 'enforces passes_run as a non-empty subset of 1, 2, 3' {
        $fixturePath = Join-Path $script:FixtureRoot 'invalid-passes-run-empty.txt'
        $errors = @(script:Test-DesignDispositionFixture -Path $fixturePath)

        $errors | Should -Contain 'invalid passes_run: must be a non-empty subset of 1, 2, 3'
    }

    It 'enforces passes_run equality with the populated entries pass set' {
        $fixturePath = Join-Path $script:FixtureRoot 'invalid-passes-run-mismatch.txt'
        $errors = @(script:Test-DesignDispositionFixture -Path $fixturePath)

        $errors | Should -Contain 'invalid passes_run: must match entries[].pass set'
    }
}