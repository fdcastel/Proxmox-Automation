$LogPath = "C:\Windows\Panther\win-cloud-init.log"
Start-Transcript -Path $LogPath -Append
$ErrorActionPreference = "Stop"

Write-Host "Starting Cloud-Init Network Configuration (nocloud format)..."

# Wait for the Cloud-Init drive to appear
$cidata = $null
for ($i = 0; $i -lt 30; $i++) {
    $cidata = Get-Volume -FileSystemLabel "cidata" -ErrorAction SilentlyContinue
    if ($cidata) { break }
    Start-Sleep -Seconds 1
}

if (-not $cidata) {
    Write-Error "Cloud-Init drive not found."
    Stop-Transcript
    Exit 1
}

$driveLetter = $cidata.DriveLetter + ":"
Write-Host "Found cloud-init drive at $driveLetter"

# Function to parse simple YAML (for cloud-init nocloud format)
function ConvertFrom-SimpleYaml {
    param(
        [string]$Content
    )
    
    $result = @{}
    $currentKey = $null
    $currentValue = @()
    $inArray = $false
    
    foreach ($line in $Content -split "`r?`n") {
        # Skip comments and empty lines
        if ($line -match '^\s*#' -or $line -match '^\s*$') {
            continue
        }
        
        # Check for key-value pairs
        if ($line -match '^(\w+):\s*(.*)$') {
            # Save previous key if exists
            if ($currentKey) {
                if ($inArray) {
                    $result[$currentKey] = $currentValue
                } else {
                    $result[$currentKey] = $currentValue[0]
                }
            }
            
            $currentKey = $matches[1]
            $value = $matches[2].Trim()
            
            if ($value) {
                $currentValue = @($value)
                $inArray = $false
            } else {
                $currentValue = @()
                $inArray = $false
            }
        }
        # Check for array items
        elseif ($line -match '^\s+-\s+(.+)$') {
            $inArray = $true
            $currentValue += $matches[1].Trim()
        }
    }
    
    # Save last key
    if ($currentKey) {
        if ($inArray) {
            $result[$currentKey] = $currentValue
        } else {
            $result[$currentKey] = $currentValue[0]
        }
    }
    
    return $result
}

# Parse user_data
$userDataPath = Join-Path $driveLetter "user-data"
$searchDomain = $null
if (Test-Path $userDataPath) {
    Write-Host "Reading user_data..."
    $userData = Get-Content $userDataPath -Raw
    
    # Extract FQDN from user_data (format: fqdn: hostname.domain)
    if ($userData -match "fqdn:\s*(\S+)") {
        $fqdn = $matches[1]
        Write-Host "Found FQDN: $fqdn"
        
        # Extract domain suffix (everything after the first dot)
        if ($fqdn -match "^[^\.]+\.(.+)$") {
            $searchDomain = $matches[1]
            Write-Host "Extracted DNS search domain: $searchDomain"
        }
    }
} else {
    Write-Warning "user_data not found at $userDataPath"
}

