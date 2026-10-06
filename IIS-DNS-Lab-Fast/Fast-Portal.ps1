#Requires -Version 5.1
#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$configFile     = Join-Path $PSScriptRoot 'Config.ps1'
$networkFile    = Join-Path $PSScriptRoot 'Network.ps1'
$operationsFile = Join-Path $PSScriptRoot 'Operations.ps1'
$indexFile      = Join-Path $PSScriptRoot 'index.html'
$credentialFile = Join-Path $PSScriptRoot 'dns-credential.xml'
$stateFile      = Join-Path $PSScriptRoot 'deploy-state.json'

foreach ($file in @($configFile, $networkFile, $operationsFile, $indexFile)) {
    if (-not (Test-Path $file)) { throw ("Required file missing: {0}" -f $file) }
}

. $configFile
. $networkFile
. $operationsFile

$labConfig = Get-LabConfig
$ManagementIP = [string]$labConfig.iisManagementIP
$ManagementPrefix = [int]$labConfig.managementPrefix
$DnsServer = [string]$labConfig.dnsServerIP
$PortalPort = [int]$labConfig.portalPort
$PortalUrl = "http://${ManagementIP}:${PortalPort}/"
$PortalOrigin = "http://${ManagementIP}:${PortalPort}"

if (-not (Get-NetIPAddress -AddressFamily IPv4 -IPAddress $ManagementIP -ErrorAction SilentlyContinue)) {
    throw ("Run this portal only on the IIS server containing {0}." -f $ManagementIP)
}

Set-Service WinRM -StartupType Automatic
if ((Get-Service WinRM).Status -ne 'Running') { Start-Service WinRM }

$currentTrusted = (Get-Item WSMan:\localhost\Client\TrustedHosts).Value
$trustedItems = @($currentTrusted -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($DnsServer -notin $trustedItems -and '*' -notin $trustedItems) {
    $newTrusted = if ([string]::IsNullOrWhiteSpace($currentTrusted)) { $DnsServer } else { "$currentTrusted,$DnsServer" }
    Set-Item WSMan:\localhost\Client\TrustedHosts -Value $newTrusted -Force
}

if (-not (Test-Path $credentialFile)) {
    throw @"
DNS credential is not saved yet.

Run once on the IIS server:
    .\Save-DNSCredential.ps1
"@
}

$dnsCredential = Import-Clixml $credentialFile

$dnsPreflight = Invoke-Command `
    -ComputerName $DnsServer `
    -Credential $dnsCredential `
    -Authentication Negotiate `
    -ScriptBlock {
        Import-Module DnsServer -ErrorAction Stop
        Get-DnsServerZone | Select-Object -First 1 | Out-Null
        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            UserName     = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            DnsReady     = $true
        }
    } `
    -ErrorAction Stop

Write-Host ("DNS: {0} ({1}) - READY" -f $dnsPreflight.ComputerName, $DnsServer) -ForegroundColor Green
Write-Host ("DNS account: {0}" -f $dnsPreflight.UserName) -ForegroundColor DarkGreen

$ruleName = "IIS-DNS-Lab-Fast-Portal-$PortalPort"
if (-not (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule `
        -Name $ruleName `
        -DisplayName "IIS DNS Lab Fast Portal TCP $PortalPort" `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalAddress $ManagementIP `
        -LocalPort $PortalPort `
        -RemoteAddress LocalSubnet `
        -Profile Any `
        -Enabled True |
        Out-Null
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($PortalUrl)
$listener.Start()

Write-Host ''
Write-Host '==============================================' -ForegroundColor DarkCyan
Write-Host ' IIS DNS LAB - DYNAMIC FAST DEPLOY' -ForegroundColor Cyan
Write-Host '==============================================' -ForegroundColor DarkCyan
Write-Host ''
Write-Host ("Portal: {0}" -f $PortalUrl) -ForegroundColor Green
Write-Host ("DNS server detected: {0} ({1})" -f $dnsPreflight.ComputerName, $DnsServer) -ForegroundColor Green
Write-Host 'Ctrl+C or close this window to stop.' -ForegroundColor Yellow
Write-Host ''

