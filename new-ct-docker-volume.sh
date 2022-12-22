#!/bin/bash

set -e    # Exit when any command fails


#
# Functions
#

function echo_err() { 
    >&2 echo "$@"
}

function show_usage() {
    if [ -n "$1" ]; then
        tput setaf 1
        echo "Error: $1";
        tput sgr0
    fi
    echo_err
    echo_err "Usage: $0 <ctid> [--attach]"
    echo_err '    <ctid>              Proxmox unique ID of the CT.'
    echo_err '    --attach            Attach created volume to CT.'
    echo_err
    exit 1
}


#
# Main
#
CT_ATTACH=0

# Parse arguments -- https://stackoverflow.com/a/14203146/33244
POSITIONAL_ARGS=()
while [[ "$#" -gt 0 ]]; do case $1 in
    --attach) CT_ATTACH=1; shift; shift;;

    -h|--help) show_usage;;
    -*|--*) show_usage "Unknown option: $1";;
    *) POSITIONAL_ARGS+=("$1"); shift;;
esac; done
set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters

CT_ID="$1"
if [ -z "$CT_ID" ]; then show_usage "You must inform a CT id."; fi;

# Source: https://www.reddit.com/r/Proxmox/comments/lsrt28/easy_way_to_run_docker_in_an_unprivileged_lxc_on/
# Related: https://github.com/moby/moby/issues/31247
    
# Name must be in this format otherwise snapshots and migration will not work. -- https://github.com/nextcloud/all-in-one/discussions/1490
DOCKER_VOL="vm-$CT_ID-disk-1"

# Create a sparse zvol for docker configuration
DOCKER_RPOOL="rpool/data/$DOCKER_VOL"
DOCKER_DEV="/dev/zvol/$DOCKER_RPOOL"

# Set var for disk size
DISK_SIZE="32G"
zfs destroy $DOCKER_RPOOL 2> /dev/null || true      # Ignore error if does not exists
zfs create -s -V $DISK_SIZE $DOCKER_RPOOL

# Wait for it... (mkfs.$FS fails without this!)
sleep 1

# Set filesystem "ext4" or "xfs" is possible
FS="ext4"

# Format it as ext4
mkfs.$FS $DOCKER_DEV

# Set permissions
TMP_MOUNT="/tmp/$DOCKER_VOL"
mkdir -p $TMP_MOUNT
mount $DOCKER_DEV $TMP_MOUNT
chown -R 100000:100000 $TMP_MOUNT
umount $TMP_MOUNT
rmdir $TMP_MOUNT

if [ $CT_ATTACH -eq 1 ]; then 
    pct set $CT_ID --mp0 local-zfs:$DOCKER_VOL,mp=/var/lib/docker,backup=0
fi;
