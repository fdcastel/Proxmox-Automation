# win-cloud-init

## Overview

`win-cloud-init.ps1` is a minimal PowerShell implementation of cloud-init functionality for Windows VMs running on Proxmox VE.

It provides basic support for the configuration parameters that Proxmox's cloud-init feature generates, focusing specifically on network configuration and SSH key management.

**Important:** This is not a full cloud-init implementation. It is designed to work specifically with Proxmox VE's cloud-init drive (ConfigDrive v2 format) and only supports a minimal subset of cloud-init features.

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

The script looks for a volume labeled `config-2` (Proxmox's ConfigDrive v2 format):

```powershell
$cidata = Get-Volume -FileSystemLabel "config-2"
```

It waits up to 30 seconds for the drive to appear, accounting for potential delays in drive mounting during the boot process.

### 3. Configuration Files

The script reads three files from the cloud-init drive:

#### a) `openstack/latest/user_data`
- Contains FQDN information
- Used to extract DNS search domain
- Format: `fqdn: hostname.domain.com`
- The domain suffix (everything after the first dot) becomes the DNS search domain

#### b) `openstack/latest/meta_data.json`
- JSON format containing metadata
- Key fields used:
  - `uuid`: Instance identifier
  - `hostname`: VM hostname
  - `public_keys`: SSH public keys object (key-value pairs)

Example:
```json
{
  "uuid": "...",
  "hostname": "myhost",
  "public_keys": {
    "key1": "ssh-rsa AAAAB3NzaC1yc2EA...",
    "key2": "ssh-ed25519 AAAAC3NzaC1lZDI1..."
  }
}
```

#### c) `openstack/content/0000`
- Network configuration in Debian-style network interfaces format
- Contains interface definitions with static IP configuration

Example:
```
auto eth0
iface eth0 inet static
address 192.168.1.10
netmask 255.255.255.0
gateway 192.168.1.1
dns-nameservers 8.8.8.8 8.8.4.4
```

### 4. SSH Key Installation

When SSH public keys are found in `meta_data.json`:

1. Creates `C:\ProgramData\ssh\` directory if needed
2. Writes all public keys to `C:\ProgramData\ssh\administrators_authorized_keys`
3. Sets proper ACL permissions (only SYSTEM and Administrators have access)
4. Keys are written in OpenSSH format, one per line

**Note:** This assumes that the OpenSSH Server is -- or will be -- installed.
- Windows Server 2019 and 2022 include OpenSSH as an optional feature.
- Windows Server 2025 has OpenSSH installed by default.

### 5. Network Configuration

#### Interface Matching

The script uses a **simple index-based matching** approach:
- `eth0` → First network adapter (sorted by name: "Ethernet")
- `eth1` → Second network adapter (sorted by name: "Ethernet 2")
- `eth2` → Third network adapter, etc.

```powershell
$allAdapters = Get-NetAdapter | Sort-Object -Property Name
```

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

### 1. **Interface Matching by Index Only**

**Issue:** The script matches network interfaces by index (eth0 = 1st adapter, eth1 = 2nd adapter) rather than by MAC address or other unique identifiers.

**Impact:** If network adapters are enumerated in a different order than expected, configuration will be applied to the wrong interfaces.

**Workaround:** Ensure network adapters are added to the VM in a predictable order and don't remove/re-add adapters after initial configuration.

**Future Fix:** Parse MAC addresses from cloud-init configuration (if available) and match adapters by MAC address instead of index.

### 2. **No IPv6 Support**

**Issue:** The script only handles IPv4 addresses. All operations use `-AddressFamily IPv4`.

**Impact:** Cannot configure IPv6 addresses via cloud-init.

**Workaround:** Configure IPv6 manually after VM creation or use a different provisioning method.

**Future Fix:** Parse and configure IPv6 addresses from cloud-init data.

### 3. **Single Execution Assumption**

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

### 4. **Netmask to Prefix Conversion Accuracy**

**Issue:** The netmask-to-prefix conversion counts all '1' bits but doesn't validate that they are contiguous:

```powershell
for ($b = 0; $b -lt 32; $b++) {
    if (($maskInt -shr $b) -band 1) { $prefix++ }
}
```

**Impact:** An invalid netmask like `255.0.255.0` would be incorrectly counted as `/16` instead of being rejected.

**Workaround:** Only use valid netmasks (contiguous '1' bits from left to right).

**Future Fix:** Validate that netmask bits are contiguous before calculating prefix length.

### 5. **Off-link Gateway Host Route**

**Issue:** The off-link gateway configuration adds a host route using `0.0.0.0` as next hop:

```powershell
New-NetRoute -DestinationPrefix "$gateway/32" -NextHop "0.0.0.0"
```

**Impact:** This works in most cases but may not be the most correct approach. Some network configurations might not accept this.

**Workaround:** The current implementation works for typical Proxmox hosting environments with public IPs.

**Future Fix:** Research and implement the most RFC-compliant method for configuring off-link gateways on Windows.

### 6. **No Multi-Gateway Support**

**Issue:** Only one default gateway is configured per interface.

**Impact:** Cannot configure multiple default routes or policy-based routing.

**Workaround:** Configure additional routes manually after VM creation.

**Future Fix:** Parse and configure multiple routes if provided in cloud-init data.

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

1. **MAC address-based interface matching** - More reliable than index-based matching (*)
2. **Full cloud-init v2 compatibility** - Support more cloud-init features
3. **IPv6 support** - Handle dual-stack configurations
4. **Idempotency** - Safe to run multiple times
5. **User data script execution** - Run custom scripts from user_data
6. **Password configuration** - Set administrator password from cloud-init
7. **Multiple network routes** - Support complex routing scenarios
8. **Validation and rollback** - Verify configuration and rollback on failure

(*) **BLOCKER:** Proxmox doesn't include MAC addresses in `openstack/content/0000` (`configdrive2`).

## References

- [Proxmox Cloud-Init Support](https://pve.proxmox.com/wiki/Cloud-Init_Support)
- [Cloud-Init ConfigDrive v2](https://cloudinit.readthedocs.io/en/latest/reference/datasources/configdrive.html)
- [OpenSSH for Windows](https://docs.microsoft.com/en-us/windows-server/administration/openssh/openssh_overview)
- [Windows Unattended Installation](https://docs.microsoft.com/en-us/windows-hardware/manufacture/desktop/automate-windows-setup)
