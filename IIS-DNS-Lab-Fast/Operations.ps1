#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

function ConvertTo-LabSafeName {
    param([Parameter(Mandatory=$true)][string]$Value)

    $safe = $Value -replace '[^A-Za-z0-9._-]', '_'
    if ([string]::IsNullOrWhiteSpace($safe)) {
        throw 'Invalid site name.'
    }

    return $safe
}

function Test-LabTcpPort {
    param(
        [Parameter(Mandatory=$true)][string]$ComputerName,
        [Parameter(Mandatory=$true)][int]$Port,
        [int]$TimeoutMs = 800
    )

    $client = New-Object System.Net.Sockets.TcpClient

    try {
        $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            return $false
        }
        $client.EndConnect($async)
        return $true
    }
    catch {
        return $false
    }
    finally {
        try { $client.Close() } catch {}
    }
}

function Set-LabWebsiteContent {
    param(
        [Parameter(Mandatory=$true)][string]$SitePath,
        [string]$Title,
        [string]$Content
    )

    if (-not (Test-Path $SitePath)) {
        New-Item -ItemType Directory -Path $SitePath -Force | Out-Null
    }

    if ([string]::IsNullOrWhiteSpace($Title)) {
        $Title = 'IIS Lab Website'
    }

    if ($null -eq $Content) {
        $Content = ''
    }

    $safeTitle = [System.Net.WebUtility]::HtmlEncode([string]$Title)
    $safeContent = [System.Net.WebUtility]::HtmlEncode([string]$Content)
    $safeContent = $safeContent -replace "`r`n", '<br>' -replace "`n", '<br>'

    $html = @"
<!doctype html>
<html lang="vi">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>$safeTitle</title>
<style>
*{box-sizing:border-box}html,body{margin:0;min-height:100%}
body{min-height:100vh;display:flex;align-items:center;justify-content:center;padding:28px;background:#f2f6fb;color:#172740;font-family:"Segoe UI",Arial,sans-serif}
main{width:min(920px,100%);background:#fff;border:1px solid #dfe7f1;border-radius:18px;padding:44px;box-shadow:0 18px 50px rgba(0,0,0,.09)}
.badge{display:inline-block;background:#e8f1ff;color:#1557b0;padding:7px 12px;border-radius:999px;font-size:13px;font-weight:700;margin-bottom:18px}
h1{margin:0 0 22px;font-size:36px;line-height:1.25}.content{font-size:18px;line-height:1.8;word-break:break-word}
footer{margin-top:34px;padding-top:18px;border-top:1px solid #e4e9f0;color:#6b7280;font-size:13px}
.dot{display:inline-block;width:9px;height:9px;border-radius:50%;background:#1ba34a;margin-right:7px}
</style>
</head>
<body>
<main>
<div class="badge">IIS WEBSITE</div>
<h1>$safeTitle</h1>
<div class="content">$safeContent</div>
<footer><span class="dot"></span>Microsoft IIS / Windows Server</footer>
</main>
</body>
</html>
"@

    $indexFile = Join-Path $SitePath 'index.html'
    Set-Content -Path $indexFile -Value $html -Encoding UTF8 -Force
    return $indexFile
}

function Get-LabSiteBinding {
    param(
        [Parameter(Mandatory=$true)][string]$SiteName,
        [Parameter(Mandatory=$true)][ValidateSet('http','https')][string]$Protocol,
        [Parameter(Mandatory=$true)][string]$IPAddress,
        [Parameter(Mandatory=$true)][int]$Port,
        [string]$HostHeader = ''
    )

    $expected = '{0}:{1}:{2}' -f $IPAddress, $Port, $HostHeader

    return Get-WebBinding -Name $SiteName -Protocol $Protocol -ErrorAction SilentlyContinue |
        Where-Object bindingInformation -eq $expected |
        Select-Object -First 1
}

function Remove-LabConflictingBinding {
    param(
        [Parameter(Mandatory=$true)][string]$CurrentSite,
        [Parameter(Mandatory=$true)][ValidateSet('http','https')][string]$Protocol,
        [Parameter(Mandatory=$true)][string]$IPAddress,
        [Parameter(Mandatory=$true)][int]$Port,
        [string]$HostHeader = ''
    )

    $expected = '{0}:{1}:{2}' -f $IPAddress, $Port, $HostHeader

    foreach ($site in Get-Website) {
        if ($site.Name -eq $CurrentSite) { continue }

        $matches = @(
            Get-WebBinding -Name $site.Name -Protocol $Protocol -ErrorAction SilentlyContinue |
            Where-Object bindingInformation -eq $expected
        )

        foreach ($match in $matches) {
            Remove-WebBinding `
                -Name $site.Name `
                -Protocol $Protocol `
                -IPAddress $IPAddress `
                -Port $Port `
                -HostHeader $HostHeader `
                -ErrorAction SilentlyContinue
        }
    }
}

function Get-OrCreate-LabCertificate {
    param(
        [Parameter(Mandatory=$true)][string]$IPAddress,
        [string]$Hostname
    )

    if ([string]::IsNullOrWhiteSpace($Hostname)) {
        $identity = $IPAddress
        $subject  = "CN=$IPAddress"
        $san      = "2.5.29.17={text}IPAddress=$IPAddress"
    }
    else {
        $identity = "$Hostname :: $IPAddress"
        $subject  = "CN=$Hostname"
        $san      = "2.5.29.17={text}DNS=$Hostname&IPAddress=$IPAddress"
    }

    $friendlyName = "IIS-DNS-Lab Fast Dual :: $identity"

    $existing = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
        Where-Object {
            $_.HasPrivateKey -and
            $_.NotAfter -gt (Get-Date).AddDays(30) -and
            $_.FriendlyName -eq $friendlyName
        } |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1

    if ($existing) { return $existing }

    $cert = New-SelfSignedCertificate `
        -Subject $subject `
        -CertStoreLocation Cert:\LocalMachine\My `
        -Type SSLServerAuthentication `
        -KeyAlgorithm RSA `
        -KeyLength 2048 `
        -NotAfter (Get-Date).AddYears(3) `
        -TextExtension @($san)

    try { $cert.FriendlyName = $friendlyName } catch {}
    return $cert
}

function Sync-LabSiteBindings {
    param(
        [Parameter(Mandatory=$true)][string]$SiteName,
        [Parameter(Mandatory=$true)][string]$IPAddress,
        [string]$Hostname,
        [bool]$HttpEnabled,
        [int]$HttpPort,
        [bool]$HttpsEnabled,
        [int]$HttpsPort
    )

    # Intentionally use blank host headers. This lets the same site work by both
    # direct IP and DNS hostname on the selected IP/port.
    $desired = @()

    if ($HttpEnabled) {
        $desired += [pscustomobject]@{ Protocol='http'; IP=$IPAddress; Port=$HttpPort; Host='' }
    }

    if ($HttpsEnabled) {
        $desired += [pscustomobject]@{ Protocol='https'; IP=$IPAddress; Port=$HttpsPort; Host='' }
    }

    foreach ($binding in @(Get-WebBinding -Name $SiteName -ErrorAction SilentlyContinue)) {
        if ($binding.protocol -notin @('http','https')) { continue }

        $keep = $false
        foreach ($want in $desired) {
            $expected = '{0}:{1}:{2}' -f $want.IP, $want.Port, $want.Host
            if ($binding.protocol -eq $want.Protocol -and $binding.bindingInformation -eq $expected) {
                $keep = $true
                break
            }
        }

        if (-not $keep) {
            $parts = $binding.bindingInformation -split ':', 3
            $bindIP = $parts[0]
            $bindPort = [int]$parts[1]
            $bindHost = if ($parts.Count -ge 3) { $parts[2] } else { '' }

            Remove-WebBinding `
                -Name $SiteName `
                -Protocol $binding.protocol `
                -IPAddress $bindIP `
                -Port $bindPort `
                -HostHeader $bindHost `
                -ErrorAction SilentlyContinue
        }
    }

    foreach ($want in $desired) {
        Remove-LabConflictingBinding `
            -CurrentSite $SiteName `
            -Protocol $want.Protocol `
            -IPAddress $want.IP `
            -Port $want.Port `
            -HostHeader ''

        $binding = Get-LabSiteBinding `
            -SiteName $SiteName `
            -Protocol $want.Protocol `
            -IPAddress $want.IP `
            -Port $want.Port `
            -HostHeader ''

        if (-not $binding) {
            if ($want.Protocol -eq 'https') {
                New-WebBinding `
                    -Name $SiteName `
                    -Protocol https `
                    -IPAddress $want.IP `
                    -Port $want.Port `
                    -HostHeader '' `
                    -SslFlags 0 |
                    Out-Null
            }
            else {
                New-WebBinding `
                    -Name $SiteName `
                    -Protocol http `
                    -IPAddress $want.IP `
                    -Port $want.Port `
                    -HostHeader '' |
                    Out-Null
            }
        }
    }
}

function Ensure-LabFirewallPort {
    param(
        [Parameter(Mandatory=$true)][int]$Port,
        [Parameter(Mandatory=$true)][ValidateSet('HTTP','HTTPS')][string]$Kind
    )

    $name = "IIS-DNS-Lab-Fast-$Kind-$Port"
    $rule = Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue

    if (-not $rule) {
        New-NetFirewallRule `
            -Name $name `
            -DisplayName "IIS DNS Lab Fast $Kind TCP $Port" `
            -Direction Inbound `
            -Action Allow `
            -Protocol TCP `
            -LocalPort $Port `
            -Profile Any `
            -Enabled True |
            Out-Null
    }
    else {
        Set-NetFirewallRule -Name $name -Enabled True -Action Allow -ErrorAction SilentlyContinue | Out-Null
    }
}

function Invoke-LabDnsChange {
    param(
        [Parameter(Mandatory=$true)][string]$Hostname,
        [Parameter(Mandatory=$true)][string]$IPAddress,
        [Parameter(Mandatory=$true)]$Credential,
        [Parameter(Mandatory=$true)][string]$DnsServer
    )

    if ([string]::IsNullOrWhiteSpace($Hostname)) {
        return [pscustomobject]@{ skipped=$true; zone=''; record=''; message='DNS skipped because hostname is empty.' }
    }

    $scriptBlock = {
        param($Fqdn, $IP)

        Import-Module DnsServer -ErrorAction Stop
        $Fqdn = $Fqdn.Trim().TrimEnd('.').ToLowerInvariant()

        $zones = @(Get-DnsServerZone -ErrorAction Stop | Select-Object -ExpandProperty ZoneName)
        $matchingZone = $zones |
            Where-Object {
                $z = $_.TrimEnd('.').ToLowerInvariant()
                $Fqdn -eq $z -or $Fqdn.EndsWith(".$z")
            } |
            Sort-Object Length -Descending |
            Select-Object -First 1

        if ($matchingZone) {
            $zone = $matchingZone.TrimEnd('.')
            if ($Fqdn -eq $zone.ToLowerInvariant()) { $record = '@' }
            else { $record = $Fqdn.Substring(0, $Fqdn.Length - $zone.Length - 1) }
        }
        else {
            $labels = @($Fqdn -split '\.')
            if ($labels.Count -lt 2) {
                $zone = $Fqdn
                $record = '@'
            }
            else {
                $zone = ($labels[($labels.Count - 2)..($labels.Count - 1)] -join '.')
                if ($labels.Count -eq 2) { $record = '@' }
                else { $record = ($labels[0..($labels.Count - 3)] -join '.') }
            }

            if (-not (Get-DnsServerZone -Name $zone -ErrorAction SilentlyContinue)) {
                Add-DnsServerPrimaryZone `
                    -Name $zone `
                    -ZoneFile "$zone.dns" `
                    -DynamicUpdate None `
                    -ErrorAction Stop
            }
        }

        $existing = @(
            Get-DnsServerResourceRecord -ZoneName $zone -Name $record -ErrorAction SilentlyContinue |
            Where-Object RecordType -eq 'A'
        )

        $same = @($existing | Where-Object {
            try { $_.RecordData.IPv4Address.IPAddressToString -eq $IP } catch { $false }
        })

        if ($same.Count -eq 1 -and $existing.Count -eq 1) {
            return [pscustomobject]@{ zone=$zone; record=$record; message="DNS already correct: $Fqdn -> $IP" }
        }

        foreach ($r in $existing) {
            Remove-DnsServerResourceRecord -ZoneName $zone -InputObject $r -Force -ErrorAction Stop
        }

        Add-DnsServerResourceRecordA -ZoneName $zone -Name $record -IPv4Address $IP -ErrorAction Stop
        [pscustomobject]@{ zone=$zone; record=$record; message="DNS configured: $Fqdn -> $IP" }
    }

    return Invoke-Command `
        -ComputerName $DnsServer `
        -Credential $Credential `
        -Authentication Negotiate `
        -ScriptBlock $scriptBlock `
        -ArgumentList $Hostname, $IPAddress `
        -ErrorAction Stop
}

function New-LabUrl {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('http','https')][string]$Protocol,
        [Parameter(Mandatory=$true)][string]$TargetHost,
        [Parameter(Mandatory=$true)][int]$Port
    )

    $defaultPort = if ($Protocol -eq 'https') { 443 } else { 80 }
    if ($Port -eq $defaultPort) { return ("{0}://{1}/" -f $Protocol, $TargetHost) }
    return ("{0}://{1}:{2}/" -f $Protocol, $TargetHost, $Port)
}

