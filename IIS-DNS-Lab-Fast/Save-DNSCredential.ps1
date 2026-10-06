#Requires -Version 5.1
#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$configFile = Join-Path $PSScriptRoot 'Config.ps1'
if (-not (Test-Path $configFile)) { throw 'Config.ps1 is missing.' }
. $configFile

$labConfig = Get-LabConfig
$DnsServer = [string]$labConfig.dnsServerIP
$credentialFile = Join-Path $PSScriptRoot 'dns-credential.xml'

Write-Host ''
Write-Host 'ONE-TIME DNS CREDENTIAL SETUP' -ForegroundColor Cyan
Write-Host ("DNS IP: {0}" -f $DnsServer) -ForegroundColor Yellow
Write-Host 'The DNS computer name can be anything.' -ForegroundColor Yellow
Write-Host 'Use an administrator account that is valid on that DNS server.' -ForegroundColor Yellow
Write-Host 'Example: DNS01\Administrator' -ForegroundColor DarkGray
Write-Host ''

Set-Service WinRM -StartupType Automatic
if ((Get-Service WinRM).Status -ne 'Running') { Start-Service WinRM }

$currentTrusted = (Get-Item WSMan:\localhost\Client\TrustedHosts).Value
$trustedItems = @($currentTrusted -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($DnsServer -notin $trustedItems -and '*' -notin $trustedItems) {
    $newTrusted = if ([string]::IsNullOrWhiteSpace($currentTrusted)) { $DnsServer } else { "$currentTrusted,$DnsServer" }
    Set-Item WSMan:\localhost\Client\TrustedHosts -Value $newTrusted -Force
}

Write-Host 'Checking WinRM...' -ForegroundColor Cyan
Test-WSMan $DnsServer -ErrorAction Stop | Out-Null

$credential = Get-Credential -Message "Enter an administrator account for DNS server $DnsServer. Example: DNS01\Administrator"
if (-not $credential) { throw 'DNS credential is required.' }

Write-Host 'Testing credential and DNS Server role...' -ForegroundColor Cyan
$remote = Invoke-Command `
    -ComputerName $DnsServer `
    -Credential $credential `
    -Authentication Negotiate `
    -ScriptBlock {
        Import-Module DnsServer -ErrorAction Stop
        Get-DnsServerZone | Select-Object -First 1 | Out-Null
        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            UserName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            DnsReady = $true
        }
    } `
    -ErrorAction Stop

$credential | Export-Clixml -Path $credentialFile

Write-Host ''
Write-Host 'DNS CREDENTIAL SAVED' -ForegroundColor Green
Write-Host ("DNS IP        : {0}" -f $DnsServer)
Write-Host ("DNS computer  : {0}" -f $remote.ComputerName)
Write-Host ("Remote user   : {0}" -f $remote.UserName)
Write-Host ("Credential    : {0}" -f $credential.UserName)
Write-Host ("Saved to      : {0}" -f $credentialFile)
Write-Host ''
Write-Host 'This file is DPAPI-protected. Do not upload it to GitHub or copy it to another computer.' -ForegroundColor Yellow