try {
    $edgeCandidates = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
    )
    $edge = $edgeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($edge) { Start-Process -FilePath $edge -ArgumentList @('--new-window', $PortalUrl) }
    else { Start-Process $PortalUrl }
}
catch { Write-Warning ("Open {0} manually." -f $PortalUrl) }

function Write-JsonResponse {
    param(
        [Parameter(Mandatory=$true)]$Context,
        [Parameter(Mandatory=$true)]$Object,
        [int]$StatusCode = 200
    )

    $json = $Object | ConvertTo-Json -Depth 10 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.Headers['Cache-Control'] = 'no-store'
    $Context.Response.Headers['X-Content-Type-Options'] = 'nosniff'
    $Context.Response.Headers['X-Frame-Options'] = 'DENY'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        try {
            $req = $ctx.Request
            $path = $req.Url.AbsolutePath

            if ($req.HttpMethod -eq 'GET' -and $path -eq '/') {
                $html = [IO.File]::ReadAllText($indexFile, [Text.Encoding]::UTF8)
                $bytes = [Text.Encoding]::UTF8.GetBytes($html)
                $ctx.Response.StatusCode = 200
                $ctx.Response.ContentType = 'text/html; charset=utf-8'
                $ctx.Response.Headers['Cache-Control'] = 'no-store'
                $ctx.Response.Headers['X-Content-Type-Options'] = 'nosniff'
                $ctx.Response.Headers['X-Frame-Options'] = 'DENY'
                $ctx.Response.ContentLength64 = $bytes.Length
                $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            }
            elseif ($req.HttpMethod -eq 'GET' -and $path -eq '/api/health') {
                Write-JsonResponse -Context $ctx -Object @{
                    ok = $true
                    server = $ManagementIP
                    managementPrefix = $ManagementPrefix
                    dnsServer = $DnsServer
                    dnsComputerName = [string]$dnsPreflight.ComputerName
                    dnsAccount = [string]$dnsPreflight.UserName
                    time = (Get-Date).ToString('o')
                }
            }
            elseif ($req.HttpMethod -eq 'GET' -and $path -eq '/api/deploy/current') {
                $deployment = $null
                if (Test-Path $stateFile) {
                    try { $deployment = Get-Content $stateFile -Raw | ConvertFrom-Json } catch { $deployment = $null }
                }
                Write-JsonResponse -Context $ctx -Object @{ ok=$true; deployment=$deployment }
            }
            elseif ($req.HttpMethod -eq 'POST' -and $path -eq '/api/deploy') {
                $origin = [string]$req.Headers['Origin']
                if (-not [string]::IsNullOrWhiteSpace($origin) -and $origin -ne $PortalOrigin) { throw 'Invalid request origin.' }
                if ($req.ContentType -notmatch '^application/json') { throw 'Expected application/json.' }
                if ($req.ContentLength64 -lt 0 -or $req.ContentLength64 -gt 65536) { throw 'Request body must be 64 KB or smaller.' }

                $reader = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
                try { $raw = $reader.ReadToEnd() } finally { $reader.Dispose() }
                $data = $raw | ConvertFrom-Json

                $deployment = Invoke-FastDeploy -Data $data -DnsCredential $dnsCredential -DnsServer $DnsServer -ManagementIP $ManagementIP
                $deployment | ConvertTo-Json -Depth 10 | Set-Content -Path $stateFile -Encoding UTF8

                Write-JsonResponse -Context $ctx -Object @{
                    ok = $true
                    message = 'Deployment completed.'
                    deployment = $deployment
                }
            }
            else {
                Write-JsonResponse -Context $ctx -StatusCode 404 -Object @{ ok=$false; message='Not found.' }
            }
        }
        catch {
            try {
                Write-JsonResponse -Context $ctx -StatusCode 400 -Object @{ ok=$false; message=$_.Exception.Message }
            }
            catch {}
        }
        finally { try { $ctx.Response.Close() } catch {} }
    }
}
finally {
    try { $listener.Close() } catch {}
    $dnsCredential = $null
}