function Invoke-FastDeploy {
    param(
        [Parameter(Mandatory=$true)]$Data,
        [Parameter(Mandatory=$true)]$DnsCredential,
        [Parameter(Mandatory=$true)][string]$DnsServer,
        [Parameter(Mandatory=$true)][string]$ManagementIP
    )

    Import-Module WebAdministration -ErrorAction Stop

    $siteName = ([string]$Data.site).Trim()
    $ip = ([string]$Data.ip).Trim()
    $hostname = ([string]$Data.hostname).Trim().TrimEnd('.')
    $title = [string]$Data.title
    $content = [string]$Data.content

    if ($siteName -notmatch '^[A-Za-z0-9._-]{1,64}$') {
        throw 'Site name may contain only letters, numbers, dot, underscore, and hyphen.'
    }

    $prefix = 0
    if (-not [int]::TryParse([string]$Data.prefix, [ref]$prefix)) { throw 'Invalid prefix.' }

    $httpEnabled  = [bool]$Data.httpEnabled
    $httpsEnabled = [bool]$Data.httpsEnabled
    if (-not $httpEnabled -and -not $httpsEnabled) { throw 'Enable HTTP, HTTPS, or both.' }

    $httpPort = 80
    $httpsPort = 443
    if ($httpEnabled -and -not [int]::TryParse([string]$Data.httpPort, [ref]$httpPort)) { throw 'Invalid HTTP port.' }
    if ($httpsEnabled -and -not [int]::TryParse([string]$Data.httpsPort, [ref]$httpsPort)) { throw 'Invalid HTTPS port.' }

    foreach ($p in @($httpPort, $httpsPort)) {
        if ($p -lt 1 -or $p -gt 65535) { throw ("Invalid TCP port: {0}" -f $p) }
    }

    Get-LabSubnet -IP $ip -Prefix $prefix | Out-Null
    if ($ip -eq $DnsServer) { throw ("{0} is reserved for the DNS server." -f $DnsServer) }

    $existingIP = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $ip -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existingIP) {
        if ($existingIP.AddressState -ne 'Preferred') { throw ("IP {0} exists but its state is {1}." -f $ip, $existingIP.AddressState) }
        $networkMessage = "IP already ready: $ip/$($existingIP.PrefixLength)"
    }
    else {
        $networkMessage = Add-LabAddress -Index 0 -IP $ip -Prefix $prefix -Server $true -ManagementIP $ManagementIP -DnsServer $DnsServer
    }

    $safeSite = ConvertTo-LabSafeName $siteName
    $sitePath = Join-Path 'C:\IIS-DNS-Sites' $safeSite
    if (-not (Test-Path $sitePath)) { New-Item -ItemType Directory -Path $sitePath -Force | Out-Null }

    if ([string]::IsNullOrWhiteSpace($title)) { $title = if ($hostname) { $hostname } else { $siteName } }
    $indexFile = Set-LabWebsiteContent -SitePath $sitePath -Title $title -Content $content

    Set-Service W3SVC -StartupType Automatic
    if ((Get-Service W3SVC).Status -ne 'Running') { Start-Service W3SVC }

    if (-not (Test-Path IIS:\AppPools\DefaultAppPool)) { New-WebAppPool -Name DefaultAppPool | Out-Null }

    $site = Get-Website -Name $siteName -ErrorAction SilentlyContinue
    if (-not $site) {
        $bootstrapPort = 65534
        $bootstrapHost = "bootstrap-$safeSite.local"

        Remove-LabConflictingBinding -CurrentSite $siteName -Protocol http -IPAddress '127.0.0.1' -Port $bootstrapPort -HostHeader $bootstrapHost
        New-Website `
            -Name $siteName `
            -Port $bootstrapPort `
            -IPAddress '127.0.0.1' `
            -HostHeader $bootstrapHost `
            -PhysicalPath $sitePath `
            -ApplicationPool DefaultAppPool `
            -Force |
            Out-Null
    }
    else {
        Set-ItemProperty "IIS:\Sites\$siteName" -Name physicalPath -Value $sitePath
    }

    Sync-LabSiteBindings `
        -SiteName $siteName `
        -IPAddress $ip `
        -Hostname $hostname `
        -HttpEnabled $httpEnabled `
        -HttpPort $httpPort `
        -HttpsEnabled $httpsEnabled `
        -HttpsPort $httpsPort

    $certificateThumbprint = ''
    if ($httpsEnabled) {
        $cert = Get-OrCreate-LabCertificate -IPAddress $ip -Hostname $hostname

        $httpsBinding = Get-LabSiteBinding `
            -SiteName $siteName `
            -Protocol https `
            -IPAddress $ip `
            -Port $httpsPort `
            -HostHeader ''

        if (-not $httpsBinding) { throw 'HTTPS binding was not created.' }

        $httpsBinding.AddSslCertificate($cert.Thumbprint, 'My')
        $certificateThumbprint = $cert.Thumbprint
        Ensure-LabFirewallPort -Port $httpsPort -Kind HTTPS
    }

    if ($httpEnabled) { Ensure-LabFirewallPort -Port $httpPort -Kind HTTP }

    $poolState = Get-WebAppPoolState -Name DefaultAppPool -ErrorAction SilentlyContinue
    if ($poolState -and $poolState.Value -ne 'Started') { Start-WebAppPool -Name DefaultAppPool }

    $siteState = (Get-Website -Name $siteName).State
    if ($siteState -ne 'Started') { Start-Website -Name $siteName }

    $dnsResult = [pscustomobject]@{ skipped=$true; zone=''; record=''; message='DNS skipped.' }
    if (-not [string]::IsNullOrWhiteSpace($hostname)) {
        $dnsResult = Invoke-LabDnsChange -Hostname $hostname -IPAddress $ip -Credential $DnsCredential -DnsServer $DnsServer
    }

    $httpOK = -not $httpEnabled
    $httpsOK = -not $httpsEnabled

    for ($i = 0; $i -lt 20; $i++) {
        if ($httpEnabled -and -not $httpOK) { $httpOK = Test-LabTcpPort -ComputerName $ip -Port $httpPort -TimeoutMs 250 }
        if ($httpsEnabled -and -not $httpsOK) { $httpsOK = Test-LabTcpPort -ComputerName $ip -Port $httpsPort -TimeoutMs 250 }
        if ($httpOK -and $httpsOK) { break }
        Start-Sleep -Milliseconds 100
    }

    if (-not $httpOK) { throw ("HTTP {0}:{1} did not become ready." -f $ip, $httpPort) }
    if (-not $httpsOK) { throw ("HTTPS {0}:{1} did not become ready." -f $ip, $httpsPort) }

    $preferredHost = if ($hostname) { $hostname } else { $ip }
    if ($httpsEnabled) {
        $preferredUrl = New-LabUrl -Protocol https -TargetHost $preferredHost -Port $httpsPort
        $ipUrl = New-LabUrl -Protocol https -TargetHost $ip -Port $httpsPort
        $hostnameUrl = if ($hostname) { New-LabUrl -Protocol https -TargetHost $hostname -Port $httpsPort } else { '' }
    }
    else {
        $preferredUrl = New-LabUrl -Protocol http -TargetHost $preferredHost -Port $httpPort
        $ipUrl = New-LabUrl -Protocol http -TargetHost $ip -Port $httpPort
        $hostnameUrl = if ($hostname) { New-LabUrl -Protocol http -TargetHost $hostname -Port $httpPort } else { '' }
    }

    [pscustomobject][ordered]@{
        id                    = [guid]::NewGuid().ToString('N')
        createdAt             = (Get-Date).ToString('o')
        site                  = $siteName
        sitePath              = $sitePath
        ip                    = $ip
        prefix                = $prefix
        hostname              = $hostname
        title                 = $title
        httpEnabled           = $httpEnabled
        httpPort              = $httpPort
        httpsEnabled          = $httpsEnabled
        httpsPort             = $httpsPort
        certificateThumbprint = $certificateThumbprint
        dnsZone               = [string]$dnsResult.zone
        dnsRecord             = [string]$dnsResult.record
        dnsMessage            = [string]$dnsResult.message
        networkMessage        = $networkMessage
        indexFile             = $indexFile
        preferredUrl          = $preferredUrl
        ipUrl                 = $ipUrl
        hostnameUrl           = $hostnameUrl
        httpReady             = $httpOK
        httpsReady            = $httpsOK
    }
}
