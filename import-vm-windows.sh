#!/bin/bash

set -e    # Exit when any command fails


#
# Constants
#

DEFAULT_OSTYPE='win11'
DEFAULT_CORES=2
DEFAULT_MEMORY=2048


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
    echo_err "Usage: $0 <vmid> --image <file> --name <name> [OPTIONS]"
    echo_err '    <vmid>              Proxmox unique ID of the VM.'
    echo_err '    --image             Source image to import (.qcow2 | .vhdx).'
    echo_err '    --name              A name for the VM.'
    echo_err
    echo_err 'Additional options:'
    echo_err "    --ostype            Guest OS type (default = $DEFAULT_OSTYPE)."
    echo_err "    --cores             Number of cores per socket (default = $DEFAULT_CORES)."
    echo_err "    --memory            Amount of RAM for the VM in MB (default = $DEFAULT_MEMORY)."
    echo_err "    --help, -h          Display this help message."
    echo_err
    echo_err "Any additional arguments are passed to 'qm create' command."
    echo_err
    exit 1
}


#
# Main
#

VM_OSTYPE=$DEFAULT_OSTYPE
VM_CORES=$DEFAULT_CORES
VM_MEMORY=$DEFAULT_MEMORY

# Parse arguments -- https://stackoverflow.com/a/14203146/33244
POSITIONAL_ARGS=()
while [[ "$#" -gt 0 ]]; do case $1 in
    --image) VM_IMAGE="$2"; shift; shift;;
    --name) VM_NAME="$2"; shift; shift;;

    --ostype) VM_OSTYPE="$2"; shift; shift;;
    --cores) VM_CORES="$2"; shift; shift;;
    --memory) VM_MEMORY="$2"; shift; shift;;

    -h|--help) show_usage;;
    *) POSITIONAL_ARGS+=("$1"); shift;;
esac; done
set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters

VM_ID="$1"; shift
if [ -z "$VM_ID" ]; then show_usage "You must inform a VM id."; fi;
if [ -z "$VM_IMAGE" ]; then show_usage "You must inform a image file (--image)."; fi;
if [ -z "$VM_NAME" ]; then show_usage "You must inform a VM name (--name)."; fi;



# Create VM
#   Disables balloon driver due poor performance on Windows
#   Source: https://pve.proxmox.com/wiki/Performance_Tweaks#Do_not_use_the_Virtio_Balloon_Driver
VM_BALLOON=0

qm create $VM_ID --name $VM_NAME \
    --cpu host \
    --ostype $VM_OSTYPE \
    --scsihw virtio-scsi-single \
    --agent 1 \
    --bios ovmf \
    --machine q35 \
    --net0 virtio,bridge=vmbr0 \
    --cores $VM_CORES \
    --numa 1 \
    --memory $VM_MEMORY \
    --balloon $VM_BALLOON \
    --vga type=virtio \
    --onboot 1 \
    "$@" # pass remaining arguments -- https://stackoverflow.com/a/4824637/33244

# Disk 0: EFI
pvesm alloc local-zfs $VM_ID vm-$VM_ID-efi 1M
qm set $VM_ID --efidisk0 local-zfs:vm-$VM_ID-efi

# Disk 1: Main disk.
qm importdisk $VM_ID $VM_IMAGE local-zfs --format 'raw'
qm set $VM_ID --scsi1 local-zfs:vm-$VM_ID-disk-0,discard=on,iothread=1,ssd=1 \
    --boot c \
    --bootdisk scsi1



# Start VM
qm start $VM_ID

# Wait for qemu-guest-agent
echo "Waiting for VM $VM_ID..."
until qm agent $VM_ID ping
do
    sleep 2
done

echo 'All done!'
