#Requires -Version 5.1
#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

$StateDir = Join-Path $env:ProgramData 'IIS-DNS-Lab-Fast'
$StateFile = Join-Path $StateDir 'agent-state.json'
$ConfigFile = Join-Path $StateDir 'client-config.json'
$HostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
$HostsTag = '# IIS-DNS-Lab-Fast'

if (-not (Test-Path $StateDir)) {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
}

if (-not (Test-Path $ConfigFile)) {
    throw 'client-config.json is missing. Run Install-ClientAgent.ps1 again.'
}

$config = Get-Content $ConfigFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
$IisServerIP = ([string]$config.iisServerIP).Trim()
$DnsServerIP = ([string]$config.dnsServerIP).Trim()
$ManagementPrefix = [int]$config.managementPrefix
$PortalPort = [int]$config.portalPort
$PortalBase = "http://${IisServerIP}:${PortalPort}"

function ConvertTo-UInt32IPv4 {
    param([Parameter(Mandatory=$true)][string]$IP)

    $addr = [Net.IPAddress]::Parse($IP)
    $b = $addr.GetAddressBytes()

    return [uint64]$b[0] * 16777216 +
           [uint64]$b[1] * 65536 +
           [uint64]$b[2] * 256 +
           [uint64]$b[3]
}

