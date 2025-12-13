# PSCloudInit

## Overview

`PSCloudInit.ps1` is a minimal PowerShell implementation of cloud-init functionality for Windows VMs running on Proxmox VE.

It provides basic support for the configuration parameters that Proxmox's cloud-init feature generates, focusing specifically on network configuration and SSH key management.

**Important:** This is not a full cloud-init implementation. It is designed to work specifically with Proxmox VE's cloud-init drive (NoCloud format) and only supports a minimal subset of cloud-init features.

## Purpose

This script enables Windows VMs created with `new-vm-windows.sh` to:
- Automatically configure static IPv4 and IPv6 addresses from Proxmox cloud-init settings
- Enable DHCP, DHCPv6, and IPv6 SLAAC for dynamic addressing
- Support multiple IP addresses (IPv4 and IPv6) on the same interface
- Set up DNS servers (IPv4 and IPv6) and search domains
- Install SSH public keys for administrator access
- Handle both on-link and off-link gateway configurations
- Run safely multiple times (idempotent)

## How It Works

### 1. Execution Context

The script is executed during Windows installation via `SetupComplete.cmd`, which runs automatically at the end of the Windows setup process (OOBE phase). The execution flow is:

1. `new-vm-windows.sh` creates an ISO with the script
2. The ISO is attached to the VM as drive `E:\`
3. Windows installation includes `SetupComplete.cmd` in `C:\Windows\Setup\Scripts\`
4. After installation completes, Windows automatically runs `SetupComplete.cmd`
5. `SetupComplete.cmd` executes `powershell.exe -ExecutionPolicy Bypass -File E:\PSCloudInit.ps1`

### 2. Cloud-init Drive Detection

The script looks for a volume labeled `cidata` (Proxmox's NoCloud format):

```powershell
$cidata = Get-Volume -FileSystemLabel "cidata"
```

By default, it waits up to 5 seconds for the drive to appear.

### 3. Configuration Files

The script reads three files from the root of the cloud-init drive:

#### a) `user-data`
- YAML format containing user configuration
- Used to extract:
  - FQDN information (format: `fqdn: hostname.domain.com`)
  - SSH authorized keys (under `ssh_authorized_keys:` section)
- The domain suffix (everything after the first dot in FQDN) becomes the DNS search domain

Example:
```yaml
#cloud-config
hostname: tst241
manage_etc_hosts: true
fqdn: tst241.poa.dalcastel.com
password: asdf
ssh_authorized_keys:
  - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABQ...
  - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAA...
chpasswd:
  expire: false
users:
  - default
package_upgrade: true
```

#### b) `meta-data`
- YAML format containing instance metadata
- Key fields used:
  - `instance_id`: Instance identifier
  - `hostname`: VM hostname

Example:
```yaml
instance-id: tst241
hostname: tst241
```

#### c) `network-config`
- YAML format (cloud-init network config version 1)
- Contains interface definitions with MAC addresses for reliable matching
- Includes static IP configuration, DHCP configuration, nameservers, and search domains

Example (IPv4 and IPv6):
```yaml
version: 1
config:
  - type: physical
    name: eth0
    mac_address: 'bc:24:11:8f:14:44'
    subnets:
      - type: dhcp        # IPv4 DHCP
      - type: dhcp6       # IPv6 DHCPv6
  - type: physical
    name: eth1
    mac_address: 'bc:24:11:14:af:9a'
    subnets:
      - type: static
        address: '192.168.10.241'
        netmask: '255.255.255.0'
        gateway: '192.168.10.1'
      - type: static      # IPv6 static address
        address: '2001:db8::1'
        netmask: '64'
  - type: physical
    name: eth2
    mac_address: 'bc:24:11:c9:b8:fc'
    subnets:
      - type: ipv6_slaac  # IPv6 auto-configuration
  - type: physical
    name: eth3
    mac_address: 'bc:24:11:16:64:2b'
    subnets:
      - type: static
        address: '1.1.1.1'
        netmask: '255.240.0.0'
  - type: nameserver
    address:
      - '192.168.10.1'
      - '2001:4860:4860::8888'  # IPv6 DNS (Google Public DNS)
    search:
      - 'poa.dalcastel.com'
