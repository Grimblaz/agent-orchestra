#Requires -Version 7.0
<#
.SYNOPSIS
    Library for plugin preflight validation logic. Dot-source and call Invoke-PluginPreflight.
#>

function Resolve-PluginContentPath {
    # Issue #367: resolve agents/ or skills/ at either the new repo-root location
    # or the legacy .github/ location, so validators run green mid-migration.
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][ValidateSet('agents', 'skills')][string]$ContentName
    )
    $preferred = Join-Path -Path $RootPath -ChildPath $ContentName
    if (Test-Path -LiteralPath $preferred) { return $preferred }
    $fallback = Join-Path -Path $RootPath -ChildPath '.github' -AdditionalChildPath $ContentName
    if (Test-Path -LiteralPath $fallback) { return $fallback }
    return $preferred
}

function Invoke-PluginPreflight {
    [CmdletBinding()]
    param(
        [string]$RootPath,
        [string]$PluginJsonPath
    )

    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest

    try {
        if (-not $RootPath) {
            $RootPath = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
        }
        if (-not $PluginJsonPath) {
            $PluginJsonPath = Join-Path -Path $RootPath -ChildPath 'plugin.json'
        }

        $results = [System.Collections.Generic.List[PSCustomObject]]::new()

        # --- 1. plugin.json exists and parses ---
        try {
            if (-not (Test-Path $PluginJsonPath)) {
                $results.Add([PSCustomObject]@{ Name = 'PluginJsonExists'; Passed = $false; Detail = "Not found: $PluginJsonPath" })
                # Cannot proceed without the manifest
                return _PreflightSummary $results
            }
            $manifest = Get-Content -Path $PluginJsonPath -Raw | ConvertFrom-Json
            # VS Code resolves paths in plugin.json relative to the manifest own directory.
            # The manifest sits at the plugin/repo root (relocated from .github/plugin.json
            # in v2.0.0 per issue #367 D10), so manifest-relative and plugin-root-relative
            # resolution are equivalent — paths read as `./agents/` and `./skills/{name}/`.
            $manifestDir = Split-Path -Parent (Resolve-Path -LiteralPath $PluginJsonPath)
            $results.Add([PSCustomObject]@{ Name = 'PluginJsonExists'; Passed = $true; Detail = '' })
        }
        catch {
            $results.Add([PSCustomObject]@{ Name = 'PluginJsonExists'; Passed = $false; Detail = "Parse error: $_" })
            return _PreflightSummary $results
        }

        # --- 2. author/repository placeholders replaced ---
        try {
            $authorName = $manifest.author.name
            $repo = $manifest.repository
            if ($authorName -like '*YOUR-ORG*' -or $repo -like '*YOUR-ORG*' -or $repo -like '*YOUR-REPO*') {
                $results.Add([PSCustomObject]@{ Name = 'PlaceholdersReplaced'; Passed = $false; Detail = "Placeholder values remain: author='$authorName' repository='$repo'" })
            }
            else {
                $results.Add([PSCustomObject]@{ Name = 'PlaceholdersReplaced'; Passed = $true; Detail = '' })
            }
        }
        catch { $results.Add([PSCustomObject]@{ Name = 'PlaceholdersReplaced'; Passed = $false; Detail = "Error: $_" }) }

        # --- 3. All declared agent paths exist ---
        try {
            # Filter out null/empty entries so a malformed manifest produces a precise
            # 'Missing: <empty>' rather than a generic Resolve-Path failure.
            $agentPaths = @($manifest.agents | Where-Object { $_ })
            $missingAgents = @($agentPaths | ForEach-Object {
                    $abs = Resolve-Path -LiteralPath (Join-Path $manifestDir $_) -ErrorAction SilentlyContinue
                    if (-not $abs) { $_ }
                })
            if ($missingAgents.Count -eq 0) {
                $results.Add([PSCustomObject]@{ Name = 'AgentPathsExist'; Passed = $true; Detail = '' })
            }
            else {
                $results.Add([PSCustomObject]@{ Name = 'AgentPathsExist'; Passed = $false; Detail = "Missing: $($missingAgents -join ', ')" })
            }
        }
        catch { $results.Add([PSCustomObject]@{ Name = 'AgentPathsExist'; Passed = $false; Detail = "Error: $_" }) }

        # --- 4. Agent directory contains expected .agent.md files ---
        try {
            $agentDir = Resolve-PluginContentPath -RootPath $RootPath -ContentName 'agents'
            $agentFiles = @(Get-ChildItem -Path $agentDir -Filter '*.agent.md' -File -ErrorAction SilentlyContinue)
            # Derive the expected count from the manifest instead of a hardcoded literal so
            # this check stays self-maintaining as agents are added or removed. Mirrors the
            # string-vs-array handling already established for SkillCountMatch below: when the
            # manifest declares agents as an itemized array (one entry per agent, the same
            # shape AgentPathsExist above already filters with), count the declared entries;
            # when it declares a bare directory string (the shape this repo root plugin.json
            # currently uses), there is no itemized list to compare against, so the expectation
            # falls back to the on-disk count for that directory.
            $agentsValue = $manifest.agents
            if ($agentsValue -is [string]) {
                # M18 (verified, not further fixable without a manifest-shape change):
                # this repo root plugin.json currently declares "agents": "agents/" --
                # a bare directory reference, not an itemized list -- so there is no
                # itemized-array count to drift-check the on-disk *.agent.md files
                # against in this branch. Setting expected = actual here is
                # structurally a no-op check (always Passed=true) for that shape, by
                # design (see the corresponding Pester test own comment). This is
                # NOT fixable by cross-checking .claude-plugin/plugin.json own itemized
                # agents array instead: that array enumerates the lowercase Claude-
                # native shells (agents/{name}.md, e.g. agents/code-smith.md), a
                # DIFFERENT file set than the capitalized shared bodies this check
                # counts (agents/*.agent.md). The two sets happen to pair 1:1 today
                # by repo convention, but nothing in this validator enforces that
                # pairing, so treating the shell count as ground truth for the body
                # count would assume an invariant this check does not actually own.
                $expectedAgentCount = $agentFiles.Count
            }
            else {
                $expectedAgentCount = @($agentsValue | Where-Object { $_ }).Count
            }
            if ($agentFiles.Count -eq $expectedAgentCount) {
                $results.Add([PSCustomObject]@{ Name = 'AgentCount'; Passed = $true; Detail = "$($agentFiles.Count) agents found" })
            }
            else {
                $results.Add([PSCustomObject]@{ Name = 'AgentCount'; Passed = $false; Detail = "Expected $expectedAgentCount agents (per plugin.json), found $($agentFiles.Count)" })
            }
        }
        catch { $results.Add([PSCustomObject]@{ Name = 'AgentCount'; Passed = $false; Detail = "Error: $_" }) }

        # --- 5. All declared skill paths exist ---
        try {
            $skillPaths = @($manifest.skills | Where-Object { $_ })
            $missingSkills = @($skillPaths | ForEach-Object {
                    $abs = Resolve-Path -LiteralPath (Join-Path $manifestDir $_) -ErrorAction SilentlyContinue
                    if (-not $abs) { $_ }
                })
            if ($missingSkills.Count -eq 0) {
                $results.Add([PSCustomObject]@{ Name = 'SkillPathsExist'; Passed = $true; Detail = '' })
            }
            else {
                $results.Add([PSCustomObject]@{ Name = 'SkillPathsExist'; Passed = $false; Detail = "$($missingSkills.Count) missing: $($missingSkills -join ', ')" })
            }
        }
        catch { $results.Add([PSCustomObject]@{ Name = 'SkillPathsExist'; Passed = $false; Detail = "Error: $_" }) }

        # --- 6. Skill count in plugin.json matches filesystem ---
        try {
            $skillsValue = $manifest.skills
            if ($skillsValue -is [string]) {
                # String format (e.g. "skills/"): resolve relative to manifest dir, count subdirectories
                $skillsDirPath = Join-Path $manifestDir $skillsValue
                $declaredSkillCount = @(Get-ChildItem -Path $skillsDirPath -Directory -ErrorAction SilentlyContinue).Count
            }
            else {
                $declaredSkillCount = @($skillsValue).Count
            }
            $fsSkillCount = @(Get-ChildItem -Path (Resolve-PluginContentPath -RootPath $RootPath -ContentName 'skills') -Directory -ErrorAction SilentlyContinue).Count
            if ($declaredSkillCount -eq $fsSkillCount) {
                $results.Add([PSCustomObject]@{ Name = 'SkillCountMatch'; Passed = $true; Detail = "$declaredSkillCount skills declared and on disk" })
            }
            else {
                $results.Add([PSCustomObject]@{ Name = 'SkillCountMatch'; Passed = $false; Detail = "plugin.json declares $declaredSkillCount skills; filesystem has $fsSkillCount directories" })
            }
        }
        catch { $results.Add([PSCustomObject]@{ Name = 'SkillCountMatch'; Passed = $false; Detail = "Error: $_" }) }

        # --- 7. Manifest does not declare unknown fields ---
        # Shared plugin-format known fields per the GitHub Copilot CLI plugin reference,
        # plus standard package metadata this repo already ships in plugin.json.
        try {
            $allowedFields = @('name', 'description', 'version', 'author', 'skills', 'agents', 'hooks', 'mcpServers', 'commands', 'repository', 'license', 'keywords')
            $manifestProps = @($manifest.PSObject.Properties.Name)
            $unsupported = @($manifestProps | Where-Object { $_ -notin $allowedFields })
            if ($unsupported.Count -eq 0) {
                $results.Add([PSCustomObject]@{ Name = 'NoUnsupportedFields'; Passed = $true; Detail = '' })
            }
            else {
                $results.Add([PSCustomObject]@{ Name = 'NoUnsupportedFields'; Passed = $false; Detail = "Manifest declares unknown fields: $($unsupported -join ', ')" })
            }
        }
        catch { $results.Add([PSCustomObject]@{ Name = 'NoUnsupportedFields'; Passed = $false; Detail = "Error: $_" }) }

        return _PreflightSummary $results
    }
    catch {
        Write-Host "[FATAL] Plugin preflight encountered a catastrophic error: $_"
        return [PSCustomObject]@{
            Results    = @()
            PassCount  = 0
            FailCount  = 1
            TotalCount = 1
            ExitCode   = 1
        }
    }
}

function _PreflightSummary {
    param([System.Collections.Generic.List[PSCustomObject]]$Results)

    $passCount = @($Results | Where-Object { $_.Passed -eq $true }).Count
    $failCount = @($Results | Where-Object { $_.Passed -eq $false }).Count
    $totalCount = $Results.Count

    foreach ($r in $Results) {
        if ($r.Passed -eq $true) {
            Write-Host "[PASS] $($r.Name)$(if ($r.Detail) { ' — ' + $r.Detail })"
        }
        else {
            Write-Host "[FAIL] $($r.Name) — $($r.Detail)"
        }
    }

    $summary = "Plugin preflight: $passCount/$totalCount checks passed"
    Write-Host $summary

    return [PSCustomObject]@{
        Results    = $Results.ToArray()
        PassCount  = [int]$passCount
        FailCount  = [int]$failCount
        TotalCount = [int]$totalCount
        ExitCode   = if ($failCount -gt 0) { 1 } else { 0 }
    }
}
