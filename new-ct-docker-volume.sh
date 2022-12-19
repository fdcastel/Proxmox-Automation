#!/bin/bash

set -e    # Exit when any command fails


#
# Usage
#
function show_usage() {
    if [ -n "$1" ]; then
        tput setaf 1
        echo "Error: $1";
        tput sgr0
    fi
    echo
    echo "Usage: $0 <ctid>"
    echo '    <ctid>              Proxmox unique ID of the CT.'
    echo
    exit 1
}


#
# Main
#

# Parse arguments
CT_ID="$1"
shift

while [[ "$#" > 0 ]]; do case $1 in
    *) show_usage "Invalid argument: $1"; shift; shift;;
esac; done

if [ -z "$CT_ID" ]; then show_usage "You must inform a CT id."; fi;

# Source: https://www.reddit.com/r/Proxmox/comments/lsrt28/easy_way_to_run_docker_in_an_unprivileged_lxc_on/
# Related: https://github.com/moby/moby/issues/31247
    
# Name must be in this format otherwise snapshots and migration will not work. -- https://github.com/nextcloud/all-in-one/discussions/1490
DOCKER_VOL="vm-$CT_ID-disk-1"

# Create a sparse zvol for docker configuration
DOCKER_RPOOL="rpool/data/$DOCKER_VOL"
DOCKER_DEV="/dev/zvol/$DOCKER_RPOOL"
zfs destroy $DOCKER_RPOOL 2> /dev/null || true      # Ignore error if does not exists
zfs create -s -V 32G $DOCKER_RPOOL

# Wait for it... (mkfs.ext4 fails without this!)
sleep 1

# Format it as ext4
mkfs.ext4 $DOCKER_DEV

# Set permissions
TMP_MOUNT="/tmp/$DOCKER_VOL"
mkdir -p $TMP_MOUNT
mount $DOCKER_DEV $TMP_MOUNT
chown -R 100000:100000 $TMP_MOUNT
umount $TMP_MOUNT
rmdir $TMP_MOUNT

pct set $CT_ID --mp0 local-zfs:$DOCKER_VOL,mp=/var/lib/docker,backup=0
