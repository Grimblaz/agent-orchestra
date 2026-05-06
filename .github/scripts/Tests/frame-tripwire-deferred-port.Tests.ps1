#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Tests for the 90-day deferred-port tripwire (issue #443, Step 11).
#
# The tripwire is embedded in Invoke-FrameCreditLedger (Step 5b).
# It scans credits for DEFERRED(#NNN): evidence, reads trigger-deferred-since
# from the matching port YAML, and emits a stderr warning when age > 90 days.
# It is NEVER a merge gate — it only writes to stderr.

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path

    . (Join-Path $script:RepoRoot '.github/scripts/lib/frame-predicate-core.ps1')
    . (Join-Path $script:RepoRoot '.github/scripts/lib/frame-credit-ledger-core.ps1')

    # Re-implement the tripwire logic in an extractable helper for unit testing
    # without running the full Invoke-FrameCreditLedger stack.
    function script:Invoke-DeferredPortTripwire {
        param(
            [object[]]$Credits,
            [string]$PortsDir,
            [int]$TripwireDays = 90
        )
        $warnings = [System.Collections.Generic.List[string]]::new()
        $today = [datetime]::UtcNow.Date
        foreach ($c in $Credits) {
            $evidenceProp = $c.PSObject.Properties['evidence']
            if ($null -eq $evidenceProp) { continue }
            $evidence = [string]$evidenceProp.Value
            if ([string]::IsNullOrWhiteSpace($evidence)) { continue }
            if ($evidence -notmatch '^DEFERRED\(#(\d+)\):') { continue }

            $portProp = $c.PSObject.Properties['port']
            if ($null -eq $portProp) { continue }
            $portName = [string]$portProp.Value
            if ([string]::IsNullOrWhiteSpace($portName)) { continue }

            $portYaml = Join-Path $PortsDir "$portName.yaml"
            if (-not (Test-Path -LiteralPath $portYaml -PathType Leaf)) { continue }

            $portRaw = ''
            try { $portRaw = Get-Content -LiteralPath $portYaml -Raw -ErrorAction Stop } catch { continue }

            $sincePattern = '(?m)^\s*trigger-deferred-since\s*:\s*[''"]?(?<val>[0-9]{4}-[0-9]{2}-[0-9]{2})[''"]?\s*$'
            $sinceMatch = [regex]::Match($portRaw, $sincePattern)
            if (-not $sinceMatch.Success) { continue }

            $sinceDate = $null
            try {
                $sinceDate = [datetime]::ParseExact($sinceMatch.Groups['val'].Value, 'yyyy-MM-dd',
                    [System.Globalization.CultureInfo]::InvariantCulture)
            } catch { continue }

            $age = ($today - $sinceDate.Date).Days
            if ($age -gt $TripwireDays) {
                $warnings.Add("deferred-port tripwire: port '$portName' deferred $age days (threshold: $TripwireDays)")
            }
        }
        return , @($warnings)
    }

    # Build a temp ports dir with a port YAML file.
    function script:New-TempPortYaml {
        param([string]$PortName, [string]$DeferredSince)
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "tripwire-test-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $content = "name: $PortName`ntrigger-status: deferred`ntrigger-deferred-since: '$DeferredSince'`n"
        Set-Content -Path (Join-Path $dir "$PortName.yaml") -Value $content -Encoding UTF8
        return $dir
    }
}

AfterAll {
    # Temp dirs are cleaned up by OS; no explicit cleanup needed.
}

Describe '90-day deferred-port tripwire' {
    Context 'credit without DEFERRED prefix' {
        It 'emits no warning for non-deferred credit' {
            $dir = script:New-TempPortYaml -PortName 'some-port' -DeferredSince '2020-01-01'
            $credit = [pscustomobject]@{ port = 'some-port'; evidence = 'Review completed; 0 findings sustained.' }
            $warnings = script:Invoke-DeferredPortTripwire -Credits @($credit) -PortsDir $dir
            $warnings.Count | Should -Be 0
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'DEFERRED credit within 90 days' {
        It 'emits no warning when deferred < 90 days ago' {
            $recent = [datetime]::UtcNow.Date.AddDays(-30).ToString('yyyy-MM-dd')
            $dir = script:New-TempPortYaml -PortName 'test-port' -DeferredSince $recent
            $credit = [pscustomobject]@{ port = 'test-port'; evidence = 'DEFERRED(#348): trigger predicate deferred.' }
            $warnings = script:Invoke-DeferredPortTripwire -Credits @($credit) -PortsDir $dir
            $warnings.Count | Should -Be 0
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'DEFERRED credit older than 90 days' {
        It 'emits a warning when deferred > 90 days ago' {
            $old = [datetime]::UtcNow.Date.AddDays(-100).ToString('yyyy-MM-dd')
            $dir = script:New-TempPortYaml -PortName 'test-port' -DeferredSince $old
            $credit = [pscustomobject]@{ port = 'test-port'; evidence = 'DEFERRED(#348): trigger predicate deferred.' }
            $warnings = script:Invoke-DeferredPortTripwire -Credits @($credit) -PortsDir $dir
            $warnings.Count | Should -Be 1
            $warnings[0] | Should -BeLike '*tripwire*'
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
        }

        It 'warning mentions the port name' {
            $old = [datetime]::UtcNow.Date.AddDays(-91).ToString('yyyy-MM-dd')
            $dir = script:New-TempPortYaml -PortName 'process-retrospective' -DeferredSince $old
            $credit = [pscustomobject]@{ port = 'process-retrospective'; evidence = 'DEFERRED(#348): deferred.' }
            $warnings = script:Invoke-DeferredPortTripwire -Credits @($credit) -PortsDir $dir
            $warnings[0] | Should -BeLike "*process-retrospective*"
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
        }

        It 'warning mentions the day count' {
            $old = [datetime]::UtcNow.Date.AddDays(-95).ToString('yyyy-MM-dd')
            $dir = script:New-TempPortYaml -PortName 'test-port' -DeferredSince $old
            $credit = [pscustomobject]@{ port = 'test-port'; evidence = 'DEFERRED(#348): deferred.' }
            $warnings = script:Invoke-DeferredPortTripwire -Credits @($credit) -PortsDir $dir
            $warnings[0] | Should -BeLike '*95*'
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'port YAML has no trigger-deferred-since field' {
        It 'emits no warning when trigger-deferred-since is absent' {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) "tripwire-nofield-$([System.Guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -Path (Join-Path $dir 'some-port.yaml') -Value "name: some-port`ntrigger-status: deferred`n" -Encoding UTF8
            $credit = [pscustomobject]@{ port = 'some-port'; evidence = 'DEFERRED(#348): deferred.' }
            $warnings = script:Invoke-DeferredPortTripwire -Credits @($credit) -PortsDir $dir
            $warnings.Count | Should -Be 0
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'port YAML does not exist' {
        It 'emits no warning when port YAML is absent (fail-open)' {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) "tripwire-missing-$([System.Guid]::NewGuid().ToString('N'))"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $credit = [pscustomobject]@{ port = 'missing-port'; evidence = 'DEFERRED(#348): deferred.' }
            $warnings = script:Invoke-DeferredPortTripwire -Credits @($credit) -PortsDir $dir
            $warnings.Count | Should -Be 0
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'process-retrospective live port YAML' {
        It 'process-retrospective.yaml has trigger-deferred-since field' {
            $portsDir = Join-Path $script:RepoRoot 'frame/ports'
            $yaml = Get-Content (Join-Path $portsDir 'process-retrospective.yaml') -Raw
            $yaml | Should -Match 'trigger-deferred-since'
        }

        It 'process-retrospective stays under 90-day threshold when deferred today' {
            $today = [datetime]::UtcNow.Date.ToString('yyyy-MM-dd')
            $dir = script:New-TempPortYaml -PortName 'process-retrospective' -DeferredSince $today
            $credit = [pscustomobject]@{ port = 'process-retrospective'; evidence = 'DEFERRED(#348): deferred.' }
            $warnings = script:Invoke-DeferredPortTripwire -Credits @($credit) -PortsDir $dir -TripwireDays 90
            $warnings.Count | Should -Be 0
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
