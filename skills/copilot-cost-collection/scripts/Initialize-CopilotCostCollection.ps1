#Requires -Version 7.0
<#
.SYNOPSIS
    Installs machine-local Copilot Chat OTel file-export settings for cost collection.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [string]$UserSettingsPath,

    [Parameter()]
    [string]$WorkspacePath = (Get-Location).Path,

    [Parameter()]
    [switch]$Yes,

    [Parameter()]
    [switch]$NonInteractive,

    [Parameter()]
    [string]$UserHome = [Environment]::GetFolderPath('UserProfile')
)

$ErrorActionPreference = 'Stop'
$script:SentinelFileName = '.copilot-cost-collection-installed'
$script:SentinelVersion = 'v1'
$script:WorkspaceSettingsGitignoreEntry = '.vscode/settings.json'

function Resolve-CopilotCostDefaultUserSettingsPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($IsWindows) {
        if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
            throw 'APPDATA is not set; pass -UserSettingsPath for this VS Code installation.'
        }

        return Join-Path -Path $env:APPDATA -ChildPath 'Code\User\settings.json'
    }

    $profileHome = [Environment]::GetFolderPath('UserProfile')
    if ([string]::IsNullOrWhiteSpace($profileHome)) { $profileHome = $env:HOME }
    if ([string]::IsNullOrWhiteSpace($profileHome)) {
        throw 'Unable to resolve the current user home; pass -UserSettingsPath.'
    }

    if ($IsMacOS) {
        return Join-Path -Path $profileHome -ChildPath 'Library/Application Support/Code/User/settings.json'
    }

    return Join-Path -Path $profileHome -ChildPath '.config/Code/User/settings.json'
}

function Resolve-CopilotCostFullPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$MustExist
    )

    if ($MustExist -and -not (Test-Path -LiteralPath $Path)) {
        throw "Path does not exist: $Path"
    }

    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Read-CopilotCostJsonObject {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary], [hashtable])]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not [System.IO.File]::Exists($Path)) { return [ordered]@{} }

    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) { return [ordered]@{} }

    try {
        $parsed = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    catch {
        throw "Failed to parse JSON settings at '$Path': $($_.Exception.Message)"
    }

    if ($parsed -isnot [System.Collections.IDictionary]) {
        throw "Settings file '$Path' must contain a JSON object."
    }

    return $parsed
}

function Set-CopilotCostSettingValue {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The top-level installer script owns ShouldProcess for the full atomic install.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$Value
    )

    if ($Settings.Contains($Name) -and $Settings[$Name] -eq $Value) { return $false }

    $Settings[$Name] = $Value
    return $true
}

function Write-CopilotCostJsonObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        $null = [System.IO.Directory]::CreateDirectory($parent)
    }

    $json = $Settings | ConvertTo-Json -Depth 20
    if ($json -is [array]) { $json = $json -join "`n" }

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $json + "`n", $encoding)
}

function Test-CopilotCostGitignoreContainsSentinel {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    return Test-CopilotCostGitignoreContainsEntry -Path $Path -Entry $script:SentinelFileName
}

function Test-CopilotCostGitignoreContainsEntry {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Entry
    )

    if (-not [System.IO.File]::Exists($Path)) { return $false }

    $lines = [System.IO.File]::ReadAllLines($Path)
    return @($lines | Where-Object { $_.Trim() -eq $Entry }).Count -gt 0
}

function Join-CopilotCostGitignoreEntryBlock {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Entries
    )

    $linesToAdd = @($Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($linesToAdd.Count -eq 0) { return '' }

    return ($linesToAdd -join "`n") + "`n"
}

function Add-CopilotCostGitignoreEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Entries
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    $entryBlock = Join-CopilotCostGitignoreEntryBlock -Entries $Entries
    if ([string]::IsNullOrEmpty($entryBlock)) { return }

    if (-not [System.IO.File]::Exists($Path)) {
        [System.IO.File]::WriteAllText($Path, $entryBlock, $encoding)
        return
    }

    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrEmpty($raw)) {
        [System.IO.File]::WriteAllText($Path, $entryBlock, $encoding)
        return
    }

    $separator = if ($raw.EndsWith("`n")) { '' } else { "`n" }
    [System.IO.File]::WriteAllText($Path, $raw + $separator + $entryBlock, $encoding)
}

