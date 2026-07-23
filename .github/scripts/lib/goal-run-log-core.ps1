#Requires -Version 7.0
<#
.SYNOPSIS
    Schema-validating writer/reader for the goal-run harness typed run
    log (issue #874, fix M9). Prior to this fix only the JSON Schema
    (skills/goal-run/schemas/goal-run-log.schema.json) existed -- no
    defined file location, writer, or reader.
.DESCRIPTION
    The run log lives at the worktree root, alongside goal-run-active.json:
    `goal-run-log.jsonl` -- one JSON object per line, each independently
    validated against the schema before it is ever appended (never the
    file as a whole), mirroring the validate-before-write discipline
    Test-GoalRunHaltReport (goal-run-halt-core.ps1) already established for
    halt reports.

      Get-GoalRunLogPath -WorktreePath <string>
        Resolves the fixed run-log filename under the worktree root.

      Test-GoalRunLogEntry -Entry <object> -RepoRoot <string>
        Never throws. Validates -Entry against
        skills/goal-run/schemas/goal-run-log.schema.json via Test-Json,
        mirroring the Test-GoalRunHaltReport own shape.
        Returns [pscustomobject]@{ IsValid; Violations }.

      Add-GoalRunLogEntry -WorktreePath <string> -Issue <int>
                           -EntryType <string> -Data <hashtable>
                           [-RepoRoot <string>] [-Timestamp <string>]
        Builds a schema-shaped entry (schema_version/issue/type/timestamp
        plus whatever entry-type-specific fields -Data supplies -- e.g.
        commit_sha/summary for checkpoint, summary/rationale for
        deviation, scenario/observation for experience-observation,
        summary[/halt_reason] for halt-claim), schema-validates it, and
        only on a valid object appends it as one compact JSON line via
        Add-Content. Refuses to write (Success = $false) on a schema
        violation -- callers must not treat a refused write as if the
        entry landed. -RepoRoot defaults to -WorktreePath when omitted
        (the schema file is read relative to it); pass the actual repo
        root explicitly when WorktreePath is a goal-run-provisioned
        worktree whose own checkout may not carry every schema file the
        primary checkout does.

      Test-GoalRunLogHasCheckpoint -WorktreePath <string>
        The reader the Resolve-GoalRunResumeStage -RunLogHasCheckpoint
        parameter (goal-run-stage-core.ps1) is fed from. Tolerant JSONL
        parsing, the same convention Get-GoalRunStatusEvent
        (goal-run-status-core.ps1) established: a malformed or
        partial/mid-write tail line is skipped silently, never thrown.
        Returns $true on the first checkpoint/deviation/experience-
        observation entry found (halt-claim deliberately does not count --
        it is not evidence the loop reached a genuine checkpoint, only
        that an executor asserted a halt claim). Returns $false (never
        throws) when the log file does not exist yet.
#>

$script:GoalRunLogFileName = 'goal-run-log.jsonl'
$script:GoalRunLogSchemaRelativePath = 'skills/goal-run/schemas/goal-run-log.schema.json'

function Get-GoalRunLogPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$WorktreePath
    )

    return (Join-Path $WorktreePath $script:GoalRunLogFileName)
}

function Test-GoalRunLogEntry {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    $violations = [System.Collections.Generic.List[string]]::new()

    $schemaPath = Join-Path $RepoRoot $script:GoalRunLogSchemaRelativePath
    if (-not (Test-Path -LiteralPath $schemaPath)) {
        $violations.Add("Schema file not found at $schemaPath") | Out-Null
        return [pscustomobject]@{ IsValid = $false; Violations = $violations.ToArray() }
    }
    $schemaRaw = Get-Content -LiteralPath $schemaPath -Raw

    $json = $null
    try {
        $json = $Entry | ConvertTo-Json -Depth 10
    }
    catch {
        $violations.Add("Entry object could not be serialized to JSON: $($_.Exception.Message)") | Out-Null
        return [pscustomobject]@{ IsValid = $false; Violations = $violations.ToArray() }
    }

    $testJsonError = $null
    $isValid = Test-Json -Json $json -Schema $schemaRaw -ErrorVariable testJsonError -ErrorAction SilentlyContinue

    if (-not $isValid) {
        $detail = if ($testJsonError -and $testJsonError.Count -gt 0) {
            (($testJsonError | ForEach-Object { $_.Exception.Message }) -join '; ')
        }
        else {
            'Run-log entry object failed schema validation.'
        }
        $violations.Add($detail) | Out-Null
        return [pscustomobject]@{ IsValid = $false; Violations = $violations.ToArray() }
    }

    return [pscustomobject]@{ IsValid = $true; Violations = @() }
}

function Add-GoalRunLogEntry {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [Parameter(Mandatory)][int]$Issue,
        [Parameter(Mandatory)][ValidateSet('checkpoint', 'deviation', 'experience-observation', 'halt-claim')]
        [string]$EntryType,
        [Parameter(Mandatory)][hashtable]$Data,
        [string]$RepoRoot,
        [string]$Timestamp
    )

    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = $WorktreePath }
    if ([string]::IsNullOrWhiteSpace($Timestamp)) { $Timestamp = (Get-Date).ToUniversalTime().ToString('o') }

    $entry = [ordered]@{
        schema_version = 1
        issue          = $Issue
        type           = $EntryType
        timestamp      = $Timestamp
    }
    foreach ($key in $Data.Keys) {
        $entry[$key] = $Data[$key]
    }
    $entryObject = [pscustomobject]$entry

    $validation = Test-GoalRunLogEntry -Entry $entryObject -RepoRoot $RepoRoot
    if (-not $validation.IsValid) {
        return [pscustomobject]@{ Success = $false; Reason = 'schema-invalid'; Violations = $validation.Violations; Entry = $entryObject }
    }

    $logPath = Get-GoalRunLogPath -WorktreePath $WorktreePath
    try {
        $line = $entryObject | ConvertTo-Json -Depth 10 -Compress
        Add-Content -LiteralPath $logPath -Value $line -Encoding utf8
        return [pscustomobject]@{ Success = $true; Reason = $null; Violations = @(); Entry = $entryObject; Path = $logPath }
    }
    catch {
        return [pscustomobject]@{ Success = $false; Reason = "write-failed: $($_.Exception.Message)"; Violations = @(); Entry = $entryObject; Path = $logPath }
    }
}

function Test-GoalRunLogHasCheckpoint {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$WorktreePath
    )

    $logPath = Get-GoalRunLogPath -WorktreePath $WorktreePath
    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
        return $false
    }

    $rawLines = @(Get-Content -LiteralPath $logPath -Encoding utf8 -ErrorAction SilentlyContinue)
    $countingTypes = @('checkpoint', 'deviation', 'experience-observation')

    foreach ($rawLine in $rawLines) {
        $trimmed = $rawLine.Trim()
        if ([string]::IsNullOrEmpty($trimmed)) { continue }

        $parsed = $null
        try {
            $parsed = $trimmed | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            # Malformed or partial/mid-write tail line: skip silently, the
            # same tolerance convention Get-GoalRunStatusEvent established.
            continue
        }
        if ($null -eq $parsed) { continue }

        if ($countingTypes -contains [string]$parsed.type) {
            return $true
        }
    }

    return $false
}
