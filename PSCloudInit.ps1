[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(HelpMessage = "Install the script as a Windows Scheduled Task to run at startup")]
    [switch]$Install
)

#region Functions

function Wait-CloudInitDrive {
    <#
    .SYNOPSIS
        Waits for the cloud-init drive to appear
    .PARAMETER Seconds
        Number of seconds to wait for the drive to appear
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [int]$Seconds = 5
    )

    Write-Verbose "Waiting up to $Seconds seconds for cloud-init drive to appear..."
    $cidata = $null

    for ($i = 0; $i -lt $Seconds; $i++) {
        Write-Verbose "Attempt $($i + 1) of $Seconds..."
        $cidata = Get-Volume -FileSystemLabel "cidata" -ErrorAction SilentlyContinue

        if ($cidata) {
            Write-Verbose "cloud-init drive found on attempt $($i + 1)"
            break
        }

        Start-Sleep -Seconds 1
    }

    if (-not $cidata) {
        Write-Host "cloud-init drive not found after $Seconds seconds."
        throw "cloud-init drive not found."
    }

    $driveLetter = $cidata.DriveLetter + ":"
    Write-Host "Found cloud-init drive at $driveLetter"
    Write-Verbose "Drive properties: DriveLetter=$($cidata.DriveLetter), FileSystemLabel=$($cidata.FileSystemLabel)"

    return $driveLetter
}

function Convert-CidrToNetmask {
    <#
    .SYNOPSIS
        Convert CIDR prefix to netmask
    .PARAMETER Prefix
        CIDR prefix length (e.g., 24 for /24)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$Prefix
    )

    Write-Verbose "Converting CIDR prefix /$Prefix to netmask..."
    $mask = [uint32](0xFFFFFFFF -shl (32 - $Prefix))
    $bytes = [System.BitConverter]::GetBytes($mask)
    if ([System.BitConverter]::IsLittleEndian) { [Array]::Reverse($bytes) }
    $netmask = [System.Net.IPAddress]::new($bytes).ToString()
    Write-Verbose "CIDR /$Prefix = $netmask"
    return $netmask
}

function Test-GatewayOnLink {
    <#
    .SYNOPSIS
        Check if gateway is on-link (in the same subnet)
    .PARAMETER IpAddress
        IP address to check
    .PARAMETER Prefix
        CIDR prefix length
    .PARAMETER Gateway
        Gateway IP address
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$IpAddress,

        [Parameter(Mandatory = $true)]
        [int]$Prefix,

        [Parameter(Mandatory = $true)]
        [string]$Gateway
    )

    Write-Verbose "Checking if gateway $Gateway is on-link for $IpAddress/$Prefix..."

    # Validate prefix is in valid range
    if ($Prefix -lt 0 -or $Prefix -gt 32) {
        Write-Warning "Invalid prefix length: $Prefix. Assuming off-link gateway."
        return $false
    }

    if ($Prefix -eq 32) {
        Write-Verbose "Prefix is /32, gateway is off-link"
        return $false
    }

    $ipBytes = [System.Net.IPAddress]::Parse($IpAddress).GetAddressBytes()
    $gwBytes = [System.Net.IPAddress]::Parse($Gateway).GetAddressBytes()

    if ([System.BitConverter]::IsLittleEndian) {
        [Array]::Reverse($ipBytes)
        [Array]::Reverse($gwBytes)
    }

    $ipInt = [System.BitConverter]::ToUInt32($ipBytes, 0)
    $gwInt = [System.BitConverter]::ToUInt32($gwBytes, 0)
    $maskInt = [uint32]::MaxValue -shl (32 - $Prefix)

    $isOnLink = (($ipInt -band $maskInt) -eq ($gwInt -band $maskInt))
    Write-Verbose "Gateway is $(if ($isOnLink) { 'on-link' } else { 'off-link' })"

    return $isOnLink
}

