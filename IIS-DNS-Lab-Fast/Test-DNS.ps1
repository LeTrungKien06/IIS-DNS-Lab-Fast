#Requires -Version 5.1
#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

. (Join-Path $PSScriptRoot 'Config.ps1')
$labConfig = Get-LabConfig
$DnsServer = [string]$labConfig.dnsServerIP
$credentialFile = Join-Path $PSScriptRoot 'dns-credential.xml'

if (-not (Test-Path $credentialFile)) {
    throw 'dns-credential.xml is missing. Run .\Save-DNSCredential.ps1 first.'
}

$credential = Import-Clixml $credentialFile

Write-Host ''
Write-Host 'Testing DNS server...' -ForegroundColor Cyan
Write-Host ("DNS IP: {0}" -f $DnsServer)

Test-WSMan $DnsServer -ErrorAction Stop | Out-Null

$result = Invoke-Command `
    -ComputerName $DnsServer `
    -Credential $credential `
    -Authentication Negotiate `
    -ScriptBlock {
        Import-Module DnsServer -ErrorAction Stop
        $zones = @(Get-DnsServerZone -ErrorAction Stop)
        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            UserName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            ZoneCount = $zones.Count
        }
    } `
    -ErrorAction Stop

Write-Host ''
Write-Host 'DNS CHECK: READY' -ForegroundColor Green
Write-Host ("Computer Name : {0}" -f $result.ComputerName)
Write-Host ("IP            : {0}" -f $DnsServer)
Write-Host ("Remote User   : {0}" -f $result.UserName)
Write-Host ("DNS Zones     : {0}" -f $result.ZoneCount)
Write-Host ''
