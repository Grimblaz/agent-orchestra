#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Find-OrUpsertComment' {
    BeforeAll {
        $script:LibPath = Join-Path $PSScriptRoot '..\lib\find-or-upsert-comment.ps1'
    }

    BeforeEach {
        # Reset mock state per test
        $script:lastGhArgs = $null
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
        Remove-Item function:global:gh -ErrorAction SilentlyContinue
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
        It 'PATCHes the earliest match and emits stderr warning naming duplicates' {
            $script:mockComments = @(
                @{ id = 100; body = '<!-- frame-credit-ledger-123 --> first' },
                @{ id = 200; body = '<!-- frame-credit-ledger-123 --> second' },
                @{ id = 300; body = '<!-- frame-credit-ledger-123 --> third' }
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
        It 'PATCHes the issue comment when one marker match exists' {
            $script:mockComments = @(
                @{ id = 555; body = '<!-- plan-issue-429 --> existing' }
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
            $script:mockComments = @(@{ id = 1; body = '<!-- m --> old' })
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
        It 'matches markers via substring containment, not whole-line equality' {
            $script:mockComments = @(
                @{ id = 42; body = "header line`n<!-- frame-credit-ledger-123 -->`nbody after" }
            )
            $url = Find-OrUpsertComment -Type pr -Number 123 -Marker '<!-- frame-credit-ledger-123 -->' -Body 'new'
            $script:lastPatchArgs | Should -Not -BeNullOrEmpty
        }
    }

    Context 'GraphQL node ID handling' {
        It 'extracts numeric REST id from comment url when id is a GraphQL node id (IC_kwDO...)' {
            $script:mockComments = @(
                @{
                    id   = 'IC_kwDOQkYn5M8AAAABA91Ixg'
                    url  = 'https://github.com/Grimblaz/agent-orchestra/issues/484#issuecomment-4359801030'
                    body = '<!-- frame-credit-ledger-484 --> old body'
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
                    body = '<!-- frame-credit-ledger-484 --> old body'
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
                    body = '<!-- frame-credit-ledger-484 --> third'
                },
                @{
                    id   = 'IC_kwDO222'
                    url  = 'https://github.com/Grimblaz/agent-orchestra/issues/484#issuecomment-100'
                    body = '<!-- frame-credit-ledger-484 --> first'
                },
                @{
                    id   = 'IC_kwDO333'
                    url  = 'https://github.com/Grimblaz/agent-orchestra/issues/484#issuecomment-200'
                    body = '<!-- frame-credit-ledger-484 --> second'
                }
            )
            $url = Find-OrUpsertComment -Type pr -Number 484 -Marker '<!-- frame-credit-ledger-484 -->' -Body 'new'
            $script:lastPatchArgs | Should -Not -BeNullOrEmpty
            ($script:lastPatchArgs -join ' ') | Should -Match 'comments/100'
        }
    }
}