function Install-Script {
    <#
    .SYNOPSIS
        Install the script as a Windows Scheduled Task
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    $targetFolder = "C:\Windows\Setup\Scripts"

    $sourceItem = Get-Item $PSCommandPath
    $targetFile = Join-Path $targetFolder $sourceItem.Name

    Write-Host "Installing PSCloudInit as a startup task..."
    Write-Verbose "Source: $sourceItem"
    Write-Verbose "Target: $targetFile"

    # Copy script
    $copyScript = $true
    if (Test-Path $targetFile) {
        Write-Verbose "Existing script found at target location."
        $targetItem = Get-Item $targetFile

        if ($sourceItem.Directory.FullName -eq $targetItem.Directory.FullName) {
            Write-Warning "Source and target are the same. Skipping copy."
            $copyScript = $false
        }
    }

    if ($copyScript -and $PSCmdlet.ShouldProcess($targetFile, "Copy script")) {
        Write-Host "  Copying script to: $targetFile"

        # Create directory if it doesn't exist
        New-Item -Path $targetFolder -ItemType Directory -Force | Out-Null

        Copy-Item -Path $sourceItem.FullName -Destination $targetFile -Force
        Write-Verbose "Script copied successfully"
    }

    # Create scheduled task
    $taskName = "PSCloudInit-Startup"
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        if ($PSCmdlet.ShouldProcess($taskName, "Remove existing scheduled task")) {
            Write-Host "  Removing existing scheduled task: $taskName"
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Write-Verbose "Existing task removed"
        }
    }

    if ($PSCmdlet.ShouldProcess($taskName, "Create scheduled task")) {
        Write-Host "  Creating scheduled task: $taskName"

        $action = New-ScheduledTaskAction `
            -Execute "powershell.exe" `
            -Argument "-ExecutionPolicy Bypass -File `"$targetFile`" -Verbose"

        $trigger = New-ScheduledTaskTrigger -AtStartup

        $principal = New-ScheduledTaskPrincipal `
            -UserId "SYSTEM" `
            -LogonType ServiceAccount `
            -RunLevel Highest

        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -ExecutionTimeLimit (New-TimeSpan -Hours 1)

        Register-ScheduledTask `
            -TaskName $taskName `
            -Action $action `
            -Trigger $trigger `
            -Principal $principal `
            -Settings $settings `
            -Description "Runs PSCloudInit configuration at Windows startup" | Out-Null

        Write-Verbose "Scheduled task created successfully"
        Write-Host "  Installation complete. The script will run automatically at the next system startup.`n"
    }
}

function Get-UserDataConfig {
    <#
    .SYNOPSIS
        Parse user-data file and extract configuration
    .PARAMETER DriveLetter
        Drive letter of the cloud-init drive
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DriveLetter
    )

    $userDataPath = Join-Path $DriveLetter "user-data"
    $searchDomain = $null
    $userData = $null

    if (Test-Path $userDataPath) {
        Write-Verbose "Found user-data at: $userDataPath"
        $userData = Get-Content $userDataPath -Raw

        # Extract FQDN from user_data (format: fqdn: hostname.domain)
        if ($userData -match "fqdn:\s*(\S+)") {
            $fqdn = $matches[1]
            Write-Verbose "FQDN: $fqdn"

            # Extract domain suffix (everything after the first dot)
            if ($fqdn -match "^[^\.]+\.(.+)$") {
                $searchDomain = $matches[1]
                Write-Verbose "DNS search domain: $searchDomain"
            }
        } else {
            Write-Verbose "No FQDN found in user-data"
        }
    } else {
        Write-Warning "user_data not found at $userDataPath"
    }

    return @{
        SearchDomain = $searchDomain
        Content = $userData
    }
}

