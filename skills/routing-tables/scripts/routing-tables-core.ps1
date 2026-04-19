#Requires -Version 7.0

function Get-RTConfigPath {
    return Join-Path $PSScriptRoot '..\assets\routing-config.json'
}

function Get-RTGateCriteriaPath {
    return Join-Path $PSScriptRoot '..\assets\gate-criteria.json'
}

function Read-RTJsonFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    return Get-Content -Path $Path -Raw | ConvertFrom-Json -AsHashtable
}

function Resolve-RTRoutingLookupEntry {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Entry,

        [Parameter(Mandatory)]
        [string]$Table,

        [Parameter(Mandatory)]
        [string]$Key
    )

    switch ($Table) {
        'specialist_dispatch' {
            if ($Key -eq 'FilePattern' -and $Entry.ContainsKey('file_patterns')) {
                return $Entry.file_patterns
            }

            break
        }
        'review_mode_routing' {
            if ($Key -eq 'Marker' -and $Entry.ContainsKey('marker')) {
                return $Entry.marker
            }

            break
        }
        'surface_identification' {
            if ($Key -eq 'Surface' -and $Entry.ContainsKey('surface_type')) {
                return $Entry.surface_type
            }

            break
        }
    }

    $candidateKey = $Key.Substring(0, 1).ToLowerInvariant() + $Key.Substring(1)
    if ($Entry.ContainsKey($candidateKey)) {
        return $Entry[$candidateKey]
    }

    return $null
}

function Resolve-RTRoutingLookupResult {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Entry,

        [Parameter(Mandatory)]
        [string]$Table
    )

    switch ($Table) {
        'specialist_dispatch' {
            return $Entry.agent
        }
        'review_mode_routing' {
            return $Entry.mode
        }
        'surface_identification' {
            if ($Entry.ContainsKey('status_result_template')) {
                return $Entry.status_result_template
            }

            return $Entry.tool_or_method
        }
        default {
            return $null
        }
    }
}

function Test-RTWildcardMatch {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Patterns,

        [Parameter(Mandatory)]
        [string]$Value
    )

    $patternList = @()

    if ($Patterns -is [string]) {
        $patternList = @([string]$Patterns)
    }
    elseif ($null -ne $Patterns) {
        $patternList = @($Patterns | ForEach-Object { [string]$_ })
    }

    foreach ($pattern in $patternList) {
        if (-not $pattern) {
            continue
        }

        if ($Value -like $pattern -or $pattern -eq $Value) {
            return $true
        }
    }

    return $false
}

function Test-RTRoutingEntryMatch {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Entry,

        [Parameter(Mandatory)]
        [string]$Table,

        [Parameter(Mandatory)]
        [string]$Key,

        [Parameter(Mandatory)]
        [string]$Value
    )

    if ($Table -eq 'specialist_dispatch' -and $Key -eq 'FilePattern') {
        if (-not $Entry.ContainsKey('file_patterns')) {
            return $false
        }

        return Test-RTWildcardMatch -Patterns $Entry.file_patterns -Value $Value
    }

    $entryValue = Resolve-RTRoutingLookupEntry -Entry $Entry -Table $Table -Key $Key
    if ($null -eq $entryValue) {
        return $false
    }

    return [string]$entryValue -eq $Value
}

function Get-RTDefaultGateResult {
    param(
        [Parameter(Mandatory)]
        [string]$Gate
    )

    switch ($Gate) {
        'scope_classification' {
            return 'full'
        }
        'express_lane' {
            return 'does_not_qualify'
        }
        'post_fix_trigger' {
            return 'not_triggered'
        }
        default {
            return $null
        }
    }
}

function Convert-RTGateOutcomeToPublicResult {
    param(
        [Parameter(Mandatory)]
        [string]$Gate,

        [AllowNull()]
        [string]$Outcome,

        [Parameter(Mandatory)]
        [bool]$Qualifies
    )

    switch ($Gate) {
        'scope_classification' {
            if ($Qualifies -and $Outcome) {
                return $Outcome
            }

            return 'full'
        }
        'express_lane' {
            if ($Qualifies) {
                return 'qualifies'
            }

            return 'does_not_qualify'
        }
        'post_fix_trigger' {
            if ($Qualifies) {
                return 'triggered'
            }

            return 'not_triggered'
        }
        default {
            return $Outcome
        }
    }
}

function Invoke-RoutingLookup {
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Table,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Key,

        [Parameter(Mandatory)]
        [string]$Value
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    try {
        $config = Read-RTJsonFile -Path (Get-RTConfigPath)
    }
    catch {
        Write-Warning "Failed to read routing configuration: $($_.Exception.Message)"
        return $null
    }

    if (-not $config.ContainsKey($Table)) {
        throw "Routing table '$Table' was not found."
    }

    $tableDefinition = $config[$Table]
    if (-not $tableDefinition.ContainsKey('entries')) {
        return $null
    }

    foreach ($entry in $tableDefinition.entries) {
        if (Test-RTRoutingEntryMatch -Entry $entry -Table $Table -Key $Key -Value $Value) {
            return Resolve-RTRoutingLookupResult -Entry $entry -Table $Table
        }
    }

    return $null
}

function Test-GateCriteria {
    param(
        [Parameter(Mandatory)]
        [string]$Gate,

        [Parameter(Mandatory)]
        [hashtable]$Criteria
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    try {
        $gateConfig = Read-RTJsonFile -Path (Get-RTGateCriteriaPath)
    }
    catch {
        Write-Warning "Failed to read gate criteria configuration: $($_.Exception.Message)"
        return Get-RTDefaultGateResult -Gate $Gate
    }

    if (-not $gateConfig.ContainsKey($Gate)) {
        Write-Warning "Gate '$Gate' was not found in gate criteria configuration."
        return Get-RTDefaultGateResult -Gate $Gate
    }

    $gateDefinition = $gateConfig[$Gate]
    $criterionIds = @()

    if ($gateDefinition.ContainsKey('criteria')) {
        $criterionIds = @($gateDefinition.criteria | ForEach-Object { $_.id })
    }
    elseif ($gateDefinition.ContainsKey('trigger_conditions')) {
        $criterionIds = @($gateDefinition.trigger_conditions | ForEach-Object { $_.id })
    }

    $usesAnySemantics = $gateDefinition.ContainsKey('trigger_logic') -and $gateDefinition.trigger_logic -eq 'any'
    $qualifies = -not $usesAnySemantics

    foreach ($criterionId in $criterionIds) {
        $criterionSatisfied = $Criteria.ContainsKey($criterionId) -and [bool]$Criteria[$criterionId]

        if ($usesAnySemantics) {
            if ($criterionSatisfied) {
                $qualifies = $true
                break
            }
        }
        elseif (-not $criterionSatisfied) {
            $qualifies = $false
            break
        }
    }

    $outcome = if ($qualifies) {
        if ($gateDefinition.ContainsKey('outcome_if_all_true')) {
            [string]$gateDefinition.outcome_if_all_true
        }
        else {
            $null
        }
    }
    else {
        if ($gateDefinition.ContainsKey('default_outcome')) {
            [string]$gateDefinition.default_outcome
        }
        else {
            $null
        }
    }

    return Convert-RTGateOutcomeToPublicResult -Gate $Gate -Outcome $outcome -Qualifies $qualifies
}
