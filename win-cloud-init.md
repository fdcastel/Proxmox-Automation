# win-cloud-init

## Overview

`win-cloud-init.ps1` is a minimal PowerShell implementation of cloud-init functionality for Windows VMs running on Proxmox VE.

It provides basic support for the configuration parameters that Proxmox's cloud-init feature generates, focusing specifically on network configuration and SSH key management.

**Important:** This is not a full cloud-init implementation. It is designed to work specifically with Proxmox VE's cloud-init drive (NoCloud format) and only supports a minimal subset of cloud-init features.

## Purpose

This script enables Windows VMs created with `new-vm-windows.sh` to:
- Automatically configure static IP addresses from Proxmox cloud-init settings
- Set up DNS servers and search domains
- Install SSH public keys for administrator access
- Handle both on-link and off-link gateway configurations

## How It Works

### 1. Execution Context

The script is executed during Windows installation via `SetupComplete.cmd`, which runs automatically at the end of the Windows setup process (OOBE phase). The execution flow is:

1. `new-vm-windows.sh` creates an ISO with the script
2. The ISO is attached to the VM as drive `E:\`
3. Windows installation includes `SetupComplete.cmd` in `C:\Windows\Setup\Scripts\`
4. After installation completes, Windows automatically runs `SetupComplete.cmd`
5. `SetupComplete.cmd` executes `powershell.exe -ExecutionPolicy Bypass -File E:\win-cloud-init.ps1`

### 2. Cloud-Init Drive Detection

The script looks for a volume labeled `cidata` (Proxmox's NoCloud format):

```powershell
$cidata = Get-Volume -FileSystemLabel "cidata"
```

It waits up to 30 seconds for the drive to appear, accounting for potential delays in drive mounting during the boot process.

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

Example:
```yaml
version: 1
config:
  - type: physical
    name: eth0
    mac_address: 'bc:24:11:8f:14:44'
    subnets:
      - type: dhcp6
  - type: physical
    name: eth1
    mac_address: 'bc:24:11:14:af:9a'
    subnets:
      - type: static
        address: '192.168.10.241'
        netmask: '255.255.255.0'
        gateway: '192.168.10.1'
  - type: physical
    name: eth2
    mac_address: 'bc:24:11:c9:b8:fc'
    subnets:
      - type: ipv6_slaac
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

For each static interface, the script:

1. Disables DHCP
2. Removes existing IP addresses and routes
3. Converts netmask to CIDR prefix length
4. Configures the IP address

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

### 7. Logging

All output is logged to `C:\Windows\Panther\win-cloud-init.log` using PowerShell's `Start-Transcript` and `Stop-Transcript` cmdlets.

## Limitations and Known Issues

### 1. **No IPv6 Support**

**Issue:** The script only handles IPv4 addresses. All operations use `-AddressFamily IPv4`.

**Impact:** Cannot configure IPv6 addresses via cloud-init.

**Workaround:** Configure IPv6 manually after VM creation or use a different provisioning method.

**Future Fix:** Parse and configure IPv6 addresses from cloud-init data. The `network-config` format already supports `ipv6_slaac` and `dhcp6` types, so this would require extending the PowerShell parser to handle IPv6 addresses.

### 2. **Single Execution Assumption**

**Issue:** The script is designed to run once during initial setup via `SetupComplete.cmd`.

**Impact:** 
- Cannot be used to reconfigure networking on a running system
- Doesn't handle already-configured interfaces gracefully
- Running it again may cause duplicate routes or conflicting configurations

**Workaround:** The script does attempt to clear existing configuration before applying new settings:
```powershell
Set-NetIPInterface -InterfaceIndex $adapter.InterfaceIndex -Dhcp Disabled
Remove-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -Confirm:$false
Remove-NetRoute -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -Confirm:$false
```

**Future Fix:** Add idempotency checks to safely handle multiple executions.

### 3. **Netmask to Prefix Conversion Accuracy**

**Issue:** The netmask-to-prefix conversion counts all '1' bits but doesn't validate that they are contiguous:

```powershell
for ($b = 0; $b -lt 32; $b++) {
    if (($maskInt -shr $b) -band 1) { $prefix++ }
}
```

**Impact:** An invalid netmask like `255.0.255.0` would be incorrectly counted as `/16` instead of being rejected.

**Workaround:** Only use valid netmasks (contiguous '1' bits from left to right).

**Future Fix:** Validate that netmask bits are contiguous before calculating prefix length.

### 4. **Off-link Gateway Host Route**

**Issue:** The off-link gateway configuration adds a host route using `0.0.0.0` as next hop:

```powershell
New-NetRoute -DestinationPrefix "$gateway/32" -NextHop "0.0.0.0"
```

**Impact:** This works in most cases but may not be the most correct approach. Some network configurations might not accept this.

**Workaround:** The current implementation works for typical Proxmox hosting environments with public IPs.

**Future Fix:** Research and implement the most RFC-compliant method for configuring off-link gateways on Windows.

### 5. **No Multi-Gateway Support**

**Issue:** Only one default gateway is configured per interface.

**Impact:** Cannot configure multiple default routes or policy-based routing.

**Workaround:** Configure additional routes manually after VM creation.

**Future Fix:** Parse and configure multiple routes if provided in cloud-init data.

### 6. **Simple YAML Parser**

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

### Standalone Execution

While designed for automated execution, the script can be run manually:

```powershell
# Must be run with Administrator privileges
powershell.exe -ExecutionPolicy Bypass -File E:\win-cloud-init.ps1
```

Where `E:` is the drive letter of the mounted cloud-init drive.

### Log File

Check the log file for execution details:

```powershell
Get-Content C:\Windows\Panther\win-cloud-init.log
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

1. **IPv6 support** - Handle dual-stack configurations (network-config already includes ipv6_slaac and dhcp6 types)
2. **Full cloud-init compatibility** - Support more cloud-init features and modules
3. **Idempotency** - Safe to run multiple times with proper state checking
4. **User data script execution** - Run custom scripts from user_data (runcmd, bootcmd modules)
5. **Password configuration** - Set administrator password from cloud-init
6. **Multiple network routes** - Support complex routing scenarios
7. **Validation and rollback** - Verify configuration and rollback on failure
8. **Full YAML parser** - Replace simple parser with a robust YAML library

## Version History

### Version 2.0 (Current)
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