function Get-NetworkConfig {
    <#
    .SYNOPSIS
        Parse network-config file
    .PARAMETER DriveLetter
        Drive letter of the cloud-init drive
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DriveLetter
    )

    $networkConfigPath = Join-Path $DriveLetter "network-config"

    if (-not (Test-Path $networkConfigPath)) {
        throw "Network config not found at $networkConfigPath"
    }

    Write-Verbose "Found network-config at $networkConfigPath..."
    $networkConfigContent = Get-Content $networkConfigPath -Raw

    $interfaces = @()
    $nameservers = @()
    $searchDomains = @()
    $currentInterface = $null
    $currentSubnet = $null
    $inConfigSection = $false
    $inSubnetsSection = $false
    $inNameserverSection = $false
    $inAddressSection = $false
    $inSearchSection = $false

    Write-Verbose "Parsing network configuration..."

    foreach ($line in $networkConfigContent -split "`r?`n") {
        $trimmedLine = $line.Trim()

        # Skip empty lines and comments
        if ($trimmedLine -match '^\s*$' -or $trimmedLine -match '^\s*#') {
            continue
        }

        # Check indentation level
        $indent = ($line -replace '\S.*$', '').Length

        # Parse based on content
        if ($trimmedLine -match '^config:') {
            $inConfigSection = $true
            Write-Verbose "Entering config section"
            continue
        }

        if ($trimmedLine -match '^-\s+type:\s*physical') {
            Write-Verbose "Found physical interface definition"

            # Save last subnet for previous interface
            if ($currentInterface -and $currentSubnet -and ($currentSubnet.Address -or $currentSubnet.Type -in @('dhcp', 'dhcp6', 'ipv6_slaac'))) {
                $currentInterface.Subnets += $currentSubnet
            }

            # Save previous interface
            if ($currentInterface -and $currentInterface.MacAddress) {
                $interfaces += $currentInterface
            }

            # Start new interface
            $currentInterface = @{
                Name = $null
                MacAddress = $null
                Subnets = @()
                DnsServers = @()
            }
            $inSubnetsSection = $false
            $currentSubnet = $null
            continue
        }

        if ($trimmedLine -match '^-\s+type:\s*nameserver') {
            Write-Verbose "Found nameserver definition"

            # Save last subnet for previous interface
            if ($currentInterface -and $currentSubnet -and ($currentSubnet.Address -or $currentSubnet.Type -in @('dhcp', 'dhcp6', 'ipv6_slaac'))) {
                $currentInterface.Subnets += $currentSubnet
            }

            # Save previous interface
            if ($currentInterface -and $currentInterface.MacAddress) {
                $interfaces += $currentInterface
            }

            $currentInterface = $null
            $inNameserverSection = $true
            $inSubnetsSection = $false
            continue
        }

        # Parse interface properties
        if ($currentInterface) {
            if ($trimmedLine -match "^name:\s*(\S+)") {
                $currentInterface.Name = $matches[1]
                Write-Verbose "  Found interface name: $($currentInterface.Name)"
            }
            elseif ($trimmedLine -match '^mac_address:\s*(.+)$') {
                $macValue = $matches[1].Trim().Trim("'").Trim('"')
                $currentInterface.MacAddress = $macValue.ToUpper().Replace(':', '-')
                Write-Verbose "  Found MAC $($currentInterface.MacAddress) for interface $($currentInterface.Name)"
            }
            elseif ($trimmedLine -match '^subnets:') {
                $inSubnetsSection = $true
                Write-Verbose "  Entering subnets section for interface $($currentInterface.Name)"
            }
            elseif ($inSubnetsSection -and $trimmedLine -match '^-\s+type:\s*(\S+)') {
                # Save previous subnet if exists
                if ($currentSubnet -and ($currentSubnet.Address -or $currentSubnet.Type -in @('dhcp', 'dhcp6', 'ipv6_slaac'))) {
                    $currentInterface.Subnets += $currentSubnet
                    Write-Verbose "    Saved subnet type: $($currentSubnet.Type)"
                }
                # Start new subnet
                $subnetType = $matches[1]
                $currentSubnet = @{
                    Type = $subnetType
                    Address = $null
                    Netmask = $null
                    Gateway = $null
                }
                Write-Verbose "    New subnet type: $subnetType"
            }
            elseif ($inSubnetsSection -and $trimmedLine -match '^address:\s*(.+)$') {
                if ($currentSubnet) {
                    $currentSubnet.Address = $matches[1].Trim().Trim("'").Trim('"')
                    Write-Verbose "    Subnet address: $($currentSubnet.Address)"
                }
            }
            elseif ($inSubnetsSection -and $trimmedLine -match '^netmask:\s*(.+)$') {
                if ($currentSubnet) {
                    $currentSubnet.Netmask = $matches[1].Trim().Trim("'").Trim('"')
                    Write-Verbose "    Subnet netmask: $($currentSubnet.Netmask)"
                }
            }
            elseif ($inSubnetsSection -and $trimmedLine -match '^gateway:\s*(.+)$') {
                if ($currentSubnet) {
                    $currentSubnet.Gateway = $matches[1].Trim().Trim("'").Trim('"')
                    Write-Verbose "    Subnet gateway: $($currentSubnet.Gateway)"
                }
            }
        }

        # Parse nameserver section
        if ($inNameserverSection) {
            if ($trimmedLine -match '^address:') {
                $inAddressSection = $true
                $inSearchSection = $false
                Write-Verbose "Entering nameserver address section"
            }
            elseif ($trimmedLine -match '^search:') {
                $inSearchSection = $true
                $inAddressSection = $false
                Write-Verbose "Entering nameserver search section"
            }
            elseif ($inAddressSection -and $trimmedLine -match '^-\s+(.+)$') {
                $ns = $matches[1].Trim().Trim("'").Trim('"')
                $nameservers += $ns
                Write-Verbose "  Nameserver: $ns"
            }
            elseif ($inSearchSection -and $trimmedLine -match '^-\s+(.+)$') {
                $sd = $matches[1].Trim().Trim("'").Trim('"')
                $searchDomains += $sd
                Write-Verbose "  Search domain: $sd"
            }
        }
    }

    # Save last subnet for last interface (only if interface exists)
    if ($currentInterface -and $currentSubnet -and ($currentSubnet.Address -or $currentSubnet.Type -in @('dhcp', 'dhcp6', 'ipv6_slaac'))) {
        $currentInterface.Subnets += $currentSubnet
        Write-Verbose "Saved last subnet"
    }

    # Save last interface
    if ($currentInterface -and $currentInterface.MacAddress) {
        $interfaces += $currentInterface
        Write-Verbose "Saved last interface: $($currentInterface.Name)"
    }

    return @{
        Interfaces = $interfaces
        Nameservers = $nameservers
        SearchDomains = $searchDomains
    }
}