```

### 4. SSH Key Installation

When SSH public keys are found in `user-data` under `ssh_authorized_keys:`:

1. Creates `C:\ProgramData\ssh\` directory if needed
2. Writes all public keys to `C:\ProgramData\ssh\administrators_authorized_keys`
3. Sets proper ACL permissions (only SYSTEM and Administrators have access)
4. Keys are written in OpenSSH format, one per line

**Note:** This assumes that the OpenSSH Server is -- or will be -- installed.
- Windows Server 2019 and 2022 include OpenSSH as an optional feature.
- Windows Server 2025 has OpenSSH installed by default.

### 5. Network Configuration

#### Interface Matching

The script uses **MAC address-based matching** for reliable interface identification:
- Each interface in `network-config` includes a `mac_address` field
- Windows network adapters are matched by comparing MAC addresses
- This approach is reliable even with dozens of interfaces and doesn't depend on adapter enumeration order

```powershell
$adapter = $allAdapters | Where-Object { $_.MacAddress -eq $iface.MacAddress }
```

Example matching process:
1. Parse `network-config` and extract interface with `mac_address: 'bc:24:11:14:af:9a'`
2. Find Windows adapter with matching MAC address `BC-24-11-14-AF-9A`
3. Apply configuration to that specific adapter

This ensures configuration is always applied to the correct physical interface, regardless of:
- Adapter naming in Windows (Ethernet, Ethernet 2, etc.)
- Order in which adapters are detected by Windows
- Number of network interfaces in the VM

#### Static IP Configuration

The script supports multiple subnet configurations per interface, including:

- **static**: Static IPv4 or IPv6 addresses with optional gateway
- **dhcp**: Dynamic IPv4 address assignment via DHCP
- **dhcp6**: Dynamic IPv6 address assignment via DHCPv6
- **ipv6_slaac**: IPv6 Stateless Address Autoconfiguration (SLAAC)

For each subnet configuration, the script:

1. Detects if the address is IPv4 or IPv6 automatically
2. Checks if the IP is already configured (idempotency)
3. Converts netmask to CIDR prefix length (for IPv4)
4. Configures the IP address only if not already present
5. Checks for existing routes before adding new ones

#### Gateway Configuration

The script handles two scenarios:

**On-link Gateway** (gateway is in the same subnet):
```powershell
New-NetIPAddress -IPAddress $ip -PrefixLength $prefix -DefaultGateway $gateway
```

**Off-link Gateway** (gateway is NOT in the same subnet):
```powershell
# Add IP without gateway
New-NetIPAddress -IPAddress $ip -PrefixLength $prefix

# Add host route to gateway
New-NetRoute -DestinationPrefix "$gateway/32" -NextHop "0.0.0.0"

