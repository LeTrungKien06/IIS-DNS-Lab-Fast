#Requires -Version 5.1
#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

. (Join-Path $PSScriptRoot 'Config.ps1')

$configFile = Join-Path $PSScriptRoot 'lab-config.json'

Write-Host ''
Write-Host '==============================================' -ForegroundColor DarkCyan
Write-Host ' IIS DNS LAB - ONE-TIME SERVER SETUP' -ForegroundColor Cyan
Write-Host '==============================================' -ForegroundColor DarkCyan
Write-Host ''
Write-Host 'This setup does NOT assume fixed IIS/DNS IP addresses.' -ForegroundColor Yellow
Write-Host 'Enter the addresses used by YOUR lab.' -ForegroundColor Yellow
Write-Host ''
Write-Host 'Current connected IPv4 addresses on this IIS server:' -ForegroundColor Cyan

Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object {
        $_.IPAddress -notlike '127.*' -and
        $_.IPAddress -notlike '169.254.*'
    } |
    Select-Object InterfaceAlias,IPAddress,PrefixLength,AddressState |
    Format-Table -AutoSize

function Read-IPv4Value {
    param(
        [Parameter(Mandatory=$true)][string]$Prompt,
        [string]$Default = ''
    )

    while ($true) {
        $display = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
        $value = (Read-Host $display).Trim()
        if (-not $value -and $Default) { $value = $Default }
        if (Test-LabIPv4 -IP $value) { return $value }
        Write-Host 'Invalid IPv4 address. Try again.' -ForegroundColor Red
    }
}

function Read-IntRange {
    param(
        [Parameter(Mandatory=$true)][string]$Prompt,
        [Parameter(Mandatory=$true)][int]$Default,
        [Parameter(Mandatory=$true)][int]$Min,
        [Parameter(Mandatory=$true)][int]$Max
    )

    while ($true) {
        $raw = (Read-Host "$Prompt [$Default]").Trim()
        if (-not $raw) { return $Default }
        $value = 0
        if ([int]::TryParse($raw, [ref]$value) -and $value -ge $Min -and $value -le $Max) {
            return $value
        }
        Write-Host ("Enter a number from {0} to {1}." -f $Min, $Max) -ForegroundColor Red
    }
}

$iisIP = Read-IPv4Value -Prompt 'IIS management IP on THIS server'

$localAddress = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $iisIP -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $localAddress) {
    throw ("The IIS management IP {0} is not configured on this server." -f $iisIP)
}

$interface = Get-NetIPInterface -InterfaceIndex $localAddress.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop
if ($interface.ConnectionState -ne 'Connected') {
    throw 'The selected IIS management adapter is not connected.'
}
if ($interface.Dhcp -ne 'Disabled') {
    Write-Warning 'The selected IIS management adapter uses DHCP. A static management IP is strongly recommended for this lab.'
}

$prefixDefault = [int]$localAddress.PrefixLength
if ($prefixDefault -lt 8 -or $prefixDefault -gt 30) { $prefixDefault = 24 }
$managementPrefix = Read-IntRange -Prompt 'Management network prefix' -Default $prefixDefault -Min 8 -Max 30

$dnsIP = Read-IPv4Value -Prompt 'DNS Server IP'
if ($dnsIP -eq $iisIP) { throw 'DNS Server IP cannot be the same as IIS management IP.' }

$portalPort = Read-IntRange -Prompt 'Fast Portal TCP port' -Default 8787 -Min 1 -Max 65535

$config = [pscustomobject][ordered]@{
    iisManagementIP = $iisIP
    managementPrefix = $managementPrefix
    dnsServerIP = $dnsIP
    portalPort = $portalPort
}

$config | ConvertTo-Json -Depth 4 | Set-Content -Path $configFile -Encoding UTF8

Set-Service WinRM -StartupType Automatic
if ((Get-Service WinRM).Status -ne 'Running') { Start-Service WinRM }

$currentTrusted = (Get-Item WSMan:\localhost\Client\TrustedHosts).Value
$trustedItems = @($currentTrusted -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($dnsIP -notin $trustedItems -and '*' -notin $trustedItems) {
    $newTrusted = if ([string]::IsNullOrWhiteSpace($currentTrusted)) { $dnsIP } else { "$currentTrusted,$dnsIP" }
    Set-Item WSMan:\localhost\Client\TrustedHosts -Value $newTrusted -Force
}

Write-Host ''
Write-Host 'SERVER CONFIG SAVED' -ForegroundColor Green
Write-Host ("IIS management IP : {0}/{1}" -f $iisIP, $managementPrefix)
Write-Host ("DNS Server IP     : {0}" -f $dnsIP)
Write-Host ("Portal            : http://{0}:{1}/" -f $iisIP, $portalPort)
Write-Host ("Config file       : {0}" -f $configFile)
Write-Host ''

try {
    Test-NetConnection $dnsIP -Port 5985 -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction Stop | ForEach-Object {
        if ($_){ Write-Host 'DNS WinRM TCP 5985 : reachable' -ForegroundColor Green }
        else { Write-Warning 'DNS WinRM TCP 5985 is not reachable yet. Configure WinRM on the DNS Server before saving credentials.' }
    }
}
catch {
    Write-Warning 'Could not test DNS WinRM yet. You can continue after the DNS Server is ready.'
}

Write-Host ''
Write-Host 'Next:' -ForegroundColor Cyan
Write-Host '  .\Save-DNSCredential.ps1'
Write-Host '  .\Test-DNS.ps1'
Write-Host '  .\Fast-Portal.ps1'
