#Requires -Version 7.0
<#
.SYNOPSIS
    Audit hub artifact paths — extract and inventory file path references across
    the five locked agent-orchestra scopes.

.DESCRIPTION
    Scans the five declared scopes (agent bodies, Claude shells, skill bodies,
    command files, and manifests-and-hooks) and extracts backtick-fenced inline
    path references, JSON string values, and PowerShell string literals that
    match the allowed file-extension set.

    Default invocation prints a deterministic JSON inventory to stdout.

    Switches:
      -Diff      Compare extracted inventory against the classification YAML and
                 report added, removed, and uncategorized families.
      -Render    Regenerate Documents/Design/hub-artifact-paths-audit.md from
                 the current classification YAML and extraction inventory.
      --input    Single-file mode for testing
      --format   Output format flag (currently only 'json' is recognised)
      --help     Print usage

.PARAMETER InputFile
    Single-file mode: extract paths from this file only, using the grammar
    appropriate for its extension.

.PARAMETER Format
    Output format. Currently only 'json' is recognised.

.PARAMETER Diff
    Compare the extracted path inventory against the classification YAML.
    Prints a single-line report: added, removed, and uncategorized counts.

.PARAMETER Render
    Regenerate Documents/Design/hub-artifact-paths-audit.md from the current
    classification YAML and extraction inventory.

.PARAMETER RepoRoot
    Override the repository root (defaults to three levels above this script).
#>

[CmdletBinding()]
param(
    [string]$InputFile,
    [string]$Format,
    [switch]$Diff,
    [switch]$Render,
    [string]$RepoRoot
)

# ---------------------------------------------------------------------------
# --help
# ---------------------------------------------------------------------------
if ($args -contains '--help' -or $args -contains '-Help') {
    @'
audit-hub-artifact-paths.ps1

USAGE
    pwsh audit-hub-artifact-paths.ps1 [--input <file>] [--format json]
                                       [-Diff] [-Render] [--help]

SWITCHES
    --input <file>   Single-file mode: extract from one file only.
    --format json    Emit JSON (default when --format is omitted: also JSON).
    -Diff            Compare extracted inventory against classification YAML;
                     prints: added: N; removed: N; uncategorized: N.
    -Render          Regenerate hub-artifact-paths-audit.md from the
                     classification YAML and current extraction inventory.
    --help           Print this message.
'@
    exit 0
}

# Parse --input and --format from $args (compatibility with positional/named callers)
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -eq '--input' -and $i + 1 -lt $args.Count) {
        $InputFile = $args[$i + 1]
        $i++
    }
    elseif ($args[$i] -eq '--format' -and $i + 1 -lt $args.Count) {
        $Format = $args[$i + 1]
        $i++
    }
}

# (Diff and Render are handled in MAIN after repo root and helpers are resolved)

# ---------------------------------------------------------------------------
# Resolve repo root
# ---------------------------------------------------------------------------
if (-not $RepoRoot) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
}

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Allowed file extensions (the extraction filter)
$AllowedExtensions = @('md', 'ps1', 'yml', 'yaml', 'json', 'sh')
$ExtPattern = '(?:' + ($AllowedExtensions -join '|') + ')'

# Path body pattern: characters allowed in a file path token
# Must contain at least one slash to be considered a path
$PathBodyPattern = "[A-Za-z0-9._/{\\}*-]+"

# Regex: backtick-fenced inline code whose body looks like a path with allowed ext
$MarkdownPathRegex = [regex]"``($PathBodyPattern\.(?:$ExtPattern))``"

# Tool-name tokens that must be excluded even if they accidentally match the pattern
$ToolNameTokens = [System.Collections.Generic.HashSet[string]]@(
    'Read', 'Grep', 'Edit', 'Write', 'Bash', 'Glob', 'Agent',
    'AskUserQuestion', 'gh', 'read_file',
    # extra common tool/cli tokens
    'Get-Content', 'Set-Content', 'Out-File'
)

# Marker template pattern: <!-- marker-name-{PLACEHOLDER} -->
# These must not be extracted as paths
$MarkerTemplateRegex = [regex]'<!--\s*[a-z][a-z0-9-]*-\{[A-Z_a-z]+\}\s*-->'

# URL pattern
$UrlRegex = [regex]'https?://'

# CLI flag pattern (e.g., --%  --no-verify  --force)
$CliFlagRegex = [regex]'^--'

# Predicate DSL tokens to exclude.
# These are bare identifiers declared in Documents/Design/frame-architecture.md
# under the "Predicate-DSL-evaluable" and "Runtime-resolver-only" tables.
$PredicateDslTokens = [System.Collections.Generic.HashSet[string]]@(
    # port names (bare identifiers in applies-when / provides fields)
    'implement-code', 'implement-test', 'implement-refactor', 'implement-docs',
    'experience', 'design', 'plan', 'review', 'post-pr', 'post-fix-review',
    'process-review', 'process-retrospective', 'release-hygiene',
    'ce-gate-cli', 'ce-gate-browser', 'ce-gate-canvas', 'ce-gate-api',
    # DSL identifiers
    'changeset.touches', 'changeset.touchesAny', 'changeset.touchesSource',
    'changeset.touchesTestableCode', 'changeset.touchesTestableCodeOrTests',
    'changeset.touchedAreaHasRefactorableDebt', 'changeset.changesBehaviorOrInterface',
    'changeset.touchesCliSurface', 'changeset.touchesBrowserSurface',
    'changeset.touchesCanvasSurface', 'changeset.touchesApiSurface',
    'changeset.touchesPluginEntryPoint', 'changeset.totalLines',
    'changeset.complexity', 'changeset.isPipelineEntryTrivial',
    'changeset.touchedAreaHasDebt', 'changeset.touchesBehaviorOrInterfaceDocsExtended',
    'scope.isReReview', 'scope.isProxyGithub',
    'review.sustainedCriticalOrHigh', 'ceGate.defectsFound',
    'express_lane', 'never',
    # function fragments that can appear as bare tokens
    'touchesSource', 'touchesTestableCode', 'touchedAreaHasRefactorableDebt',
    'changesBehaviorOrInterface', 'touchesCliSurface', 'touchesBrowserSurface',
    'touchesCanvasSurface', 'touchesApiSurface', 'touchesPluginEntryPoint',
    'sustainedCriticalOrHigh', 'defectsFound', 'isReReview', 'isProxyGithub',
    'isPipelineEntryTrivial', 'touchedAreaHasDebt',
    'touchesBehaviorOrInterfaceDocsExtended', 'touchesAny'
)

