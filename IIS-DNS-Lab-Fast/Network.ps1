#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

function Get-LabSubnet {
    param(
        [Parameter(Mandatory=$true)][string]$IP,
        [Parameter(Mandatory=$true)][int]$Prefix
    )

    $parsed = $null
    if (
        $IP -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or
        -not [Net.IPAddress]::TryParse($IP, [ref]$parsed) -or
        $parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork
    ) {
        throw ("Invalid IPv4 address: {0}" -f $IP)
    }

    if ($Prefix -lt 8 -or $Prefix -gt 30) {
        throw 'This lab supports prefix lengths /8 to /30.'
    }

    $b = $parsed.GetAddressBytes()

    if ($b[0] -eq 0 -or $b[0] -eq 127 -or $b[0] -ge 224 -or ($b[0] -eq 169 -and $b[1] -eq 254)) {
        throw 'Use a unicast lab IP, not loopback, link-local, multicast, or reserved address.'
    }

    $number =
        [uint64]$b[0] * 16777216 +
        [uint64]$b[1] * 65536 +
        [uint64]$b[2] * 256 +
        [uint64]$b[3]

    $size  = [uint64][Math]::Pow(2, 32 - $Prefix)
    $first = [uint64]([Math]::Floor($number / $size) * $size)
    $last  = $first + $size - 1

    if ($number -eq $first -or $number -eq $last) {
        throw 'Network and broadcast addresses cannot be assigned to a host.'
    }

    [pscustomobject]@{
        Number = $number
        First  = $first
        Last   = $last
        IP     = $parsed.ToString()
        Prefix = $Prefix
    }
}

function Get-LabNetwork {
    param([string]$ManagementIP = '')

    foreach ($n in Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object ConnectionState -eq Connected) {

        $ips = @(
            Get-NetIPAddress `
                -InterfaceIndex $n.InterfaceIndex `
                -AddressFamily IPv4 `
                -ErrorAction SilentlyContinue
        )

        [pscustomobject]@{
            index      = [int]$n.InterfaceIndex
            alias      = [string]$n.InterfaceAlias
            dhcp       = [string]$n.Dhcp
            ips        = @($ips | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength) [$($_.AddressState)]" })
            management = [bool]($ManagementIP -and ($ManagementIP -in $ips.IPAddress))
        }
    }
}

function Resolve-LabServerInterfaceIndex {
    param([Parameter(Mandatory=$true)][string]$ManagementIP)

    $matches = @(
        Get-NetIPAddress `
            -AddressFamily IPv4 `
            -IPAddress $ManagementIP `
            -ErrorAction SilentlyContinue
    )

    if ($matches.Count -eq 0) {
        throw ("Cannot find the IIS management adapter containing {0}." -f $ManagementIP)
    }

    if ($matches.Count -gt 1) {
        throw ("Management IP {0} exists on more than one adapter." -f $ManagementIP)
    }

    $index = [int]$matches[0].InterfaceIndex
    $nic = Get-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction Stop

    if ($nic.ConnectionState -ne 'Connected') {
        throw 'IIS management adapter is disconnected.'
    }

    if ($nic.Dhcp -ne 'Disabled') {
        throw 'IIS management adapter uses DHCP. Use a static VMware lab adapter.'
    }

    return $index
}

function Add-LabAddress {
    param(
        [int]$Index = 0,
        [Parameter(Mandatory=$true)][string]$IP,
        [Parameter(Mandatory=$true)][int]$Prefix,
        [bool]$Server = $true,
        [string]$ManagementIP = '',
        [string]$DnsServer = ''
    )

    $sub = Get-LabSubnet -IP $IP -Prefix $Prefix

    if ($DnsServer -and $IP -eq $DnsServer) {
        throw ("{0} is reserved for the DNS server." -f $DnsServer)
    }

    if ($Server -and $Index -le 0) {
        if (-not $ManagementIP) { throw 'ManagementIP is required for server address changes.' }
        $Index = Resolve-LabServerInterfaceIndex -ManagementIP $ManagementIP
    }

    if (-not $Server -and $Index -le 0) {
        throw 'A client adapter index is required.'
    }

    $nic = Get-NetIPInterface -InterfaceIndex $Index -AddressFamily IPv4 -ErrorAction Stop

    if ($nic.ConnectionState -ne 'Connected') {
        throw 'Selected adapter is disconnected.'
    }

    if ($nic.Dhcp -ne 'Disabled') {
        throw 'Selected adapter uses DHCP. The lab refuses to modify it.'
    }

    $all = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)

    if ($Server -and -not ($all | Where-Object {
        $_.InterfaceIndex -eq $Index -and $_.IPAddress -eq $ManagementIP
    })) {
        throw ("The selected IIS adapter does not contain management IP {0}." -f $ManagementIP)
    }

    $same = @($all | Where-Object IPAddress -eq $IP)

    if ($same.Count) {
        if (
            $same.Count -eq 1 -and
            $same[0].InterfaceIndex -eq $Index -and
            $same[0].PrefixLength -eq $Prefix -and
            $same[0].AddressState -eq 'Preferred'
        ) {
            return ("IP already ready: {0}/{1}" -f $IP, $Prefix)
        }

        throw 'This IP already exists with a different adapter, prefix, or address state.'
    }

    foreach ($old in $all) {
        if ($old.PrefixLength -lt 8 -or $old.PrefixLength -gt 30) {
            continue
        }

        try {
            $oldSub = Get-LabSubnet -IP $old.IPAddress -Prefix $old.PrefixLength
        }
        catch {
            continue
        }

        if ($sub.First -le $oldSub.Last -and $oldSub.First -le $sub.Last) {
            if ($old.InterfaceIndex -ne $Index -or $old.PrefixLength -ne $Prefix) {
                throw ("Subnet overlaps adapter {0} / {1}. Review routing first." -f $old.InterfaceAlias, $old.IPAddress)
            }
        }
    }

    if (Test-Connection -ComputerName $IP -Count 1 -Quiet -ErrorAction SilentlyContinue) {
        throw ("IP {0} already responds. Choose a verified unused lab address." -f $IP)
    }

    $created = $null

    try {
        $created = New-NetIPAddress `
            -InterfaceIndex $Index `
            -IPAddress $IP `
            -PrefixLength $Prefix `
            -AddressFamily IPv4 `
            -SkipAsSource $Server `
            -ErrorAction Stop

        for ($i = 0; $i -lt 12; $i++) {
            $current = Get-NetIPAddress `
                -InterfaceIndex $Index `
                -IPAddress $IP `
                -AddressFamily IPv4 `
                -ErrorAction Stop

            if ($current.AddressState -eq 'Preferred') {
                return ("IP ready: {0}/{1} on {2}." -f $IP, $Prefix, $nic.InterfaceAlias)
            }

            if ($current.AddressState -in @('Duplicate','Invalid')) {
                throw ("Address state: {0}." -f $current.AddressState)
            }

            Start-Sleep -Milliseconds 250
        }

        throw 'IP did not become Preferred within 3 seconds.'
    }
    catch {
        $reason = $_.Exception.Message

        if ($created) {
            try {
                $created | Remove-NetIPAddress -Confirm:$false -ErrorAction Stop
            }
            catch {
                throw ("{0} Cleanup failed for {1}: {2}" -f $reason, $IP, $_.Exception.Message)
            }
        }

        throw $reason
    }
}