function ConvertFrom-UInt32IPv4 {
    param([Parameter(Mandatory=$true)][uint64]$Value)

    return '{0}.{1}.{2}.{3}' -f `
        (($Value -shr 24) -band 255),
        (($Value -shr 16) -band 255),
        (($Value -shr 8) -band 255),
        ($Value -band 255)
}

function Get-SubnetRange {
    param(
        [Parameter(Mandatory=$true)][string]$IP,
        [Parameter(Mandatory=$true)][int]$Prefix
    )

    $number = ConvertTo-UInt32IPv4 $IP
    $size = [uint64][Math]::Pow(2, 32 - $Prefix)
    $first = [uint64]([Math]::Floor($number / $size) * $size)
    $last = $first + $size - 1

    [pscustomobject]@{
        Number = $number
        First = $first
        Last = $last
    }
}

function Test-SameSubnet {
    param(
        [Parameter(Mandatory=$true)][string]$IP1,
        [Parameter(Mandatory=$true)][string]$IP2,
        [Parameter(Mandatory=$true)][int]$Prefix
    )

    $a = Get-SubnetRange -IP $IP1 -Prefix $Prefix
    $b = Get-SubnetRange -IP $IP2 -Prefix $Prefix
    return $a.First -eq $b.First
}

function Resolve-ManagementAdapter {
    $candidates = @()

    foreach ($adapter in Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object Status -eq 'Up') {

        if (
            $adapter.Name -notmatch 'VMware|VMnet' -and
            $adapter.InterfaceDescription -notmatch 'VMware|VMnet'
        ) {
            continue
        }

        $interface = Get-NetIPInterface `
            -InterfaceIndex $adapter.ifIndex `
            -AddressFamily IPv4 `
            -ErrorAction SilentlyContinue

        if (-not $interface -or $interface.Dhcp -ne 'Disabled') {
            continue
        }

        $ips = @(
            Get-NetIPAddress `
                -InterfaceIndex $adapter.ifIndex `
                -AddressFamily IPv4 `
                -ErrorAction SilentlyContinue
        )

        $matchesManagementSubnet = $false
        foreach ($address in $ips) {
            try {
                if (Test-SameSubnet -IP1 $address.IPAddress -IP2 $IisServerIP -Prefix $ManagementPrefix) {
                    $matchesManagementSubnet = $true
                    break
                }
            }
            catch {}
        }

        if ($matchesManagementSubnet) {
            $candidates += $adapter
        }
    }

    if ($candidates.Count -eq 0) {
        throw ("No safe VMware adapter was found in the IIS management subnet for {0}/{1}." -f $IisServerIP, $ManagementPrefix)
    }

    return $candidates | Select-Object -First 1
}

function Find-FreeClientIP {
    param(
        [Parameter(Mandatory=$true)][string]$ServerIP,
        [Parameter(Mandatory=$true)][int]$Prefix
    )

    $range = Get-SubnetRange -IP $ServerIP -Prefix $Prefix
    $existing = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty IPAddress)

    $reserved = @(
        $ServerIP,
        $IisServerIP,
        $DnsServerIP
    )

    # Try up to 128 nearby host addresses, then fall back near the beginning.
    for ($offset = 1; $offset -le 128; $offset++) {
        $candidateNumber = $range.Number + $offset

        if ($candidateNumber -ge $range.Last) {
            $candidateNumber = $range.First + $offset
        }

        if ($candidateNumber -le $range.First -or $candidateNumber -ge $range.Last) {
            continue
        }

        $candidate = ConvertFrom-UInt32IPv4 $candidateNumber

        if ($candidate -in $existing -or $candidate -in $reserved) {
            continue
        }

        if (Test-Connection -ComputerName $candidate -Count 1 -Quiet -ErrorAction SilentlyContinue) {
            continue
        }

        return $candidate
    }

    throw 'Unable to find a free client IP in the website subnet.'
}

function Ensure-ClientRouteAddress {
    param(
        [Parameter(Mandatory=$true)]$Adapter,
        [Parameter(Mandatory=$true)][string]$ServerIP,
        [Parameter(Mandatory=$true)][int]$Prefix,
        $PreviousState
    )

    $previousManagedIP = ''
    if ($PreviousState -and $PreviousState.managedClientIP) {
        $previousManagedIP = [string]$PreviousState.managedClientIP
    }

    # If the previous agent-managed IP belongs to another website subnet,
    # remove only that exact IP. Never remove unrelated/manual addresses.
    if ($previousManagedIP) {
        $reusePrevious = $false

        try {
            $reusePrevious = Test-SameSubnet `
                -IP1 $previousManagedIP `
                -IP2 $ServerIP `
                -Prefix $Prefix
        }
        catch {}

        if (-not $reusePrevious) {
            $old = Get-NetIPAddress `
                -InterfaceIndex $Adapter.ifIndex `
                -IPAddress $previousManagedIP `
                -AddressFamily IPv4 `
                -ErrorAction SilentlyContinue

            if ($old) {
                try {
                    $old | Remove-NetIPAddress -Confirm:$false -ErrorAction Stop
                }
                catch {}
            }

            $previousManagedIP = ''
        }
    }

    $addresses = @(
        Get-NetIPAddress `
            -InterfaceIndex $Adapter.ifIndex `
            -AddressFamily IPv4 `
            -ErrorAction SilentlyContinue
    )

    foreach ($address in $addresses) {
        try {
            if (Test-SameSubnet -IP1 $address.IPAddress -IP2 $ServerIP -Prefix $Prefix) {
                return [pscustomobject]@{
                    IP = $address.IPAddress
                    Managed = ($previousManagedIP -and $address.IPAddress -eq $previousManagedIP)
                }
            }
        }
        catch {}
    }

    $clientIP = Find-FreeClientIP -ServerIP $ServerIP -Prefix $Prefix

    New-NetIPAddress `
        -InterfaceIndex $Adapter.ifIndex `
        -IPAddress $clientIP `
        -PrefixLength $Prefix `
        -AddressFamily IPv4 `
        -SkipAsSource $true `
        -ErrorAction Stop |
        Out-Null

    for ($i = 0; $i -lt 12; $i++) {
        $current = Get-NetIPAddress `
            -InterfaceIndex $Adapter.ifIndex `
            -IPAddress $clientIP `
            -AddressFamily IPv4 `
            -ErrorAction Stop

        if ($current.AddressState -eq 'Preferred') {
            return [pscustomobject]@{
                IP = $clientIP
                Managed = $true
            }
        }

        Start-Sleep -Milliseconds 200
    }

    throw "Client IP $clientIP did not become Preferred."
}

function Set-LabHostsEntry {
    param(
        [string]$Hostname,
        [string]$IPAddress
    )

    $lines = @()
    if (Test-Path $HostsFile) {
        $lines = @(Get-Content $HostsFile -ErrorAction SilentlyContinue)
    }

    $filtered = @($lines | Where-Object { $_ -notmatch [regex]::Escape($HostsTag) })
    $filtered | Set-Content -Path $HostsFile -Encoding ASCII

    if (-not [string]::IsNullOrWhiteSpace($Hostname)) {
        Add-Content `
            -Path $HostsFile `
            -Value "$IPAddress`t$Hostname`t$HostsTag" `
            -Encoding ASCII
    }

    try { Clear-DnsClientCache } catch {}
}