function Set-NetworkInterface {
    <#
    .SYNOPSIS
        Configure a network interface
    .PARAMETER Interface
        Interface configuration object
    .PARAMETER Nameservers
        Global DNS nameservers
    .PARAMETER SearchDomain
        DNS search domain
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Interface,

        [Parameter(Mandatory = $false)]
        [array]$Nameservers = @(),

        [Parameter(Mandatory = $false)]
        [string]$SearchDomain
    )

    Write-Host "`nConfiguring interface: $($Interface.Name) / $($Interface.MacAddress)"
    Write-Verbose "Interface configuration: Name=$($Interface.Name), MAC=$($Interface.MacAddress), Subnets=$($Interface.Subnets.Count)"

    if ($Interface.Subnets.Count -eq 0) {
        Write-Host "Skipping interface with no subnets configured"
        return
    }

    # Get all network adapters
    $allAdapters = @(Get-NetAdapter)

    # Match by MAC address
    $adapter = $allAdapters | Where-Object { $_.MacAddress -eq $Interface.MacAddress }
    if (-not $adapter) {
        Write-Warning "No adapter found with MAC address $($Interface.MacAddress)"
        return
    }
    Write-Verbose "Found adapter $($adapter.Name) (Index: $($adapter.InterfaceIndex), MAC: $($adapter.MacAddress), Status: $($adapter.Status))"

    if ($adapter.Name -ne $Interface.Name) {
        Write-Verbose "  Adapter name '$($adapter.Name)' does not match expected name '$($Interface.Name)'"
        # Rename adapter
        if ($PSCmdlet.ShouldProcess($adapter.Name, "Rename adapter to $($Interface.Name)")) {
            Write-Host "  Renaming adapter to $($Interface.Name)..."
            Rename-NetAdapter -Name $adapter.Name -NewName $Interface.Name -ErrorAction Continue
            Write-Verbose "Adapter renamed successfully"
        }
    } else {
        Write-Host "  Adapter name '$($adapter.Name)' already matches expected name"
    }

    # Process each subnet configuration
    foreach ($subnet in $Interface.Subnets) {
        Set-SubnetConfiguration -Adapter $adapter -Subnet $subnet
    }

    # Configure DNS
    $dns = if ($Nameservers.Count -gt 0) { $Nameservers } else { $Interface.DnsServers }

    if ($dns.Count -gt 0) {
        $joinedDns = $dns -join ', '
        # Check current DNS configuration
        $currentDNS = (Get-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
        $dnsChanged = $false

        Write-Verbose "Current DNS: $($currentDNS -join ', ')"
        Write-Verbose "Expected DNS: $joinedDns"

        if ($currentDNS) {
            # Compare DNS servers
            if ($currentDNS.Count -ne $dns.Count) {
                $dnsChanged = $true
                Write-Verbose "DNS count different: current=$($currentDNS.Count), expected=$($dns.Count)"
            } else {
                for ($i = 0; $i -lt $dns.Count; $i++) {
                    if ($currentDNS[$i] -ne $dns[$i]) {
                        $dnsChanged = $true
                        Write-Verbose "DNS mismatch at position ${i}: current=$($currentDNS[$i]), expected=$($dns[$i])"
                        break
                    }
                }
            }
        } else {
            $dnsChanged = $true
            Write-Verbose "No current DNS configured"
        }

        if ($dnsChanged) {
            if ($PSCmdlet.ShouldProcess($adapter.Name, "Configure DNS: $joinedDns")) {
                Write-Host "  Configuring DNS: $joinedDns"
                Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses $dns
                Write-Verbose "DNS configured successfully"
            }
        } else {
            Write-Host "  DNS already configured: $joinedDns"
        }
    } else {
        Write-Verbose "No DNS servers to configure"
    }

    # Configure DNS search domain
    if ($SearchDomain) {
        $currentSuffix = (Get-DnsClient -InterfaceIndex $adapter.InterfaceIndex -ErrorAction SilentlyContinue).ConnectionSpecificSuffix
        Write-Verbose "Current DNS suffix: $currentSuffix"
        Write-Verbose "Expected DNS suffix: $SearchDomain"

        if ($currentSuffix -ne $SearchDomain) {
            if ($PSCmdlet.ShouldProcess($adapter.Name, "Configure DNS search domain: $SearchDomain")) {
                Write-Host "  Configuring DNS search domain: $SearchDomain"
                Set-DnsClient -InterfaceIndex $adapter.InterfaceIndex -ConnectionSpecificSuffix $SearchDomain
                Write-Verbose "DNS search domain configured successfully"
            }
        } else {
            Write-Host "  DNS search domain already configured: $SearchDomain"
        }
    } else {
        Write-Verbose "No DNS search domain to configure"
    }
}

