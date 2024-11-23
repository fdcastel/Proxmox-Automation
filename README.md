# Proxmox VE automation scripts

Collection of scripts to manage Proxmox environments.

Please read section [Using Docker on LXC](#using-docker-on-lxc) if you are planning to use Docker with Linux Containers (LXC).

To migrate an existing Windows VM from Hyper-V to Proxmox see [this other project](https://github.com/fdcastel/Hyper-V-Automation#windows-prepare-a-vhdx-for-qemu-migration) (for Windows) first.



# How to install

To download all scripts into a temporary folder:

```bash
source <(curl -Ls https://bit.ly/p-v-a)
```

This will download and execute [bootstrap.sh](bootstrap.sh). It will also install `unzip` apt package.



# Scripts

## Summary
  - [download-cloud-image](#download-cloud-image)
  - [new-ct](#new-ct)
  - [new-vm](#new-vm)
  - [new-vm-windows](#new-vm-windows)
  - [remove-nag-subscription](#remove-nag-subscription)
  - [setup-pbs](#setup-pbs)
  - [setup-pve](#setup-pve)



## download-cloud-image

```
Usage: ./download-cloud-image.sh <url> [OPTIONS]
    <url>                Url of image to download.
    --no-clobber, -nc    Doesn't overwrite an existing image.
    --help, -h           Display this help message.
```

Downloads an image from given `url` into `/var/lib/vz/template/iso/` folder. 

If the image already exists it will not be downloaded again.

If the file is compressed with `gz`, `xz` or `zip` it will also uncompress it.

Returns the full path of downloaded image.

### Example

```bash
# Download Debian 12 image
DEBIAN_URL='https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2'
./download-cloud-image.sh $DEBIAN_URL
```



## download-cloud-template

```
Usage: ./download-cloud-template.sh <url> [OPTIONS]
    <url>                Url of template to download.
    --filename, -f       Renames the downloaded file.
    --no-clobber, -nc    Doesn't overwrite an existing template.
    --help, -h           Display this help message.
```

Downloads a LXC template from given `url` into `/var/lib/vz/template/cache/` folder. 

You can use `--filename` to rename the resulting file.

If the template already exists it will not be downloaded again.

Please note that this script DOES NOT uncompress the resulting file. LXCs templates can be used in compressed format.

Returns the full path of downloaded template.

### Example

```bash
# Download OpenWRT template
OPENWRT_URL='https://images.linuxcontainers.org/images/openwrt/23.05/amd64/default/20241109_11:57/rootfs.tar.xz'
OPENWRT_TEMPLATE_NAME='openwrt-23.05-amd64-default-20241109.tar.xz'
./download-cloud-template.sh $OPENWRT_URL --filename $OPENWRT_TEMPLATE_NAME
```



## new-ct

```
Usage: ./new-ct.sh <ctid> --ostemplate <file> --hostname <name> --password <password> [OPTIONS]
    <ctid>              Proxmox unique ID of the CT.
    --ostemplate        The OS template or backup file.
    --hostname          Set a host name for the container.
    --password          Sets root password inside container.
    --sshkey[s]         Setup public SSH keys (one key per line, OpenSSH format).

Additional options:
    --ostype            OS type (default = ubuntu).
    --cores             Number of cores per socket (default = unlimited).
    --memory            Amount of RAM for the VM in MB (default = 2048).
    --rootfs            Use volume as container root (default = local-zfs:120).
    --privileged        Makes the container run as privileged user (default = unprivileged).
    --bridge            Use bridge for container networking (default = vmbr0).
    --hwaddr            MAC address for eth0 interface.
    --install-docker    Install docker and docker-compose.
    --no-start          Do not start the container after creation.
    --help, -h          Display this help message.
```

Creates a LXC container (CT).

Additionally, you can use `--install-docker` to also install `docker` into container (currently implemented only for Ubuntu, Debian and Alpine). In this case, please see section [Using Docker on LXC](#using-docker-on-lxc) for more information.

Any additional arguments are passed to `pct create` command. Please see [`pct` command documentation](https://pve.proxmox.com/pve-docs/pct.1.html) for more information about the options.

### Examples

#### Ubuntu

```bash
# Download Ubuntu 24.04 LTS image
UBUNTU_IMAGE='ubuntu-24.04-standard_24.04-2_amd64.tar.zst'
UBUNTU_TEMPLATE="local:vztmpl/$UBUNTU_IMAGE"
pveam download local $UBUNTU_IMAGE

# Creates an Ubuntu LXC container with a 120G storage, "id_rsa.pub" ssh key and Docker installed.
CT_ID=310
CT_NAME='ct-ubuntu'
./new-ct.sh $CT_ID \
    --memory 1024 \
    --ostemplate $UBUNTU_TEMPLATE \
    --hostname $CT_NAME \
    --sshkey ~/.ssh/id_rsa.pub \
    --rootfs local-zfs:120 \
    --install-docker
```

#### OpenWRT

```bash
# Download OpenWRT image
OPENWRT_URL='https://images.linuxcontainers.org/images/openwrt/23.05/amd64/default/20241109_11:57/rootfs.tar.xz'
OPENWRT_TEMPLATE_NAME='openwrt-23.05-amd64-default-20241109.tar.xz'
OPENWRT_TEMPLATE=$(./download-cloud-template.sh $OPENWRT_URL --filename $OPENWRT_TEMPLATE_NAME)

# Creates an OpenWRT privileged LXC container with a 8G storage, two named network interfaces and sets root password.
CT_ID=311
CT_NAME='ct-openwrt'
CT_PASSWORD='uns@f3'
CT_LAN_IFNAME='lan'
CT_LAN_BRIDGE='vmbrloc0'    # Do NOT use your LAN here! (will start a DHCP server on it).
CT_WAN_IFNAME='wan'
CT_WAN_BRIDGE='vmbr0'
./new-ct.sh $CT_ID \
    --ostype unmanaged \
    --arch amd64 \
    --memory 1024 \
    --ostemplate $OPENWRT_TEMPLATE \
    --hostname $CT_NAME \
    --password $CT_PASSWORD \
    --rootfs local-zfs:8 \
    --privileged \
    --no-start \
    --net0 name=$CT_LAN_IFNAME,bridge=$CT_LAN_BRIDGE \
    --net1 name=$CT_WAN_IFNAME,bridge=$CT_WAN_BRIDGE,ip=dhcp,ip6=auto

# Load initial OpenWRT configuration
CT_ROOT_MOUNTPOINT="/rpool/data/subvol-$CT_ID-disk-0"
cat > "$CT_ROOT_MOUNTPOINT/etc/uci-defaults/80-init" << OUTER_EOF
#!/bin/sh

# System
uci batch << EOF
set system.@system[0].hostname='{{ openwrt.hostname }}'
commit system
EOF

# Network interfaces
uci batch << EOF
set network.lan=interface
set network.lan.ifname='$CT_LAN_IFNAME'
set network.lan.proto='static'
set network.lan.ipaddr='192.168.1.1'
set network.lan.netmask='255.255.255.0'

set network.wan=interface
set network.wan.ifname='$CT_WAN_IFNAME'
set network.wan.proto='dhcp'
set network.wan.zone='wan'
commit network
EOF
OUTER_EOF

# Set passwd for LUCI
cat > "$CT_ROOT_MOUNTPOINT/etc/uci-defaults/81-passwd" << OUTER_EOF
#!/bin/sh

passwd << EOF
$CT_PASSWORD
$CT_PASSWORD
EOF
OUTER_EOF

# Start the LXC Container
pct start $CT_ID
```

OpenWRT offers extensive configuration options through the [UCI system](https://openwrt.org/docs/guide-user/base-system/uci). 

More information about the `uci-defaults` folder can be found [here](https://openwrt.org/docs/guide-developer/uci-defaults).



## new-vm

```
Usage: ./new-vm.sh <vmid> --image <file> --name <name> [--cipassword <password>] | [--sshkey[s] <filepath>] [OPTIONS]
    <vmid>              Proxmox unique ID of the VM.
    --image             Path to image file.
    --name              A name for the VM.
    --cipassword        Password to assign the user. Using this is generally not recommended. Use ssh keys instead.
    --sshkey[s]         Setup public SSH keys (one key per line, OpenSSH format).

Additional options:
    --ostype            Guest OS type (default = l26).
    --cores             Number of cores per socket (default = 2).
    --memory            Amount of RAM for the VM in MB (default = 2048).
    --disksize          Size of VM main disk (default = 120G).
    --balloon           Amount of target RAM for the VM in MB. Using zero (default) disables the ballon driver.
    --install-docker    Install docker and docker-compose.
    --help, -h          Display this help message.
```

Creates a VM from a cloud image.

You can use any image containing `cloud-init` and `qemu-guest-agent` installed.

Additionally, you can use `--install-docker` to also install `docker` into virtual machine (currently implemented only for Ubuntu). 

Any additional arguments are passed to `qm create` command. Please see [`qm` command documentation](https://pve.proxmox.com/pve-docs/qm.1.html) for more information about the options.

### Examples

```bash
# Download Ubuntu 24.04 LTS image
UBUNTU_URL='https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img'
UBUNTU_IMAGE_FILE=$(./download-cloud-image.sh $UBUNTU_URL --no-clobber)

# Creates an Ubuntu VM with "id_rsa.pub" ssh key and Docker installed.
VM_ID=401
./new-vm.sh $VM_ID --image $UBUNTU_IMAGE_FILE --name 'vm-ubuntu' --sshkey ~/.ssh/id_rsa.pub --install-docker
```

```bash
# Download Debian 12 image
DEBIAN_URL='https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2'
DEBIAN_IMAGE_FILE=$(./download-cloud-image.sh $DEBIAN_URL --no-clobber)

# Creates a Debian VM with "id_rsa.pub" ssh key and Docker installed.
VM_ID=402
./new-vm.sh $VM_ID --image $DEBIAN_IMAGE_FILE --name 'vm-debian' --sshkey '~/.ssh/id_rsa.pub' --install-docker
```



## new-vm-windows

```
Usage: ./new-vm-windows.sh <vmid> --image <file> --name <name> [OPTIONS]
    <vmid>              Proxmox unique ID of the VM.
    --image             Source image to import (.vhdx | .qcow2).
    --name              A name for the VM.

Additional options:
    --ostype            Guest OS type (default = win11).
    --cores             Number of cores per socket (default = 2).
    --memory            Amount of RAM for the VM in MB (default = 2048).
    --no-start          Do not start the VM after creation.
    --no-guest          Do not wait for QEMU Guest Agent after start.
    --help, -h          Display this help message.
```

Creates a VM from a `vhdx` image. For _Generation 2_ (UEFI) types only.

The image will be _imported_ as a `raw` image format. The original `vhdx` file remains unaltered.

Any additional arguments are passed to `qm create` command. Please see [`qm` command documentation](https://pve.proxmox.com/pve-docs/qm.1.html) for more information about the options.

After creation, the script will start the VM and wait for the QEMU Guest Agent to be responsive. These actions can be skipped using the `--no-start` and `--no-guest` options, respectively.

It's recommended that the `vhdx` includes the following:

- [Windows VirtIO Drivers](https://pve.proxmox.com/wiki/Windows_VirtIO_Drivers) (recommended)
- [QEMU Guest Agent](https://pve.proxmox.com/wiki/Qemu-guest-agent) (recommended)
- [Cloudbase-Init](https://cloudbase.it/cloudbase-init/) (optional)

Please refer to [Hyper-V Automation](https://github.com/fdcastel/Hyper-V-Automation#examples) project for more information.



### Examples

Creates a Windows VM from a [`vhdx` template](https://github.com/fdcastel/Hyper-V-Automation#create-a-windows-vhdx-template-for-qemu) previously created with [`New-VHDXFromWindowsImage.ps1`](https://github.com/fdcastel/Hyper-V-Automation#new-vhdxfromwindowsimage-) and initializes the Administrator password via CloudBase-Init.

```bash
VM_ID=103
./new-vm-windows.sh $VM_ID \
    --image '/tmp/Server2025Standard-template.vhdx' \
    --name 'tst-win2025' \
    --ide2 local-zfs:cloudinit \
    --cipassword 'Unsaf3@AnySp33d!'

# You can run any commands on VM with "qm guest exec":
qm guest exec $VM_ID -- powershell -c $(cat << 'EOF'
    <# Enables ICMP Echo Request (ping) for IPv4 and IPv6 #>
    Get-NetFirewallRule -Name 'FPS-ICMP*' | Set-NetFirewallRule -Enabled:True ;

    <# Enables Remote Desktop (more secure) #>
    $tsSettings = Get-WmiObject -Class 'Win32_TerminalServiceSetting' -Namespace root\cimv2\terminalservices ;
    $tsSettings.SetAllowTsConnections(1, 1) ;
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop" ;

    <# Enables SSH (Server 2025 only) #>
    Start-Service sshd ;
    Set-Service -Name sshd -StartupType 'Automatic' ;
    Set-NetFirewallRule OpenSSH-Server-In-TCP -Profile Any
EOF
)
```

Creates a Windows VM from a [previously prepared `vhdx`](https://github.com/fdcastel/Hyper-V-Automation#prepare-a-vhdx-for-qemu-migration) of an existing Hyper-V VM.

```bash
VM_ID=104
./new-vm-windows.sh $VM_ID --image '/tmp/TstWindows.vhdx' --name 'TstWindows'

# Query ipv4 addresses
qm guest cmd $VM_ID network-get-interfaces | \
    jq -r '.[] | .["ip-addresses"][] | select(.["ip-address-type"]=="ipv4") | .["ip-address"]'
```



## remove-nag-subscription

```
Usage: ./remove-nag-subscription.sh
```

Removes Proxmox VE / Proxmox Backup Server nag dialog from web UI.



## setup-pbs

```
Usage: ./setup-pbs.sh
```

First-time setup for Proxmox Backup Server.

Remove `enterprise` (subscription-only) sources and adds `pbs-no-subscription` repository provided by [proxmox.com](https://proxmox.com). NOT recommended for production use.

This script must be run only once.



## setup-pve

```
Usage: ./setup-pve.sh
```

First-time setup for Proxmox VE. 

Remove `enterprise` (subscription-only) sources and adds `pve-no-subscription` repository provided by [proxmox.com](https://proxmox.com). NOT recommended for production use.

This script must be run only once.



# Using Docker on LXC

The following is a compilation about the subject I found around the net. Please read if you wish to follow this path.



## Overview

**Using Docker on LXC is not recommended by Proxmox team.** However, certain features of LXC like reduced memory usage and bind mount points between containers and host may be an incentive to go against this recommendation.

Two discussions about the pros and cons of each alternative may be found [here](https://forum.proxmox.com/threads/proxmox-7-1-and-docker-lxc-vs-vm.105140) and [here](https://www.reddit.com/r/Proxmox/comments/xno101/using_multiple_lxc_vs_multiple_lxcdocker_vs/).



## Backups

Backups (both to local storage and to Proxmox Backup Server) work fine.

However, please note that **the contents of `/var/lib/docker` will be included in backups** by default. This is probably NOT what you want.

> This folder often grows in size very quickly. And its contents (except for Docker volumes, see below) may easily be downloaded or rebuilt.

To avoid this, you may use a [`.pxarexclude` file](https://pbs.proxmox.com/docs/backup-client.html#excluding-files-directories-from-a-backup) to exclude its contents from the backup archive.

```bash
cat > /.pxarexclude <<EOF
var/lib/docker/
EOF
```

Please note that in this case you SHOULD NOT use [Docker volumes](https://docs.docker.com/storage/volumes/) to store any persistent data which is important since they are kept at this location (and, again, will **not** be included in backups). 

Instead you should use [Docker bind mounts](https://docs.docker.com/storage/bind-mounts/) which mounts a file or directory from the Docker host (LXC, in our case) into a Docker container. All files from LXC filesystem will be included into backups.



## ZFS

### Update (2023-Nov)

Proxmox VE 8.1 uses ZFS 2.2 which finally supports `overlay2` out of the box.

All [previous workarounds](docker-zfs-legacy.md) should be considered deprecated.

Starting with Proxmox VE 8.1 the [`new-ct.sh`](new-ct.sh) script will always assume `--no-docker-volume`, never creating the workaround volume needed for previous Proxmox VE versions.
