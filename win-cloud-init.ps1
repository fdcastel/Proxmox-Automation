$LogPath = "C:\Windows\Panther\win-cloud-init.log"
Start-Transcript -Path $LogPath -Append
$ErrorActionPreference = "Stop"

Write-Host "Starting Cloud-Init Network Configuration (configdrive2 format)..."

# Wait for the Cloud-Init drive to appear
$cidata = $null
for ($i = 0; $i -lt 30; $i++) {
    $cidata = Get-Volume -FileSystemLabel "config-2" -ErrorAction SilentlyContinue
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

# Parse user_data
$userDataPath = Join-Path $driveLetter "openstack\latest\user_data"
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

# Parse meta_data.json
$metaDataPath = Join-Path $driveLetter "openstack\latest\meta_data.json"
if (Test-Path $metaDataPath) {
    Write-Host "Reading meta_data.json..."
    $metaData = Get-Content $metaDataPath -Raw | ConvertFrom-Json
    Write-Host "Instance ID: $($metaData.uuid)"
    Write-Host "Hostname: $($metaData.hostname)"
    
    # Process SSH public keys
    if ($metaData.public_keys) {
        Write-Host "`n--- Processing SSH Public Keys ---"
        $sshDir = "C:\ProgramData\ssh"
        $authorizedKeysPath = Join-Path $sshDir "administrators_authorized_keys"
        
        # Create SSH directory if it doesn't exist
        if (-not (Test-Path $sshDir)) {
            Write-Host "Creating SSH directory: $sshDir"
            New-Item -Path $sshDir -ItemType Directory -Force | Out-Null
        }
        
        # Collect all public keys
        $publicKeys = @()
        foreach ($keyProperty in $metaData.public_keys.PSObject.Properties) {
            $keyName = $keyProperty.Name
            $keyValue = $keyProperty.Value
            Write-Host "Found key: $keyName"
            $publicKeys += $keyValue
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
            Write-Host "No public keys found in metadata"
        }
    } else {
        Write-Host "No public_keys field in meta_data.json"
    }
} else {
    Write-Warning "meta_data.json not found at $metaDataPath"
}

# Parse network configuration from content/0000
$networkConfigPath = Join-Path $driveLetter "openstack\content\0000"
if (-not (Test-Path $networkConfigPath)) {
    Write-Error "Network config not found at $networkConfigPath"
    Stop-Transcript
    Exit 1
}

Write-Host "Reading network configuration from $networkConfigPath..."
$networkConfigContent = Get-Content $networkConfigPath -Raw
Write-Host "Network config content:"
Write-Host $networkConfigContent

# Parse the network configuration
# Format is like: auto eth0 \n iface eth0 inet static \n address X.X.X.X \n netmask X.X.X.X \n gateway X.X.X.X \n dns-nameservers X.X.X.X X.X.X.X
$interfaces = @()
$currentInterface = $null

foreach ($line in $networkConfigContent -split "`n") {
    $line = $line.Trim()
    
    if ($line -match "^auto\s+(\S+)") {
        # Start of new interface
        if ($currentInterface) {
            $interfaces += $currentInterface
        }
        $currentInterface = @{
            Name = $matches[1]
            Type = $null
            Address = $null
            Netmask = $null
            Gateway = $null
            DnsServers = @()
        }
    }
    elseif ($line -match "^iface\s+(\S+)\s+inet\s+(\S+)") {
        if ($currentInterface) {
            $currentInterface.Type = $matches[2]
        }
    }
    elseif ($line -match "^address\s+(.+)") {
        if ($currentInterface) {
            $currentInterface.Address = $matches[1].Trim()
        }
    }
    elseif ($line -match "^netmask\s+(.+)") {
        if ($currentInterface) {
            $currentInterface.Netmask = $matches[1].Trim()
        }
    }
    elseif ($line -match "^gateway\s+(.+)") {
        if ($currentInterface) {
            $currentInterface.Gateway = $matches[1].Trim()
        }
    }
    elseif ($line -match "^dns-nameservers\s+(.+)") {
        if ($currentInterface) {
            $dnsServers = $matches[1].Trim() -split "\s+"
            $currentInterface.DnsServers = $dnsServers
        }
    }
}

# Add the last interface
if ($currentInterface) {
    $interfaces += $currentInterface
}

Write-Host "Parsed $($interfaces.Count) network interface(s)"

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
    
    if ($Prefix -eq 32) { return $false }
    
    $ipBytes = [System.Net.IPAddress]::Parse($IpAddress).GetAddressBytes()
    $gwBytes = [System.Net.IPAddress]::Parse($Gateway).GetAddressBytes()
    
    if ([System.BitConverter]::IsLittleEndian) {
        [Array]::Reverse($ipBytes)
        [Array]::Reverse($gwBytes)
    }
    
    $ipInt = [System.BitConverter]::ToUInt32($ipBytes, 0)
    $gwInt = [System.BitConverter]::ToUInt32($gwBytes, 0)
    $maskInt = [uint32](0xFFFFFFFF -shl (32 - $Prefix))
    
    return (($ipInt -band $maskInt) -eq ($gwInt -band $maskInt))
}