function Set-SubnetConfiguration {
    <#
    .SYNOPSIS
        Configure a subnet on an adapter
    .PARAMETER Adapter
        Network adapter object
    .PARAMETER Subnet
        Subnet configuration object
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        $Adapter,

        [Parameter(Mandatory = $true)]
        [hashtable]$Subnet
    )

    $subnetType = $Subnet.Type
    Write-Verbose "Configuring subnet type: $subnetType"
    Write-Verbose "Subnet details: Type=$subnetType, Address=$($Subnet.Address), Netmask=$($Subnet.Netmask), Gateway=$($Subnet.Gateway)"

    # Handle different subnet types
    switch ($subnetType) {
        { $_ -in @('static', 'static6') } {
            Set-StaticIpConfiguration -Adapter $Adapter -Subnet $Subnet
        }

        'dhcp' {
            $dhcpStatus = Get-NetIPInterface -InterfaceIndex $Adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if ($dhcpStatus.Dhcp -eq 'Enabled') {
                Write-Host "  DHCPv4 already enabled"
            } else {
                if ($PSCmdlet.ShouldProcess($adapter.Name, "Enable DHCP for IPv4")) {
                    Write-Host "  Enabling DHCP for IPv4..."
                    Set-NetIPInterface -InterfaceIndex $Adapter.InterfaceIndex -Dhcp Enabled -AddressFamily IPv4
                    Write-Verbose "DHCPv4 enabled successfully"
                }
            }
        }

        { $_ -in @('dhcp6', 'ipv6_slaac') } {
            $dhcp6ExpectedState = if ($subnetType -eq 'dhcp6') { 'Enabled' } else { 'Disabled' }
            $dhcpStatus = Get-NetIPInterface -InterfaceIndex $Adapter.InterfaceIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue
            if ($dhcpStatus.Dhcp -eq $dhcp6ExpectedState) {
                Write-Host "  DHCPv6 already $dhcp6ExpectedState"
            } else {
                if ($PSCmdlet.ShouldProcess($adapter.Name, "Set DHCPv6 to $dhcp6ExpectedState")) {
                    Write-Host "  Setting DHCPv6 to $dhcp6ExpectedState..."
                    Set-NetIPInterface -InterfaceIndex $Adapter.InterfaceIndex -AddressFamily IPv6 -Dhcp $dhcp6ExpectedState
                    Write-Verbose "DHCPv6 $dhcp6ExpectedState successfully"
                }
            }

            $slaacExpectedState = if ($subnetType -eq 'ipv6_slaac') { 'Enabled' } else { 'Disabled' }
            $routerDiscovery = Get-NetIPInterface -InterfaceIndex $Adapter.InterfaceIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue
            if ($routerDiscovery.RouterDiscovery -eq $slaacExpectedState) {
                Write-Host "  IPv6 SLAAC already $slaacExpectedState"
            } else {
                if ($PSCmdlet.ShouldProcess($adapter.Name, "Set IPv6 SLAAC to $slaacExpectedState")) {
                    Write-Host "  Setting IPv6 SLAAC to $slaacExpectedState..."
                    Set-NetIPInterface -InterfaceIndex $Adapter.InterfaceIndex -AddressFamily IPv6 -RouterDiscovery $slaacExpectedState
                    Write-Verbose "IPv6 SLAAC $slaacExpectedState successfully"
                }
            }
        }

        default {
            Write-Host "  Unsupported subnet type: $subnetType"
        }
    }
}