# D2a template placeholders — normalized to '*' before family clustering
$D2aPlaceholders = @(
    '\{ID\}', '\{PR\}', '\{NUMBER\}', '\{name\}',
    '\{port\}', '\{ISSUE_NUMBER\}', '\{N\}', '\{Surface\}'
)

# ---------------------------------------------------------------------------
# Helper: normalise D2a placeholders in a path string
# ---------------------------------------------------------------------------
function Normalize-Placeholders {
    param([string]$Path)
    $result = $Path
    foreach ($ph in $D2aPlaceholders) {
        $result = [regex]::Replace($result, $ph, '*')
    }
    return $result
}

# ---------------------------------------------------------------------------
# Helper: determine whether a candidate string is a valid extractable path
# ---------------------------------------------------------------------------
function Test-IsExtractablePath {
    param([string]$Candidate)

    # Must contain a slash — bare filenames without a path separator are not paths
    if ($Candidate -notmatch '/') { return $false }

    # Exclude glob-only patterns containing ** (tool capability globs, not real paths)
    if ($Candidate -match '\*\*') { return $false }

    # Must end with an allowed extension
    if ($Candidate -notmatch "\.($ExtPattern)$") { return $false }

    # Exclude tool-name tokens
    if ($ToolNameTokens.Contains($Candidate)) { return $false }

    # Exclude URLs
    if ($UrlRegex.IsMatch($Candidate)) { return $false }

    # Exclude CLI flags
    if ($CliFlagRegex.IsMatch($Candidate)) { return $false }

    # Exclude predicate DSL tokens
    if ($PredicateDslTokens.Contains($Candidate)) { return $false }

    return $true
}

# ---------------------------------------------------------------------------
# Grammar 1: Markdown — extract backtick-fenced inline code spans
# ---------------------------------------------------------------------------
function Extract-MarkdownPaths {
    param([string]$Content)
    $results = [System.Collections.Generic.List[string]]::new()
    $matches = $MarkdownPathRegex.Matches($Content)
    foreach ($m in $matches) {
        $candidate = $m.Groups[1].Value
        # Skip marker template comments in surrounding context
        # (the backtick itself is not a marker, but check anyway)
        if (Test-IsExtractablePath $candidate) {
            $results.Add($candidate)
        }
    }
    return $results
}

# ---------------------------------------------------------------------------
# Grammar 2: JSON — recursively walk all string values
# ---------------------------------------------------------------------------
function Extract-JsonStringValues {
    param([object]$Node)
    $results = [System.Collections.Generic.List[string]]::new()

    if ($null -eq $Node) { return $results }

    if ($Node -is [string]) {
        $candidate = $Node
        if (Test-IsExtractablePath $candidate) {
            $results.Add($candidate)
        }
    }
    elseif ($Node -is [System.Collections.IDictionary]) {
        foreach ($key in $Node.Keys) {
            foreach ($item in (Extract-JsonStringValues $Node[$key])) {
                $results.Add($item)
            }
        }
    }
    elseif ($Node -is [System.Collections.IEnumerable]) {
        foreach ($element in $Node) {
            foreach ($item in (Extract-JsonStringValues $element)) {
                $results.Add($item)
            }
        }
    }
    elseif ($Node -is [PSCustomObject]) {
        foreach ($prop in $Node.PSObject.Properties) {
            foreach ($item in (Extract-JsonStringValues $prop.Value)) {
                $results.Add($item)
            }
        }
    }

    return $results
}

function Extract-JsonPaths {
    param([string]$Content)
    $results = [System.Collections.Generic.List[string]]::new()
    try {
        $parsed = $Content | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        foreach ($item in (Extract-JsonStringValues $parsed)) {
            $results.Add($item)
        }
    }
    catch {
        Write-Error "JSON parse error: $_"
        exit 1
    }
    return $results
}

# ---------------------------------------------------------------------------
# Grammar 3: PowerShell — extract single- and double-quoted string literals
# ---------------------------------------------------------------------------
function Extract-PowerShellPaths {
    param([string]$Content)
    $results = [System.Collections.Generic.List[string]]::new()

    # Single-quoted literals: '...'
    $singleQuoteRegex = [regex]"'([^']+)'"
    foreach ($m in $singleQuoteRegex.Matches($Content)) {
        $candidate = $m.Groups[1].Value
        if (Test-IsExtractablePath $candidate) {
            $results.Add($candidate)
        }
    }

    # Double-quoted literals: "..."
    # Avoid matching PowerShell interpolation $(...) as a path — simple filter
    $doubleQuoteRegex = [regex]'"([^"]+)"'
    foreach ($m in $doubleQuoteRegex.Matches($Content)) {
        $candidate = $m.Groups[1].Value
        # Skip strings that contain PowerShell variable expressions
        if ($candidate -match '\$') { continue }
        if (Test-IsExtractablePath $candidate) {
            $results.Add($candidate)
        }
    }

    return $results
}

# ---------------------------------------------------------------------------
# Dispatch grammar by file extension / name
# ---------------------------------------------------------------------------
function Extract-PathsFromFile {
    param([string]$FilePath)

    $content = Get-Content -Path $FilePath -Raw -ErrorAction Stop
    $ext = [System.IO.Path]::GetExtension($FilePath).TrimStart('.')
    $name = [System.IO.Path]::GetFileName($FilePath)

    if ($ext -eq 'json') {
        return Extract-JsonPaths $content
    }
    elseif ($ext -eq 'ps1') {
        return Extract-PowerShellPaths $content
    }
    else {
        # Markdown grammar for .md, .agent.md, SKILL.md, etc.
        return Extract-MarkdownPaths $content
    }
}