# Parse meta_data
$metaDataPath = Join-Path $driveLetter "meta-data"
if (Test-Path $metaDataPath) {
    Write-Host "Reading meta-data..."
    $metaDataContent = Get-Content $metaDataPath -Raw
    $metaData = ConvertFrom-SimpleYaml -Content $metaDataContent
    
    if ($metaData.instance_id) {
        Write-Host "Instance ID: $($metaData.instance_id)"
    }
    if ($metaData.hostname) {
        Write-Host "Hostname: $($metaData.hostname)"
    }
    
    # Process SSH public keys from user_data
    # In nocloud format, SSH keys are in user_data, not meta-data
    if ($userData -match 'ssh_authorized_keys:') {
        Write-Host "`n--- Processing SSH Public Keys ---"
        $sshDir = "C:\ProgramData\ssh"
        $authorizedKeysPath = Join-Path $sshDir "administrators_authorized_keys"
        
        # Create SSH directory if it doesn't exist
        if (-not (Test-Path $sshDir)) {
            Write-Host "Creating SSH directory: $sshDir"
            New-Item -Path $sshDir -ItemType Directory -Force | Out-Null
        }
        
        # Extract SSH keys from user_data (YAML format)
        $publicKeys = @()
        $inKeysSection = $false
        foreach ($line in $userData -split "`r?`n") {
            if ($line -match 'ssh_authorized_keys:') {
                $inKeysSection = $true
                continue
            }
            if ($inKeysSection) {
                # Check if still in the keys section (indented with - )
                if ($line -match '^\s+-\s+(.+)$') {
                    $key = $matches[1].Trim()
                    Write-Host "Found SSH key: $($key.Substring(0, [Math]::Min(50, $key.Length)))..."
                    $publicKeys += $key
                } elseif ($line -match '^\w+:') {
                    # New top-level key, exit keys section
                    break
                }
            }
        }
        
        if ($publicKeys.Count -gt 0) {
            Write-Host "Installing $($publicKeys.Count) SSH public key(s) to $authorizedKeysPath"
            
            # Write keys to file (overwrite if exists)
            $publicKeys | Out-File -FilePath $authorizedKeysPath -Encoding ASCII -Force
            
            # Set proper permissions (only SYSTEM and Administrators should have access) -- https://superuser.com/a/1531769
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
            Write-Host "Set proper ACL permissions on authorized_keys file"
            
            Write-Host "SSH public keys installed successfully"
        } else {
            Write-Host "No public keys found in user_data"
        }
    } else {
        Write-Host "No ssh_authorized_keys in user_data"
    }
} else {
    Write-Warning "meta-data not found at $metaDataPath"
}

# Parse network configuration from network-config
$networkConfigPath = Join-Path $driveLetter "network-config"
if (-not (Test-Path $networkConfigPath)) {
    Write-Error "Network config not found at $networkConfigPath"
    Stop-Transcript
    Exit 1
}

Write-Host "`n--- Reading Network Configuration ---"
Write-Host "Reading network configuration from $networkConfigPath..."
$networkConfigContent = Get-Content $networkConfigPath -Raw
Write-Host "Network config content:"
Write-Host $networkConfigContent

# Parse the network configuration (YAML format with MAC addresses)
# Format example from nocloud:
# version: 1
# config:
#   - type: physical
#     name: eth0
#     mac_address: 'bc:24:11:8f:14:44'
#     subnets:
#       - type: dhcp6
#   - type: physical
#     name: eth1
#     mac_address: 'bc:24:11:14:af:9a'
#     subnets:
#       - type: static
#         address: '192.168.10.241'
#         netmask: '255.255.255.0'
#         gateway: '192.168.10.1'
#   - type: nameserver
#     address:
#       - '192.168.10.1'
#     search:
#       - 'poa.dalcastel.com'

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
        continue
    }
    
    if ($trimmedLine -match '^-\s+type:\s*physical') {
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
            Subnets = @()  # Support multiple subnets (IPv4 and IPv6)
            DnsServers = @()
        }
        $inSubnetsSection = $false
        $currentSubnet = $null
        continue
    }
    
    if ($trimmedLine -match '^-\s+type:\s*nameserver') {
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
        }
        elseif ($trimmedLine -match '^mac_address:\s*(.+)$') {
            $macValue = $matches[1].Trim().Trim("'").Trim('"')
            $currentInterface.MacAddress = $macValue.ToUpper().Replace(':', '-')
            Write-Host "Found interface $($currentInterface.Name) with MAC: $($currentInterface.MacAddress)"
        }
        elseif ($trimmedLine -match '^subnets:') {
            $inSubnetsSection = $true
        }
        elseif ($inSubnetsSection -and $trimmedLine -match '^-\s+type:\s*(\S+)') {
            # Save previous subnet if exists
            if ($currentSubnet -and ($currentSubnet.Address -or $currentSubnet.Type -in @('dhcp', 'dhcp6', 'ipv6_slaac'))) {
                $currentInterface.Subnets += $currentSubnet
            }
            # Start new subnet
            $currentSubnet = @{
                Type = $matches[1]
                Address = $null
                Netmask = $null
                Gateway = $null
            }
        }
        elseif ($inSubnetsSection -and $trimmedLine -match '^address:\s*(.+)$') {
            if ($currentSubnet) {
                $currentSubnet.Address = $matches[1].Trim().Trim("'").Trim('"')
            }
        }
        elseif ($inSubnetsSection -and $trimmedLine -match '^netmask:\s*(.+)$') {
            if ($currentSubnet) {
                $currentSubnet.Netmask = $matches[1].Trim().Trim("'").Trim('"')
            }
        }
        elseif ($inSubnetsSection -and $trimmedLine -match '^gateway:\s*(.+)$') {
            if ($currentSubnet) {
                $currentSubnet.Gateway = $matches[1].Trim().Trim("'").Trim('"')
            }
        }
    }
    
    # Parse nameserver section
    if ($inNameserverSection) {
        if ($trimmedLine -match '^address:') {
            $inAddressSection = $true
            $inSearchSection = $false
        }
        elseif ($trimmedLine -match '^search:') {
            $inSearchSection = $true
            $inAddressSection = $false
        }
        elseif ($inAddressSection -and $trimmedLine -match '^-\s+(.+)$') {
            $nameservers += $matches[1].Trim().Trim("'").Trim('"')
        }
        elseif ($inSearchSection -and $trimmedLine -match '^-\s+(.+)$') {
            $searchDomains += $matches[1].Trim().Trim("'").Trim('"')
        }
    }
}

