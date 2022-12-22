#!/bin/bash

set -e    # Exit when any command fails


#
# Constants
#

DEFAULT_ROOTFS='local-zfs:8'


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
    echo_err "Usage: $0 <ctid> --from <file> [OPTIONS]"
    echo_err '    <ctid>              Proxmox unique ID of the CT.'
    echo_err '    --from              The backup file.'
    echo_err
    echo_err 'Additional options:'
    echo_err '    --restore-docker    Restore docker zfs volumes.'
    echo_err "    --help, -h          Display this help message."
    echo_err
    exit 1
}


#
# Main
#

CT_RESTORE_DOCKER=0
DOCKER_ARGS=

# Parse arguments -- https://stackoverflow.com/a/14203146/33244
POSITIONAL_ARGS=()
while [[ "$#" -gt 0 ]]; do case $1 in
    --from) CT_FROM="$2"; shift; shift;;
    
    --restore-docker) CT_RESTORE_DOCKER=1; shift;;

    -h|--help) show_usage;;
    -*|--*) show_usage "Unknown option: $1";;
    *) POSITIONAL_ARGS+=("$1"); shift;;
esac; done
set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters

CT_ID="$1"
if [ -z "$CT_ID" ]; then show_usage "You must inform a CT id."; fi;
if [ -z "$CT_FROM" ]; then show_usage "You must inform a backup file to restore (--from)."; fi;

if [ $CT_RESTORE_DOCKER -eq 1 ]; then
    ./new-ct-docker-volume.sh $CT_ID

    # Name must be in this format otherwise snapshots and migration will not work. -- https://github.com/nextcloud/all-in-one/discussions/1490
    DOCKER_VOL="vm-$CT_ID-disk-1"

    # Extra arguments required for Docker
    DOCKER_ARGS="--rootfs $DEFAULT_ROOTFS --mp0 local-zfs:$DOCKER_VOL,mp=/var/lib/docker,backup=0"
fi;

# Create CT
CT_INTERFACE_NAME='eth0'
pct restore $CT_ID $CT_FROM \
    --storage local-zfs \
    $DOCKER_ARGS

# Start container
pct start $CT_ID

if [ $CT_RESTORE_DOCKER -eq 1 ]; then
    # Wait for network -- Source: https://stackoverflow.com/a/24963234
    cat | pct exec $CT_ID -- sh <<'EOF'
        WAIT_FOR_HOST=google.com
        while ! (ping -c 1 -W 1 $WAIT_FOR_HOST > /dev/null 2>&1); do
            echo "Waiting for $WAIT_FOR_HOST - network interface might be down..."
            sleep 1
        done
EOF

    # Assert that storage driver is 'overlay2'
    pct exec $CT_ID docker info | grep -i 'storage driver: overlay2' > /dev/null
    if [ $? -ne 0 ]; then
        tput setaf 1
        echo_err 'WARNING: Docker storage driver is not "overlay2".'
        tput sgr0
    fi

    echo "All done! Now please remember to rebuild your docker infrastructure inside the container (e.g. 'docker-compose up -d')."
fi