function Test-TcpFast {
    param(
        [string]$HostName,
        [int]$Port,
        [int]$TimeoutMs = 350
    )

    $client = New-Object Net.Sockets.TcpClient

    try {
        $async = $client.BeginConnect($HostName, $Port, $null, $null)
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

function Trust-LabHttpsCertificate {
    param(
        [Parameter(Mandatory=$true)][string]$ServerIP,
        [Parameter(Mandatory=$true)][int]$Port,
        [string]$Hostname
    )

    $targetName = if ([string]::IsNullOrWhiteSpace($Hostname)) { $ServerIP } else { $Hostname }

    $tcp = $null
    $ssl = $null
    $root = $null

    try {
        $tcp = New-Object Net.Sockets.TcpClient
        $tcp.Connect($ServerIP, $Port)

        $callback = {
            param($sender, $certificate, $chain, $errors)
            return $true
        }

        $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, $callback)
        $ssl.AuthenticateAsClient($targetName)

        $remote = New-Object Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)

        $san = ''
        $sanExtension = $remote.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' } | Select-Object -First 1
        if ($sanExtension) {
            try { $san = $sanExtension.Format($false) } catch {}
        }

        $simpleName = $remote.GetNameInfo(
            [Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
            $false
        )

        $nameMatches =
            $simpleName -eq $targetName -or
            $san -match [regex]::Escape($targetName)

        if (-not $nameMatches) {
            throw "Certificate name mismatch. Expected $targetName."
        }

        $root = New-Object Security.Cryptography.X509Certificates.X509Store('Root','LocalMachine')
        $root.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)

        $already = @($root.Certificates | Where-Object Thumbprint -eq $remote.Thumbprint)

        if ($already.Count -eq 0) {
            $root.Add($remote)
        }

        return $remote.Thumbprint
    }
    finally {
        if ($root) { try { $root.Close() } catch {} }
        if ($ssl) { try { $ssl.Dispose() } catch {} }
        if ($tcp) { try { $tcp.Close() } catch {} }
    }
}

function Get-EdgePath {
    foreach ($path in @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
    )) {
        if (Test-Path $path) {
            return $path
        }
    }

    return $null
}

function Open-LabInEdge {
    param([Parameter(Mandatory=$true)][string]$Url)

    $edge = Get-EdgePath

    if ($edge) {
        Start-Process -FilePath $edge -ArgumentList @('--new-window', $Url)
    }
    else {
        Start-Process "microsoft-edge:$Url"
    }
}

function Load-AgentState {
    if (-not (Test-Path $StateFile)) {
        return $null
    }

    try {
        return Get-Content $StateFile -Raw | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Save-AgentState {
    param($State)

    $State |
        ConvertTo-Json -Depth 8 |
        Set-Content -Path $StateFile -Encoding UTF8
}

function Handle-Deployment {
    param([Parameter(Mandatory=$true)]$Deployment)

    $previous = Load-AgentState
    $adapter = Resolve-ManagementAdapter

    $routeAddress = Ensure-ClientRouteAddress `
        -Adapter $adapter `
        -ServerIP ([string]$Deployment.ip) `
        -Prefix ([int]$Deployment.prefix) `
        -PreviousState $previous

    Set-LabHostsEntry `
        -Hostname ([string]$Deployment.hostname) `
        -IPAddress ([string]$Deployment.ip)

    $port = if ([bool]$Deployment.httpsEnabled) {
        [int]$Deployment.httpsPort
    }
    else {
        [int]$Deployment.httpPort
    }

    $ready = $false

    for ($i = 0; $i -lt 30; $i++) {
        if (Test-TcpFast -HostName ([string]$Deployment.ip) -Port $port -TimeoutMs 250) {
            $ready = $true
            break
        }

        Start-Sleep -Milliseconds 100
    }

    if (-not $ready) {
        throw "Website $($Deployment.ip):$port is not reachable."
    }

    $trustedThumbprint = ''

    if ([bool]$Deployment.httpsEnabled) {
        $trustedThumbprint = Trust-LabHttpsCertificate `
            -ServerIP ([string]$Deployment.ip) `
            -Port ([int]$Deployment.httpsPort) `
            -Hostname ([string]$Deployment.hostname)
    }

    Open-LabInEdge -Url ([string]$Deployment.preferredUrl)

    Save-AgentState -State ([pscustomobject]@{
        lastDeploymentId = [string]$Deployment.id
        managedClientIP = if ($routeAddress.Managed) { [string]$routeAddress.IP } else { '' }
        interfaceIndex = [int]$adapter.ifIndex
        lastUrl = [string]$Deployment.preferredUrl
        trustedThumbprint = $trustedThumbprint
        updatedAt = (Get-Date).ToString('o')
    })
}

Add-Type -AssemblyName System.Net.Http

$http = New-Object System.Net.Http.HttpClient
$http.Timeout = [TimeSpan]::FromSeconds(1)

while ($true) {
    try {
        $json = $http.GetStringAsync("$PortalBase/api/deploy/current").GetAwaiter().GetResult()
        $result = $json | ConvertFrom-Json

        if ($result.ok -and $result.deployment) {
            $state = Load-AgentState
            $lastId = if ($state) { [string]$state.lastDeploymentId } else { '' }
            $newId = [string]$result.deployment.id

            if ($newId -and $newId -ne $lastId) {
                try {
                    Handle-Deployment -Deployment $result.deployment
                }
                catch {
                    # Do not mark it complete; the next poll retries automatically.
                    Start-Sleep -Milliseconds 500
                }
            }
        }

        Start-Sleep -Milliseconds 200
    }
    catch {
        # Server/portal is offline. Back off until it returns.
        Start-Sleep -Seconds 2
    }
}
