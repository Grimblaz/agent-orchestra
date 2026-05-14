#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Drift gate tests for hub-artifact-paths — AC8 coverage, live-walk completeness,
    and render-staleness assertions.

.DESCRIPTION
    Covers:
      - Coverage assertion (AC8): audit-hub-artifact-paths.ps1 -Diff reports
        'uncategorized: 0' — every path family in the inventory has a matching
        entry in Documents/Design/hub-artifact-paths-classification.yml.
        The -Diff mode uses the authoritative Get-PathFamilyCandidates expansion
        logic, which handles bare-relative intra-skill references (e.g.,
        'platforms/claude.md', 'lib/cost-anomaly.ps1') by expanding them to
        their parent family before matching.
      - Live-walk completeness: all five locked scopes produce at least one
        reference in the inventory. Zero references from any scope indicates an
        extraction grammar regression or scope-walker bug.
      - Render-staleness: when the audit doc exists and -Render produces in-place
        output, the pre-render and post-render content must be identical (modulo
        the <!-- audit-meta --> block containing run-specific timestamp/SHA fields).
        If the audit doc does not yet exist or -Render is still a stub, this
        assertion is skipped.
#>

Describe 'hub-artifact-paths drift gate (AC8)' {

    BeforeAll {
        $script:ScriptPath  = Join-Path $PSScriptRoot '../audit-hub-artifact-paths.ps1'
        $script:ClassificationYaml = Join-Path $PSScriptRoot '../../../Documents/Design/hub-artifact-paths-classification.yml'
        $script:AuditDoc    = Join-Path $PSScriptRoot '../../../Documents/Design/hub-artifact-paths-audit.md'
        $script:RepoRoot    = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

        # Invoke the extraction script in default (JSON) mode and parse the inventory.
        # This is used by assertions 2 and 3; assertion 1 uses -Diff mode directly.
        $script:InventoryRaw = if (Test-Path $script:ScriptPath) {
            & pwsh -NoProfile -NonInteractive -File $script:ScriptPath 2>&1
        }
        else {
            $null
        }

        $script:Inventory = if ($null -ne $script:InventoryRaw) {
            $script:InventoryRaw | ConvertFrom-Json -ErrorAction SilentlyContinue
        }
        else {
            $null
        }
    }

    # -------------------------------------------------------------------------
    # Assertion 1: Coverage — every path family is classified
    # -------------------------------------------------------------------------
    Context 'Coverage assertion — every path family is classified' {

        It 'all extracted path families are present in the classification YAML' {
            if (-not (Test-Path $script:ScriptPath)) {
                throw "Missing script: $($script:ScriptPath)"
            }
            if (-not (Test-Path $script:ClassificationYaml)) {
                throw "Missing classification YAML: $($script:ClassificationYaml)"
            }

            # Use the script's own -Diff mode, which applies the authoritative
            # Get-PathFamilyCandidates expansion logic (handles bare-relative paths,
            # ./ prefix stripping, D2a placeholder normalization, and lib/adapters/
            # prefix expansions). Output format: 'added: N; removed: N; uncategorized: N'
            $diffOutput = & pwsh -NoProfile -NonInteractive -File $script:ScriptPath -Diff 2>&1
            $diffText = ($diffOutput -join "`n").Trim()

            # Parse uncategorized count from output.
            $uncategorizedCount = 0
            if ($diffText -match 'uncategorized:\s*(\d+)') {
                $uncategorizedCount = [int]$Matches[1]
            }
            else {
                throw "Unexpected -Diff output format (expected 'added: N; removed: N; uncategorized: N'): $diffText"
            }

            if ($uncategorizedCount -gt 0) {
                # Surface the specific uncategorized path families by running the
                # JSON extraction and applying the same family-key matching the -Diff
                # mode uses (simple -like after ./ stripping for scope-rooted paths).
                # This gives contributors the contributor-facing message template.
                $yamlLines = Get-Content $script:ClassificationYaml -ErrorAction SilentlyContinue
                $familyKeys = @($yamlLines | Where-Object { $_ -match '^\s+"([^"]+)":\s*$' } | ForEach-Object {
                    if ($_ -match '"([^"]+)"') { $Matches[1] }
                })

                $inventory = if ($null -ne $script:Inventory) { $script:Inventory } else { @() }

                # Known scope prefixes for scope-rooted path detection.
                $scopePrefixes = @(
                    'agents/', 'commands/', 'skills/',
                    '.claude-plugin/', '.github/', '.claude/',
                    '.copilot-tracking/', '.vscode/',
                    '/memories/',
                    'Documents/', 'frame/', 'examples/',
                    'hooks/', 'templates/', 'workflows/'
                )

                $unclassifiedPaths = [System.Collections.Generic.List[string]]::new()
                foreach ($rawPath in $inventory) {
                    $normalPath = $rawPath -replace '^\./', ''
                    $isRooted = $false
                    foreach ($prefix in $scopePrefixes) {
                        if ($normalPath.StartsWith($prefix) -or $rawPath.StartsWith($prefix)) {
                            $isRooted = $true
                            break
                        }
                    }
                    if (-not $isRooted) { continue }

                    $isClassified = $false
                    foreach ($fk in $familyKeys) {
                        if ($rawPath -like $fk -or $normalPath -like $fk) {
                            $isClassified = $true
                            break
                        }
                    }
                    if (-not $isClassified) {
                        $unclassifiedPaths.Add($rawPath)
                    }
                }

                # Emit a contributor-facing failure for each uncategorized path found.
                # If the simple matching didn't find them (due to candidate expansion),
                # fall back to the uncategorized count from -Diff.
                if ($unclassifiedPaths.Count -gt 0) {
                    foreach ($glob in $unclassifiedPaths) {
                        $glob | Should -BeNullOrEmpty -Because "Uncategorized path family '$glob' detected; add a classification entry to Documents/Design/hub-artifact-paths-classification.yml"
                    }
                }
                else {
                    # -Diff found uncategorized paths but simple matching couldn't identify
                    # them (candidate expansion hid them). Fail with the count.
                    $uncategorizedCount | Should -Be 0 -Because "-Diff reported $uncategorizedCount uncategorized path family(ies); run 'pwsh .github/scripts/audit-hub-artifact-paths.ps1 -Diff' for details, then add classification entries to Documents/Design/hub-artifact-paths-classification.yml"
                }
            }
            else {
                $uncategorizedCount | Should -Be 0
            }
        }
    }

    # -------------------------------------------------------------------------
    # Assertion 2: Live-walk completeness — all five scopes have >= 1 reference
    # -------------------------------------------------------------------------
    Context 'Live-walk completeness — all five scopes have at least one reference' {

        It 'scope <Scope> has at least one reference' -ForEach @(
            @{ Scope = 'agent-bodies';    Pattern = 'agents/*.agent.md' },
            @{ Scope = 'claude-shells';   Pattern = 'agents/*.md (non-body)' },
            @{ Scope = 'skill-bodies';    Pattern = 'skills/*/SKILL.md' },
            @{ Scope = 'commands';        Pattern = 'commands/*.md' },
            @{ Scope = 'manifests-hooks'; Pattern = '*.json|*.ps1 hooks' }
        ) {
            param($Scope, $Pattern)

            if (-not (Test-Path $script:ScriptPath)) {
                throw "Missing script: $($script:ScriptPath)"
            }
            if ($null -eq $script:Inventory) {
                throw "Extraction script returned no parseable JSON. Raw output: $($script:InventoryRaw -join "`n")"
            }

            # Count paths belonging to this scope.
            # Each path is tested in both raw and ./-stripped form.
            $count = switch ($Scope) {
                'agent-bodies' {
                    @($script:Inventory | Where-Object {
                        ($_ -like 'agents/*.agent.md') -or
                        (($_ -replace '^\./', '') -like 'agents/*.agent.md')
                    }).Count
                }
                'claude-shells' {
                    @($script:Inventory | Where-Object {
                        $normalPath = $_ -replace '^\./', ''
                        ($normalPath -like 'agents/*.md') -and
                        ($normalPath -notlike 'agents/*.agent.md')
                    }).Count
                }
                'skill-bodies' {
                    @($script:Inventory | Where-Object {
                        ($_ -like 'skills/*/SKILL.md') -or
                        (($_ -replace '^\./', '') -like 'skills/*/SKILL.md')
                    }).Count
                }
                'commands' {
                    @($script:Inventory | Where-Object {
                        ($_ -like 'commands/*.md') -or
                        (($_ -replace '^\./', '') -like 'commands/*.md')
                    }).Count
                }
                'manifests-hooks' {
                    @($script:Inventory | Where-Object {
                        $p = $_ -replace '^\./', ''
                        ($p -like '.claude-plugin/*.json') -or
                        ($p -like '.github/scripts/*.ps1') -or
                        ($p -like 'skills/*/platforms/*.md') -or
                        ($p -like 'hooks/*.json') -or
                        ($_ -like '.claude-plugin/*.json') -or
                        ($_ -like '.github/scripts/*.ps1') -or
                        ($_ -like 'skills/*/platforms/*.md') -or
                        ($_ -like 'hooks/*.json')
                    }).Count
                }
                default { 0 }
            }

            $count | Should -BeGreaterOrEqual 1 -Because "Scope '$Scope' returned zero references — extraction grammar regression or scope-walker bug"
        }
    }

    # -------------------------------------------------------------------------
    # Assertion 3: Render-staleness — audit doc matches classification YAML
    # -------------------------------------------------------------------------
    Context 'Render-staleness — audit doc matches classification YAML' {

        It 'audit doc is not stale relative to classification YAML' {
            if (-not (Test-Path $script:ScriptPath)) {
                throw "Missing script: $($script:ScriptPath)"
            }

            # Skip if the audit doc does not exist yet (s6 creates it concurrently
            # with this test file; absence is not staleness).
            if (-not (Test-Path $script:AuditDoc)) {
                Set-ItResult -Skipped -Because 'Audit doc does not yet exist; run pwsh .github/scripts/audit-hub-artifact-paths.ps1 -Render to generate it'
                return
            }

            # Snapshot the current audit doc before running -Render, so we can
            # detect whether -Render produces a different result.
            $preRenderContent = Get-Content -Path $script:AuditDoc -Raw -Encoding UTF8

            # Run -Render. The current implementation writes to the audit doc in-place
            # and emits a status line on stdout ('Rendered: <path>').
            # A stub implementation emits 'stub: -Render not yet implemented'.
            $renderOutput = & pwsh -NoProfile -NonInteractive -File $script:ScriptPath -Render 2>&1
            $renderText = ($renderOutput -join "`n").Trim()

            # If -Render is still a stub, skip this assertion (pending state).
            if ($renderText -match 'stub') {
                Set-ItResult -Skipped -Because '-Render is still a stub; staleness check is pending implementation'
                return
            }

            # Helper: strip the <!-- audit-meta ... --> block from text.
            # The block format is:
            #   <!-- audit-meta
            #   last-verified: <sha>
            #   generated-at: <timestamp>
            #   -->
            # The 'last-verified' and 'generated-at' fields change on every render
            # and must be excluded from the staleness comparison.
            function script:Remove-AuditMeta {
                param([string]$Text)
                # Match from <!-- audit-meta (open comment) through the closing -->
                # using dotall mode so newlines are included.
                $Text -replace '(?s)<!--\s*audit-meta.*?-->', ''
            }

            # Case A: -Render writes content to stdout (future full implementation).
            #         $renderText will be the rendered markdown (substantially longer
            #         than a status line — use 256 chars as the threshold).
            # Case B: -Render writes in-place and emits a short status line on stdout
            #         ('Rendered: <path>'). Read the updated file to get fresh content.
            $isStatusLineOnly = ($renderText -match '^Rendered:') -or ($renderText.Length -lt 256)

            if ($isStatusLineOnly) {
                # Case B: in-place render. Compare pre-render snapshot to post-render file.
                # If render changed the content, the doc was stale. Restore original
                # content to keep the working tree clean, then fail.
                $postRenderContent = Get-Content -Path $script:AuditDoc -Raw -Encoding UTF8

                $strippedPre  = script:Remove-AuditMeta $preRenderContent
                $strippedPost = script:Remove-AuditMeta $postRenderContent

                if ($strippedPre -ne $strippedPost) {
                    # Restore to avoid leaving the working tree dirty from the test run.
                    Set-Content -Path $script:AuditDoc -Value $preRenderContent -Encoding UTF8 -NoNewline
                    $strippedPre | Should -Be $strippedPost -Because "Audit doc is stale relative to classification YAML; run 'pwsh .github/scripts/audit-hub-artifact-paths.ps1 -Render' and commit the result."
                }
                # If pre == post (stripped content identical), the doc is current — pass.
            }
            else {
                # Case A: stdout render. Compare stdout content against on-disk audit doc.
                $strippedRendered = script:Remove-AuditMeta $renderText
                $strippedDoc      = script:Remove-AuditMeta $preRenderContent

                $strippedRendered | Should -Be $strippedDoc -Because "Audit doc is stale relative to classification YAML; run 'pwsh .github/scripts/audit-hub-artifact-paths.ps1 -Render' and commit the result."
            }
        }
    }
}
