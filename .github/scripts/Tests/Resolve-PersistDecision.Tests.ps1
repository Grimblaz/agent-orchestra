#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $helperPath = Join-Path $PSScriptRoot '..' '..' '..' 'skills' 'persist-changes' 'scripts' 'Resolve-PersistDecision.ps1'
    . $helperPath   # dot-source the helper under test
}

Describe 'Resolve-PersistDecision' {

    Context 'Guard: detached HEAD' {
        It 'refuses with detached reason' {
            $result = Resolve-PersistDecision @{
                branch               = ''
                isDetached           = $true
                defaultBranch        = 'main'
                headRemote           = 'origin'
                headRemoteWritable   = $true
                commitPolicyDisabled = $false
                hasFixFiles          = $true
                isUpToDate           = $false
                nonFastForwardProbe  = $false
            }
            $result.commit        | Should -Be $false
            $result.push          | Should -Be $false
            $result.refuse_reason | Should -Be 'detached'
        }
    }

    Context 'Guard: default branch' {
        It 'refuses with default-branch reason' {
            $result = Resolve-PersistDecision @{
                branch               = 'main'
                isDetached           = $false
                defaultBranch        = 'main'
                headRemote           = 'origin'
                headRemoteWritable   = $true
                commitPolicyDisabled = $false
                hasFixFiles          = $true
                isUpToDate           = $false
                nonFastForwardProbe  = $false
            }
            $result.commit        | Should -Be $false
            $result.push          | Should -Be $false
            $result.refuse_reason | Should -Be 'default-branch'
        }
    }

    Context 'Guard: nothing to push' {
        It 'skips when no fix files' {
            $result = Resolve-PersistDecision @{
                branch               = 'feature/x'
                isDetached           = $false
                defaultBranch        = 'main'
                headRemote           = 'origin'
                headRemoteWritable   = $true
                commitPolicyDisabled = $false
                hasFixFiles          = $false
                isUpToDate           = $false
                nonFastForwardProbe  = $false
            }
            $result.commit            | Should -Be $false
            $result.push              | Should -Be $false
            $result.not_pushed_reason | Should -Be 'nothing-to-push'
        }

        It 'skips when already up to date' {
            $result = Resolve-PersistDecision @{
                branch               = 'feature/x'
                isDetached           = $false
                defaultBranch        = 'main'
                headRemote           = 'origin'
                headRemoteWritable   = $true
                commitPolicyDisabled = $false
                hasFixFiles          = $true
                isUpToDate           = $true
                nonFastForwardProbe  = $false
            }
            $result.commit            | Should -Be $false
            $result.push              | Should -Be $false
            $result.not_pushed_reason | Should -Be 'nothing-to-push'
        }
    }

    Context 'Push gate: commit-policy opt-out' {
        It 'commits but does not push; sets manual_instruction' {
            $result = Resolve-PersistDecision @{
                branch               = 'feature/x'
                isDetached           = $false
                defaultBranch        = 'main'
                headRemote           = 'origin'
                headRemoteWritable   = $true
                commitPolicyDisabled = $true
                hasFixFiles          = $true
                isUpToDate           = $false
                nonFastForwardProbe  = $false
            }
            $result.commit            | Should -Be $true
            $result.push              | Should -Be $false
            $result.not_pushed_reason | Should -Be 'opt-out'
            $result.manual_instruction | Should -Not -BeNullOrEmpty
            $result.manual_instruction | Should -Match 'git push origin HEAD:feature/x'
        }
    }

    Context 'Push gate: fork / no write access' {
        It 'commits but does not push with fork-no-write reason' {
            $result = Resolve-PersistDecision @{
                branch               = 'feature/x'
                isDetached           = $false
                defaultBranch        = 'main'
                headRemote           = 'upstream'
                headRemoteWritable   = $false
                commitPolicyDisabled = $false
                hasFixFiles          = $true
                isUpToDate           = $false
                nonFastForwardProbe  = $false
            }
            $result.commit            | Should -Be $true
            $result.push              | Should -Be $false
            $result.not_pushed_reason | Should -Be 'fork-no-write'
        }
    }

    Context 'Push gate: non-fast-forward' {
        It 'commits but does not push with non-ff reason' {
            $result = Resolve-PersistDecision @{
                branch               = 'feature/x'
                isDetached           = $false
                defaultBranch        = 'main'
                headRemote           = 'origin'
                headRemoteWritable   = $true
                commitPolicyDisabled = $false
                hasFixFiles          = $true
                isUpToDate           = $false
                nonFastForwardProbe  = $true
            }
            $result.commit            | Should -Be $true
            $result.push              | Should -Be $false
            $result.not_pushed_reason | Should -Be 'non-ff'
        }
    }

    Context 'Happy path' {
        It 'commits and pushes to headRemote' {
            $result = Resolve-PersistDecision @{
                branch               = 'feature/x'
                isDetached           = $false
                defaultBranch        = 'main'
                headRemote           = 'origin'
                headRemoteWritable   = $true
                commitPolicyDisabled = $false
                hasFixFiles          = $true
                isUpToDate           = $false
                nonFastForwardProbe  = $false
            }
            $result.commit             | Should -Be $true
            $result.push               | Should -Be $true
            $result.push_target_remote | Should -Be 'origin'
        }
    }

    Context 'Edge case: null headRemote defaults to origin' {
        It 'uses origin when headRemote is null' {
            $result = Resolve-PersistDecision @{
                branch               = 'feature/x'
                isDetached           = $false
                defaultBranch        = 'main'
                headRemote           = $null
                headRemoteWritable   = $true
                commitPolicyDisabled = $false
                hasFixFiles          = $true
                isUpToDate           = $false
                nonFastForwardProbe  = $false
            }
            $result.commit             | Should -Be $true
            $result.push               | Should -Be $true
            $result.push_target_remote | Should -Be 'origin'
        }
    }

    Context 'Schema: no force-push field' {
        It 'output struct has no force or forcePush key' {
            $result = Resolve-PersistDecision @{
                branch               = 'feature/x'
                isDetached           = $false
                defaultBranch        = 'main'
                headRemote           = 'origin'
                headRemoteWritable   = $true
                commitPolicyDisabled = $false
                hasFixFiles          = $true
                isUpToDate           = $false
                nonFastForwardProbe  = $false
            }
            $result.Keys | Should -Not -Contain 'force'
            $result.Keys | Should -Not -Contain 'forcePush'
        }
    }

    Context 'Enum membership: all returned reason values are in the allowed set' {
        BeforeAll {
            $script:allowedReasons = @(
                'detached', 'default-branch', 'fork-no-write',
                'non-ff', 'opt-out', 'nothing-to-push'
            )
        }

        It 'refuse_reason is from the allowed enum' {
            $result = Resolve-PersistDecision @{
                branch               = ''
                isDetached           = $true
                defaultBranch        = 'main'
                headRemote           = 'origin'
                headRemoteWritable   = $true
                commitPolicyDisabled = $false
                hasFixFiles          = $true
                isUpToDate           = $false
                nonFastForwardProbe  = $false
            }
            if ($null -ne $result.refuse_reason) {
                $script:allowedReasons | Should -Contain $result.refuse_reason
            }
        }

        It 'not_pushed_reason is from the allowed enum' {
            $result = Resolve-PersistDecision @{
                branch               = 'feature/x'
                isDetached           = $false
                defaultBranch        = 'main'
                headRemote           = 'origin'
                headRemoteWritable   = $true
                commitPolicyDisabled = $false
                hasFixFiles          = $false
                isUpToDate           = $false
                nonFastForwardProbe  = $false
            }
            if ($null -ne $result.not_pushed_reason) {
                $script:allowedReasons | Should -Contain $result.not_pushed_reason
            }
        }
    }

    Context 'Enum producibility: each declared reason value has a producing input vector' {
        It 'produces refuse_reason detached' {
            $r = Resolve-PersistDecision @{
                branch               = ''
                isDetached           = $true
                defaultBranch        = 'main'
                headRemote           = 'origin'
                headRemoteWritable   = $true
                commitPolicyDisabled = $false
                hasFixFiles          = $true
                isUpToDate           = $false
                nonFastForwardProbe  = $false
            }
            $r.refuse_reason | Should -Be 'detached'
        }

        It 'produces refuse_reason default-branch' {
            $r = Resolve-PersistDecision @{
                branch               = 'main'
                isDetached           = $false
                defaultBranch        = 'main'
                headRemote           = 'origin'
                headRemoteWritable   = $true
                commitPolicyDisabled = $false
                hasFixFiles          = $true
                isUpToDate           = $false
                nonFastForwardProbe  = $false
            }
            $r.refuse_reason | Should -Be 'default-branch'
        }

        It 'produces not_pushed_reason nothing-to-push' {
            $r = Resolve-PersistDecision @{
                branch               = 'feature/x'
                isDetached           = $false
                defaultBranch        = 'main'
                headRemote           = 'origin'
                headRemoteWritable   = $true
                commitPolicyDisabled = $false
                hasFixFiles          = $false
                isUpToDate           = $false
                nonFastForwardProbe  = $false
            }
            $r.not_pushed_reason | Should -Be 'nothing-to-push'
        }

        It 'produces not_pushed_reason opt-out' {
            $r = Resolve-PersistDecision @{
                branch               = 'feature/x'
                isDetached           = $false
                defaultBranch        = 'main'
                headRemote           = 'origin'
                headRemoteWritable   = $true
                commitPolicyDisabled = $true
                hasFixFiles          = $true
                isUpToDate           = $false
                nonFastForwardProbe  = $false
            }
            $r.not_pushed_reason | Should -Be 'opt-out'
        }

        It 'produces not_pushed_reason fork-no-write' {
            $r = Resolve-PersistDecision @{
                branch               = 'feature/x'
                isDetached           = $false
                defaultBranch        = 'main'
                headRemote           = 'upstream'
                headRemoteWritable   = $false
                commitPolicyDisabled = $false
                hasFixFiles          = $true
                isUpToDate           = $false
                nonFastForwardProbe  = $false
            }
            $r.not_pushed_reason | Should -Be 'fork-no-write'
        }

        It 'produces not_pushed_reason non-ff' {
            $r = Resolve-PersistDecision @{
                branch               = 'feature/x'
                isDetached           = $false
                defaultBranch        = 'main'
                headRemote           = 'origin'
                headRemoteWritable   = $true
                commitPolicyDisabled = $false
                hasFixFiles          = $true
                isUpToDate           = $false
                nonFastForwardProbe  = $true
            }
            $r.not_pushed_reason | Should -Be 'non-ff'
        }
    }
}
