#Requires -Version 7.0

<#
.SYNOPSIS
    Core helper library for reading and parsing engagement records (SMC-20).

.DESCRIPTION
    Scans the comments of a GitHub issue (or parses in-memory marker strings)
    to find <!-- engagement-record-{phase}-{ID} --> markers, decodes their
    YAML payloads using the powershell-yaml module, and returns the parsed
    decisions. Supports latest-comment-wins resolution by createdAt timestamp.

    InMemoryMarkers timestamp-tiebreak rule:
    When -InMemoryMarkers is used, there are no gh createdAt timestamps, so
    latest is resolved by input order (the last element in the array wins).

.PARAMETER IssueNumber
    The GitHub issue ID. Mandatory.

.PARAMETER Phase
    Optional. If specified, must be 'experience', 'design', 'plan', or 'orchestration'. Filters records to this phase.

.PARAMETER Repo
    Optional. The GitHub repository in owner/name format. Defaults to current repo.

.PARAMETER InMemoryMarkers
    Optional. Array of raw marker text strings to parse directly, bypassing gh.

.PARAMETER GhCliPath
    Optional. Path to the gh CLI executable. Defaults to 'gh'.

.PARAMETER AcceptLegacy
    Optional. If set, permits parsing legacy #571 markers that lack schema_version,
    phase, and capture_session, returning decisions tagged with _legacy: $true.

.OUTPUTS
    [PSCustomObject[]] Array of parsed decision objects.
#>

# Decision-ID slug contract (D3 globally unique + always-filter-by-phase).
# Case-sensitive; lowercase only; 2-64 chars; must start with [a-z]; must not end with hyphen.
# Pattern uses \z (not $) to forbid trailing newline.
$script:DecisionIdSlugRegex = '^[a-z][a-z0-9-]{0,62}[a-z0-9]\z'
$script:DecisionIdSlugDescription = "lowercase only (case-sensitive); 2-64 chars; must start with [a-z]; must not end with hyphen"

