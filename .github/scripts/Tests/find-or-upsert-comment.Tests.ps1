#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# ---------------------------------------------------------------------------
# FIXTURE MOVE (issue #1031, parent #1011 AC2 close arm).
#
# Find-OrUpsertComment now selects the comment whose FIRST LINE is exactly the
# marker, instead of any comment containing the marker anywhere. TEN fixtures
# in this file, across SIX `It` blocks, put the marker at column 0 of line 1
# but with TRAILING PROSE on that same line (at 1cc08df: lines 104, 105, 106,
# 129, 144, 207, 220, 233, 238, 243); one more put it alone on line 2 (line
# 159). They were written that way as convenient filler, not to state a
# requirement — no test in this repository ever asserted that a marker with
# trailing content must be selectable, and no production composer emits that
# shape (all fourteen live call sites put the bare marker on line 1; verified
# by executing each composer, and by a live-corpus probe of every marker this
# function writes across issues and pull requests 1..1037 — 282 of 283
# occurrences are line-1-exact and the one exception is the defect itself,
# issue #782's plan comment quoting a marker in prose). The probe command and
# its full output are recorded in this issue's completion account, on issue
# #1031; the numbers above are a summary of that record, not a fresh claim.
#
# Rather than weaken the new rule to keep them green, the fixtures moved. Each
# is listed at its Context below with what changed. The one test that ASSERTED
# the old rule by name — 'matches markers via substring containment, not
# whole-line equality' — was not re-fixtured but REPLACED, because its claim is
# the behaviour #1031 removed; editing its fixture while keeping its title
# would have left a test asserting the opposite of what ships.
# ---------------------------------------------------------------------------

