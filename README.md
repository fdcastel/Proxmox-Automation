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
  - [import-vm-windows](#import-vm-windows)
  - [new-ct](#new-ct)
  - [new-vm](#new-vm)
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



## import-vm-windows

```
Usage: ./import-vm-windows.sh <vmid> --image <file> --name <name> [OPTIONS]
    <vmid>              Proxmox unique ID of the VM.
    --image             Path to image file.
    --name              A name for the VM.

Additional options:
    --ostype            Guest OS type (default = win11).
    --cores             Number of cores per socket (default = 2).
    --memory            Amount of RAM for the VM in MB (default = 2048).
    --help, -h          Display this help message.
```

Creates a VM from an existing Hyper-V Windows VM. For _Generation 2_ (UEFI) types only.

Image must be in `qcow2` format. You may use [Convert-VhdxToQcow2](https://github.com/fdcastel/Hyper-V-Automation#convert-vhdxtoqcow2) (on Windows) to convert a VHDX.

Please see [`qm` command documentation](https://pve.proxmox.com/pve-docs/qm.1.html) for more information about the options.

### Example

```bash
# Creates a Windows VM from a vhdx converted to qcow2.
VM_ID=103
./import-vm-windows.sh $VM_ID --image '/tmp/TstWindows.qcow2' --name 'tst-windows'
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
    --help, -h          Display this help message.
```

Creates a LXC container (CT).

Additionally, you can use `--install-docker` to also install `docker` into container (currently implemented only for Ubuntu, Debian and Alpine). In this case, please see section [Using Docker on LXC](#using-docker-on-lxc) for more information.

Any additional arguments are passed to `pct create` command. Please see [`pct` command documentation](https://pve.proxmox.com/pve-docs/pct.1.html) for more information about the options.

### Example

```bash
# Download Ubuntu 24.04 LTS image
UBUNTU_IMAGE='ubuntu-24.04-standard_24.04-2_amd64.tar.zst'
UBUNTU_TEMPLATE="local:vztmpl/$UBUNTU_IMAGE"
pveam download local $UBUNTU_IMAGE

# Creates an Ubuntu LXC container with a 120G storage, "id_rsa.pub" ssh key and Docker installed.
CT_ID=310
CT_NAME='ct-ubuntu'
./new-ct.sh $CT_ID --memory 1024 --ostemplate $UBUNTU_TEMPLATE --hostname $CT_NAME --sshkey ~/.ssh/id_rsa.pub --rootfs local-zfs:120 --install-docker
```



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
