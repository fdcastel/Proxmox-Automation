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
  - [new-ct-docker-volume](#new-ct-docker-volume)
  - [new-ct](#new-ct)
  - [new-vm](#new-vm)
  - [remove-nag-subscription](#remove-nag-subscription)
  - [restore-ct](#restore-ct)
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
# Download Ubuntu 22.04 LTS image
UBUNTU_IMAGE='ubuntu-22.04-standard_22.04-1_amd64.tar.zst'
pveam download local $UBUNTU_IMAGE
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



## new-ct-docker-volume

```
Usage: ./new-ct-docker-volume.sh <ctid> [--attach]
    <ctid>              Proxmox unique ID of the CT.
    --volsize           Size of volume (default = 8G).
    --attach            Attach created volume to CT.
```

Creates a special `ext4` volume for Docker usage with LXC containers running over `zfs`. 

There's no need to use this script directly. Please see section [Using Docker on LXC](#using-docker-on-lxc) for more information.

Returns the name of created volume.



## new-ct

```
Usage: ./new-ct.sh <ctid> --ostemplate <file> --hostname <name> --password <password> [OPTIONS]
    <ctid>              Proxmox unique ID of the CT.
    --ostemplate        The OS template or backup file.
    --hostname          Set a host name for the container.
    --password          Sets root password inside container.

Additional options:
    --ostype            OS type (default = ubuntu).
    --cores             Number of cores per socket (default = 2).
    --memory            Amount of RAM for the VM in MB (default = 2048).
    --rootfs            Use volume as container root (default = local-zfs:120).
    --sshkey[s]         Setup public SSH keys (one key per line, OpenSSH format).
    --privileged        Makes the container run as privileged user (default = unprivileged).
    --bridge            Use bridge for container networking (default = vmbr0)
    --install-docker    Install docker and docker-compose.
    --no-docker-volume  Do not create a new volume for /var/lib/docker.
    --docker-volsize    Set container volume size (default = 8G)
    --help, -h          Display this help message.
```

Creates a LXC container (CT).

Additionally, you can use `--install-docker` to also install `docker` into container (currently implemented only for Ubuntu, Debian and Alpine). In this case, please see section [Using Docker on LXC](#using-docker-on-lxc) for more information.

Any additional arguments are passed to `pct create` command. Please see [`pct` command documentation](https://pve.proxmox.com/pve-docs/pct.1.html) for more information about the options.

### Example

```bash
# Download Ubuntu 22.04 LTS image
UBUNTU_IMAGE='ubuntu-22.04-standard_22.04-1_amd64.tar.zst'
UBUNTU_TEMPLATE="local:vztmpl/$UBUNTU_IMAGE"
pveam download local $UBUNTU_IMAGE

# Creates an Ubuntu LXC container with a 120G storage, "my-key.pub" ssh key and Docker installed.
CT_ID=310
CT_NAME='ct-ubuntu'
CT_PASSWORD='uns@f3p@ss0rd'
./new-ct.sh $CT_ID --memory 1024 --ostemplate $UBUNTU_TEMPLATE --hostname $CT_NAME --password $CT_PASSWORD --sshkey ~/.ssh/my-key.pub --rootfs local-zfs:120 --install-docker
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

### Example

```bash
# Download Ubuntu 22.04 LTS image
URL='https://cloud-images.ubuntu.com/releases/jammy/release/ubuntu-22.04-server-cloudimg-amd64.img'
UBUNTU_IMAGE_FILE=$(./download-cloud-image.sh $URL --no-clobber)

# Creates an Ubuntu VM with "my-key.pub" ssh key and Docker installed.
VM_ID=201
./new-vm.sh $VM_ID --image $UBUNTU_IMAGE_FILE --name 'vm-ubuntu' --sshkey '~/.ssh/my-key.pub' --install-docker
```



## remove-nag-subscription

```
Usage: ./remove-nag-subscription.sh
```

Removes Proxmox VE / Proxmox Backup Server nag dialog from web UI.



## restore-ct

```
Usage: ./restore-ct.sh <ctid> --from <file> [OPTIONS]
    <ctid>              Proxmox unique ID of the CT.
    --from              The backup file.

Additional options:
    --rootfs            Use volume as container root (default = local-zfs:120).
    --restore-docker    Restore docker zfs volumes.
    --help, -h          Display this help message.
```

Restores a CT from a backup. 

Use `--restore-docker` to rebuild docker `zfs` volume for `/var/lib/docker`.

### Example

```bash
# Local backups are stored into '/var/lib/vz/dump/'
CT_ID=321
FROM='/var/lib/vz/dump/vzdump-lxc-321-2022_12_22-18_21_59.tar.zst'
./restore-ct.sh $CT_ID --from $FROM --restore-docker
```



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



## ZFS

### Update (2023-Nov)

Proxmox VE 8.1 uses ZFS 2.2 which finally supports `overlay2` out of the box. 

**If you are using Proxmox VE 8.1 you should always use `--no-docker-volume` (see below) for new containers.** All previous workarounds should be considered deprecated.



### Update (2023-Jun)

As of Proxmox 7.3 Docker over LXC does uses `overlay2` by default. However there are still problems when using it over ZFS.

The default behavior of [`new-ct.sh`](new-ct.sh) script when invoked with `--install-docker` option is to create a dedicated volume for `/var/lib/docker` as explained in the next section. 

You may try to use `--no-docker-volume` to skip this step. However, be advised that (currently) many docker images fail to start due another problem with permissions. If you got an error like

```
docker: failed to register layer: ApplyLayer exit status 1 stdout: stderr: unlinkat /var/log/apt: invalid argument.
```

simply rebuild your container without `--no-docker-volume` and it will work.



### Legacy information

**IMPORTANT: This section contains outdated information.**

Using Docker _over ZFS storage_ causes an additional burden: It will use [`vfs` driver](https://docs.docker.com/storage/storagedriver/vfs-driver/) by default, which is terribly inefficient.

To check what storage driver Docker is currently using, use `docker info` and look for the `Storage Driver` line:
```bash
$ docker info

<...>
Storage Driver: vfs
<...>
```

To avoid this, you have 3 options:

  - use [`fuse-overlayfs`](https://github.com/containers/fuse-overlayfs)
  - use [`zfs` storage driver](https://docs.docker.com/storage/storagedriver/zfs-driver/)
  - use `overlay2` storage driver

To make a long story short, I did not find any successful report of the two first options.

`overlay2` is a [stable and recommended driver](https://docs.docker.com/storage/storagedriver/select-storage-driver/) but only works with `xfs` and `ext4` filesystems.

This did not not stop [u/volopasse](https://www.reddit.com/r/Proxmox/comments/lsrt28/comment/goubt7u/?utm_source=reddit&utm_medium=web2x&context=3) some years ago to find a workaround: to create a sparse zfs volume formatted as `ext4` and use it as a bind mount point for `/var/lib/docker`. This will make Docker use `overlay2` without any changes needed in Docker configuration.

It may seem a hack (which it is) but it [reportedly works better than the very own Docker ZFS driver](https://github.com/moby/moby/issues/31247#issuecomment-611976248).

All these steps are wrapped into [`new-ct-docker-volume.sh`](new-ct-docker-volume.sh) script, which is also used by [`new-ct.sh`](new-ct.sh) script when invoked with `--install-docker` option.

From my personal experience: I am using this solution for more than a year now in my home servers with zero problems of performance nor stability. That said I do not use nor recommend this solution in any production capacity. Also, see [Caveats](#caveats) section below.



## Caveats when using Docker on LXC

### Backups

Backups (both to local storage and to Proxmox Backup Server) works fine.

However, please note that **the contents of `/var/lib/docker` will not be included in backups**.

Because of this you should not use [Docker volumes](https://docs.docker.com/storage/volumes/) to store any persistent data which is important since they will be kept at this location (and, again, will **not** be included in backups). 

Instead you should use [Docker bind mounts](https://docs.docker.com/storage/bind-mounts/) which mounts a file or directory from the Docker host (LXC, in our case) into a Docker container. All files from LXC filesystem will be included into backups.

Lastly, since we are talking about backups, please remember again that all this is very new and _not recommended by Proxmox team_. I put these scripts initially for my personal usage and they have yet a long way to run until be considered stable and battle-tested. Thus, caution is advised.



### Restoring backups

To restore an existing backup you _must_ use [restore-ct](#restore-ct) script with the `--restore-docker` option. This will rebuild the `zfs` volume for `/var/lib/docker` and mount it correctly.

Simply using the _Restore_ command from Proxmox Web UI will fail since it doesn't know what to do with `/var/lib/docker/` bind mount point. 



### Migrations & Snapshots

Originally this method caused migrations and snapshot to fail.

[iGadget](https://github.com/alexpdp7/ansible-create-proxmox-host/issues/1#issue-1492924235) found that naming the ZFS volume in a very specific way solves the snapshot and migration problems. This naming scheme is already adopted by these scripts so, for now, migrations and snapshots are working.

However, please be aware that this takes advantage of a very specific way Proxmox was implemented and it may break in future Proxmox versions. 