Describe 'Find-OrUpsertComment' {
    BeforeAll {
        $script:LibPath = Join-Path $PSScriptRoot '../lib/find-or-upsert-comment.ps1'
    }

    BeforeEach {
        # Reset mock state per test
        $script:lastGhArgs = $null
        $script:lastListArgs = $null
        $script:lastPostArgs = $null
        $script:lastPatchArgs = $null
        $script:ghCallCount = 0
        $script:simulateFailure = ''  # 'list' | 'patch' | 'post' | ''
        $script:mockComments = @()
        $script:mockRepoOwner = 'Grimblaz'
        $script:mockRepoName = 'agent-orchestra'

        function global:gh {
            param([Parameter(ValueFromRemainingArguments = $true)]$Args)
            $script:ghCallCount++
            $script:lastGhArgs = $Args
            $joined = $Args -join ' '
            if ($joined -match 'issue view \d+ --json comments') {
                $script:lastListArgs = $Args
                if ($script:simulateFailure -eq 'list') {
                    $global:LASTEXITCODE = 1
                    return ''
                }
                $global:LASTEXITCODE = 0
                $payload = @{ comments = $script:mockComments } | ConvertTo-Json -Depth 8
                return $payload
            }
            if ($joined -match 'api repos/[^/]+/[^/]+ ') {
                $global:LASTEXITCODE = 0
                return (@{ owner = @{ login = $script:mockRepoOwner }; name = $script:mockRepoName } | ConvertTo-Json -Depth 4)
            }
            if ($joined -match 'api -X PATCH repos/[^/]+/[^/]+/issues/comments/(\d+)') {
                if ($script:simulateFailure -eq 'patch') {
                    $global:LASTEXITCODE = 1
                    return ''
                }
                $script:lastPatchArgs = $Args
                $global:LASTEXITCODE = 0
                return (@{ html_url = "https://github.com/$($script:mockRepoOwner)/$($script:mockRepoName)/issues/123#issuecomment-patched" } | ConvertTo-Json)
            }
            if ($joined -match '(issue|pr) comment \d+ --body') {
                if ($script:simulateFailure -eq 'post') {
                    $global:LASTEXITCODE = 1
                    return ''
                }
                $script:lastPostArgs = $Args
                $global:LASTEXITCODE = 0
                return "https://github.com/$($script:mockRepoOwner)/$($script:mockRepoName)/issues/123#issuecomment-new"
            }
            $global:LASTEXITCODE = 0
            return ''
        }

        # Dot-source the library if it exists; otherwise a CommandNotFound at call time is the RED signal.
        if (Test-Path $script:LibPath) {
            . $script:LibPath
        }
    }

    AfterEach {
        # NOTE: `Remove-Item function:global:gh` (with `global:` in the path)
        # interprets `global:gh` as a function NAME, not a scope qualifier — it
        # silently no-ops with -ErrorAction SilentlyContinue and the global mock
        # leaks into other test files (manifesting as `$script:ghCallCount`
        # strict-mode errors when StrictMode-enabled libraries call the leaked
        # mock). The Function: PSDrive holds one entry per name regardless of
        # scope, so `Remove-Item Function:gh` actually removes the global mock.
        Remove-Item Function:gh -ErrorAction SilentlyContinue
    }

    Context 'PR comment - zero matches' {
        It 'POSTs a new comment when no marker match exists' {
            $script:mockComments = @()
            $url = Find-OrUpsertComment -Type pr -Number 123 -Marker '<!-- frame-credit-ledger-123 -->' -Body 'hello'
            $url | Should -Not -BeNullOrEmpty
            $script:lastPostArgs | Should -Not -BeNullOrEmpty
            $script:lastPatchArgs | Should -BeNullOrEmpty
        }
    }

    Context 'PR comment - one match' {
        It 'PATCHes the existing comment when a single marker match exists' {
            $script:mockComments = @(
                @{ id = 999; body = "<!-- frame-credit-ledger-123 -->`nold body" }
            )
            $url = Find-OrUpsertComment -Type pr -Number 123 -Marker '<!-- frame-credit-ledger-123 -->' -Body 'new body'
            $url | Should -Not -BeNullOrEmpty
            $script:lastPatchArgs | Should -Not -BeNullOrEmpty
            $script:lastPostArgs | Should -BeNullOrEmpty
        }
    }

    Context 'PR comment - multiple matches (data error path)' {
        # FIXTURE MOVE (#1031): the three bodies were
        # '<!-- frame-credit-ledger-123 --> first|second|third' — marker on
        # line 1 with trailing prose. Moved to marker-on-its-own-line-1. The
        # duplicate/earliest-id behaviour under test is unchanged.
        It 'PATCHes the earliest match and emits stderr warning naming duplicates' {
            $script:mockComments = @(
                @{ id = 100; body = "<!-- frame-credit-ledger-123 -->`nfirst" },
                @{ id = 200; body = "<!-- frame-credit-ledger-123 -->`nsecond" },
                @{ id = 300; body = "<!-- frame-credit-ledger-123 -->`nthird" }
            )
            $stderr = $null
            $url = Find-OrUpsertComment -Type pr -Number 123 -Marker '<!-- frame-credit-ledger-123 -->' -Body 'new' 2>&1 | Tee-Object -Variable stderr | Out-Null
            $script:lastPatchArgs | Should -Not -BeNullOrEmpty
            $joined = $script:lastPatchArgs -join ' '
            $joined | Should -Match 'comments/100'  # earliest id
        }
    }

    Context 'Issue comment - zero matches' {
        It 'POSTs a new issue comment when no match' {
            $script:mockComments = @()
            $url = Find-OrUpsertComment -Type issue -Number 429 -Marker '<!-- plan-issue-429 -->' -Body 'plan'
            $url | Should -Not -BeNullOrEmpty
            $script:lastPostArgs | Should -Not -BeNullOrEmpty
            ($script:lastPostArgs -join ' ') | Should -Match 'issue comment'
        }
    }

    Context 'Issue comment - one match' {
        # FIXTURE MOVE (#1031): body was '<!-- plan-issue-429 --> existing'.
        It 'PATCHes the issue comment when one marker match exists' {
            $script:mockComments = @(
                @{ id = 555; body = "<!-- plan-issue-429 -->`nexisting" }
            )
            $url = Find-OrUpsertComment -Type issue -Number 429 -Marker '<!-- plan-issue-429 -->' -Body 'updated'
            $script:lastPatchArgs | Should -Not -BeNullOrEmpty
            $script:lastPostArgs | Should -BeNullOrEmpty
        }
    }

    Context 'Fail-open' {
        It 'returns null when gh list fails' {
            $script:simulateFailure = 'list'
            $url = Find-OrUpsertComment -Type pr -Number 123 -Marker '<!-- m -->' -Body 'b'
            $url | Should -BeNullOrEmpty
        }
        It 'returns null when gh PATCH fails' {
            # FIXTURE MOVE (#1031): body was '<!-- m --> old'. It must still
            # SELECT for this test to reach the PATCH path at all.
            $script:mockComments = @(@{ id = 1; body = "<!-- m -->`nold" })
            $script:simulateFailure = 'patch'
            $url = Find-OrUpsertComment -Type pr -Number 123 -Marker '<!-- m -->' -Body 'b'
            $url | Should -BeNullOrEmpty
        }
        It 'returns null when gh POST fails' {
            $script:simulateFailure = 'post'
            $url = Find-OrUpsertComment -Type pr -Number 123 -Marker '<!-- m -->' -Body 'b'
            $url | Should -BeNullOrEmpty
        }
    }

    Context 'Marker matching' {
        # REPLACED, not re-fixtured (#1031). This Context previously held
        # 'matches markers via substring containment, not whole-line
        # equality', whose fixture was
        #   "header line`n<!-- ... -->`nbody after"
        # and which asserted a PATCH happened. That is precisely the
        # behaviour #1031 removed: a marker below line 1 is now a quotation,
        # not a target. Keeping the title and moving the fixture would have
        # left a test whose name asserts the opposite of what ships, so the
        # claim was inverted instead. The full population is covered in
        # marker-line1-selection.Tests.ps1, which — unlike this file — runs in
        # CI (this one is quarantined `unclassified` under issue #993).
        It 'requires the marker to be the comment first line, not merely contained in it' {
            $script:mockComments = @(
                @{ id = 42; body = "header line`n<!-- frame-credit-ledger-123 -->`nbody after" }
            )
            $url = Find-OrUpsertComment -Type pr -Number 123 -Marker '<!-- frame-credit-ledger-123 -->' -Body 'new'
            $script:lastPatchArgs | Should -BeNullOrEmpty `
                -Because 'a marker on line 3 is a mention; patching it would replace an unrelated comment body'
            $script:lastPostArgs | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Explicit Owner/Repo (P4 regression - #887 post-fix)' {
        It 'threads the caller-supplied -Owner/-Repo through to every gh call, not "/"' {
            # Root cause under test: the pre-fix code used lowercase $owner/$repo
            # locals for the derived-from-git-remote fallback. PowerShell
            # variable names are case-insensitive, so $owner IS $Owner -- the
            # fallback-reset line `$owner = $null` nulled the caller-supplied
            # -Owner parameter itself, and every gh call below ended up
            # targeting "-R \"/\"" regardless of what was passed in.
            $script:mockComments = @(
                @{ id = 999; body = "<!-- explicit-owner-test -->`nold body" }
            )
            $url = Find-OrUpsertComment -Type pr -Number 123 -Marker '<!-- explicit-owner-test -->' -Body 'new body' -Owner 'ExplicitOwner' -Repo 'explicit-repo'

            $url | Should -Not -BeNullOrEmpty
            $script:lastListArgs | Should -Not -BeNullOrEmpty
            ($script:lastListArgs -join ' ') | Should -Match 'issue view 123 --json comments -R ExplicitOwner/explicit-repo' `
                -Because 'the list call must be explicitly repo-targeted with the caller-supplied owner/repo, not derived/nulled'

            $script:lastPatchArgs | Should -Not -BeNullOrEmpty
            ($script:lastPatchArgs -join ' ') | Should -Match 'repos/ExplicitOwner/explicit-repo/issues/comments/999' `
                -Because 'the PATCH path must embed the caller-supplied owner/repo, not "/" (nulled owner/repo)'
            ($script:lastPatchArgs -join ' ') | Should -Not -Match 'repos//issues'
        }

        It 'threads explicit -Owner/-Repo through the POST (zero-match) path' {
            $script:mockComments = @()
            $url = Find-OrUpsertComment -Type pr -Number 456 -Marker '<!-- explicit-owner-post-test -->' -Body 'hello' -Owner 'ExplicitOwner' -Repo 'explicit-repo'

            $url | Should -Not -BeNullOrEmpty
            $script:lastPostArgs | Should -Not -BeNullOrEmpty
            ($script:lastPostArgs -join ' ') | Should -Match '-R ExplicitOwner/explicit-repo' `
                -Because 'the POST call must be explicitly repo-targeted with the caller-supplied owner/repo, not "/"'
        }
    }

    Context 'GraphQL node ID handling' {
        # FIXTURE MOVE (#1031): all four bodies in this Context were
        # '<!-- frame-credit-ledger-484 --> old body|first|second|third' —
        # marker on line 1 with trailing prose. Moved to
        # marker-on-its-own-line-1. The REST-id extraction and ordering
        # behaviour under test is unchanged. The move matters for the
        # 'falls back to POST' case in particular: under the new rule that
        # body would no longer select AT ALL, so the test would have gone on
        # passing while testing nothing — a POST for the wrong reason.
        It 'extracts numeric REST id from comment url when id is a GraphQL node id (IC_kwDO...)' {
            $script:mockComments = @(
                @{
                    id   = 'IC_kwDOQkYn5M8AAAABA91Ixg'
                    url  = 'https://github.com/Grimblaz/agent-orchestra/issues/484#issuecomment-4359801030'
                    body = "<!-- frame-credit-ledger-484 -->`nold body"
                }
            )
            $url = Find-OrUpsertComment -Type pr -Number 484 -Marker '<!-- frame-credit-ledger-484 -->' -Body 'new body'
            $script:lastPatchArgs | Should -Not -BeNullOrEmpty
            ($script:lastPatchArgs -join ' ') | Should -Match 'comments/4359801030'
            $script:lastPostArgs | Should -BeNullOrEmpty
        }

        It 'falls back to POST when GraphQL node id has no resolvable url' {
            $script:mockComments = @(
                @{
                    id   = 'IC_kwDOQkYn5M8AAAABA91Ixg'
                    body = "<!-- frame-credit-ledger-484 -->`nold body"
                }
            )
            $url = Find-OrUpsertComment -Type pr -Number 484 -Marker '<!-- frame-credit-ledger-484 -->' -Body 'new body'
            $script:lastPostArgs | Should -Not -BeNullOrEmpty
            $script:lastPatchArgs | Should -BeNullOrEmpty
        }

        It 'picks the earliest numeric REST id when multiple GraphQL-id comments match' {
            $script:mockComments = @(
                @{
                    id   = 'IC_kwDO111'
                    url  = 'https://github.com/Grimblaz/agent-orchestra/issues/484#issuecomment-300'
                    body = "<!-- frame-credit-ledger-484 -->`nthird"
                },
                @{
                    id   = 'IC_kwDO222'
                    url  = 'https://github.com/Grimblaz/agent-orchestra/issues/484#issuecomment-100'
                    body = "<!-- frame-credit-ledger-484 -->`nfirst"
                },
                @{
                    id   = 'IC_kwDO333'
                    url  = 'https://github.com/Grimblaz/agent-orchestra/issues/484#issuecomment-200'
                    body = "<!-- frame-credit-ledger-484 -->`nsecond"
                }
            )
            $url = Find-OrUpsertComment -Type pr -Number 484 -Marker '<!-- frame-credit-ledger-484 -->' -Body 'new'
            $script:lastPatchArgs | Should -Not -BeNullOrEmpty
            ($script:lastPatchArgs -join ' ') | Should -Match 'comments/100'
        }
    }
}