function Set-StaticIpConfiguration {
    <#
    .SYNOPSIS
        Configure static IP address on an adapter
    .PARAMETER Adapter
        Network adapter object
    .PARAMETER Subnet
        Subnet configuration object
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        $Adapter,

        [Parameter(Mandatory = $true)]
        [hashtable]$Subnet
    )

    $ip = $Subnet.Address
    if (-not $ip) {
        Write-Warning "  No IP address defined for static subnet"
        Write-Verbose "Skipping static configuration - no IP address"
        return
    }

    # Check if address has CIDR prefix embedded (e.g., "2001:db8::1/64")
    $prefix = $null
    if ($ip -match '^(.+)/(\d+)$') {
        $ip = $matches[1]
        $prefix = [int]$matches[2]
        Write-Verbose "Extracted CIDR from address: IP=$ip, Prefix=$prefix"
    }

    # Detect if IPv4 or IPv6
    $isIPv6 = $ip -match ':'
    $addressFamily = if ($isIPv6) { 'IPv6' } else { 'IPv4' }

    # Get prefix length from netmask if not already set
    if ($Subnet.Netmask -and -not $prefix) {
        if (-not $isIPv6) {
            # Convert netmask to prefix length for IPv4
            $maskBytes = [System.Net.IPAddress]::Parse($Subnet.Netmask).GetAddressBytes()
            if ([System.BitConverter]::IsLittleEndian) { [Array]::Reverse($maskBytes) }
            $maskInt = [System.BitConverter]::ToUInt32($maskBytes, 0)

            # Count leading 1 bits from the left
            $prefix = 0
            for ($b = 31; $b -ge 0; $b--) {
                if (($maskInt -shr $b) -band 1) {
                    $prefix++
                } else {
                    break
                }
            }
        } else {
            # For IPv6, netmask field might contain prefix length
            $prefix = [int]$Subnet.Netmask
            Write-Verbose "Using netmask as prefix for IPv6: $prefix"
        }
    }

    # Set defaults if still not set
    if (-not $prefix) {
        $prefix = 24  # default for IPv4
        if ($isIPv6) { $prefix = 64 }  # default for IPv6
        Write-Verbose "Using default prefix: $prefix"
    }

    Write-Verbose "  IP Configuration: $ip/$prefix ($addressFamily)"

    # Get gateway
    $gateway = $Subnet.Gateway
    if ($gateway) {
        Write-Verbose "  Gateway configured: $gateway"
    } else {
        Write-Verbose "  No gateway specified"
    }

    $existingIPs = Get-NetIPAddress -InterfaceIndex $Adapter.InterfaceIndex -AddressFamily $addressFamily -ErrorAction SilentlyContinue

    $existingIP = $existingIPs | Where-Object { $_.IPAddress -eq $ip }
    $additionalIPs = $existingIPs | Where-Object { $_.IPAddress -ne $ip }

    # Check if this IP is already configured
    if ($existingIP) {
        Write-Host "  IP address already configured: $ip"

        if ($additionalIPs) {
            Write-Warning "  Additional IP addresses found on interface:"
            foreach ($addr in $additionalIPs) {
                Write-Warning "    - $($addr.IPAddress)/$($addr.PrefixLength)"
            }
        }
        return
    }

    if ($additionalIPs) {
        # Remove additional IPs
        foreach ($addr in $additionalIPs) {
            if ($PSCmdlet.ShouldProcess($Adapter.Name, "Remove additional IP address $($addr.IPAddress)/$($addr.PrefixLength)")) {
                Write-Host "  Removing additional IP address: $($addr.IPAddress)/$($addr.PrefixLength)"
                Remove-NetIPAddress -InterfaceIndex $Adapter.InterfaceIndex -IPAddress $addr.IPAddress -Confirm:$false
            }
        }
    }

    # Configure IP address
    if ($gateway -and -not $isIPv6) {
        # Only handle gateway logic for IPv4 (IPv6 uses router advertisements)
        $isOnLink = Test-GatewayOnLink -IpAddress $ip -Prefix $prefix -Gateway $gateway

        if ($isOnLink) {
            if ($PSCmdlet.ShouldProcess("$ip/$prefix", "Configure with on-link gateway $gateway")) {
                Write-Host "  Configuring with on-link gateway..."
                New-NetIPAddress -InterfaceIndex $Adapter.InterfaceIndex `
                    -IPAddress $ip `
                    -PrefixLength $prefix `
                    -DefaultGateway $gateway `
                    -AddressFamily $addressFamily | Out-Null
            }
        } else {
            if ($PSCmdlet.ShouldProcess("$ip/$prefix", "Configure with off-link gateway $gateway")) {
                Write-Host "  Configuring with off-link gateway..."

                # Add IP address without gateway
                New-NetIPAddress -InterfaceIndex $Adapter.InterfaceIndex `
                    -IPAddress $ip `
                    -PrefixLength $prefix `
                    -AddressFamily $addressFamily | Out-Null

                # Check if host route already exists
                $existingHostRoute = Get-NetRoute -DestinationPrefix "$gateway/32" -InterfaceIndex $Adapter.InterfaceIndex -ErrorAction SilentlyContinue
                if (-not $existingHostRoute) {
                    Write-Host "  Adding host route to gateway $gateway..."
                    New-NetRoute -DestinationPrefix "$gateway/32" `
                        -InterfaceIndex $Adapter.InterfaceIndex `
                        -NextHop "0.0.0.0" | Out-Null
                } else {
                    Write-Verbose "Host route already exists"
                }

                # Check if default route already exists
                $existingDefaultRoute = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -InterfaceIndex $Adapter.InterfaceIndex -ErrorAction SilentlyContinue
                if (-not $existingDefaultRoute) {
                    Write-Host "  Adding default route via $gateway..."
                    New-NetRoute -DestinationPrefix "0.0.0.0/0" `
                        -InterfaceIndex $Adapter.InterfaceIndex `
                        -NextHop $gateway | Out-Null
                } else {
                    Write-Verbose "Default route already exists"
                }
            }
        }
    } else {
        if ($PSCmdlet.ShouldProcess("$ip/$prefix", "Configure without gateway")) {
            Write-Host "  Configuring without gateway..."
            New-NetIPAddress -InterfaceIndex $Adapter.InterfaceIndex `
                -IPAddress $ip `
                -PrefixLength $prefix `
                -AddressFamily $addressFamily | Out-Null
        }
    }

    Write-Host "  IP configuration applied successfully"
}