# ---------------------------------------------------------------------------
# Build the inventory entry list
# ---------------------------------------------------------------------------
function Build-Inventory {
    param([string[]]$FilePaths)

    $entries = [System.Collections.Generic.List[pscustomobject]]::new()

    foreach ($fp in $FilePaths) {
        $normalized = $fp -replace '\\', '/'
        $rawPaths = Extract-PathsFromFile $fp

        foreach ($raw in $rawPaths) {
            $normalizedPath = Normalize-Placeholders $raw
            $entries.Add([pscustomobject]@{
                source_file = $normalized
                raw_path    = $raw
                path_family = $normalizedPath
            })
        }
    }

    # Sort deterministically: path_family then raw_path then source_file
    $sorted = $entries | Sort-Object path_family, raw_path, source_file

    return $sorted
}

# ---------------------------------------------------------------------------
# Resolve the five locked scope globs (full-repo mode)
# ---------------------------------------------------------------------------
function Get-ScopeFiles {
    param([string]$Root)

    $files = [System.Collections.Generic.List[string]]::new()

    # Scope 1: agents/*.agent.md
    $scope1 = Get-ChildItem -Path (Join-Path $Root 'agents') -Filter '*.agent.md' -ErrorAction SilentlyContinue
    foreach ($f in $scope1) { $files.Add($f.FullName) }

    # Scope 2: agents/*.md (excluding .agent.md)
    $scope2 = Get-ChildItem -Path (Join-Path $Root 'agents') -Filter '*.md' -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -notlike '*.agent.md' }
    foreach ($f in $scope2) { $files.Add($f.FullName) }

    # Scope 3: skills/*/SKILL.md
    $scope3 = Get-ChildItem -Path (Join-Path $Root 'skills') -Filter 'SKILL.md' -Recurse -ErrorAction SilentlyContinue
    foreach ($f in $scope3) { $files.Add($f.FullName) }

    # Scope 4: commands/*.md
    $scope4 = Get-ChildItem -Path (Join-Path $Root 'commands') -Filter '*.md' -ErrorAction SilentlyContinue
    foreach ($f in $scope4) { $files.Add($f.FullName) }

    # Scope 5: manifests-and-hooks aggregates
    # .claude-plugin/plugin.json
    $claudePlugin = Join-Path $Root '.claude-plugin/plugin.json'
    if (Test-Path $claudePlugin) { $files.Add((Resolve-Path $claudePlugin).Path) }

    # root plugin.json
    $rootPlugin = Join-Path $Root 'plugin.json'
    if (Test-Path $rootPlugin) { $files.Add((Resolve-Path $rootPlugin).Path) }

    # root hooks.json
    $rootHooks = Join-Path $Root 'hooks.json'
    if (Test-Path $rootHooks) { $files.Add((Resolve-Path $rootHooks).Path) }

    # plugin-distributed hook scripts (SessionStart / PostToolUse)
    # These are .ps1 files referenced by the plugin manifests in .claude-plugin/
    $hooksDir = Join-Path $Root '.github/scripts'
    if (Test-Path $hooksDir) {
        $hookScripts = Get-ChildItem -Path $hooksDir -Filter '*.ps1' -Depth 0 -ErrorAction SilentlyContinue
        foreach ($f in $hookScripts) { $files.Add($f.FullName) }

        # lib/ helper scripts are also plugin-distributed; scan them separately
        $libDir = Join-Path $hooksDir 'lib'
        if (Test-Path $libDir) {
            $libScripts = Get-ChildItem -Path $libDir -Filter '*.ps1' -Depth 0 -ErrorAction SilentlyContinue
            foreach ($f in $libScripts) { $files.Add($f.FullName) }
        }
    }

    # skills/*/platforms/*.md
    $scope5Platforms = Get-ChildItem -Path (Join-Path $Root 'skills') -Filter '*.md' -Recurse -ErrorAction SilentlyContinue |
                       Where-Object { $_.DirectoryName -like '*\platforms' -or $_.DirectoryName -like '*/platforms' }
    foreach ($f in $scope5Platforms) { $files.Add($f.FullName) }

    return $files.ToArray()
}

# ---------------------------------------------------------------------------
# Helper: load YAML family keys from the classification file
# ---------------------------------------------------------------------------
function Get-ClassificationFamilyKeys {
    param([string]$YamlPath)
    $keys = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path $YamlPath)) { return $keys }
    $lines = Get-Content -Path $YamlPath -Raw
    $keyMatches = [regex]::Matches($lines, '(?m)^\s+"([^"]+)":\s*$')
    foreach ($m in $keyMatches) {
        $keys.Add($m.Groups[1].Value)
    }
    return $keys
}

# ---------------------------------------------------------------------------
# Helper: return the set of candidate forms to try for matching a path_family
# against YAML family keys.
#
# Bare relative path_family values extracted from skill bodies appear without
# the skills/*/ prefix (e.g., "adapters/*.md" instead of "skills/*/adapters/*.md").
# The classification YAML documents these as mapping to their parent family.
# We enumerate all reasonable expanded forms so the -like match succeeds.
# ---------------------------------------------------------------------------
function Get-PathFamilyCandidates {
    param([string]$PathFamily)

    $candidates = [System.Collections.Generic.List[string]]::new()

    # Always include the original and the ./stripped form
    $stripped = $PathFamily -replace '^\./', ''
    $candidates.Add($PathFamily)
    if ($stripped -ne $PathFamily) {
        $candidates.Add($stripped)
    }

    # For bare relative paths (no leading . or / and no drive letter),
    # try common prefix expansions that the YAML notes document:
    #   adapters/...   -> skills/*/adapters/...
    #   references/... -> skills/*/references/...
    #   platforms/...  -> skills/*/platforms/...
    #   scripts/...    -> skills/*/scripts/...
    #   assets/...     -> skills/*/assets/...
    #   templates/...  -> templates/... (already matches)
    #   workflows/...  -> workflows/... (already matches)
    #   lib/...        -> .github/scripts/lib/... AND skills/*/scripts/...
    #   {name}/SKILL.md (bare skill-relative SKILL.md) -> skills/*/SKILL.md
    #   {name}/SKILL.md                               -> skills/*/{name}/SKILL.md (subset)

    if ($stripped -notmatch '^[./]') {
        # Bare relative path
        $firstSegment = ($stripped -split '/')[0]

        switch -Regex ($firstSegment) {
            '^adapters$' {
                $candidates.Add("skills/*/adapters/$($stripped.Substring('adapters/'.Length))")
            }
            '^references$' {
                $candidates.Add("skills/*/references/$($stripped.Substring('references/'.Length))")
            }
            '^platforms$' {
                $candidates.Add("skills/*/platforms/$($stripped.Substring('platforms/'.Length))")
            }
            '^scripts$' {
                $candidates.Add("skills/*/scripts/$($stripped.Substring('scripts/'.Length))")
            }
            '^assets$' {
                $candidates.Add("skills/*/assets/$($stripped.Substring('assets/'.Length))")
            }
            '^lib$' {
                # lib/*.ps1 references from copilot-cost-collection map to .github/scripts/lib/
                $candidates.Add(".github/scripts/lib/$($stripped.Substring('lib/'.Length))")
                $candidates.Add("skills/*/scripts/$($stripped.Substring('lib/'.Length))")
            }
            default {
                # A bare path like "bdd-scenarios/SKILL.md" or "session-startup/SKILL.md"
                # These are bare skill-relative SKILL.md references; they map to skills/*/SKILL.md.
                # Also try "skills/*/{bare}" for completeness.
                if ($stripped -match '/SKILL\.md$') {
                    $candidates.Add('skills/*/SKILL.md')
                }
                $candidates.Add("skills/*/$stripped")
            }
        }
    }

    return $candidates
}

