#Requires -Version 5.1
#Requires -RunAsAdministrator

param(
    [string]$IisServerIP = '',
    [string]$DnsServerIP = '',
    [int]$ManagementPrefix = 0,
    [int]$PortalPort = 0
)

$ErrorActionPreference = 'Stop'

function Test-IPv4 {
    param([Parameter(Mandatory=$true)][string]$IP)
    $parsed = $null
    return (
        $IP -match '^\d{1,3}(\.\d{1,3}){3}$' -and
        [Net.IPAddress]::TryParse($IP, [ref]$parsed) -and
        $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork
    )
}

function Read-IPv4Value {
    param(
        [Parameter(Mandatory=$true)][string]$Prompt,
        [string]$Current = ''
    )

    while ($true) {
        $display = if ($Current) { "$Prompt [$Current]" } else { $Prompt }
        $value = (Read-Host $display).Trim()
        if (-not $value -and $Current) { $value = $Current }
        if (Test-IPv4 -IP $value) { return $value }
        Write-Host 'Invalid IPv4 address. Try again.' -ForegroundColor Red
    }
}

$source = Join-Path $PSScriptRoot 'Client-Agent.ps1'
$targetDir = Join-Path $env:ProgramData 'IIS-DNS-Lab-Fast'
$target = Join-Path $targetDir 'Client-Agent.ps1'
$configTarget = Join-Path $targetDir 'client-config.json'
$taskName = 'IIS DNS Lab Fast Client Agent'

if (-not (Test-Path $source)) {
    throw 'Client-Agent.ps1 not found beside this installer.'
}

if (-not $IisServerIP) { $IisServerIP = Read-IPv4Value -Prompt 'IIS management / Portal IP' }
if (-not (Test-IPv4 -IP $IisServerIP)) { throw 'Invalid IIS Server IP.' }

if (-not $DnsServerIP) { $DnsServerIP = Read-IPv4Value -Prompt 'DNS Server IP' }
if (-not (Test-IPv4 -IP $DnsServerIP)) { throw 'Invalid DNS Server IP.' }

if ($IisServerIP -eq $DnsServerIP) { throw 'IIS Server IP and DNS Server IP must be different.' }

if ($ManagementPrefix -eq 0) {
    while ($true) {
        $rawPrefix = (Read-Host 'Management network prefix [24]').Trim()
        if (-not $rawPrefix) { $ManagementPrefix = 24; break }
        $parsedPrefix = 0
        if ([int]::TryParse($rawPrefix, [ref]$parsedPrefix) -and $parsedPrefix -ge 8 -and $parsedPrefix -le 30) {
            $ManagementPrefix = $parsedPrefix
            break
        }
        Write-Host 'Enter a prefix from 8 to 30.' -ForegroundColor Red
    }
}
if ($ManagementPrefix -lt 8 -or $ManagementPrefix -gt 30) { throw 'ManagementPrefix must be between 8 and 30.' }

if ($PortalPort -eq 0) {
    while ($true) {
        $rawPort = (Read-Host 'Fast Portal TCP port [8787]').Trim()
        if (-not $rawPort) { $PortalPort = 8787; break }
        $parsedPort = 0
        if ([int]::TryParse($rawPort, [ref]$parsedPort) -and $parsedPort -ge 1 -and $parsedPort -le 65535) {
            $PortalPort = $parsedPort
            break
        }
        Write-Host 'Enter a TCP port from 1 to 65535.' -ForegroundColor Red
    }
}
if ($PortalPort -lt 1 -or $PortalPort -gt 65535) { throw 'PortalPort must be between 1 and 65535.' }

if (-not (Test-Path $targetDir)) {
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
}

Copy-Item -Path $source -Destination $target -Force

[pscustomobject][ordered]@{
    iisServerIP = $IisServerIP
    dnsServerIP = $DnsServerIP
    managementPrefix = $ManagementPrefix
    portalPort = $PortalPort
} | ConvertTo-Json -Depth 4 | Set-Content -Path $configTarget -Encoding UTF8

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$target`""

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user

$principal = New-ScheduledTaskPrincipal `
    -UserId $user `
    -LogonType Interactive `
    -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description 'Automatically prepares the VMware lab client and opens the newest deployed IIS website in Microsoft Edge.' `
    -Force |
    Out-Null

Start-ScheduledTask -TaskName $taskName

Write-Host ''
Write-Host 'Client Agent installed and started.' -ForegroundColor Green
Write-Host ("IIS Portal IP     : {0}" -f $IisServerIP)
Write-Host ("DNS Server IP     : {0}" -f $DnsServerIP)
Write-Host ("Management prefix : /{0}" -f $ManagementPrefix)
Write-Host ("Portal            : http://{0}:{1}/" -f $IisServerIP, $PortalPort)
Write-Host ("Task              : {0}" -f $taskName)
Write-Host ("Agent             : {0}" -f $target)
Write-Host ("Client config     : {0}" -f $configTarget)
Write-Host ''
Write-Host 'From now on, a successful server deployment will open Microsoft Edge automatically.'
