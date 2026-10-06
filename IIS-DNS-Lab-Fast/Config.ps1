#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

function Test-LabIPv4 {
    param([Parameter(Mandatory=$true)][string]$IP)

    $parsed = $null
    return (
        $IP -match '^\d{1,3}(\.\d{1,3}){3}$' -and
        [Net.IPAddress]::TryParse($IP, [ref]$parsed) -and
        $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
    )
}

function Get-LabConfig {
    param(
        [string]$Path = (Join-Path $PSScriptRoot 'lab-config.json')
    )

    if (-not (Test-Path $Path)) {
        throw @"
Lab configuration has not been created yet.
Run once on the IIS server:
    .\Setup-Server.ps1
"@
    }

    try {
        $config = Get-Content $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw ("Cannot read lab configuration {0}: {1}" -f $Path, $_.Exception.Message)
    }

    $iisIP = ([string]$config.iisManagementIP).Trim()
    $dnsIP = ([string]$config.dnsServerIP).Trim()
    $prefix = 0
    $portalPort = 0

    if (-not (Test-LabIPv4 -IP $iisIP)) { throw 'Invalid iisManagementIP in lab-config.json.' }
    if (-not (Test-LabIPv4 -IP $dnsIP)) { throw 'Invalid dnsServerIP in lab-config.json.' }
    if ($iisIP -eq $dnsIP) { throw 'IIS management IP and DNS Server IP must be different.' }
    if (-not [int]::TryParse([string]$config.managementPrefix, [ref]$prefix) -or $prefix -lt 8 -or $prefix -gt 30) {
        throw 'managementPrefix must be between 8 and 30.'
    }
    if (-not [int]::TryParse([string]$config.portalPort, [ref]$portalPort) -or $portalPort -lt 1 -or $portalPort -gt 65535) {
        throw 'portalPort must be between 1 and 65535.'
    }

    return [pscustomobject][ordered]@{
        iisManagementIP = $iisIP
        managementPrefix = $prefix
        dnsServerIP = $dnsIP
        portalPort = $portalPort
    }
}