# Add default route via gateway
New-NetRoute -DestinationPrefix "0.0.0.0/0" -NextHop $gateway
```

This off-link gateway handling is crucial for VMs with public IP addresses where the gateway is outside the assigned subnet.

#### DNS Configuration

- DNS servers are configured per interface using `Set-DnsClientServerAddress`
- DNS search domain is applied to **all interfaces** that have network configuration
  - The search domain is extracted from the FQDN in `user_data`
  - This ensures single-interface VMs and multi-interface VMs both get proper DNS resolution

### 6. Error Handling

The script uses a **fail-fast** approach with `$ErrorActionPreference = "Stop"`. Any critical error during execution will cause the script to terminate immediately, ensuring that partial or incorrect configurations are not applied silently.

This means:
- Network configuration errors will halt execution
- SSH key installation errors will stop the script
- DNS configuration failures will prevent completion

### 7. Idempotency

The script is designed to be **idempotent** and can be safely run multiple times. It checks the current configuration before making changes:

- **IP Addresses**: Checks if the IP address is already configured before attempting to add it
- **Routes**: Verifies if routes exist before creating new ones (host routes and default routes)
- **DNS**: Compares current DNS server configuration with desired state
- **DNS Search Domain**: Only updates if different from current value
- **DHCP**: Checks if DHCP is already enabled before enabling it

This makes the script safe to use for both initial configuration and subsequent updates without causing errors or duplicate configurations.

### 8. Logging

All output is logged to `C:\Windows\Panther\PSCloudInit.log` using PowerShell's `Start-Transcript` and `Stop-Transcript` cmdlets.

## Limitations and Known Issues

### 1. **Netmask to Prefix Conversion Accuracy**

**Issue:** The netmask-to-prefix conversion counts all '1' bits but doesn't validate that they are contiguous:

```powershell
for ($b = 0; $b -lt 32; $b++) {
    if (($maskInt -shr $b) -band 1) { $prefix++ }
}
```

**Impact:** An invalid netmask like `255.0.255.0` would be incorrectly counted as `/16` instead of being rejected.

**Workaround:** Only use valid netmasks (contiguous '1' bits from left to right).

**Future Fix:** Validate that netmask bits are contiguous before calculating prefix length.

### 2. **Off-link Gateway Host Route**

**Issue:** The off-link gateway configuration adds a host route using `0.0.0.0` as next hop:

```powershell
New-NetRoute -DestinationPrefix "$gateway/32" -NextHop "0.0.0.0"
```

**Impact:** This works in most cases but may not be the most correct approach. Some network configurations might not accept this.

**Workaround:** The current implementation works for typical Proxmox hosting environments with public IPs.

**Future Fix:** Research and implement the most RFC-compliant method for configuring off-link gateways on Windows.

### 3. **No Multi-Gateway Support**

**Issue:** Only one default gateway is configured per interface.

**Impact:** Cannot configure multiple default routes or policy-based routing.

**Workaround:** Configure additional routes manually after VM creation.

**Future Fix:** Parse and configure multiple routes if provided in cloud-init data.

### 4. **Simple YAML Parser**

**Issue:** The script includes a basic YAML parser (`ConvertFrom-SimpleYaml`) that handles the simple key-value format used by Proxmox's `user-data` and `meta-data` files. However, it's not a full YAML parser.

**Impact:** 
- Works well for Proxmox's simple YAML format
- The `network-config` file uses a more complex nested structure and is parsed with custom logic specific to the cloud-init network config v1 format
- May not handle all possible YAML constructs

**Workaround:** The current implementation is specifically designed for Proxmox's cloud-init format and handles the structures that Proxmox generates.

**Future Fix:** Consider using a full-featured YAML parser module if more complex YAML processing is needed.

## Usage

### Prerequisites

- Windows Server 2019+ or Windows 10/11 (with OpenSSH Server installed if using SSH keys)
- VM created with Proxmox cloud-init drive configured
- Script must be executed during or after Windows setup

### Parameters

The script supports the following parameters:

- **`-Install`**: Installs the script as a Windows Scheduled Task that runs at system startup
  - Copies the script to `C:\Windows\Setup\Scripts\`
  - Creates a scheduled task named "CloudInit-WindowsSetup"
  - Task runs at startup with SYSTEM privileges

- **`-Verbose`**: Enable detailed diagnostic output for troubleshooting
  - Shows each decision branch taken during execution
  - Displays parsing details and configuration validation
  - Useful for debugging configuration issues

- **`-WhatIf`**: Preview mode - shows what actions would be taken without making changes
  - Displays proposed network configurations
  - Shows SSH keys that would be installed
  - Safe for testing before actual execution

### Installation as Startup Task

To install the script to run automatically at Windows startup:

```powershell
# Must be run with Administrator privileges
powershell.exe -ExecutionPolicy Bypass -File E:\PSCloudInit.ps1 -Install
```

This will:
1. Copy the script to `C:\Windows\Setup\Scripts\PSCloudInit.ps1`
2. Create a scheduled task that runs at system startup
3. Configure the task to run with SYSTEM privileges
4. Run the configuration process if a `cidata` volume drive is found.

### Standalone Execution

While designed for automated execution, the script can be run manually:

```powershell
# Basic execution (must be run with Administrator privileges)
powershell.exe -ExecutionPolicy Bypass -File E:\PSCloudInit.ps1

# With verbose output for troubleshooting
powershell.exe -ExecutionPolicy Bypass -File E:\PSCloudInit.ps1 -Verbose

# Preview mode (no changes made)
powershell.exe -ExecutionPolicy Bypass -File E:\PSCloudInit.ps1 -WhatIf

# Combination of parameters
powershell.exe -ExecutionPolicy Bypass -File E:\PSCloudInit.ps1 -Verbose -SecondsForCloudInitDrive 10
```

Where `E:` is the drive letter of the mounted cloud-init drive.

### Log File

Check the log file for execution details:

```powershell
Get-Content C:\Windows\Panther\PSCloudInit.log
```

### Verification

After execution, verify the configuration:

```powershell
# Check IP configuration
Get-NetIPAddress -AddressFamily IPv4