# ---------------------------------------------------------------------------
# Describe: Get-RestCommentId helper — static structure
# (AC6 — issue #492 Step 4 RED / Step 5 GREEN)
#
# These tests verify that Get-RestCommentId is a file-level function rather
# than a nested helper defined inside Find-OrUpsertComment. Two assertions:
#   (a) AST position: no FunctionDefinitionAst ancestor in the parent chain.
#   (b) Resolvability: the function is visible after dot-sourcing the library
#       (before hoist it is defined only at call time — invisible at load time).
#
# RED phase: (a) finds the helper nested inside Find-OrUpsertComment and
#            (b) dot-source does not expose it.
# GREEN phase (after Step 5 hoist): both assertions pass.
# ---------------------------------------------------------------------------

Describe 'Get-RestCommentId helper — static structure (AC6)' {

    BeforeAll {
        $script:Ac6LibPath = Join-Path $PSScriptRoot '../lib/find-or-upsert-comment.ps1'
        $libContent = Get-Content -Path $script:Ac6LibPath -Raw
        $script:Ac6ParseErrors = $null
        $script:Ac6LibAst = [System.Management.Automation.Language.Parser]::ParseInput(
            $libContent, [ref]$null, [ref]$script:Ac6ParseErrors
        )
    }

    It 'find-or-upsert-comment.ps1 parses without errors (AST test prerequisite)' {
        # Without this guard, a syntax error in the file under test would silently
        # produce an incomplete AST — FindAll could return zero matches, and the
        # downstream nested/resolvable assertions would either pass with a misleading
        # zero-count or fail with cryptic messages. Surface parser errors directly.
        $errorMessages = if ($script:Ac6ParseErrors) {
            ($script:Ac6ParseErrors | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" }) -join '; '
        } else { '' }
        $script:Ac6ParseErrors.Count | Should -Be 0 `
            -Because "find-or-upsert-comment.ps1 must parse cleanly for AST tests to be meaningful — errors: $errorMessages"
    }

    It 'Get-RestCommentId is defined at file scope, not nested inside Find-OrUpsertComment' {
        # Find ALL FunctionDefinitionAst nodes whose name contains Get-RestCommentId.
        # Using -match to catch both 'Get-RestCommentId' and 'script:Get-RestCommentId'.
        $helperDefs = @($script:Ac6LibAst.FindAll(
            {
                $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $args[0].Name -match 'Get-RestCommentId'
            },
            $true
        ))
        $helperDefs.Count | Should -BeGreaterThan 0 `
            -Because 'Get-RestCommentId must be defined somewhere in find-or-upsert-comment.ps1'

        # Walk each definition's parent chain. If any ancestor is a FunctionDefinitionAst,
        # the helper is nested inside another function (RED). After the hoist (GREEN),
        # the parent chain goes to the script root with no function ancestor.
        $nestedDefs = @($helperDefs | Where-Object {
            $node = $_
            $ancestor = $node.Parent
            $foundFunctionAncestor = $false
            while ($null -ne $ancestor) {
                if ($ancestor -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                    $foundFunctionAncestor = $true
                    break
                }
                $ancestor = $ancestor.Parent
            }
            $foundFunctionAncestor
        })
        $nestedDefs.Count | Should -Be 0 `
            -Because 'Get-RestCommentId must be at file scope, not nested inside Find-OrUpsertComment'
    }

    It 'Get-RestCommentId is resolvable after dot-sourcing the library (isolated runspace check)' {
        # Before the hoist, Get-RestCommentId is defined with `function script:Get-RestCommentId`
        # inside Find-OrUpsertComment. Dot-sourcing only runs the script top level, which
        # defines Find-OrUpsertComment but does NOT execute its body — so Get-RestCommentId
        # is never defined at load time. After the hoist it is defined at the top level and
        # becomes available immediately on dot-source.
        #
        # Use an in-process isolated PowerShell runspace to avoid scope pollution from
        # other tests that called Find-OrUpsertComment (which lazily defines
        # script:Get-RestCommentId in the shared test-file scope).
        #
        # Pass the path via SessionStateProxy.SetVariable rather than string
        # interpolation so paths containing single quotes (or other PS metachars)
        # cannot break parsing of the script.
        $checkScript = ". `$LibPath; if (Get-Command Get-RestCommentId -ErrorAction SilentlyContinue) { 'found' } else { 'not-found' }"
        $ps = [System.Management.Automation.PowerShell]::Create()
        try {
            $ps.Runspace.SessionStateProxy.SetVariable('LibPath', $script:Ac6LibPath)
            $null = $ps.AddScript($checkScript)
            $results = $ps.Invoke()
        }
        finally {
            $ps.Dispose()
        }
        ($results | Select-Object -Last 1) | Should -Be 'found' `
            -Because 'Get-RestCommentId must be resolvable after dot-sourcing the library, not only when Find-OrUpsertComment runs'
    }
}