function Install-SshKeys {
    <#
    .SYNOPSIS
        Process and install SSH public keys from user_data
    .PARAMETER UserData
        user-data content as string
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [string]$UserData
    )

    Write-Host "`nConfiguring SSH keys"

    if (-not $UserData -or $UserData -notmatch 'ssh_authorized_keys:') {
        Write-Host "No ssh_authorized_keys in user_data"
        return
    }

    Write-Verbose "Parsing SSH keys from user_data"

    $sshDir = "C:\ProgramData\ssh"
    $authorizedKeysPath = Join-Path $sshDir "administrators_authorized_keys"

    # Create SSH directory if it doesn't exist
    if (-not (Test-Path $sshDir)) {
        if ($PSCmdlet.ShouldProcess($sshDir, "Create SSH directory")) {
            Write-Host "Creating SSH directory: $sshDir"
            New-Item -Path $sshDir -ItemType Directory -Force | Out-Null
        }
    } else {
        Write-Verbose "SSH directory already exists: $sshDir"
    }

    # Extract SSH keys from user_data (YAML format)
    $publicKeys = @()
    $inKeysSection = $false

    foreach ($line in $UserData -split "`r?`n") {
        if ($line -match 'ssh_authorized_keys:') {
            $inKeysSection = $true
            Write-Verbose "Found ssh_authorized_keys section"
            continue
        }

        if ($inKeysSection) {
            # Check if still in the keys section (indented with - )
            if ($line -match '^\s+-\s+(.+)$') {
                $key = $matches[1].Trim()
                Write-Verbose "Found SSH key: $($key.Substring(0, [Math]::Min(50, $key.Length)))..."
                Write-Verbose "Full key: $key"
                $publicKeys += $key
            } elseif ($line -match '^\w+:') {
                # New top-level key, exit keys section
                Write-Verbose "Exiting ssh_authorized_keys section"
                break
            }
        }
    }

    if ($publicKeys.Count -gt 0) {
        if ($PSCmdlet.ShouldProcess($authorizedKeysPath, "Install $($publicKeys.Count) SSH public key(s)")) {
            Write-Host "  Installing $($publicKeys.Count) SSH public key(s) to $authorizedKeysPath"

            # Write keys to file (overwrite if exists)
            $publicKeys | Out-File -FilePath $authorizedKeysPath -Encoding ASCII -Force

            # Set proper permissions (only SYSTEM and Administrators should have access)
            Write-Host "  Setting ACL permissions on authorized_keys file"
            $acl = Get-Acl $authorizedKeysPath
            $acl.SetAccessRuleProtection($true, $false)  # Disable inheritance

            # Remove all existing rules
            $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }

            # Add SYSTEM with Full Control
            $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                "NT AUTHORITY\SYSTEM", "FullControl", "Allow")
            $acl.AddAccessRule($systemRule)

            # Add Administrators with Full Control
            $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                "BUILTIN\Administrators", "FullControl", "Allow")
            $acl.AddAccessRule($adminRule)

            Set-Acl -Path $authorizedKeysPath -AclObject $acl
            Write-Host "  SSH public keys installed successfully"
        }
    } else {
        Write-Host "No public keys found in user_data"
    }
}

