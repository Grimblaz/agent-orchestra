#Requires -Version 7.0
<#
.SYNOPSIS
    Library for port-availability check logic. Dot-source this file and call Invoke-CheckPort.
#>

function Test-CPSocketBind {
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 65535)]
        [int]$Port
    )
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
    try {
        $listener.Start()
        return $true
    }
    catch {
        return $false
    }
    finally {
        $listener.Stop()
    }
}

function Get-CPWindowsPortInfo {
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 65535)]
        [int]$Port
    )
    if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
        return $null
    }
    $conn = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $conn) {
        return $null
    }
    $ownerPid = $conn.OwningProcess
    $proc = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
    $processName = if ($proc) { $proc.ProcessName } else { $null }
    return @{ OwningProcess = $ownerPid; ProcessName = $processName }
}

function Invoke-CheckPort {
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 65535)]
        [int]$Port
    )
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    try {
        $bindResult = Test-CPSocketBind -Port $Port

        if ($bindResult) {
            return [PSCustomObject]@{ InUse = $false; Pid = $null; ProcessName = $null }
        }

        $info = Get-CPWindowsPortInfo -Port $Port
        if ($info) {
            return [PSCustomObject]@{ InUse = $true; Pid = $info.OwningProcess; ProcessName = $info.ProcessName }
        }
        return [PSCustomObject]@{ InUse = $true; Pid = $null; ProcessName = $null }
    }
    catch {
        return [PSCustomObject]@{ InUse = $false; Pid = $null; ProcessName = $null }
    }
}