# Get all network adapters
$allAdapters = Get-NetAdapter | Sort-Object -Property Name   # First adapter is 'Ethernet', second is 'Ethernet 2', etc.

# Configure each interface
$interfaceIndex = 0
foreach ($iface in $interfaces) {
    Write-Host "`n--- Processing Interface: $($iface.Name) ---"
    
    if ($iface.Type -ne "static") {
        Write-Host "Skipping non-static interface"
        continue
    }
    
    # Match by interface index (eth0 = first adapter, eth1 = second adapter, etc)
    if ($interfaceIndex -ge $allAdapters.Count) {
        Write-Warning "No adapter found for interface index $interfaceIndex"
        continue
    }
    
    $adapter = $allAdapters[$interfaceIndex]
    $interfaceIndex++
    
    Write-Host "Matched Adapter: $($adapter.Name) (Index: $($adapter.InterfaceIndex), MAC: $($adapter.MacAddress))"
    
    # Clear existing configuration
    Write-Host "Clearing existing configuration..."
    Set-NetIPInterface -InterfaceIndex $adapter.InterfaceIndex -Dhcp Disabled -ErrorAction SilentlyContinue
    Remove-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetRoute -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
    
    # Get IP configuration
    $ip = $iface.Address
    if (-not $ip) {
        Write-Warning "No IP address defined for interface '$($iface.Name)'"
        continue
    }
    
    $netmask = $iface.Netmask
    $prefix = 24  # default
    
    if ($netmask) {
        # Convert netmask to prefix length
        $maskBytes = [System.Net.IPAddress]::Parse($netmask).GetAddressBytes()
        if ([System.BitConverter]::IsLittleEndian) { [Array]::Reverse($maskBytes) }
        $maskInt = [System.BitConverter]::ToUInt32($maskBytes, 0)
        $prefix = 0
        for ($b = 0; $b -lt 32; $b++) {
            if (($maskInt -shr $b) -band 1) { $prefix++ }
        }
    }
    
    Write-Host "IP Configuration: $ip/$prefix"
    
    # Get gateway
    $gateway = $iface.Gateway
    if ($gateway) {
        Write-Host "Default Gateway: $gateway"
    }
    
    # Configure IP address
    if ($gateway) {
        $isOnLink = Test-GatewayOnLink -IpAddress $ip -Prefix $prefix -Gateway $gateway
        
        if ($isOnLink) {
            Write-Host "Configuring with on-link gateway..."
            New-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex `
                -IPAddress $ip `
                -PrefixLength $prefix `
                -DefaultGateway $gateway `
                -AddressFamily IPv4 | Out-Null
        } else {
            Write-Host "Configuring with off-link gateway..."
            
            # Add IP address without gateway
            New-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex `
                -IPAddress $ip `
                -PrefixLength $prefix `
                -AddressFamily IPv4 | Out-Null
            
            # Add host route to gateway
            Write-Host "Adding host route to gateway $gateway..."
            New-NetRoute -DestinationPrefix "$gateway/32" `
                -InterfaceIndex $adapter.InterfaceIndex `
                -NextHop "0.0.0.0" | Out-Null
            Write-Host "Host route added successfully"
            
            # Add default route via gateway
            Write-Host "Adding default route via $gateway..."
            New-NetRoute -DestinationPrefix "0.0.0.0/0" `
                -InterfaceIndex $adapter.InterfaceIndex `
                -NextHop $gateway | Out-Null
            Write-Host "Default route added successfully"
        }
    } else {
        Write-Host "Configuring without gateway..."
        New-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex `
            -IPAddress $ip `
            -PrefixLength $prefix `
            -AddressFamily IPv4 | Out-Null
    }
    
    Write-Host "IP configuration applied successfully"
    
    # Configure DNS
    $dns = $iface.DnsServers
    
    if ($dns.Count -gt 0) {
        Write-Host "Configuring DNS: $($dns -join ', ')"
        Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex `
            -ServerAddresses $dns
    }
    
    # Configure DNS search domain for all interfaces
    if ($searchDomain) {
        Write-Host "Configuring DNS search domain: $searchDomain"
        Set-DnsClient -InterfaceIndex $adapter.InterfaceIndex `
            -ConnectionSpecificSuffix $searchDomain
        Write-Host "DNS search domain configured successfully"
    }
}

Write-Host "`n=== Cloud-Init Script Completed ==="
Stop-Transcript