# ---------------------------------------------------------------------------
# Helper: test whether a path_family matches a YAML family key,
# trying all candidate expansions.
# ---------------------------------------------------------------------------
function Test-FamilyMatchesYaml {
    param([string]$PathFamily, [string[]]$FamilyKeys)

    $candidates = Get-PathFamilyCandidates -PathFamily $PathFamily
    foreach ($cand in $candidates) {
        foreach ($fk in $FamilyKeys) {
            if ($cand -like $fk) {
                return $true
            }
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Helper: test whether a YAML family key has any inventory coverage,
# trying all candidate expansions of each inventory path_family.
# ---------------------------------------------------------------------------
function Test-YamlFamilyHasInventory {
    param([string]$FamilyKey, [string[]]$InventoryFamilies)

    foreach ($invFamily in $InventoryFamilies) {
        $candidates = Get-PathFamilyCandidates -PathFamily $invFamily
        foreach ($cand in $candidates) {
            if ($cand -like $FamilyKey) {
                return $true
            }
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Helper: Invoke-DiffMode — compare inventory against classification YAML
# ---------------------------------------------------------------------------
function Invoke-DiffMode {
    param([string]$Root)

    $yamlPath = Join-Path $Root 'Documents/Design/hub-artifact-paths-classification.yml'
    $familyKeys = @(Get-ClassificationFamilyKeys -YamlPath $yamlPath)

    # Build full inventory
    $scopeFiles = Get-ScopeFiles -Root $Root
    $inventory = Build-Inventory -FilePaths $scopeFiles

    # Collect unique normalized path_family values from inventory
    $inventoryFamilies = @($inventory | ForEach-Object { $_.path_family } | Select-Object -Unique | Sort-Object)

    # uncategorized: unique path_family values that don't match any YAML family key
    $uncategorizedFamilies = [System.Collections.Generic.List[string]]::new()
    foreach ($invFamily in $inventoryFamilies) {
        if (-not (Test-FamilyMatchesYaml -PathFamily $invFamily -FamilyKeys $familyKeys)) {
            $uncategorizedFamilies.Add($invFamily)
        }
    }
    $uncategorizedCount = $uncategorizedFamilies.Count

    # added: same as uncategorized (inventory families not covered by any YAML entry)
    $addedCount = $uncategorizedCount

    # removed: YAML family keys that have no inventory path_family matching them
    $removedFamilies = [System.Collections.Generic.List[string]]::new()
    foreach ($fk in $familyKeys) {
        if (-not (Test-YamlFamilyHasInventory -FamilyKey $fk -InventoryFamilies $inventoryFamilies)) {
            $removedFamilies.Add($fk)
        }
    }
    $removedCount = $removedFamilies.Count

    Write-Output "added: $addedCount; removed: $removedCount; uncategorized: $uncategorizedCount"
}

# ---------------------------------------------------------------------------
# Helper: Invoke-RenderMode — generate hub-artifact-paths-audit.md
# ---------------------------------------------------------------------------
function Invoke-RenderMode {
    param([string]$Root)

    $outputPath = Join-Path $Root 'Documents/Design/hub-artifact-paths-audit.md'
    $yamlPath = Join-Path $Root 'Documents/Design/hub-artifact-paths-classification.yml'
    $BT = [char]96  # backtick character — avoids PS escape-processing in strings

    # Read classification YAML for catalog section
    $yamlContent = Get-Content -Path $yamlPath -Raw -ErrorAction Stop

    # Get HEAD SHA and timestamp for audit-meta block
    $headSha = (& git -C $Root rev-parse HEAD 2>$null)
    if (-not $headSha) { $headSha = 'unknown' }
    $headSha = $headSha.Trim()
    $generatedAt = [System.DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

    # ---------------------------------------------------------------------------
    # Parse the classification YAML into structured entries for the catalog
    # ---------------------------------------------------------------------------
    $families = [System.Collections.Generic.List[hashtable]]::new()

    # Split into family blocks by matching the quoted family key lines
    $familyBlockRegex = [regex]'(?ms)^\s+"([^"]+)":\s*\n((?:(?!\s+"[^"]+":).)*)'
    $familyMatches = $familyBlockRegex.Matches($yamlContent)

    foreach ($fm in $familyMatches) {
        $familyName = $fm.Groups[1].Value
        $block = $fm.Groups[2].Value

        # Parse fields
        $claude = ''
        $copilot = ''
        $versionBump = ''
        $experience = ''
        $notes = ''
        $examples = [System.Collections.Generic.List[string]]::new()

        if ($block -match 'claude_resolves:\s*(\S+)') { $claude = $Matches[1] }
        if ($block -match 'copilot_resolves:\s*(\S+)') { $copilot = $Matches[1] }
        if ($block -match 'requires_version_bump:\s*(\S+)') { $versionBump = $Matches[1] }
        if ($block -match 'experience:\s*(\S+)') { $experience = $Matches[1] }

        # Parse examples list
        $exampleMatches = [regex]::Matches($block, '(?m)^\s+-\s+(.+)$')
        foreach ($em in $exampleMatches) {
            $examples.Add($em.Groups[1].Value.Trim())
        }

        # Parse notes (may be multi-line quoted)
        if ($block -match '(?s)notes:\s*"(.*?)"') {
            $notes = $Matches[1] -replace '\s+', ' '
            $notes = $notes.Trim()
        }

        $families.Add(@{
            Name        = $familyName
            Claude      = $claude
            Copilot     = $copilot
            VersionBump = $versionBump
            Experience  = $experience
            Examples    = $examples
            Notes       = $notes
        })
    }

    # ---------------------------------------------------------------------------
    # Build the catalog section text (families sorted alphabetically for
    # deterministic output and ease of lookup)
    # ---------------------------------------------------------------------------
    $sortedFamilies = $families | Sort-Object { $_.Name }
    $catalogLines = [System.Collections.Generic.List[string]]::new()
    foreach ($fam in $sortedFamilies) {
        $catalogLines.Add("### $BT$($fam.Name)$BT")
        $catalogLines.Add('')
        $catalogLines.Add("- **claude_resolves**: $($fam.Claude)")
        $catalogLines.Add("- **copilot_resolves**: $($fam.Copilot)")
        $catalogLines.Add("- **requires_version_bump**: $($fam.VersionBump)")
        $catalogLines.Add("- **experience**: $($fam.Experience)")
        if ($fam.Examples.Count -gt 0) {
            $catalogLines.Add("- **examples**:")
            foreach ($ex in $fam.Examples) {
                $catalogLines.Add("  - $BT$ex$BT")
            }
        }
        if ($fam.Notes) {
            $catalogLines.Add("- **notes**: $($fam.Notes)")
        }
        $catalogLines.Add('')
    }
    $catalogText = $catalogLines -join "`n"

    # ---------------------------------------------------------------------------
    # Build each section as a string (using $BT for literal backtick characters)
    # ---------------------------------------------------------------------------

    $sectionAuditMeta = "<!-- audit-meta`nlast-verified: $headSha`ngenerated-at: $generatedAt`n-->"

    $sectionPurpose = @(
        '## Purpose',
        '',
        'This document catalogs all hub artifact path references across five scopes of the Agent Orchestra plugin, providing downstream consumer repository maintainers with a reliable inventory of what paths are safe to reference and how each is resolved.'
    ) -join "`n"

    $sectionCustomer = @(
        '## Customer',
        '',
        "Downstream consumer-repo maintainers who install ${BT}agent-orchestra@agent-orchestra${BT} via the Claude plugin marketplace or as a Copilot extension and need to understand which hub artifacts their repo can reference without breaking."
    ) -join "`n"

    $sectionMethodology = @(
        '## Methodology',
        '',
        'This audit document is produced and kept current by the following pipeline:',
        '',
        "(a) **Extraction script and grammar spec** (${BT}.github/scripts/audit-hub-artifact-paths.ps1${BT}): scans five locked scopes — agent bodies (${BT}agents/*.agent.md${BT}), Claude shells (${BT}agents/*.md${BT}), skill bodies (${BT}skills/*/SKILL.md${BT}), command files (${BT}commands/*.md${BT}), and manifests-and-hooks — extracting backtick-fenced inline path references (Markdown grammar), JSON string values (JSON grammar), and single/double-quoted string literals (PowerShell grammar) that end with an allowed extension (${BT}md${BT}, ${BT}ps1${BT}, ${BT}yml${BT}, ${BT}yaml${BT}, ${BT}json${BT}, ${BT}sh${BT}).",
        '',
        "(b) **Classification YAML** (${BT}Documents/Design/hub-artifact-paths-classification.yml${BT}): maps each normalized path family to its resolution behavior for Claude and Copilot, the consumer experience when a path is absent, and whether modifying files in that family requires a plugin version bump.",
        '',
        "(c) **D2a placeholder normalization**: before family clustering, all eight template placeholder tokens are normalized to ${BT}*${BT}:",
        "- ${BT}{ID}${BT}",
        "- ${BT}{PR}${BT}",
        "- ${BT}{NUMBER}${BT}",
        "- ${BT}{name}${BT}",
        "- ${BT}{port}${BT}",
        "- ${BT}{ISSUE_NUMBER}${BT}",
        "- ${BT}{N}${BT}",
        "- ${BT}{Surface}${BT}",
        '',
        "(d) **Pester drift gate** (Step 5 test: ${BT}.github/scripts/Tests/hub-artifact-paths-coverage.Tests.ps1${BT}): asserts that ${BT}-Diff${BT} reports ${BT}added: 0; removed: 0; uncategorized: 0${BT}, blocking merges when the inventory diverges from the classification.",
        '',
        "(e) **Pester CI workflow** (Step 4: ${BT}.github/workflows/pester.yml${BT}): runs the full Pester suite on every pull request, including the extraction grammar tests and drift gate.",
        '',
        "(f) **Reproduction recipes for CE Gate**:",
        '',
        "**Hub-repo verification** (maintainers): from the cloned agent-orchestra working tree, run ${BT}pwsh .github/scripts/audit-hub-artifact-paths.ps1 -Diff${BT}. A result of ${BT}added: 0; removed: 0; uncategorized: 0${BT} confirms the classification covers all inventory paths in the current working tree.",
        '',
        "**Consumer scratch-repo verification** (downstream consumers): in a fresh directory that contains only a consumer project (no agent-orchestra source tree), install the plugin via ${BT}claude plugin install agent-orchestra@agent-orchestra${BT}. Then obtain the script from the plugin cache (path shown by ${BT}cat ~/.claude/plugins/installed_plugins.json${BT} → ${BT}installPath${BT}) and run it from your consumer repo root: ${BT}pwsh <installPath>/.github/scripts/audit-hub-artifact-paths.ps1 -Diff${BT}. A zero-result output confirms the installed plugin cache matches the current classification.",
        '',
        "(g) **Verification Log** (CE Gate s9, issue [#243](https://github.com/Grimblaz/agent-orchestra/issues/243), 2026-05-13): 12-path spot-check executed against plugin cache v2.13.0. All 12 checks PASS.",
        '',
        '| Check | Family | claude_resolves / copilot_resolves | Mechanism | Result |',
        '|---|---|---|---|---|',
        "| C1 | ${BT}agents/*.agent.md${BT} | both | plugin-cache hit: ${BT}agents/Code-Critic.agent.md${BT}; source-tree hit | PASS |",
        "| C2 | ${BT}agents/*.md${BT} | plugin-cache | plugin-cache hit: ${BT}agents/code-critic.md${BT}; registered in ${BT}agents[]${BT} array | PASS |",
        "| C3 | ${BT}skills/*/SKILL.md${BT} | both | plugin-cache hit: ${BT}skills/session-startup/SKILL.md${BT}; source-tree hit | PASS |",
        "| C4 | ${BT}commands/*.md${BT} | plugin-cache | plugin-cache hit: ${BT}commands/orchestrate.md${BT} | PASS |",
        "| C5 | ${BT}.claude-plugin/*.json${BT} | plugin-cache | ${BT}.claude-plugin/plugin.json${BT} present in plugin cache | PASS |",
        "| C6 | ${BT}.github/scripts/*.ps1${BT} | plugin-cache | plugin-cache hit: ${BT}.github/scripts/frame-credit-ledger.ps1${BT} | PASS |",
        "| P1 | ${BT}agents/*.agent.md${BT} | source-tree | ${BT}agents/Code-Conductor.agent.md${BT} present in hub source tree | PASS |",
        "| P2 | ${BT}skills/*/SKILL.md${BT} | source-tree | ${BT}skills/customer-experience/SKILL.md${BT} + ${BT}skills/implementation-discipline/SKILL.md${BT} present | PASS |",
        "| P3 | ${BT}skills/*/platforms/*.md${BT} | source-tree | ${BT}skills/session-startup/platforms/claude.md${BT} + ${BT}copilot.md${BT} present | PASS |",
        "| P4 | ${BT}.github/scripts/*.ps1${BT} | source-tree | ${BT}.github/scripts/frame-credit-ledger.ps1${BT} present in source tree | PASS |",
        "| P5 | ${BT}.github/scripts/lib/*.ps1${BT} | source-tree | ${BT}.github/scripts/lib/frame-credit-ledger-core.ps1${BT} present | PASS |",
        "| P6 | ${BT}agents/*.md${BT} | not-applicable | Shell registered via ${BT}agents[]${BT} in ${BT}.claude-plugin/plugin.json${BT} only; no Copilot equivalent | PASS |",
        '',
        'Scenario results:',
        '',
        '- **S1** (hub agent runs in consumer repo without missing-artifact failures): PASS — all `hard-failure` families present in plugin cache v2.13.0.',
        '- **S2** (audit catalog covers every referenced artifact across five scopes): PASS — `-Diff` reports `added: 0; removed: 0; uncategorized: 0`.',
        '- **S3** (intentionally unresolved references feel informative not broken): PASS — `none`-classified families use `wasted-tool-call` experience with explicit documentation.',
        '- **S4** (maintainer can find the audit and act on it without prior context): PASS — audit doc linked from README.md + CLAUDE.md; Purpose + Customer sections orient a cold reader; `-Diff` output is actionable.',
        '',
        'CE Gate result: ✅ CE Gate passed — intent match: strong. Browser, canvas, and api surfaces: ⏭️ not applicable.'
    ) -join "`n"

    $sectionResolutionTaxonomy = @(
        '## Resolution Taxonomy',
        '',
        '### claude_resolves values',
        '',
        "- **plugin-cache**: Claude loads the artifact from the installed plugin cache (resolved via ${BT}~/.claude/plugins/installed_plugins.json${BT} → ${BT}installPath${BT} → artifact path). This is the primary path for consumer runs.",
        "- **source-tree**: Claude reads directly from the working tree (source-repo CWD). Used for hub-only artifacts that are not distributed via the plugin cache.",
        "- **both**: Claude can resolve from either the plugin cache (D1-chain: ${BT}installed_plugins.json${BT} → ${BT}installPath${BT}) OR from source-repo CWD as fallback. Used for shared artifacts that exist in both contexts.",
        "- **none**: Claude cannot resolve this artifact (it is consumer-generated or session-scoped and not present in any resolvable location).",
        "- **not-applicable**: This family is not applicable from Claude's perspective (e.g., a Copilot-only surface).",
        '',
        '### copilot_resolves values',
        '',
        '- **plugin-manifest**: Copilot loads the artifact via the plugin manifest registration.',
        '- **source-tree**: Copilot reads directly from the source tree in the hub repo.',
        '- **both**: Copilot can resolve from either the plugin manifest or source tree.',
        '- **none**: Copilot cannot resolve this artifact.',
        "- **not-applicable**: This family is not applicable from Copilot's perspective (e.g., Claude-only shells).",
        '',
        '### not-applicable annotation',
        '',
        "When a family is ${BT}not-applicable${BT} for one tool, the ${BT}notes${BT} field in the classification YAML explains the asymmetry — for example, Claude subagent shells (${BT}agents/*.md${BT}) are Claude-only surfaces registered via the ${BT}agents[]${BT} array in ${BT}.claude-plugin/plugin.json${BT}; Copilot uses ${BT}.agent.md${BT} bodies directly and has no corresponding concept.",
        '',
        "### Worked dual-resolved example: ${BT}agents/Code-Critic.agent.md${BT}",
        '',
        "In a **consumer-repo run** (a downstream repo that has installed the plugin), Claude resolves ${BT}agents/Code-Critic.agent.md${BT} via the D1-chain:",
        '',
        "1. Read ${BT}~/.claude/plugins/installed_plugins.json${BT} to find ${BT}installPath${BT} for ${BT}agent-orchestra@agent-orchestra${BT}.",
        "2. Join ${BT}installPath${BT} + ${BT}agents/Code-Critic.agent.md${BT} to get the plugin-cache absolute path.",
        '3. Read the file from plugin cache.',
        '',
        "In a **hub-repo run** (the agent-orchestra repository itself, with ${BT}.claude-plugin/plugin.json${BT} present and no separate plugin install pointing at itself), Claude falls back to source-tree CWD and reads ${BT}agents/Code-Critic.agent.md${BT} directly from the working tree.",
        '',
        "Copilot always reads from the source tree in the hub repo. This dual-resolved behavior is why the classification records ${BT}claude_resolves: both${BT} and ${BT}copilot_resolves: source-tree${BT} for the ${BT}agents/*.agent.md${BT} family."
    ) -join "`n"

    $sectionCatalogHeader = '## Catalog'

    $sectionUnresolvedExperience = @(
        '## Unresolved-Path Experience',
        '',
        "The ${BT}experience${BT} field in the classification describes what a downstream consumer observes when a path in that family cannot be resolved.",
        '',
        '### hard-failure',
        '',
        'The agent dispatch or skill load fails immediately. The consumer sees an explicit error message and no fallback is available.',
        '',
        "**Example families**: ${BT}agents/*.agent.md${BT}, ${BT}agents/*.md${BT}, ${BT}commands/*.md${BT}, ${BT}skills/*/SKILL.md${BT}, ${BT}skills/*/platforms/*.md${BT}, ${BT}skills/*/references/*.md${BT}, ${BT}skills/*/adapters/*.md${BT}, ${BT}skills/*/assets/*.json${BT}, ${BT}.claude-plugin/*.json${BT}, ${BT}.github/plugin/marketplace.json${BT}, ${BT}frame/ports/*.yaml${BT}, ${BT}frame/pipeline-metrics-v4-schema.md${BT}, ${BT}hooks/hooks.json${BT}",
        '',
        '### visible-warning',
        '',
        'The pipeline continues but the consumer sees an error or warning message. A fallback path exists (e.g., the agent falls back to inline guidance in the skill body).',
        '',
        "**Example families**: ${BT}skills/*/scripts/*.ps1${BT}, ${BT}.github/scripts/*.ps1${BT}, ${BT}.github/scripts/lib/*.ps1${BT}, ${BT}.github/scripts/Tests/*.Tests.ps1${BT}, ${BT}.github/scripts/Tests/fixtures/*.ps1${BT}, ${BT}.github/architecture-rules.md${BT}, ${BT}.github/copilot-instructions.md${BT}, ${BT}Documents/Design/*.md${BT}, ${BT}templates/*.md${BT}, ${BT}workflows/*.md${BT}",
        '',
        '### wasted-tool-call',
        '',
        'The agent issues a file-read tool call that returns nothing (or an empty result) because the artifact does not exist in the expected location. No error surface; the agent silently proceeds without the content.',
        '',
        "**Example families**: ${BT}/memories/session/*.md${BT}, ${BT}.github/instructions/*.instructions.md${BT}, ${BT}.claude/settings.json${BT}, ${BT}.claude/settings.local.json${BT}, ${BT}.claude/.state/*.json${BT}, ${BT}.copilot-tracking/*.yml${BT}, ${BT}.copilot-tracking/*.json${BT}, ${BT}.copilot-tracking/*.md${BT}, ${BT}.vscode/settings.json${BT}, ${BT}examples/{stack}/*.md${BT}",
        '',
        '### silent-skip',
        '',
        'The path reference is recognized as consumer-local or gitignored; the agent skips loading it without issuing a tool call or warning.',
        '',
        '**Example families**: None currently classified. This experience tier is reserved for families where the agent has explicit consumer-local knowledge and suppresses the tool call entirely.'
    ) -join "`n"

    $sectionHistoricalContext = @(
        '## Historical Context',
        '',
        'This section documents specific path migration findings (MF) that influenced the audit scope.',
        '',
        "### MF1 — Workspace-relative ${BT}.github/skills/{name}/SKILL.md${BT} pattern (2026-05-12 drift-confirmation)",
        '',
        "The literal ${BT}.github/skills/{name}/SKILL.md${BT} workspace-relative pattern is absent from all five audited scopes. This was a pre-plugin-migration path pattern used before the Agent Orchestra plugin migration. After the migration, agent bodies and skill references moved to the ${BT}skills/*/SKILL.md${BT} family (plugin-cache-distributed). The extraction script finds zero matches for this pattern in the current inventory. **Inventory citations**: zero — this path family no longer appears in any audited scope file.",
        '',
        '### MF7 — Agent body path family resolution under the plugin cache',
        '',
        "The ${BT}agents/*.agent.md${BT} family documents how shared agent bodies (e.g., ${BT}agents/Code-Conductor.agent.md${BT}, ${BT}agents/Code-Critic.agent.md${BT}) are resolved after the plugin migration. Rather than the old workspace-relative path, Claude now resolves these via the D1-chain: ${BT}installed_plugins.json${BT} → ${BT}installPath${BT} → agent body path in the plugin cache. Source-repo CWD is the fallback for hub-repo runs. **Inventory citations**: the ${BT}agents/*.agent.md${BT} family entry in the Catalog section above, with examples including ${BT}agents/Code-Conductor.agent.md${BT}, ${BT}agents/Code-Critic.agent.md${BT}, and ${BT}agents/Code-Smith.agent.md${BT}.",
        '',
        "### MF18 — ${BT}skills/skill-creator/SKILL.md${BT} reference resolution",
        '',
        "${BT}skills/skill-creator/SKILL.md${BT} is referenced within the audited scopes and falls under the ${BT}skills/*/SKILL.md${BT} family. In Claude consumer runs this resolves from the plugin cache (D1-chain: ${BT}installed_plugins.json${BT} → ${BT}installPath${BT} → ${BT}skills/skill-creator/SKILL.md${BT}). In hub-repo runs it resolves from the source-tree CWD. **Inventory citations**: ${BT}skills/skill-creator/SKILL.md${BT} appears in the current extraction inventory, confirming the reference is live and the classification entry for ${BT}skills/*/SKILL.md${BT} covers it."
    ) -join "`n"

    $sectionStaleness = @(
        '## How to Detect Staleness',
        '',
        'The audit document can become stale when agent bodies, skill files, or command files add or remove path references without a corresponding update to the classification YAML.',
        '',
        "(a) **Run the diff tool**: execute ${BT}pwsh .github/scripts/audit-hub-artifact-paths.ps1 -Diff${BT} from the repo root. This produces a single-line report:",
        '',
        '```',
        'added: N; removed: N; uncategorized: N',
        '```',
        '',
        "A result of ${BT}added: 0; removed: 0; uncategorized: 0${BT} means the classification covers all inventory paths. Any non-zero value identifies the gap.",
        '',
        "(b) **Pester drift gate**: the Pester test ${BT}.github/scripts/Tests/hub-artifact-paths-coverage.Tests.ps1${BT} runs ${BT}-Diff${BT} and asserts that all three counts are zero. It runs as part of the CI workflow at ${BT}.github/workflows/pester.yml${BT} on every pull request.",
        '',
        "(c) **${BT}<!-- audit-meta -->${BT} header**: the ${BT}last-verified${BT} SHA in the audit-meta comment block at the top of this file records the HEAD commit at the time this document was last regenerated. Compare it against ${BT}git rev-parse HEAD${BT} to see whether a regeneration pass has occurred since the last code change."
    ) -join "`n"

    $sectionOutOfScope = @(
        '## Out of Scope',
        '',
        '### Internal design documents',
        '',
        "${BT}Documents/Design/*.md${BT} files are carved out of the downstream-consumer scope because they are internal design and decision records for the Agent Orchestra hub repository. Downstream consumer repositories do not receive these files through the plugin distribution mechanism (they are not included in the plugin cache). Agents and skills may cross-reference them for design intent during hub-repo development, but a consumer repo that attempts to resolve a ${BT}Documents/Design/*.md${BT} path receives a visible-warning (the agent proceeds without the design context) rather than a hard-failure.",
        '',
        '**(AC9 follow-up tracking issue: [#561](https://github.com/Grimblaz/agent-orchestra/issues/561))**',
        '',
        '### Intentionally hub-only families',
        '',
        'The following families are present in the classification but are explicitly excluded from downstream-consumer resolution contracts, because the artifacts they contain are generated at runtime or are consumer-specific:',
        '',
        "- **${BT}/memories/session/*.md${BT}**: Claude Code session-only memory files written during a live session. Not committed to any repository. Any agent that reads a path in this family when no session is active performs a wasted tool call.",
        "- **${BT}.copilot-tracking/${BT}** (covering ${BT}.copilot-tracking/*.yml${BT}, ${BT}.copilot-tracking/*.json${BT}, ${BT}.copilot-tracking/*.md${BT}): Consumer-repo Copilot tracking files for in-progress issues, calibration data, and process-review outputs. These are per-consumer-repo artifacts and are not distributed by the hub.",
        "- **${BT}.claude/.state/*.json${BT}**: Claude runtime state files written by the plugin-release-hygiene hook. Session-scoped; not distribution artifacts.",
        "- **${BT}.github/instructions/*.instructions.md${BT}**: Consumer-generated VS Code / Copilot instruction files created per consumer repo setup. Not distribution artifacts.",
        "- **${BT}.claude/settings.json${BT}** and **${BT}.claude/settings.local.json${BT}**: Consumer-generated Claude Code settings files. Each consumer repo creates its own; they are never resolved from the hub repo or plugin cache.",
        "- **${BT}.vscode/settings.json${BT}**: Consumer-generated VS Code workspace settings. Not a distribution artifact.",
        "- **${BT}examples/{stack}/*.md${BT}**: Reference templates for new consumer repo setup, not loaded at runtime by agents."
    ) -join "`n"

    # Assemble all sections in the required order (10 sections)
    $doc = $sectionAuditMeta + "`n`n" +
           $sectionPurpose + "`n`n" +
           $sectionCustomer + "`n`n" +
           $sectionMethodology + "`n`n" +
           $sectionResolutionTaxonomy + "`n`n" +
           $sectionCatalogHeader + "`n`n" +
           $catalogText + "`n" +
           $sectionUnresolvedExperience + "`n`n" +
           $sectionHistoricalContext + "`n`n" +
           $sectionStaleness + "`n`n" +
           $sectionOutOfScope + "`n"

    # Ensure output directory exists
    $outputDir = Split-Path $outputPath -Parent
    if (-not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    # Write with LF line endings for cross-platform byte-stability.
    # Skip write if only the audit-meta timestamps changed (body unchanged).
    $docLf = $doc -replace "`r`n", "`n" -replace "`r", "`n"
    $auditMetaPattern = [regex]'(?s)<!-- audit-meta.*?-->'
    $newBody = $auditMetaPattern.Replace($docLf, '')
    $shouldWrite = $true
    if (Test-Path $outputPath) {
        $existingRaw = [System.IO.File]::ReadAllText($outputPath, [System.Text.Encoding]::UTF8)
        $existingLf  = $existingRaw -replace "`r`n", "`n" -replace "`r", "`n"
        $existingBody = $auditMetaPattern.Replace($existingLf, '')
        if ($existingBody -eq $newBody) {
            # Body identical — only timestamps differ; skip write to avoid spurious diffs
            Write-Output "Rendered: $outputPath (no body changes; timestamp update skipped)"
            $shouldWrite = $false
        }
    }
    if ($shouldWrite) {
        $docBytes = [System.Text.Encoding]::UTF8.GetBytes($docLf)
        [System.IO.File]::WriteAllBytes($outputPath, $docBytes)
        Write-Output "Rendered: $outputPath"
    }
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

if ($Diff) {
    Invoke-DiffMode -Root $RepoRoot
    exit 0
}

if ($Render) {
    Invoke-RenderMode -Root $RepoRoot
    exit 0
}

if ($InputFile) {
    # Single-file mode: used by tests
    $resolvedInput = Resolve-Path $InputFile -ErrorAction Stop
    $inventory = Build-Inventory @($resolvedInput.Path)

    # For single-file mode, emit the raw_path list as a JSON array (simple strings)
    # so tests can match against path values directly.
    $paths = @($inventory | ForEach-Object { $_.raw_path }) | Select-Object -Unique | Sort-Object
    $jsonOutput = $paths | ConvertTo-Json -Compress
    Write-Output $jsonOutput
}
else {
    # Full-repo mode
    $scopeFiles = Get-ScopeFiles -Root $RepoRoot
    $inventory = Build-Inventory -FilePaths $scopeFiles

    $paths = @($inventory | ForEach-Object { $_.raw_path }) | Select-Object -Unique | Sort-Object

    $jsonOutput = $paths | ConvertTo-Json -Compress
    Write-Output $jsonOutput
}
