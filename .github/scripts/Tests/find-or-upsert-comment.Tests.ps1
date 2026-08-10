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
#
# ---------------------------------------------------------------------------
# PAYLOAD PINNING (issue #1035 review, findings F3 + the PATCH-path sibling
# it turned up).
#
# Both write paths in find-or-upsert-comment.ps1 stream their payload through
# a temp file — the POST path via `--body-file` (M26) and the PATCH path via
# `gh api --input` (Fix Pass3-F1). Neither payload was pinned by ANY assertion
# in this file, for two different reasons, and both were proven by mutation
# rather than suspected:
#
#   * POST — the mock matched '(issue|pr) comment \d+ --body', which
#     '--body-file' satisfies BY PREFIX. The tests kept passing by luck, not
#     by design. Writing an EMPTY body file, and deleting the Set-Content
#     that writes the body at all, each left the suite at 17 passed / 0
#     failed.
#   * PATCH — the mock's regex ENDED at the comment id
#     ('...issues/comments/(\d+)'), so everything after it — the `--input`
#     flag, the temp path, and the JSON envelope — was never examined.
#     Emptying the payload, deleting its write, replacing the body value with
#     'CLOBBERED', and swapping `--input` for a bogus flag ALL left the suite
#     at 17 passed / 0 failed.
#
# The fix is in the mock, not in the assertions alone: each branch now
# requires its real flag and READS the temp file it points at. That read has
# to happen inside the mock — both helpers delete the temp file in their own
# `finally` block the instant `gh` returns, so mid-call is the only moment at
# which the bytes the library intended to send exist on disk.
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
        # Payload capture (see PAYLOAD PINNING note at the top of this file).
        $script:lastPostBody = $null      # bytes read back out of --body-file
        $script:lastPatchPayload = $null  # raw bytes read back out of --input
        $script:lastPatchBody = $null     # .body decoded from that JSON envelope

        # Resolve the temp-file path that FOLLOWS $Flag in the real argv and
        # return the file's content. Reads the argv array rather than the
        # space-joined string so a temp path containing spaces cannot break
        # it. Returns a describing sentinel instead of $null on every failure
        # so an assertion message names WHY there was no payload rather than
        # reporting a bare null.
        function global:Get-MockPayloadFromFile {
            param([object[]]$ArgList, [string]$Flag)
            $idx = [array]::IndexOf($ArgList, $Flag)
            if ($idx -lt 0) { return "<<argv carried no $Flag flag>>" }
            if ($idx + 1 -ge $ArgList.Count) { return "<<$Flag had no path argument>>" }
            $path = [string]$ArgList[$idx + 1]
            if (-not (Test-Path -LiteralPath $path)) { return "<<payload file '$path' does not exist>>" }
            $raw = Get-Content -LiteralPath $path -Raw
            # Get-Content -Raw yields $null (not '') for a zero-byte file.
            if ($null -eq $raw) { return '' }
            return [string]$raw
        }

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
            # The ' --input ' tail is deliberately part of the match. Without
            # it this branch matched any `api -X PATCH .../comments/<id>`
            # whatsoever, so swapping `--input` for a bogus flag stayed green
            # (see PAYLOAD PINNING at the top of this file). A PATCH that
            # does not stream its payload through --input must now miss this
            # branch, fall through to the catch-all below, and leave
            # $script:lastPatchArgs null — which every PATCH test already
            # asserts against.
            if ($joined -match 'api -X PATCH repos/[^/]+/[^/]+/issues/comments/(\d+) --input ') {
                if ($script:simulateFailure -eq 'patch') {
                    $global:LASTEXITCODE = 1
                    return ''
                }
                $script:lastPatchArgs = $Args
                # Read the JSON envelope NOW: Find-OrUpsertComment deletes the
                # temp file in its `finally` the instant this call returns.
                $script:lastPatchPayload = Get-MockPayloadFromFile -ArgList $Args -Flag '--input'
                $script:lastPatchBody = if ([string]::IsNullOrWhiteSpace($script:lastPatchPayload)) {
                    "<<--input payload was empty>>"
                }
                else {
                    try { ($script:lastPatchPayload | ConvertFrom-Json -ErrorAction Stop).body }
                    catch { "<<--input payload is not valid JSON: $($script:lastPatchPayload)>>" }
                }
                $global:LASTEXITCODE = 0
                return (@{ html_url = "https://github.com/$($script:mockRepoOwner)/$($script:mockRepoName)/issues/123#issuecomment-patched" } | ConvertTo-Json)
            }
            # '--body-file', not '--body'. The old pattern was '--body', which
            # '--body-file' satisfies by PREFIX — so a revert to the raw-argv
            # `--body $Body` form (the ~32K CreateProcess limit M26 fixed)
            # would have gone on passing. It now misses this branch and leaves
            # $script:lastPostArgs null.
            if ($joined -match '(issue|pr) comment \d+ --body-file ') {
                if ($script:simulateFailure -eq 'post') {
                    $global:LASTEXITCODE = 1
                    return ''
                }
                $script:lastPostArgs = $Args
                # Read the body NOW: Send-NewCommentViaBodyFile deletes the
                # temp file in its `finally` the instant this call returns.
                $script:lastPostBody = Get-MockPayloadFromFile -ArgList $Args -Flag '--body-file'
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
        Remove-Item Function:Get-MockPayloadFromFile -ErrorAction SilentlyContinue
    }

    Context 'PR comment - zero matches' {
        It 'POSTs a new comment when no marker match exists' {
            $script:mockComments = @()
            $url = Find-OrUpsertComment -Type pr -Number 123 -Marker '<!-- frame-credit-ledger-123 -->' -Body 'hello'
            $url | Should -Not -BeNullOrEmpty
            $script:lastPostArgs | Should -Not -BeNullOrEmpty
            $script:lastPatchArgs | Should -BeNullOrEmpty
            $script:lastPostBody | Should -BeExactly 'hello' `
                -Because 'the --body-file the POST points at must contain the caller-supplied body; without this the POST could send nothing at all and still pass'
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
            $script:lastPatchBody | Should -BeExactly 'new body' `
                -Because 'the --input JSON envelope must carry the caller-supplied body; without this the PATCH could send an empty or clobbered body and still pass'
        }
    }

    Context 'PR comment - multiple matches (data error path)' {
        # FIXTURE MOVE (#1031): the three bodies were
        # '<!-- frame-credit-ledger-123 --> first|second|third' — marker on
        # line 1 with trailing prose. Moved to marker-on-its-own-line-1. The
        # duplicate/earliest-id behaviour under test is unchanged.
        # STDERR ASSERTION ADDED (issue #1035 review). This test's title has
        # always claimed it "emits stderr warning naming duplicates", but its
        # body only captured `$stderr` via `2>&1 | Tee-Object` and never
        # asserted on it — and could not have: Find-OrUpsertComment reports
        # via [Console]::Error.WriteLine, which writes straight to the process
        # stderr handle and never enters PowerShell's error stream, so `2>&1`
        # captures nothing. (Proof: the warning prints to the console during a
        # passing run.) The whole pipeline also fed `Out-Null`, so the `$url =`
        # assignment was dead too. Redirecting [Console]::Error to a
        # StringWriter is what actually reaches the message.
        It 'PATCHes the earliest match and emits stderr warning naming duplicates' {
            $script:mockComments = @(
                @{ id = 100; body = "<!-- frame-credit-ledger-123 -->`nfirst" },
                @{ id = 200; body = "<!-- frame-credit-ledger-123 -->`nsecond" },
                @{ id = 300; body = "<!-- frame-credit-ledger-123 -->`nthird" }
            )
            $errWriter = [System.IO.StringWriter]::new()
            $originalErr = [Console]::Error
            try {
                [Console]::SetError($errWriter)
                $url = Find-OrUpsertComment -Type pr -Number 123 -Marker '<!-- frame-credit-ledger-123 -->' -Body 'new'
            }
            finally {
                [Console]::SetError($originalErr)
            }
            $captured = $errWriter.ToString()

            $url | Should -Not -BeNullOrEmpty
            $script:lastPatchArgs | Should -Not -BeNullOrEmpty
            $joined = $script:lastPatchArgs -join ' '
            $joined | Should -Match 'comments/100'  # earliest id
            $script:lastPatchBody | Should -BeExactly 'new'

            $captured | Should -Match 'duplicates: 200, 300' `
                -Because 'the warning must NAME the duplicate ids it is leaving unpatched, not merely say duplicates exist'
            $captured | Should -Match 'patching earliest id 100' `
                -Because 'the warning must name which comment it did patch'
        }
    }

    Context 'Issue comment - zero matches' {
        It 'POSTs a new issue comment when no match' {
            $script:mockComments = @()
            $url = Find-OrUpsertComment -Type issue -Number 429 -Marker '<!-- plan-issue-429 -->' -Body 'plan'
            $url | Should -Not -BeNullOrEmpty
            $script:lastPostArgs | Should -Not -BeNullOrEmpty
            ($script:lastPostArgs -join ' ') | Should -Match 'issue comment'
            $script:lastPostBody | Should -BeExactly 'plan'
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
            $script:lastPatchBody | Should -BeExactly 'updated'
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
            $script:lastPostBody | Should -BeExactly 'new'
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
            $script:lastPatchBody | Should -BeExactly 'new body'
        }

        It 'threads explicit -Owner/-Repo through the POST (zero-match) path' {
            $script:mockComments = @()
            $url = Find-OrUpsertComment -Type pr -Number 456 -Marker '<!-- explicit-owner-post-test -->' -Body 'hello' -Owner 'ExplicitOwner' -Repo 'explicit-repo'

            $url | Should -Not -BeNullOrEmpty
            $script:lastPostArgs | Should -Not -BeNullOrEmpty
            ($script:lastPostArgs -join ' ') | Should -Match '-R ExplicitOwner/explicit-repo' `
                -Because 'the POST call must be explicitly repo-targeted with the caller-supplied owner/repo, not "/"'
            $script:lastPostBody | Should -BeExactly 'hello' `
                -Because 'repo-targeting and body transport are independent; pinning -R alone leaves the body unpinned'
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
            $script:lastPatchBody | Should -BeExactly 'new body'
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
            $script:lastPostBody | Should -BeExactly 'new body' `
                -Because 'the no-resolvable-id fallback is a SECOND Send-NewCommentViaBodyFile call site and must transport the body too'
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
            $script:lastPatchBody | Should -BeExactly 'new'
        }
    }

    # -----------------------------------------------------------------------
    # Payload transport (issue #1035 review F3 and its PATCH-path sibling).
    #
    # The assertions added to the Contexts above pin the body on every write
    # path with a short literal. These pin the properties a short literal
    # cannot reach: that the transport is the FILE-based form specifically,
    # and that it survives payloads that a raw-argv or shell-quoted transport
    # would truncate or mangle. Both are the actual motivation for M26 and
    # Fix Pass3-F1 — the ~32K Windows CreateProcess argv limit against a
    # composer that emits up to GitHub's 65,536-codepoint cap.
    # -----------------------------------------------------------------------
    Context 'Payload transport - POST (--body-file, M26)' {
        It 'sends the body through --body-file and never through a raw --body argv element' {
            $script:mockComments = @()
            $null = Find-OrUpsertComment -Type pr -Number 123 -Marker '<!-- transport-post -->' -Body 'payload'
            $argv = ($script:lastPostArgs -join ' ')
            $argv | Should -Match '--body-file' `
                -Because 'the file-based form is the fix; a raw --body packs the whole comment into one argv element'
            # '--body' followed by anything other than '-' or a word char, i.e.
            # the bare flag. Written as a lookahead because a plain '--body\b'
            # ALSO matches inside '--body-file' (the y/- transition is a word
            # boundary) and would make this assertion unfalsifiable.
            $argv | Should -Not -Match '--body(?![\w-])' `
                -Because 'a bare --body flag is the ~32K-argv-limited form M26 replaced'
            $argv | Should -Not -Match 'payload' `
                -Because 'the body text itself must never appear in argv - that is the whole point of the temp file'
        }

        It 'round-trips a cap-adjacent multi-line body through the temp file byte-for-byte' {
            # Deliberately shaped like a real marker comment near GitHub's
            # 65,536-codepoint cap, and containing characters a shell-quoted
            # or argv-packed transport is most likely to mangle. The repeat
            # count is COMPUTED from the line width rather than hard-coded, so
            # editing the line cannot silently drop the fixture below the size
            # regime the two assertions below claim for it.
            $line = '| run | ' + ('x' * 60) + ' | `$Body` "quoted" ''single'' — ✓ |'
            $reps = [math]::Ceiling(65000 / ($line.Length + 1))
            $bigBody = "<!-- ci-glob-audit-run-abc123 -->`n" + (($line + "`n") * $reps)
            $bigBody.Length | Should -BeGreaterThan 65000 `
                -Because 'the fixture must actually exceed the ~32K argv regime this transport exists for'
            $bigBody.Length | Should -BeLessOrEqual 65536 `
                -Because 'and must stay a body GitHub would actually accept, not an unreachable one'

            $script:mockComments = @()
            $url = Find-OrUpsertComment -Type issue -Number 1035 -Marker '<!-- ci-glob-audit-run-abc123 -->' -Body $bigBody
            $url | Should -Not -BeNullOrEmpty
            $script:lastPostBody | Should -BeExactly $bigBody `
                -Because 'a truncating, re-encoding, or newline-rewriting transport would post a corrupted comment'
            $script:lastPostBody.Length | Should -Be $bigBody.Length
        }
    }

    Context 'Payload transport - PATCH (--input JSON envelope, Fix Pass3-F1)' {
        It 'sends the body through an --input JSON envelope and never through a raw -f body= argv element' {
            $script:mockComments = @(@{ id = 777; body = "<!-- transport-patch -->`nold" })
            $null = Find-OrUpsertComment -Type pr -Number 123 -Marker '<!-- transport-patch -->' -Body 'payload'
            $argv = ($script:lastPatchArgs -join ' ')
            $argv | Should -Match '--input ' `
                -Because 'the stdin/file JSON form is the fix; -f "body=..." packs the whole payload into one argv element'
            $argv | Should -Not -Match '-f body=' `
                -Because 'the -f form is the ~32K-argv-limited shape Fix Pass3-F1 replaced'
            $argv | Should -Not -Match 'payload' `
                -Because 'the body text itself must never appear in argv'
            $script:lastPatchPayload | Should -Match '^\s*\{' `
                -Because 'the --input file must hold a JSON object, not the bare body text'
            $script:lastPatchBody | Should -BeExactly 'payload'
        }

        It 'round-trips a cap-adjacent multi-line body through the JSON envelope byte-for-byte' {
            $line = '| run | ' + ('x' * 60) + ' | `$Body` "quoted" ''single'' — ✓ |'
            $reps = [math]::Ceiling(65000 / ($line.Length + 1))
            $bigBody = "<!-- frame-credit-ledger-1035 -->`n" + (($line + "`n") * $reps)
            $bigBody.Length | Should -BeGreaterThan 65000
            $bigBody.Length | Should -BeLessOrEqual 65536

            $script:mockComments = @(@{ id = 888; body = "<!-- frame-credit-ledger-1035 -->`nold" })
            $url = Find-OrUpsertComment -Type pr -Number 1035 -Marker '<!-- frame-credit-ledger-1035 -->' -Body $bigBody
            $url | Should -Not -BeNullOrEmpty
            $script:lastPatchBody | Should -BeExactly $bigBody `
                -Because 'JSON escaping of quotes, backslashes and newlines must survive the round trip intact'
            $script:lastPatchBody.Length | Should -Be $bigBody.Length
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
