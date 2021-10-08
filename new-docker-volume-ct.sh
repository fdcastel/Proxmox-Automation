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

# Create a sparse zvol for docker configuration
DOCKER_VOL="rpool/data/subvol-$CT_ID-docker"
DOCKER_DEV="/dev/zvol/$DOCKER_VOL"
zfs destroy $DOCKER_VOL 2> /dev/null || true      # Ignore error if does not exists
zfs create -s -V 32G $DOCKER_VOL

# Wait for it... (mkfs.ext4 fails without this!)
sleep 1

# Format it as ext4
mkfs.ext4 $DOCKER_DEV

# Set permissions
TMP_MOUNT="/tmp/subvol-$CT_ID-docker"
mkdir -p $TMP_MOUNT
mount $DOCKER_DEV $TMP_MOUNT
chown -R 100000:100000 $TMP_MOUNT
umount $TMP_MOUNT
rmdir $TMP_MOUNT

pct set $CT_ID --mp0 $DOCKER_DEV,mp=/var/lib/docker,backup=0