# Save last subnet for last interface (only if interface exists)
if ($currentInterface -and $currentSubnet -and ($currentSubnet.Address -or $currentSubnet.Type -in @('dhcp', 'dhcp6', 'ipv6_slaac'))) {
    $currentInterface.Subnets += $currentSubnet
}

# Save last interface
if ($currentInterface -and $currentInterface.MacAddress) {
    $interfaces += $currentInterface
}

Write-Host "`nParsed $($interfaces.Count) network interface(s) with MAC addresses"
if ($nameservers.Count -gt 0) {
    Write-Host "Global DNS servers: $($nameservers -join ', ')"
}
if ($searchDomains.Count -gt 0) {
    Write-Host "Global search domains: $($searchDomains -join ', ')"
    if (-not $searchDomain -and $searchDomains.Count -gt 0) {
        $searchDomain = $searchDomains[0]
    }
}

# Function to convert CIDR prefix to netmask
function Convert-CidrToNetmask {
    param([int]$Prefix)
    $mask = [uint32](0xFFFFFFFF -shl (32 - $Prefix))
    $bytes = [System.BitConverter]::GetBytes($mask)
    if ([System.BitConverter]::IsLittleEndian) { [Array]::Reverse($bytes) }
    return [System.Net.IPAddress]::new($bytes).ToString()
}

# Function to check if gateway is on-link
function Test-GatewayOnLink {
    param(
        [string]$IpAddress,
        [int]$Prefix,
        [string]$Gateway
    )
    
    # Validate prefix is in valid range
    if ($Prefix -lt 0 -or $Prefix -gt 32) {
        Write-Warning "Invalid prefix length: $Prefix. Assuming off-link gateway."
        return $false
    }
    
    if ($Prefix -eq 32) { return $false }
    
    $ipBytes = [System.Net.IPAddress]::Parse($IpAddress).GetAddressBytes()
    $gwBytes = [System.Net.IPAddress]::Parse($Gateway).GetAddressBytes()
    
    if ([System.BitConverter]::IsLittleEndian) {
        [Array]::Reverse($ipBytes)
        [Array]::Reverse($gwBytes)
    }
    
    $ipInt = [System.BitConverter]::ToUInt32($ipBytes, 0)
    $gwInt = [System.BitConverter]::ToUInt32($gwBytes, 0)
    $maskInt = [uint32]::MaxValue -shl (32 - $Prefix)
    
    return (($ipInt -band $maskInt) -eq ($gwInt -band $maskInt))
}

# Get all network adapters
$allAdapters = @(Get-NetAdapter)
Write-Host "`nFound $($allAdapters.Count) network adapter(s) on system:"
foreach ($adapter in $allAdapters) {
    Write-Host "  - $($adapter.Name): MAC=$($adapter.MacAddress), Status=$($adapter.Status)"
}

