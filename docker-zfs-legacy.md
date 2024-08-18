# Legacy information

**IMPORTANT: This section contains outdated information.**

The following notes were part of this project [README file](README.md) in the past. It is kept for historical record only.



## ZFS

### Update (2023-Jun)

As of Proxmox 7.3 Docker over LXC does uses `overlay2` by default. However there are still problems when using it over ZFS.

The default behavior of [`new-ct.sh`](new-ct.sh) script when invoked with `--install-docker` option is to create a dedicated volume for `/var/lib/docker` as explained in the next section. 

You may try to use `--no-docker-volume` to skip this step. However, be advised that (currently) many docker images fail to start due another problem with permissions. If you got an error like

```
docker: failed to register layer: ApplyLayer exit status 1 stdout: stderr: unlinkat /var/log/apt: invalid argument.
```

simply rebuild your container without `--no-docker-volume` and it will work.



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