function Read-EngagementRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$IssueNumber,

        [Parameter(Mandatory = $false)]
        [ValidateSet('experience', 'design', 'plan', 'orchestration')]
        [string]$Phase,

        [Parameter(Mandatory = $false)]
        [string]$Repo,

        [Parameter(Mandatory = $false)]
        [string[]]$InMemoryMarkers = @(),

        [Parameter(Mandatory = $false)]
        [string]$GhCliPath = 'gh',

        [Parameter(Mandatory = $false)]
        [switch]$AcceptLegacy
    )

    # MF1: Import powershell-yaml inside the function to avoid polluting file scope
    try {
        Import-Module powershell-yaml -ErrorAction Stop
    } catch {
        throw [System.InvalidOperationException]::new("powershell-yaml module is required but could not be loaded: $_")
    }

    $parsedMarkers = @()

    # Step 1: Gather raw markers and their timestamps
    if ($InMemoryMarkers.Count -gt 0) {
        # InMemoryMarkers path (short-circuits gh)
        for ($i = 0; $i -lt $InMemoryMarkers.Count; $i++) {
            $parsedMarkers += [PSCustomObject]@{
                Body      = $InMemoryMarkers[$i]
                CreatedAt = [DateTime]::MinValue.AddTicks($i) # Synthetic ascending timestamp
            }
        }
    } else {
        # GitHub CLI path
        if ([string]::IsNullOrWhiteSpace($Repo)) {
            # Attempt to resolve current repo from git
            try {
                $Repo = & git config --get remote.origin.url
                if ($Repo -match 'github\.com[:/]([^/]+/[^/.]+)(\.git)?') {
                    $Repo = $Matches[1]
                }
                # MF3: Validate resolved repo matches expected owner/name format
                if ($Repo -notmatch '^[A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+$') {
                    $Repo = ''
                }
            } catch {
                # MF14: Emit a warning instead of silently swallowing the error
                Write-Warning "Could not resolve repo from git config: $_"
            }
        }

        try {
            # Note: 'gh issue view --json comments' caps at 100 comments; --paginate is not supported
            # by this subcommand (it is a 'gh api' flag only). For engagement-record markers this is
            # acceptable: markers are emitted at most twice per phase per issue, so the cap is never
            # reached in practice.
            $rawJson = & $GhCliPath issue view $IssueNumber --repo $Repo --json comments 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($rawJson)) {
                $commentsObj = $rawJson | ConvertFrom-Json
                foreach ($comment in $commentsObj.comments) {
                    $parsedMarkers += [PSCustomObject]@{
                        Body      = $comment.body
                        CreatedAt = [DateTime]::Parse($comment.createdAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
                    }
                }
            } elseif ($LASTEXITCODE -ne 0) {
                Write-Warning "gh issue view exited with code $LASTEXITCODE for issue $IssueNumber (repo: $Repo) — engagement-record markers may be missing."
            } else {
                Write-Verbose "gh issue view returned no comments for issue $IssueNumber (repo: $Repo)."
            }
        } catch {
            Write-Error "Failed to fetch comments for issue $IssueNumber from gh CLI: $_"
        }
    }

    $allDecisions = @()

    # Step 2: Parse each marker's YAML content
    $processedMarkers = @()
    foreach ($m in $parsedMarkers) {
        $body = $m.Body
        # Look for engagement-record marker pattern
        if ($body -match '(?m)^\s*<!--\s*engagement-record-([a-zA-Z0-9_-]+)-(\d+)\s*-->') {
            $commentPhase = $Matches[1].ToLowerInvariant()
            $commentIssue = [int]$Matches[2]

            # MF2: Always enforce issue-number match; -AcceptLegacy only relaxes schema validation
            if ($commentIssue -ne $IssueNumber) {
                continue
            }

            # Extract YAML content
            $yamlContent = $null
            if ($body -match '```yaml\s*([\s\S]*?)```') {
                $yamlContent = $Matches[1].Trim()
            } else {
                # Fallback: take everything after the HTML comment
                $htmlIndex = $body.IndexOf("-->")
                if ($htmlIndex -ge 0) {
                    $yamlContent = $body.Substring($htmlIndex + 3).Trim()
                } else {
                    $yamlContent = $body.Trim()
                }
            }

            if ([string]::IsNullOrWhiteSpace($yamlContent)) {
                continue
            }

            # Parse YAML
            $parsedYaml = $null
            try {
                $parsedYaml = ConvertFrom-Yaml -Yaml $yamlContent
            } catch {
                # MF15: Emit a warning so callers can diagnose malformed payloads
                Write-Warning "Malformed YAML in engagement-record marker (issue: $IssueNumber, phase: $commentPhase): $_"
                continue
            }

            if ($null -eq $parsedYaml) {
                continue
            }

            # Schema validation
            $isLegacy = $false
            $missingFields = @()

            # Check if required fields are missing
            if ($null -eq $parsedYaml.schema_version) { $missingFields += "schema_version" }
            if ($null -eq $parsedYaml.phase) { $missingFields += "phase" }
            if ($null -eq $parsedYaml.capture_session) { $missingFields += "capture_session" }

            if ($missingFields.Count -gt 0) {
                if ($AcceptLegacy) {
                    $isLegacy = $true
                } else {
                    # Missing fields in non-legacy mode
                    continue
                }
            }

            # CF13b: wrap per-marker schema/enum validations so a single malformed marker does not abort the scan.
            # Exception: unknown schema_version MUST propagate (SKILL.md Schema Versioning Policy).
            if (-not $isLegacy -and $null -ne $parsedYaml.schema_version -and $parsedYaml.schema_version -notin @(1, 2, 3)) {
                throw [System.InvalidOperationException]::new("unknown schema_version: $($parsedYaml.schema_version)")
            }

            try {
                # Enum validation for non-legacy markers
                if (-not $isLegacy) {
                    # Supported non-legacy phases: experience, design, plan, and orchestration (plan requires schema_version >= 2).
                    if ($parsedYaml.phase -notin @('experience', 'design', 'plan', 'orchestration') -or
                        ($parsedYaml.phase -eq 'plan' -and [int]$parsedYaml.schema_version -lt 2)) {
                        throw [System.InvalidOperationException]::new("Invalid phase value: $($parsedYaml.phase) (phase 'plan' requires schema_version >= 2)")
                    }
                    # NOTE (review P1.F1/P2.F4): this throw fires inside the CF13b try/catch at lines 202-271 and is caught
                    # as Write-Warning, then 'continue'd past. The test `It 'v2-orchestration rejection'` in
                    # conductor-engagement-record.Tests.ps1 uses -WarningAction Stop to convert the swallowed warning to a
                    # terminating action, asserting via wildcard match against the warning text. This is structurally fragile;
                    # a future PR should either (a) move this throw outside the per-marker try/catch (matching the
                    # unknown-schema_version throw at line 198 pattern, but losing cross-phase isolation) or (b) refactor the
                    # test to use -WarningVariable and assert the warning record content directly. Tracked as routine debt.
                    if ($parsedYaml.phase -eq 'orchestration' -and [int]$parsedYaml.schema_version -lt 3) {
                        throw [System.InvalidOperationException]::new("orchestration phase requires schema_version >= 3")
                    }
                }

                $resolvedPhase = if (-not [string]::IsNullOrWhiteSpace($parsedYaml.phase)) {
                    $parsedYaml.phase.ToLowerInvariant()
                } else {
                    $commentPhase
                }

                # Process decisions
                $decisionsList = @()
                if ($null -ne $parsedYaml.load_bearing_decisions) {
                    foreach ($dec in $parsedYaml.load_bearing_decisions) {
                        # Validate decision-level enums in non-legacy mode
                        if (-not $isLegacy) {
                            # Slug validation (enforced for schema_version 2+)
                            # powershell-yaml parses unquoted integers as [int]; -ge 2 is numeric here.
                            if ($parsedYaml.schema_version -ge 2 -and -not (Test-EngagementRecordSlug -DecisionId $dec.decision_id)) {
                                throw [System.InvalidOperationException]::new("Invalid decision_id slug: '$($dec.decision_id)' - $script:DecisionIdSlugDescription (must match $script:DecisionIdSlugRegex)")
                            }
                            if ($null -ne $dec.classification -and $dec.classification -notin @('load-bearing', 'routine')) {
                                throw [System.InvalidOperationException]::new("Invalid classification value: $($dec.classification)")
                            }
                            if ($null -ne $dec.articulation_status -and $dec.articulation_status -notin @('pending', 'complete', 'incomplete')) {
                                throw [System.InvalidOperationException]::new("Invalid articulation_status value: $($dec.articulation_status)")
                            }
                            # Validate recommendation_shift_trigger when present (optional field)
                            if ($null -ne $dec.recommendation_shift_trigger -and
                                $dec.recommendation_shift_trigger -notin @('engineer-pushback', 'new-evidence', 'classification-re-audit', 'classification-re-audit-routine')) {
                                throw [System.InvalidOperationException]::new("Invalid recommendation_shift_trigger value: $($dec.recommendation_shift_trigger) (allowed: engineer-pushback | new-evidence | classification-re-audit | classification-re-audit-routine)")
                            }
                        }

                        # CF22: build the returned PSCustomObject from a hashtable seeded with the raw
                        # parsed decision dict, so additive optional fields (per SKILL.md line 55)
                        # survive the round-trip. Derived fields (phase, schema_version) overlay last
                        # so they win over any like-named keys in the source dict.
                        $decisionFields = @{}
                        if ($null -ne $dec) {
                            foreach ($key in $dec.Keys) {
                                $decisionFields[$key] = $dec[$key]
                            }
                        }
                        $decisionFields['phase'] = $resolvedPhase
                        $decisionFields['schema_version'] = $parsedYaml.schema_version
                        $decObj = [PSCustomObject]$decisionFields

                        if ($isLegacy) {
                            $decObj | Add-Member -MemberType NoteProperty -Name "_legacy" -Value $true -Force
                            $decObj | Add-Member -MemberType NoteProperty -Name "_missing_fields" -Value $missingFields -Force
                        }

                        $decisionsList += $decObj
                    }
                }

                $processedMarkers += [PSCustomObject]@{
                    Phase     = $resolvedPhase
                    CreatedAt = $m.CreatedAt
                    Decisions = $decisionsList
                }
            } catch [System.InvalidOperationException] {
                # CF13b: emit a warning and skip this marker so the resume read still surfaces other valid markers.
                Write-Warning "Skipping malformed engagement-record marker on issue $IssueNumber : $($_.Exception.Message)"
                continue
            }
        }
    }

    # Step 3: Phase filtering (applied AFTER all markers are parsed and BEFORE latest-wins resolution)
    if (-not [string]::IsNullOrWhiteSpace($Phase)) {
        $targetPhase = $Phase.ToLowerInvariant()
        $processedMarkers = $processedMarkers | Where-Object { $_.Phase -eq $targetPhase }
    }

    # Step 4: Latest-wins resolution per phase
    $decisionsByPhase = @{}
    foreach ($pm in $processedMarkers) {
        $p = $pm.Phase
        if (-not $decisionsByPhase.ContainsKey($p) -or $pm.CreatedAt -gt $decisionsByPhase[$p].CreatedAt) {
            $decisionsByPhase[$p] = $pm
        }
    }

    # Collect decisions from the latest marker of each resolved phase
    foreach ($key in $decisionsByPhase.Keys) {
        $allDecisions += $decisionsByPhase[$key].Decisions
    }

    return $allDecisions
}

function Test-EngagementRecordSlug {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$DecisionId
    )
    if ([string]::IsNullOrWhiteSpace($DecisionId)) {
        return $false
    }
    return $DecisionId -cmatch $script:DecisionIdSlugRegex
}