function Test-CopilotCostGitPathTracked {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $gitCommand = Get-Command git -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $gitCommand) { return $false }

    $null = & $gitCommand.Source -C $WorkspacePath ls-files --error-unmatch -- $RelativePath 2>$null
    return ($LASTEXITCODE -eq 0)
}

function New-CopilotCostSentinelContent {
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'This helper only constructs sentinel text and does not write state.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$OtelOutfilePath
    )

    $lines = @(
        "copilot-cost-collection-installed: $script:SentinelVersion",
        'survival: within-worktree',
        "workspace: $WorkspacePath",
        "otel_outfile: $OtelOutfilePath",
        "installed_utc: $([DateTimeOffset]::UtcNow.ToString('o'))",
        'note: Machine-local setup marker; not durable plan or session memory.'
    )

    return ($lines -join "`n") + "`n"
}

function Test-CopilotCostSentinelCurrent {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$WorkspacePath,
        [Parameter(Mandatory)][string]$OtelOutfilePath
    )

    if (-not [System.IO.File]::Exists($Path)) { return $false }

    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return $raw.Contains("copilot-cost-collection-installed: $script:SentinelVersion") -and
        $raw.Contains('survival: within-worktree') -and
        $raw.Contains("workspace: $WorkspacePath") -and
        $raw.Contains("otel_outfile: $OtelOutfilePath")
}

function Confirm-CopilotCostInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Actions,
        [Parameter()][switch]$Force
    )

    if ($Actions.Count -eq 0 -or $Force -or $WhatIfPreference) { return }

    if ($NonInteractive) {
        throw 'Initialize-CopilotCostCollection requires -Yes when -NonInteractive is specified and install changes are needed.'
    }

    $message = "Apply Copilot cost collection setup changes?`n- " + ($Actions -join "`n- ")
    if (-not $PSCmdlet.ShouldContinue($message, 'Confirm Copilot cost collection setup')) {
        throw 'Copilot cost collection setup was cancelled.'
    }
}

if (-not $PSBoundParameters.ContainsKey('UserSettingsPath')) {
    $UserSettingsPath = Resolve-CopilotCostDefaultUserSettingsPath
    Write-Warning 'Defaulting to stable VS Code user settings. VS Code profiles, Insiders, portable installs, and alternate user-data dirs may require -UserSettingsPath.'
}

$resolvedWorkspacePath = Resolve-CopilotCostFullPath -Path $WorkspacePath -MustExist
$resolvedUserSettingsPath = Resolve-CopilotCostFullPath -Path $UserSettingsPath
$resolvedUserHome = Resolve-CopilotCostFullPath -Path $UserHome
$workspaceName = Split-Path -Leaf $resolvedWorkspacePath
$otelOutfilePath = Join-Path -Path $resolvedUserHome -ChildPath (Join-Path -Path '.copilot-otel' -ChildPath (Join-Path -Path $workspaceName -ChildPath 'copilot.jsonl'))
$workspaceSettingsPath = Join-Path -Path $resolvedWorkspacePath -ChildPath '.vscode/settings.json'
$gitignorePath = Join-Path -Path $resolvedWorkspacePath -ChildPath '.gitignore'
$sentinelPath = Join-Path -Path $resolvedWorkspacePath -ChildPath $script:SentinelFileName
$otelParentPath = Split-Path -Parent $otelOutfilePath

$actions = [System.Collections.Generic.List[string]]::new()

$userSettings = Read-CopilotCostJsonObject -Path $resolvedUserSettingsPath
$userSettingsChanged = $false
$userSettingsChanged = (Set-CopilotCostSettingValue -Settings $userSettings -Name 'github.copilot.chat.otel.enabled' -Value $true) -or $userSettingsChanged
$userSettingsChanged = (Set-CopilotCostSettingValue -Settings $userSettings -Name 'github.copilot.chat.otel.exporterType' -Value 'file') -or $userSettingsChanged
$userSettingsChanged = (Set-CopilotCostSettingValue -Settings $userSettings -Name 'github.copilot.chat.otel.captureContent' -Value $false) -or $userSettingsChanged
$userSettingsNeedsWrite = $userSettingsChanged -or -not [System.IO.File]::Exists($resolvedUserSettingsPath)
if ($userSettingsNeedsWrite) { $actions.Add("write user settings: $resolvedUserSettingsPath") }