#endregion Functions

#region Main Script

# Setup logging
$LogPath = "C:\Windows\Panther\PSCloudInit.log"
Start-Transcript -Path $LogPath -Append
$ErrorActionPreference = "Stop"

# Handle Install parameter
if ($Install) {
    Install-Script
}

try {
    Write-Host "Starting PSCloudInit configuration..."
    Write-Verbose "Script started at: $(Get-Date)"

    # Wait for cloud-init drive
    $driveLetter = Wait-CloudInitDrive

    # Parse user-data
    $userDataConfig = Get-UserDataConfig -DriveLetter $driveLetter
    $searchDomain = $userDataConfig.SearchDomain

    # Parse network configuration
    $networkConfig = Get-NetworkConfig -DriveLetter $driveLetter

    # Use search domain from network config if not found in user-data
    if (-not $searchDomain -and $networkConfig.SearchDomains.Count -gt 0) {
        $searchDomain = $networkConfig.SearchDomains[0]
        Write-Verbose "Using search domain from network-config: $searchDomain"
    }

    # Get all network adapters for logging
    $allAdapters = @(Get-NetAdapter)
    Write-Verbose "Found $($allAdapters.Count) network adapters on system:"
    foreach ($adapter in $allAdapters) {
        Write-Verbose "  - $($adapter.Name): MAC=$($adapter.MacAddress), Status=$($adapter.Status)"
    }

    # Configure each interface
    foreach ($iface in $networkConfig.Interfaces) {
        Set-NetworkInterface -Interface $iface -Nameservers $networkConfig.Nameservers -SearchDomain $searchDomain
    }

    # Install SSH keys
    Install-SshKeys -UserData $userDataConfig.Content

    Write-Host "`nPSCloudInit configuration completed successfully."
    Write-Verbose "Script completed at: $(Get-Date)"
}
catch {
    Write-Error "PSCloudInit script failed: $($_.Exception.Message)"
    Write-Verbose "Error details: $($_.Exception)"
    Write-Verbose "Stack trace: $($_.ScriptStackTrace)"
    Stop-Transcript
    exit 1
}
finally {
    Stop-Transcript
    exit 0
}

#endregion Main Script