# Check routes
Get-NetRoute -AddressFamily IPv4

# Check DNS servers
Get-DnsClientServerAddress -AddressFamily IPv4

# Check DNS search domain
Get-DnsClient | Select-Object InterfaceAlias, ConnectionSpecificSuffix

# Check SSH authorized keys (if configured)
Get-Content C:\ProgramData\ssh\administrators_authorized_keys
```

## Future Enhancements

Potential improvements for future versions:

1. **Full cloud-init compatibility** - Support more cloud-init features and modules
2. **User data script execution** - Run custom scripts from user_data (runcmd, bootcmd modules)
3. **Multiple network routes** - Support complex routing scenarios
4. **Validation and rollback** - Verify configuration and rollback on failure
5. **Full YAML parser** - Replace simple parser with a robust YAML library
6. **IPv6 gateway configuration** - Add support for explicit IPv6 gateway configuration (currently relies on router advertisements)

## Version History

### Version 3.0 (Current)
- **New Feature:** CmdletBinding support for PowerShell best practices
  - Added `-Verbose` parameter for detailed diagnostic output
  - Added `-WhatIf` parameter for preview mode (no changes made)
  - Write-Verbose used for debug information at each decision branch
  - Write-Host used for user-facing action notifications
- **New Feature:** Installation as scheduled task
  - Added `-Install` parameter to set up automatic startup execution
  - Copies script to `C:\Windows\Setup\Scripts\`
  - Creates scheduled task "CloudInit-WindowsSetup" to run at startup
  - Task runs with SYSTEM privileges
- **New Feature:** Configurable cloud-init drive timeout
  - Added `-SecondsForCloudInitDrive` parameter (default: 5 seconds)
  - Different timeouts for manual execution vs. scheduled task
- **Refactoring:** Improved code organization
  - All functions moved to dedicated section at file start
  - Main script execution after function declarations
  - No inline function definitions in main code
- **Enhancement:** Centralized error handling
  - Single try/catch/finally block around main script
  - Consistent error reporting and cleanup
  - Proper transcript handling in all code paths
- **Enhancement:** Dedicated function for cloud-init drive detection
  - `Wait-CloudInitDrive` function with configurable timeout
  - Better logging and verbose output

### Version 2.1
- **New Feature:** Full IPv6 support
  - Configure static IPv6 addresses
  - Enable DHCPv6 for dynamic IPv6 addressing
  - Support IPv6 SLAAC (Stateless Address Autoconfiguration)
  - Automatic detection of IPv4 vs IPv6 addresses
- **New Feature:** Idempotency
  - Safe to run multiple times without errors
  - Checks existing IP addresses before adding
  - Verifies routes exist before creating
  - Compares DNS configuration before updating
  - Smart DHCP enable/disable logic
- **Enhancement:** Multi-subnet support per interface
  - Each interface can have multiple IPv4 and IPv6 addresses
  - Mix of static, DHCP, and SLAAC on same interface
- **Enhancement:** Improved error handling and logging

### Version 2.0
- **Breaking Change:** Switched from ConfigDrive v2 to NoCloud format
- Changed drive label from `config-2` to `cidata`
- Updated file paths to root-level (`user-data`, `meta-data`, `network-config`)
- Implemented MAC address-based interface matching (resolves reliability issues)
- Added YAML parsing for network-config with full MAC address support
- Moved SSH keys parsing from meta-data to user-data (per NoCloud standard)
- Added support for global nameservers and search domains from network-config
- Enhanced logging and debugging output
- Can now reliably handle dozens of network interfaces

### Version 1.0 (Legacy)
- ConfigDrive v2 format support
- Index-based interface matching
- Debian interfaces file format parsing
- JSON meta-data parsing

## References

- [Proxmox Cloud-Init Support](https://pve.proxmox.com/wiki/Cloud-Init_Support)
- [Cloud-Init NoCloud Datasource](https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html)
- [Cloud-Init Network Config v1](https://cloudinit.readthedocs.io/en/latest/reference/network-config-format-v1.html)
- [OpenSSH for Windows](https://docs.microsoft.com/en-us/windows-server/administration/openssh/openssh_overview)
- [Windows Unattended Installation](https://docs.microsoft.com/en-us/windows-hardware/manufacture/desktop/automate-windows-setup)