$workspaceSettings = Read-CopilotCostJsonObject -Path $workspaceSettingsPath
$workspaceSettingsChanged = Set-CopilotCostSettingValue -Settings $workspaceSettings -Name 'github.copilot.chat.otel.outfile' -Value $otelOutfilePath
$workspaceSettingsNeedsWrite = $workspaceSettingsChanged -or -not [System.IO.File]::Exists($workspaceSettingsPath)
if ($workspaceSettingsNeedsWrite) { $actions.Add("write workspace settings: $workspaceSettingsPath") }

$otelParentNeedsCreate = -not [System.IO.Directory]::Exists($otelParentPath)
if ($otelParentNeedsCreate) { $actions.Add("create OTel output directory: $otelParentPath") }

$gitignoreNeedsSentinel = -not (Test-CopilotCostGitignoreContainsSentinel -Path $gitignorePath)
if ($gitignoreNeedsSentinel) { $actions.Add("ensure sentinel is gitignored: $gitignorePath") }

$workspaceSettingsTracked = Test-CopilotCostGitPathTracked -WorkspacePath $resolvedWorkspacePath -RelativePath $script:WorkspaceSettingsGitignoreEntry
if ($workspaceSettingsTracked) {
    Write-Warning "Workspace settings file '$script:WorkspaceSettingsGitignoreEntry' is already tracked by git; .gitignore cannot protect the machine-local Copilot OTel outfile path until the file is untracked."
}
$gitignoreNeedsWorkspaceSettings = -not (Test-CopilotCostGitignoreContainsEntry -Path $gitignorePath -Entry $script:WorkspaceSettingsGitignoreEntry)
if ($gitignoreNeedsWorkspaceSettings) { $actions.Add("ensure workspace settings are gitignored: $gitignorePath") }

$sentinelNeedsWrite = -not (Test-CopilotCostSentinelCurrent -Path $sentinelPath -WorkspacePath $resolvedWorkspacePath -OtelOutfilePath $otelOutfilePath)
if ($sentinelNeedsWrite) { $actions.Add("write sentinel: $sentinelPath") }

Confirm-CopilotCostInstall -Actions $actions.ToArray() -Force:$Yes

$changed = $false
if ($actions.Count -gt 0 -and $PSCmdlet.ShouldProcess($resolvedWorkspacePath, 'Install Copilot cost collection settings and sentinel')) {
    if ($userSettingsNeedsWrite) { Write-CopilotCostJsonObject -Path $resolvedUserSettingsPath -Settings $userSettings }
    if ($workspaceSettingsNeedsWrite) { Write-CopilotCostJsonObject -Path $workspaceSettingsPath -Settings $workspaceSettings }
    if ($otelParentNeedsCreate) { $null = [System.IO.Directory]::CreateDirectory($otelParentPath) }
    $gitignoreEntriesToAdd = @()
    if ($gitignoreNeedsSentinel) { $gitignoreEntriesToAdd += $script:SentinelFileName }
    if ($gitignoreNeedsWorkspaceSettings) { $gitignoreEntriesToAdd += $script:WorkspaceSettingsGitignoreEntry }
    if ($gitignoreEntriesToAdd.Count -gt 0) { Add-CopilotCostGitignoreEntry -Path $gitignorePath -Entries $gitignoreEntriesToAdd }

    if ($sentinelNeedsWrite) {
        $sentinelContent = New-CopilotCostSentinelContent -WorkspacePath $resolvedWorkspacePath -OtelOutfilePath $otelOutfilePath
        $encoding = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($sentinelPath, $sentinelContent, $encoding)
    }
    $changed = $true
}

[pscustomobject]@{
    Changed               = $changed
    WhatIf                = [bool]$WhatIfPreference
    UserSettingsPath      = $resolvedUserSettingsPath
    WorkspacePath         = $resolvedWorkspacePath
    WorkspaceSettingsPath = $workspaceSettingsPath
    OtelOutfilePath       = $otelOutfilePath
    SentinelPath          = $sentinelPath
    Actions               = [string[]]$actions.ToArray()
}
