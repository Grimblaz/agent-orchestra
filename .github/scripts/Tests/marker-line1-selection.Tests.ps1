#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Issue #1031 (chunk 1 of designed parent #1011), parent AC2 close arm.

    THE PROPERTY THESE TESTS DEFEND. Find-OrUpsertComment selects a comment
    and then REPLACES its whole body. Before this change it selected with
    `$_.body -like "*$Marker*"`, so a marker merely QUOTED in prose was enough
    to make an unrelated comment be chosen as another family's write target
    and destroyed. The live corpus carried exactly that: issue #782's approved
    plan comment (#issuecomment-4861653613) quotes
    `<!-- pc-emission-check-report -->` mid-line on its line 37 and was the
    ONLY comment on #782 containing that string, so the next emission-check
    post to #782 would have overwritten the plan.

    WHY THIS FILE EXISTS SEPARATELY FROM find-or-upsert-comment.Tests.ps1.
    That suite is listed in ci-quarantine.json as `unclassified` (issue #993)
    — never measured on Linux — so CI does not run it, and a red state
    exhibited only there would be local-only. This file is NEW, so the
    registry's rule ("CI runs every .github/scripts/Tests/*.Tests.ps1 EXCEPT
    the files listed here") makes it run in the per-pull-request Pester gate
    immediately. It is deliberately written to be CI-viable: no live `gh`, no
    network, no interactive terminal, no platform-specific paths — every
    external call goes through an in-process function mock.

    Do NOT de-quarantine find-or-upsert-comment.Tests.ps1 to solve this. That
    promotion is #993 chunk 2's job and it is mechanical only for a suite
    already measured green.
#>

BeforeAll {
    $script:LibDir = Join-Path $PSScriptRoot '..' 'lib'
    $script:SelectorLib = Join-Path $script:LibDir 'marker-line1-selector.ps1'
    $script:UpsertLib = Join-Path $script:LibDir 'find-or-upsert-comment.ps1'
    $script:HarvestLib = Join-Path $script:LibDir 'cost-baseline-harvest.ps1'
    $script:RenderLib = Join-Path $script:LibDir 'cost-session-render.ps1'
}

# ---------------------------------------------------------------------------
# 1. The predicate itself.
# ---------------------------------------------------------------------------
Describe 'Test-CommentBodyMarkerLine1 (marker-line1-selector.ps1)' {
    BeforeAll {
        . $script:SelectorLib
        $script:M = '<!-- frame-credit-ledger-123 -->'
    }

    Context 'selects — the marker is the body own line-1 payload' {
        It 'accepts the marker as line 1 followed by a body' {
            Test-CommentBodyMarkerLine1 -Body "$script:M`nreal payload" -Marker $script:M | Should -BeTrue
        }
        It 'accepts a body that is nothing but the marker (persist-phase-ledger-core.ps1:783 writes exactly this)' {
            Test-CommentBodyMarkerLine1 -Body $script:M -Marker $script:M | Should -BeTrue
        }
        It 'accepts trailing whitespace on the marker line — immaterial to which payload was posted' {
            Test-CommentBodyMarkerLine1 -Body "$script:M   `nbody" -Marker $script:M | Should -BeTrue
        }
        It 'accepts a CRLF body, which is what GitHub often returns' {
            Test-CommentBodyMarkerLine1 -Body "$script:M`r`nbody" -Marker $script:M | Should -BeTrue
        }
        It 'is REFLEXIVE: a marker carrying trailing whitespace still matches the body that carries it (#1031 finding M4)' {
            # Trimming only the body side made this false, and zero matches is
            # the POST branch — so such a caller posted a fresh comment on
            # every run, forever, silently.
            Test-CommentBodyMarkerLine1 -Body "$script:M `nbody" -Marker "$script:M " | Should -BeTrue
        }
        It 'is reflexive for a marker with a trailing CR against a body without one' {
            Test-CommentBodyMarkerLine1 -Body "$script:M`nbody" -Marker "$script:M`r" | Should -BeTrue
        }
    }

    Context 'rejects — the marker is quoted rather than owned (the #1031 population)' {
        It 'rejects a mid-line mention inside backticked prose — the shape live on issue #782' {
            Test-CommentBodyMarkerLine1 -Body "<!-- plan-issue-782 -->`nposts via ``$script:M`` with a stable anchor" -Marker $script:M |
                Should -BeFalse
        }
        It 'rejects a marker alone on its own line INSIDE A FENCED BLOCK — the shape a start-of-line anchor would still have selected' {
            $body = "<!-- plan-issue-9 -->`nExample:`n" + '```' + "`n$script:M`n" + '```'
            Test-CommentBodyMarkerLine1 -Body $body -Marker $script:M | Should -BeFalse
        }
        It 'rejects an indented marker on its own line — leading whitespace is significant' {
            Test-CommentBodyMarkerLine1 -Body "<!-- plan-issue-9 -->`n    $script:M" -Marker $script:M | Should -BeFalse
        }
        It 'rejects an INDENTED marker on line 1 (the whole-line anchor would accept it)' {
            Test-CommentBodyMarkerLine1 -Body "   $script:M`nbody" -Marker $script:M | Should -BeFalse
        }
        It 'rejects a blockquoted marker' {
            Test-CommentBodyMarkerLine1 -Body "<!-- plan-issue-9 -->`n> $script:M" -Marker $script:M | Should -BeFalse
        }
        It 'rejects a marker on line 1 with trailing content on that same line' {
            Test-CommentBodyMarkerLine1 -Body "$script:M and then some prose`nbody" -Marker $script:M | Should -BeFalse
        }
        It 'rejects a marker anywhere after line 1, even alone on its line' {
            Test-CommentBodyMarkerLine1 -Body "header`n$script:M`nbody" -Marker $script:M | Should -BeFalse
        }
    }

    Context 'fails closed' {
        It 'rejects a null body' { Test-CommentBodyMarkerLine1 -Body $null -Marker $script:M | Should -BeFalse }
        It 'rejects an empty body' { Test-CommentBodyMarkerLine1 -Body '' -Marker $script:M | Should -BeFalse }
        It 'rejects an EMPTY marker rather than selecting every comment' {
            Test-CommentBodyMarkerLine1 -Body "anything`nat all" -Marker '' | Should -BeFalse
        }
        It 'rejects a WHITESPACE-ONLY marker, which an IsNullOrEmpty guard would let through (#1031 finding M16)' {
            # A whitespace-only marker passes IsNullOrEmpty and can then never
            # match, because TrimEnd can never leave a line ending in
            # whitespace — a silent never-selects, which becomes
            # POST-a-new-comment one layer up. The mandatory [string] on
            # Find-OrUpsertComment rejects '' but not '   ', and the two
            # mirrors bind nothing at all.
            Test-CommentBodyMarkerLine1 -Body "   `nbody" -Marker '   ' | Should -BeFalse
        }
        It 'rejects a whitespace-only BODY' {
            Test-CommentBodyMarkerLine1 -Body "   `n  " -Marker $script:M | Should -BeFalse
        }
        It 'compares ordinally, so a case difference does not match' {
            Test-CommentBodyMarkerLine1 -Body "<!-- FRAME-CREDIT-LEDGER-123 -->`nb" -Marker $script:M | Should -BeFalse
        }
        It 'compares ordinally, so a leading BOM disqualifies (culture-aware -eq would accept it)' {
            Test-CommentBodyMarkerLine1 -Body ([char]0xFEFF + $script:M + "`nb") -Marker $script:M | Should -BeFalse
        }
    }
}

# ---------------------------------------------------------------------------
# 2. The selector that actually writes. These exercise the REAL
#    Find-OrUpsertComment through an in-process `gh` mock, so reverting
#    the selector to `-like "*$Marker*"` reddens them.
# ---------------------------------------------------------------------------
Describe 'Find-OrUpsertComment target selection (issue #1031)' {
    BeforeEach {
        $script:mockComments = @()
        $script:patchedId = $null
        $script:posted = $false

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$GhArgs)
            $joined = $GhArgs -join ' '
            if ($joined -match 'issue view \d+ --json comments') {
                $global:LASTEXITCODE = 0
                return (@{ comments = $script:mockComments } | ConvertTo-Json -Depth 8)
            }
            if ($joined -match 'api -X PATCH repos/[^/]+/[^/]+/issues/comments/(\d+)') {
                $script:patchedId = $Matches[1]
                $global:LASTEXITCODE = 0
                return (@{ html_url = 'https://example.invalid/#issuecomment-patched' } | ConvertTo-Json)
            }
            if ($joined -match '(issue|pr) comment \d+ --body') {
                $script:posted = $true
                $global:LASTEXITCODE = 0
                return 'https://example.invalid/#issuecomment-new'
            }
            $global:LASTEXITCODE = 0
            return ''
        }

        . $script:UpsertLib
        $script:PC = '<!-- pc-emission-check-report -->'
    }

    AfterEach {
        # `Remove-Item function:global:gh` reads `global:gh` as a NAME, not a
        # scope qualifier, and silently no-ops — leaking the mock into other
        # files. The Function: PSDrive holds one entry per name regardless of
        # scope, so this form actually removes it.
        Remove-Item Function:gh -ErrorAction SilentlyContinue
    }

    It 'PATCHes the comment whose line 1 IS the marker (control: this must keep working)' {
        $script:mockComments = @(@{ id = 900; body = "$script:PC`nSurfaces scanned: 2" })
        $null = Find-OrUpsertComment -Type issue -Number 782 -Marker $script:PC -Body 'new' -Owner 'o' -Repo 'r'
        $script:patchedId | Should -Be '900'
    }

    It 'does NOT select a comment that merely QUOTES the marker mid-line — regression guard for the unanchored `-like "*$Marker*"` selector' {
        # Shape taken from the real exposure: issue #782 plan comment
        # 4861653613 carries this marker in backticked prose on line 37.
        $script:mockComments = @(
            @{ id = 4861653613; body = "<!-- plan-issue-782 -->`n`nSingle-target mode posts the gap warning via ``Find-OrUpsertComment`` with a stable marker anchor **``$script:PC``**." }
        )
        $null = Find-OrUpsertComment -Type issue -Number 782 -Marker $script:PC -Body 'REPORT' -Owner 'o' -Repo 'r'
        $script:patchedId | Should -BeNullOrEmpty -Because 'patching it would have replaced that issue''s whole approved plan with an emission-check report'
        $script:posted | Should -BeTrue
    }

    It 'does NOT select a marker sitting alone on its own line inside a fenced block' {
        $body = "<!-- plan-issue-9 -->`nposted under:`n" + '```' + "`n$script:PC`n" + '```'
        $script:mockComments = @(@{ id = 901; body = $body })
        $null = Find-OrUpsertComment -Type issue -Number 9 -Marker $script:PC -Body 'x' -Owner 'o' -Repo 'r'
        $script:patchedId | Should -BeNullOrEmpty -Because 'a start-of-line anchor would still have selected this one'
    }

    It 'REFUSES a whitespace-only marker instead of POSTing a new comment on every run (#1031, external review)' {
        # The predicate declines to select on such a marker, and declining to
        # select is the POST branch. The mandatory [string] rejects '' at
        # binding and lets '   ' through, so the binding is not the guard.
        $script:mockComments = @(@{ id = 900; body = "$script:PC`npayload" })
        $url = Find-OrUpsertComment -Type issue -Number 782 -Marker '   ' -Body 'x' -Owner 'o' -Repo 'r' 2>$null
        $url | Should -BeNullOrEmpty
        $script:posted | Should -BeFalse -Because 'a degenerate marker must refuse, not accrete a new comment per run'
        $script:patchedId | Should -BeNullOrEmpty
    }

    It 'prefers the genuine target over an EARLIER quoting comment (the earliest-REST-id tie-break used to prefer the decoy)' {
        $script:mockComments = @(
            @{ id = 100; body = "<!-- plan-issue-9 -->`nsee ``$script:PC`` for the report" },
            @{ id = 200; body = "$script:PC`nthe real report" }
        )
        $null = Find-OrUpsertComment -Type issue -Number 9 -Marker $script:PC -Body 'x' -Owner 'o' -Repo 'r'
        $script:patchedId | Should -Be '200'
    }
}

