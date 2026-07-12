#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
Warn-only filing-call-site sweep (issue #837, plan step 3 / slice s3).

Greps `agents/` and `skills/` for filing call sites (`Add-FollowUpIssue`,
`gh issue create`) and Write-Warnings any site not present on the single
authoritative gated-callers allowlist defined below (mirroring DD1's wiring
table). This test never fails the build: assertions are limited to the
allowlist's own internal self-consistency (no duplicate entries, every entry
has a path and a reason); actual sweep mismatches are reported via
Write-Warning only, so a newly-added ungated filing surface is surfaced as a
loud warning in CI output rather than a red test.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

    # ---------------------------------------------------------------------
    # Single authoritative gated-callers allowlist (file-path + short-reason
    # pairs). These are the eight filing surfaces the #837 design wires
    # through safe-operations SKILL.md §2e, collapsed to their six distinct
    # files (Process-Review.agent.md houses two surfaces; Code-Conductor
    # .agent.md houses two surfaces; defect-response.md houses two tracks).
    # ---------------------------------------------------------------------
    $script:GatedCallers = @(
        @{
            Path   = 'agents/Code-Conductor.agent.md'
            Reason = 'Auto-Tracking sequence + pre-edit ownership upstream-issue creation route through §2e'
        },
        @{
            Path   = 'agents/Process-Review.agent.md'
            Reason = '§4.8 upstream-gotcha path and the §4 Step 4 calibration-improvement path route through §2e (surface 8)'
        },
        @{
            Path   = 'skills/calibration-pipeline/scripts/create-improvement-issue.ps1'
            Reason = 'internal gh issue create backing the §4 Step 4 calibration-improvement path routes through §2e (surface 8)'
        },
        @{
            Path   = 'skills/review-judgment/SKILL.md'
            Reason = 'Loud Guard mandatory proposal (formerly mandatory sub-issue) routes through §2e'
        },
        @{
            Path   = 'skills/code-review-intake/SKILL.md'
            Reason = 'bot-review filing path routes through §2e'
        },
        @{
            Path   = 'skills/customer-experience/references/defect-response.md'
            Reason = 'Track 1 and Track 2 filing both route through §2e'
        }
    )

    # ---------------------------------------------------------------------
    # Documented exemptions: filing call sites intentionally NOT gated.
    # ---------------------------------------------------------------------
    $script:DocumentedExemptions = @(
        @{
            Path   = 'agents/Experience-Owner.agent.md'
            Reason = 'greenfield issue creation is the upstream entry point and predates any gate-eligible finding'
        },
        @{
            Path   = 'skills/safe-operations/SKILL.md'
            Reason = "safe-operations' own instructional/example gh issue create snippets are documentation, not executable filing calls"
        },
        @{
            Path   = 'agents/Code-Conductor.agent.md:324'
            Reason = 'legacy design-doc-migration issue creation is user-confirmed inline, not autonomous filing'
        }
    )

    function script:Get-FilingCallSiteFiles {
        <#
        .SYNOPSIS
            Greps agents/ and skills/ for filing call sites and returns the
            distinct repo-relative file paths that contain one.
        #>
        param(
            [Parameter(Mandatory = $true)]
            [string]$RepoRoot
        )

        $found = New-Object System.Collections.Generic.List[string]
        foreach ($dir in @('agents', 'skills')) {
            $fullDir = Join-Path $RepoRoot $dir
            if (-not (Test-Path -LiteralPath $fullDir)) { continue }

            Get-ChildItem -LiteralPath $fullDir -Recurse -File -Include *.md, *.ps1 |
                ForEach-Object {
                    $content = $null
                    try {
                        $content = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction Stop
                    } catch {
                        return
                    }
                    if ($content -and ($content -match 'Add-FollowUpIssue' -or $content -match 'gh\s+issue\s+create')) {
                        $rel = $_.FullName.Substring($RepoRoot.Length + 1) -replace '\\', '/'
                        $found.Add($rel)
                    }
                }
        }
        return @($found | Sort-Object -Unique)
    }
}

Describe 'Filing-call-site gate coverage allowlist: self-consistency' {
    It 'has no duplicate paths in the gated-callers allowlist' {
        $dupes = $script:GatedCallers.Path | Group-Object | Where-Object { $_.Count -gt 1 }
        $dupes.Count | Should -Be 0
    }

    It 'has no duplicate paths in the documented-exemptions allowlist' {
        $dupes = $script:DocumentedExemptions.Path | Group-Object | Where-Object { $_.Count -gt 1 }
        $dupes.Count | Should -Be 0
    }

    It 'every gated-caller entry has a non-empty path and reason' {
        foreach ($entry in $script:GatedCallers) {
            $entry.Path | Should -Not -BeNullOrEmpty
            $entry.Reason | Should -Not -BeNullOrEmpty
        }
    }

    It 'every documented-exemption entry has a non-empty path and reason' {
        foreach ($entry in $script:DocumentedExemptions) {
            $entry.Path | Should -Not -BeNullOrEmpty
            $entry.Reason | Should -Not -BeNullOrEmpty
        }
    }

    It 'enumerates the six distinct gated files backing the design''s eight wired surfaces' {
        $script:GatedCallers.Count | Should -Be 6
    }

    It 'enumerates the three documented exemptions' {
        $script:DocumentedExemptions.Count | Should -Be 3
    }
}

Describe 'Filing-call-site gate coverage: live sweep (warn-only, never fails the build)' {
    It 'sweeps agents/ and skills/ for filing call sites and warns on any site absent from both allowlists' {
        {
            $liveSites = Get-FilingCallSiteFiles -RepoRoot $script:RepoRoot
            $allowlistedPaths = @($script:GatedCallers.Path) + @($script:DocumentedExemptions.Path | ForEach-Object { $_ -replace ':\d+$', '' })

            foreach ($site in $liveSites) {
                if ($site -notin $allowlistedPaths) {
                    Write-Warning "filing-call-site-gate-coverage: '$site' contains a filing call site (Add-FollowUpIssue / gh issue create) not present on the gated-callers or documented-exemptions allowlist in this test file. Verify it routes through safe-operations SKILL.md §2e or add it to the allowlist."
                }
            }
        } | Should -Not -Throw
    }
}
