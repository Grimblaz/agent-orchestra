#Requires -Version 7.0
<#
.SYNOPSIS
    JSONL transcript walker for cost-telemetry per-event cwd+gitBranch filter (issue #467, D1).
.DESCRIPTION
    Discovers all Claude session JSONL files matching the given slug (and worktree slugs),
    applies a per-event cwd+gitBranch filter, traverses subagent transcripts for included
    tool_use Agent dispatches, and returns an aggregated array of included event objects.

    Dependencies:
      - path-normalize.ps1 must be dot-sourced before calling Invoke-CostTranscriptWalk
        (it exports Get-NormalizedPath used for cwd comparison).
#>

# Silent-skip event types — no warning emitted
$script:CostWalkerSilentTypes = [System.Collections.Generic.HashSet[string]]@(
    'user', 'attachment', 'system', 'last-prompt',
    'queue-operation', 'pr-link', 'command_permissions', 'auto_mode',
    'tool_use', 'tool_result'
)
$script:CostWalkerCopilotOtelCwdPrefix = 'copilot-otel://'

function script:Get-CostWalkerPhaseMarker {
    param(
        [AllowNull()][object]$TranscriptEvent
    )

    if ($null -eq $TranscriptEvent -or $TranscriptEvent['type'] -ne 'user') { return $null }

    $content = $TranscriptEvent['message']?['content']
    if ($content -isnot [string]) { return $null }

    $markerPattern = '\A\s*<command-name>/(?<command>(?:agent-orchestra:)?(?:experience|design|plan|orchestrate|code-conductor))</command-name>\s*<command-args>(?<args>[^<]*)</command-args>\s*\z'
    $markerMatch = [regex]::Match($content, $markerPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $markerMatch.Success) { return $null }

    $portHint = $markerMatch.Groups['command'].Value
    if ($portHint.StartsWith('agent-orchestra:', [System.StringComparison]::Ordinal)) {
        $portHint = $portHint.Substring('agent-orchestra:'.Length)
    }

    $argumentText = $markerMatch.Groups['args'].Value.Trim()
    $issueText = $null

    if ([regex]::IsMatch($argumentText, '^\d+$')) {
        $issueText = $argumentText
    }
    else {
        $hashMatch = [regex]::Match($argumentText, '^#(?<issue>\d+)$')
        if ($hashMatch.Success) {
            $issueText = $hashMatch.Groups['issue'].Value
        }
        else {
            $issueMatch = [regex]::Match($argumentText, '^issue\s+(?<issue>\d+)$')
            if ($issueMatch.Success) {
                $issueText = $issueMatch.Groups['issue'].Value
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($issueText)) { return $null }

    $issueNumber = 0
    if ([int]::TryParse($issueText, [ref]$issueNumber)) {
        return @{
            IssueId  = $issueNumber
            PortHint = $portHint
        }
    }

    return $null
}

function script:Test-CostWalkerEventCwdMatchesParent {
    param(
        [Parameter(Mandatory)]$TranscriptEvent,
        [Parameter(Mandatory)][string]$NormalizedParentCwd
    )

    $eventCwd = $TranscriptEvent['cwd']
    if ($null -eq $eventCwd) { return $false }

    if (([string]$eventCwd).StartsWith($script:CostWalkerCopilotOtelCwdPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }

    $normalizedEventCwd = Get-NormalizedPath -Path ([string]$eventCwd)
    return $normalizedEventCwd -eq $NormalizedParentCwd
}

function script:Test-CostWalkerPhaseMarkerBranchAllowed {
    param(
        [AllowNull()][object]$Branch
    )

    return $null -eq $Branch -or [string]::IsNullOrEmpty([string]$Branch) -or [string]$Branch -eq 'main'
}

function script:Test-CostWalkerAssistantMatchesStrictFilter {
    param(
        [Parameter(Mandatory)]$TranscriptEvent,
        [Parameter(Mandatory)][string]$NormalizedParentCwd,  # keep param for signature compat
        [Parameter(Mandatory)][string]$Branch
    )

    $eventBranch = $TranscriptEvent['gitBranch']
    if ($null -eq $eventBranch) { return $false }
    # D2: identity check is done at slug-dir level; per-event filter uses branch only.
    return [string]$eventBranch -eq $Branch
}

function script:Add-CostWalkerAssistantEventAndSubagents {
    param(
        [Parameter(Mandatory)]$Included,
        [Parameter(Mandatory)]$TranscriptEvent,
        [Parameter(Mandatory)][string]$SlugDir
    )

    $Included.Add($TranscriptEvent)

    # Traverse subagent transcripts for included Agent tool_use dispatches.
    $messageContent = $TranscriptEvent['message']?['content']
    if ($null -eq $messageContent) { return }

    foreach ($contentItem in $messageContent) {
        if ($null -eq $contentItem) { continue }
        $itemType = $contentItem['type']
        $itemName = $contentItem['name']
        if ($itemType -eq 'tool_use' -and $itemName -eq 'Agent') {
            $toolUseId = $contentItem['id']
            if ($null -ne $toolUseId) {
                $subagPath = Join-Path $SlugDir 'subagents' "agent-$toolUseId.jsonl"
                if (Test-Path -LiteralPath $subagPath) {
                    $subLines = @(Get-Content -Path $subagPath -Encoding utf8 -ErrorAction SilentlyContinue)
                    foreach ($subLine in $subLines) {
                        $subTrimmed = $subLine.Trim()
                        if ([string]::IsNullOrEmpty($subTrimmed)) { continue }
                        try {
                            $subagEvent = $subTrimmed | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                            $Included.Add($subagEvent)
                        }
                        catch {
                            $subagPathForMsg = $subagPath
                            Write-Warning "cost-walker: failed to parse subagent JSON line in ${subagPathForMsg}: $_"
                        }
                    }
                }
                # Absent subagent transcript is silently tolerated.
            }
        }
    }
}

function Get-CostTranscriptSlug {
    <#
    .SYNOPSIS
        Derives the Claude projects slug from a CWD path string.
    .DESCRIPTION
        Slug derivation rule (issue #467 D1):
          Split path into segments, replace spaces within segments with '-',
          join as: {drive}--{seg1}-{seg2}-...
          Drive letter is lowercased; all other segment case is preserved.
        Examples:
          C:\Users\Micah\Code 2\copilot-orchestra  -> c--Users-Micah-Code-2-copilot-orchestra
          /c/Users/Micah/Code 2/copilot-orchestra  -> c--Users-Micah-Code-2-copilot-orchestra
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CwdPath
    )

    # Step 1: Normalize to forward slashes
    $p = $CwdPath.Replace('\', '/')

    # Step 2: Strip leading slash (git-bash /c/... or UNC-style leading slashes)
    $p = $p.TrimStart('/')

    # Step 3: Strip drive-letter colon and lowercase drive (e.g. "C:/..." -> "c/...")
    if ($p -match '^([A-Za-z]):(.*)$') {
        $driveLetter = $Matches[1].ToLowerInvariant()
        $afterColon = $Matches[2].TrimStart('/')
        $p = if ($afterColon) { "$driveLetter/$afterColon" } else { $driveLetter }
    }

    # Step 4: Split into non-empty path segments
    $segments = @($p.Split('/') | Where-Object { $_ -ne '' })

    if ($segments.Count -eq 0) {
        return ''
    }

    # Step 5: Replace spaces with '-' within each segment
    $processedSegments = @($segments | ForEach-Object { $_.Replace(' ', '-') })

    # Step 6: Join: drive segment + '--' + remaining segments joined by '-'
    if ($processedSegments.Count -eq 1) {
        return $processedSegments[0]
    }

    $driveSegment = $processedSegments[0]
    $remainingJoined = $processedSegments[1..($processedSegments.Count - 1)] -join '-'
    return "$driveSegment--$remainingJoined"
}

function script:Resolve-CostWalkerPrimarySlugDir {
    param(
        [Parameter(Mandatory)][string]$ProjectsRoot,
        [Parameter(Mandatory)][string]$Slug
    )

    $primaryDir = Join-Path $ProjectsRoot $Slug
    if (Test-Path -LiteralPath $primaryDir) {
        return $primaryDir
    }

    $matchingDir = Get-ChildItem -Path $ProjectsRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { [string]::Equals($_.Name, $Slug, [System.StringComparison]::OrdinalIgnoreCase) } |
        Select-Object -First 1

    if ($null -ne $matchingDir) {
        return $matchingDir.FullName
    }

    Write-Warning "cost-walker: slug directory not found: $primaryDir"
    return $null
}

function script:Resolve-CostWalkerRepoIdentity {
    <#
    .SYNOPSIS
        Normalize a git remote URL to a transport-agnostic host/path identity.
    .DESCRIPTION
        Fix #760-E1: collapse SSH, HTTPS, and credential-embedded URL forms to a
        single comparable 'host/path' string so a session cloned over SSH matches
        a ledger repo root configured over HTTPS (and vice versa).  Without this,
        the same repo reached via different transports produces different raw URLs
        and a session is silently excluded from attribution.

        Handles:
          - scp-like SSH:        git@github.com:owner/repo(.git)
          - ssh:// scheme:       ssh://git@github.com/owner/repo(.git)
          - credentialed HTTPS:  https://x-access-token:TOKEN@github.com/owner/repo
          - plain HTTPS:         https://github.com/owner/repo(.git)
        Returns $null for empty/whitespace input.
    .OUTPUTS
        [string] normalized 'host/path', or $null.
    #>
    param([string]$RawUrl)

    if ([string]::IsNullOrWhiteSpace($RawUrl)) { return $null }

    $u = $RawUrl.Trim()

    # scp-like SSH form (no scheme, ':' separates host and path): git@host:owner/repo
    if ($u -match '^[^/@]+@([^:/]+):(.+)$') {
        $u = "$($Matches[1])/$($Matches[2])"
    }
    else {
        # Strip URL scheme (https://, ssh://, git://, http://, ...)
        $u = $u -replace '^[a-zA-Z][a-zA-Z0-9+.\-]*://', ''
        # Strip userinfo (user@ or user:password@ / x-access-token:TOKEN@) before the host
        $u = $u -replace '^[^/@]+@', ''
    }

    $u = $u.ToLowerInvariant().TrimEnd('/')
    if ($u.EndsWith('.git')) { $u = $u.Substring(0, $u.Length - 4) }

    if ([string]::IsNullOrWhiteSpace($u)) { return $null }
    return $u
}

function script:Get-IdentityMatchedSlugDirs {
    param(
        [Parameter(Mandatory)][string]$ProjectsRoot,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    # Resolve target repo identity once from the ledger's repo root.
    $targetIdentity = $null
    try {
        $rawUrl = @(& git -C $RepoRoot remote get-url origin 2>$null) | Select-Object -First 1
        if ($global:LASTEXITCODE -eq 0) {
            $targetIdentity = script:Resolve-CostWalkerRepoIdentity -RawUrl ([string]$rawUrl)
        }
    } catch { }

    if ($null -eq $targetIdentity) {
        # Can't resolve target identity — fail-closed: return empty list, no slug dirs admitted.
        return [System.Collections.Generic.List[string]]::new()
    }

    $matched = [System.Collections.Generic.List[string]]::new()

    $allDirs = @(Get-ChildItem -Path $ProjectsRoot -Directory -ErrorAction SilentlyContinue)
    foreach ($dir in $allDirs) {
        # Find the first event with a cwd field in any JSONL file in this slug dir.
        $firstCwd = $null
        $jsonls = @(Get-ChildItem -Path $dir.FullName -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | Select-Object -First 5)
        foreach ($jf in $jsonls) {
            if ($null -ne $firstCwd) { break }
            $lines = @(Get-Content -Path $jf.FullName -Encoding utf8 -ErrorAction SilentlyContinue | Select-Object -First 20)
            foreach ($ln in $lines) {
                $trimmed = $ln.Trim()
                if ([string]::IsNullOrEmpty($trimmed)) { continue }
                try {
                    $ev = $trimmed | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                    if (-not [string]::IsNullOrEmpty([string]$ev['cwd'])) {
                        $cwd = [string]$ev['cwd']
                        if (-not $cwd.StartsWith($script:CostWalkerCopilotOtelCwdPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $firstCwd = $cwd
                            break
                        }
                    }
                } catch { }
            }
        }

        if ($null -eq $firstCwd) { continue }  # fail-closed: no usable cwd found

        # Resolve this slug dir's identity from the first-event cwd.
        $candidateIdentity = $null
        try {
            $rawUrl = @(& git -C $firstCwd remote get-url origin 2>$null) | Select-Object -First 1
            if ($global:LASTEXITCODE -eq 0) {
                $candidateIdentity = script:Resolve-CostWalkerRepoIdentity -RawUrl ([string]$rawUrl)
            }
        } catch { }

        if ($null -eq $candidateIdentity) { continue }  # fail-closed: can't verify identity

        if ($candidateIdentity -eq $targetIdentity) {
            $matched.Add($dir.FullName)
        }
        # else: same-leaf different-repo → rejected (identity mismatch)
    }

    return $matched
}

function Invoke-CostTranscriptWalk {
    <#
    .SYNOPSIS
        Walks Claude JSONL session transcripts and returns per-event-filtered results.
    .DESCRIPTION
        Discovers *.jsonl files under:
          {ProjectsRoot}/{Slug}/
          {ProjectsRoot}/{Slug}--claude-worktrees-*/
        For each discovered JSONL file, applies a per-event filter:
          Include if: type -eq 'assistant' AND cwd matches ParentCwd AND gitBranch matches Branch
        For each included assistant event that contains a tool_use with name -eq 'Agent',
        loads {sessionDir}/subagents/agent-{toolUseId}.jsonl and includes all its events.
        Returns a List[object] of included event hashtables (cast to array by caller via @(...)).
    .PARAMETER Slug
        Pre-computed slug string for the project directory.
    .PARAMETER Branch
        Git branch name to filter events by.
    .PARAMETER ParentCwd
        Working directory path; normalized before comparison.
    .PARAMETER ProjectsRoot
        Root directory containing project slug directories. Defaults to ~/.claude/projects.
    .PARAMETER IssueNumber
        Optional GitHub issue number. When supplied, enables upstream phase-marker windowing
        and admits only assistant events inside matching issue windows on main/empty branches.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Slug = '',
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$ParentCwd,
        [string]$ProjectsRoot = '',
        [Nullable[int]]$IssueNumber = $null,
        [string]$RepoRoot = ''
    )

    if (-not $ProjectsRoot) {
        $ProjectsRoot = Join-Path ([System.Environment]::GetFolderPath('UserProfile')) '.claude' 'projects'
    }

    # Normalize the caller's CWD once for all comparisons
    $normalizedParentCwd = Get-NormalizedPath -Path $ParentCwd
    $phaseMarkerMode = $null -ne $IssueNumber -and [int]$IssueNumber -gt 0
    $targetIssueNumber = if ($phaseMarkerMode) { [int]$IssueNumber } else { $null }

    $included = [System.Collections.Generic.List[object]]::new()

    # Collect all slug directories to search
    $slugDirs = [System.Collections.Generic.List[string]]::new()

    $resolvedRepoRoot = if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot } else { $ParentCwd }

    # D2: discover all slug dirs in ProjectsRoot that belong to the same git repo (identity match).
    $identityDirs = script:Get-IdentityMatchedSlugDirs -ProjectsRoot $ProjectsRoot -RepoRoot $resolvedRepoRoot

    foreach ($d in $identityDirs) {
        $slugDirs.Add($d)
    }

    # Also include worktree directories for the primary slug (backward compat / graceful fallback
    # for worktree slugs that may not have first-event cwd pointing to the main repo root).
    if (-not [string]::IsNullOrWhiteSpace($Slug)) {
        $worktreeDirs = @(Get-ChildItem -Path $ProjectsRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "$Slug--claude-worktrees-*" } |
            Where-Object { $slugDirs -notcontains $_.FullName })
        foreach ($wtd in $worktreeDirs) {
            $slugDirs.Add($wtd.FullName)
        }
    }

    # Backward compat: include explicit slug dir when identity resolution is unavailable
    # (e.g., tests without a real git repo). In production, identity matching already
    # finds this dir; dedup guard prevents double-counting.
    if (-not [string]::IsNullOrWhiteSpace($Slug)) {
        $primarySlugDir = script:Resolve-CostWalkerPrimarySlugDir -ProjectsRoot $ProjectsRoot -Slug $Slug
        if ($null -ne $primarySlugDir -and $slugDirs -notcontains $primarySlugDir) {
            $slugDirs.Add($primarySlugDir)
        }
    }

    if ($slugDirs.Count -eq 0) {
        return $included
    }

    foreach ($slugDir in $slugDirs) {
        # Only top-level JSONL files in the slug directory (not in subdirectories)
        $jsonlFiles = @(Get-ChildItem -Path $slugDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)

        foreach ($file in $jsonlFiles) {
            $lines = @(Get-Content -Path $file.FullName -Encoding utf8 -ErrorAction SilentlyContinue)
            $currentWindowIssue = $null
            $currentWindowPortHint = $null
            foreach ($line in $lines) {
                $trimmed = $line.Trim()
                if ([string]::IsNullOrEmpty($trimmed)) { continue }

                $parsedEvent = $null
                try {
                    $parsedEvent = $trimmed | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                }
                catch {
                    Write-Warning "cost-walker: failed to parse JSON line in $($file.FullName): $_"
                    continue
                }

                $eventType = $parsedEvent['type']

                if ($phaseMarkerMode) {
                    $eventBranch = $parsedEvent['gitBranch']
                    if (-not (script:Test-CostWalkerPhaseMarkerBranchAllowed -Branch $eventBranch)) {
                        $currentWindowIssue = $null
                        $currentWindowPortHint = $null
                    }

                    $phaseMarker = script:Get-CostWalkerPhaseMarker -TranscriptEvent $parsedEvent
                    if ($null -ne $phaseMarker) {
                        $currentWindowIssue = $phaseMarker.IssueId
                        $currentWindowPortHint = $phaseMarker.PortHint
                    }

                    if ($eventType -eq 'assistant') {
                        if (script:Test-CostWalkerAssistantMatchesStrictFilter -TranscriptEvent $parsedEvent -NormalizedParentCwd $normalizedParentCwd -Branch $Branch) {
                            script:Add-CostWalkerAssistantEventAndSubagents -Included $included -TranscriptEvent $parsedEvent -SlugDir $slugDir
                            continue
                        }

                        if ($currentWindowIssue -ne $targetIssueNumber) { continue }
                        # D2: identity check is done at slug-dir level; cwd guard removed.
                        if (-not (script:Test-CostWalkerPhaseMarkerBranchAllowed -Branch $parsedEvent['gitBranch'])) { continue }

                        $parsedEvent['_phase_marker_port'] = $currentWindowPortHint
                        script:Add-CostWalkerAssistantEventAndSubagents -Included $included -TranscriptEvent $parsedEvent -SlugDir $slugDir
                    }
                    elseif ($null -eq $eventType) {
                        Write-Warning "cost-walker: event with null type in $($file.FullName) — skipping"
                    }
                    elseif ($script:CostWalkerSilentTypes.Contains($eventType)) {
                        continue
                    }
                    else {
                        Write-Warning "cost-walker: unknown event type '$eventType' in $($file.FullName) — skipping"
                    }

                    continue
                }

                if ($eventType -eq 'assistant') {
                    if (-not (script:Test-CostWalkerAssistantMatchesStrictFilter -TranscriptEvent $parsedEvent -NormalizedParentCwd $normalizedParentCwd -Branch $Branch)) { continue }

                    # Event passes filter — include it and traverse Agent subagents.
                    script:Add-CostWalkerAssistantEventAndSubagents -Included $included -TranscriptEvent $parsedEvent -SlugDir $slugDir
                }
                elseif ($null -eq $eventType) {
                    Write-Warning "cost-walker: event with null type in $($file.FullName) — skipping"
                }
                elseif ($script:CostWalkerSilentTypes.Contains($eventType)) {
                    # Known skip types — no warning
                    continue
                }
                else {
                    Write-Warning "cost-walker: unknown event type '$eventType' in $($file.FullName) — skipping"
                }
            }
        }
    }

    return $included
}