# Configure each interface
foreach ($iface in $interfaces) {
    Write-Host "`n--- Processing Interface: $($iface.Name) ---"
    Write-Host "Looking for MAC address: $($iface.MacAddress)"
    Write-Host "Found $($iface.Subnets.Count) subnet(s) configured"
    
    if ($iface.Subnets.Count -eq 0) {
        Write-Host "Skipping interface with no subnets configured"
        continue
    }
    
    # Match by MAC address
    $adapter = $allAdapters | Where-Object { $_.MacAddress -eq $iface.MacAddress }
    
    if (-not $adapter) {
        Write-Warning "No adapter found with MAC address $($iface.MacAddress)"
        Write-Warning "Available adapters:"
        foreach ($a in $allAdapters) {
            Write-Warning "  - $($a.Name): $($a.MacAddress)"
        }
        continue
    }
    
    Write-Host "Matched Adapter: $($adapter.Name) (Index: $($adapter.InterfaceIndex), MAC: $($adapter.MacAddress))"
    
    # Process each subnet configuration
    foreach ($subnet in $iface.Subnets) {
        $subnetType = $subnet.Type
        Write-Host "`n  Configuring subnet type: $subnetType"
        
        # Handle different subnet types
        switch ($subnetType) {
            { $_ -in @('static', 'static6') } {
                $ip = $subnet.Address
                if (-not $ip) {
                    Write-Warning "  No IP address defined for static subnet"
                    continue
                }
                
                # Check if address has CIDR prefix embedded (e.g., "2001:db8::1/64")
                $prefix = $null
                if ($ip -match '^(.+)/(\d+)$') {
                    $ip = $matches[1]
                    $prefix = [int]$matches[2]
                }
                
                # Detect if IPv4 or IPv6
                $isIPv6 = $ip -match ':'
                $addressFamily = if ($isIPv6) { 'IPv6' } else { 'IPv4' }
                
                # Get prefix length from netmask if not already set
                if ($subnet.Netmask -and -not $prefix) {
                    if (-not $isIPv6) {
                        # Convert netmask to prefix length for IPv4
                        $maskBytes = [System.Net.IPAddress]::Parse($subnet.Netmask).GetAddressBytes()
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
                        Write-Host "  Converted netmask $($subnet.Netmask) to /$prefix"
                    } else {
                        # For IPv6, netmask field might contain prefix length
                        $prefix = [int]$subnet.Netmask
                    }
                }
                
                # Set defaults if still not set
                if (-not $prefix) {
                    $prefix = 24  # default for IPv4
                    if ($isIPv6) { $prefix = 64 }  # default for IPv6
                }
                
                Write-Host "  IP Configuration: $ip/$prefix ($addressFamily)"
                
                # Check if this IP is already configured (idempotency)
                $existingIP = Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily $addressFamily -ErrorAction SilentlyContinue |
                    Where-Object { $_.IPAddress -eq $ip }
                
                if ($existingIP) {
                    Write-Host "  IP address $ip already configured, skipping"
                } else {
                    # Get gateway
                    $gateway = $subnet.Gateway
                    if ($gateway) {
                        Write-Host "  Default Gateway: $gateway"
                    }
                    
                    # Configure IP address
                    if ($gateway -and -not $isIPv6) {
                        # Only handle gateway logic for IPv4 (IPv6 uses router advertisements)
                        $isOnLink = Test-GatewayOnLink -IpAddress $ip -Prefix $prefix -Gateway $gateway
                        
                        if ($isOnLink) {
                            Write-Host "  Configuring with on-link gateway..."
                            New-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex `
                                -IPAddress $ip `
                                -PrefixLength $prefix `
                                -DefaultGateway $gateway `
                                -AddressFamily $addressFamily | Out-Null
                        } else {
                            Write-Host "  Configuring with off-link gateway..."
                            
                            # Add IP address without gateway
                            New-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex `
                                -IPAddress $ip `
                                -PrefixLength $prefix `
                                -AddressFamily $addressFamily | Out-Null
                            
                            # Check if host route already exists
                            $existingHostRoute = Get-NetRoute -DestinationPrefix "$gateway/32" -InterfaceIndex $adapter.InterfaceIndex -ErrorAction SilentlyContinue
                            if (-not $existingHostRoute) {
                                Write-Host "  Adding host route to gateway $gateway..."
                                New-NetRoute -DestinationPrefix "$gateway/32" `
                                    -InterfaceIndex $adapter.InterfaceIndex `
                                    -NextHop "0.0.0.0" | Out-Null
                            }
                            
                            # Check if default route already exists
                            $existingDefaultRoute = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -InterfaceIndex $adapter.InterfaceIndex -ErrorAction SilentlyContinue
                            if (-not $existingDefaultRoute) {
                                Write-Host "  Adding default route via $gateway..."
                                New-NetRoute -DestinationPrefix "0.0.0.0/0" `
                                    -InterfaceIndex $adapter.InterfaceIndex `
                                    -NextHop $gateway | Out-Null
                            }
                        }
                    } else {
                        Write-Host "  Configuring without gateway..."
                        New-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex `
                            -IPAddress $ip `
                            -PrefixLength $prefix `
                            -AddressFamily $addressFamily | Out-Null
                    }
                    
                    Write-Host "  IP configuration applied successfully"
                }
            }
            
            'dhcp' {
                Write-Host "  Enabling DHCP for IPv4..."
                # Check if already on DHCP
                $dhcpStatus = Get-NetIPInterface -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
                if ($dhcpStatus -and $dhcpStatus.Dhcp -eq 'Enabled') {
                    Write-Host "  DHCP already enabled"
                } else {
                    Set-NetIPInterface -InterfaceIndex $adapter.InterfaceIndex -Dhcp Enabled -AddressFamily IPv4
                    Write-Host "  DHCP enabled"
                }
            }
            
            'dhcp6' {
                Write-Host "  Enabling DHCP for IPv6..."
                $dhcpStatus = Get-NetIPInterface -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue
                if ($dhcpStatus -and $dhcpStatus.Dhcp -eq 'Enabled') {
                    Write-Host "  DHCPv6 already enabled"
                } else {
                    Set-NetIPInterface -InterfaceIndex $adapter.InterfaceIndex -Dhcp Enabled -AddressFamily IPv6
                    Write-Host "  DHCPv6 enabled"
                }
            }
            
            'ipv6_slaac' {
                Write-Host "  Enabling IPv6 SLAAC (Stateless Address Autoconfiguration)..."
                # Ensure IPv6 router discovery is enabled
                $routerDiscovery = Get-NetIPInterface -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue
                if ($routerDiscovery) {
                    if ($routerDiscovery.RouterDiscovery -ne 'Enabled') {
                        Set-NetIPInterface -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv6 -RouterDiscovery Enabled
                        Write-Host "  IPv6 router discovery enabled"
                    } else {
                        Write-Host "  IPv6 SLAAC already enabled"
                    }
                }
            }
            
            default {
                Write-Host "  Unsupported subnet type: $subnetType"
            }
        }
    }
    
    # Configure DNS - use global nameservers from network config
    $dns = if ($nameservers.Count -gt 0) { $nameservers } else { $iface.DnsServers }
    
    if ($dns.Count -gt 0) {
        # Check current DNS configuration
        $currentDNS = (Get-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
        $dnsChanged = $false
        
        if ($currentDNS) {
            # Compare DNS servers
            if ($currentDNS.Count -ne $dns.Count) {
                $dnsChanged = $true
            } else {
                for ($i = 0; $i -lt $dns.Count; $i++) {
                    if ($currentDNS[$i] -ne $dns[$i]) {
                        $dnsChanged = $true
                        break
                    }
                }
            }
        } else {
            $dnsChanged = $true
        }
        
        if ($dnsChanged) {
            Write-Host "Configuring DNS: $($dns -join ', ')"
            Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex `
                -ServerAddresses $dns
        } else {
            Write-Host "DNS already configured correctly"
        }
    }
    
    # Configure DNS search domain for all interfaces
    if ($searchDomain) {
        $currentSuffix = (Get-DnsClient -InterfaceIndex $adapter.InterfaceIndex -ErrorAction SilentlyContinue).ConnectionSpecificSuffix
        if ($currentSuffix -ne $searchDomain) {
            Write-Host "Configuring DNS search domain: $searchDomain"
            Set-DnsClient -InterfaceIndex $adapter.InterfaceIndex `
                -ConnectionSpecificSuffix $searchDomain
            Write-Host "DNS search domain configured successfully"
        } else {
            Write-Host "DNS search domain already configured correctly"
        }
    }
}

Write-Host "`n=== Cloud-Init Script Completed ==="
Stop-Transcript