# ---------------------------------------------------------------------------
# 3. The two behavioural mirrors. AC-c is keyed on behaviour, not on whether
#    a selector DECLARES that it must match — so both are checked, including
#    the one that declares nothing.
# ---------------------------------------------------------------------------
Describe 'Selectors that must reach the same comment (issue #1031 AC-c)' {

    Context 'cost-baseline-harvest composite fetch' {
        BeforeEach {
            $script:mockComments = @()
            function global:gh {
                param([Parameter(ValueFromRemainingArguments = $true)]$GhArgs)
                $null = $GhArgs
                $global:LASTEXITCODE = 0
                return (@{ comments = $script:mockComments } | ConvertTo-Json -Depth 8)
            }
            . $script:HarvestLib
            $script:FCL = '<!-- frame-credit-ledger-123 -->'
        }
        AfterEach { Remove-Item Function:gh -ErrorAction SilentlyContinue }

        It 'finds the genuine composite comment (control)' {
            $script:mockComments = @(@{ id = 900; url = 'https://x/#issuecomment-900'; body = "$script:FCL`npayload"; authorAssociation = 'NONE'; author = @{ login = 'github-actions' } })
            (Get-CostBaselineHarvestCompositeComment -Pr 123).Found | Should -BeTrue
        }

        It 'does NOT find a comment that only quotes the marker — same rule as the writer it must not drift from' {
            $script:mockComments = @(@{ id = 901; url = 'https://x/#issuecomment-901'; body = "<!-- plan-issue-9 -->`nsee ``$script:FCL``"; authorAssociation = 'NONE'; author = @{ login = 'github-actions' } })
            (Get-CostBaselineHarvestCompositeComment -Pr 123).Found | Should -BeFalse
        }
    }

    Context 'cost-session-render prior-degraded read' {

        # The behavioural pin (#1031 review finding M2). The resolvability
        # test below proves only that the predicate LOADS; it never drove the
        # selector, so reverting this mirror to the old unanchored match left
        # every check in the repository green while both sibling selectors
        # reddened. These cases run the real Get-CSRPriorDegradedComment --
        # the shipped selector, the one Invoke-CostSessionRender calls --
        # against a body set that includes the quotation shape, so reverting
        # it reddens here.
        #
        # Why that selector is a named function at all: the retraction
        # decision it feeds is additionally gated on the walker having found
        # real cost events, and the walker runs behind a worker-runspace
        # boundary, so no hermetic test could reach the rule while it was an
        # inline Where-Object. See that function's .DESCRIPTION.
        BeforeAll {
            $script:DEG = '<!-- cost-pattern-data-degraded-794 -->'
            $script:InvokeCSRSelect = {
                param([string]$RenderLib, [string]$PriorBody)
                $ps = [System.Management.Automation.PowerShell]::Create()
                try {
                    $ps.Runspace.SessionStateProxy.SetVariable('RenderLib', $RenderLib)
                    $ps.Runspace.SessionStateProxy.SetVariable('PriorBody', $PriorBody)
                    $null = $ps.AddScript(@'
. $RenderLib
$prior = @([pscustomobject]@{ body = $PriorBody; databaseId = 4001 })
$hit = Get-CSRPriorDegradedComment -PriorComments $prior -DegradedMarker '<!-- cost-pattern-data-degraded-794 -->'
if ($null -eq $hit) { 'none' } else { [string]$hit.databaseId }
'@)
                    $out = $ps.Invoke()
                    return [string]($out | Select-Object -Last 1)
                }
                finally { $ps.Dispose() }
            }
        }

        It 'DOES select a genuine degraded comment (control: without this the next case passes vacuously)' {
            $body = "$script:DEG`n`n## Cost Pattern`n`ndegraded telemetry: no-transcript-found"
            (& $script:InvokeCSRSelect $script:RenderLib $body) | Should -Be '4001'
        }

        It 'does NOT select a comment that only QUOTES the marker in prose -- reverting this mirror to the unanchored match reddens here' {
            $body = "<!-- plan-issue-794 -->`n`nThe retraction keys off ``$script:DEG`` when events reappear."
            (& $script:InvokeCSRSelect $script:RenderLib $body) | Should -Be 'none' `
                -Because 'believing a stale degraded comment exists makes the anchored writer find none and POST a brand-new telemetry-recovered comment that nothing justifies'
        }

        It 'does NOT select an own-line quotation inside a fenced block' {
            $body = "<!-- plan-issue-794 -->`n" + '```' + "`n$script:DEG`n" + '```'
            (& $script:InvokeCSRSelect $script:RenderLib $body) | Should -Be 'none'
        }

        It 'resolves the shared predicate from its own dot-source, so the read cannot die as a swallowed CommandNotFound' {
            # This read runs inside Invoke-CostSessionRender fail-open catch.
            # If the predicate is not loaded at dot-source time the exception
            # is swallowed and the cost section is silently dropped — the
            # exact #496-class failure that file header warns about. Loading
            # the file in a fresh runspace and calling the predicate is the
            # behavioural check for that.
            $ps = [System.Management.Automation.PowerShell]::Create()
            try {
                $ps.Runspace.SessionStateProxy.SetVariable('RenderLib', $script:RenderLib)
                $null = $ps.AddScript('. $RenderLib; Test-CommentBodyMarkerLine1 -Body "<!-- m -->`nb" -Marker "<!-- m -->"')
                $out = $ps.Invoke()
                ($out | Select-Object -Last 1) | Should -BeTrue
            }
            finally { $ps.Dispose() }
        }
    }
}
