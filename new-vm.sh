#!/bin/bash

set -e    # Exit when any command fails


#
# Constants
#

DEFAULT_OSTYPE='l26'
DEFAULT_CORES=2
DEFAULT_MEMORY=2048
DEFAULT_DISKSIZE='120G'


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
    echo_err "Usage: $0 <vmid> --image <file> --name <name> [--cipassword <password>] | [--sshkey[s] <filepath>] [OPTIONS]"
    echo_err '    <vmid>              Proxmox unique ID of the VM.'
    echo_err '    --image             Path to image file.'
    echo_err '    --name              A name for the VM.'
    echo_err '    --cipassword        Password to assign the user. Using this is generally not recommended. Use ssh keys instead.'
    echo_err '    --sshkey[s]         Setup public SSH keys (one key per line, OpenSSH format).'
    echo_err
    echo_err 'Additional options:'
    echo_err "    --ostype            Guest OS type (default = $DEFAULT_OSTYPE)."
    echo_err "    --cores             Number of cores per socket (default = $DEFAULT_CORES)."
    echo_err "    --memory            Amount of RAM for the VM in MB (default = $DEFAULT_MEMORY)."
    echo_err "    --disksize          Size of VM main disk (default = $DEFAULT_DISKSIZE)."
    echo_err '    --balloon           Amount of target RAM for the VM in MB. Using zero (default) disables the ballon driver.'
    echo_err '    --install-docker    Install docker and docker-compose.'
    echo_err "    --help, -h          Display this help message."
    echo_err
    echo_err "Any additional arguments are passed to 'qm create' command."
    echo_err
    exit 1
}


#
# Main
#

VM_IMAGE=
VM_NAME=
VM_CIPASSWORD=
VM_SSHKEYS=
VM_OSTYPE=$DEFAULT_OSTYPE
VM_CORES=$DEFAULT_CORES
VM_MEMORY=$DEFAULT_MEMORY
VM_DISKSIZE=$DEFAULT_DISKSIZE
VM_BALLOON=0
VM_INSTALL_DOCKER=0

# Parse arguments -- https://stackoverflow.com/a/14203146/33244
POSITIONAL_ARGS=()
while [[ "$#" -gt 0 ]]; do case $1 in
    --image) VM_IMAGE="$2"; shift; shift;;
    --name) VM_NAME="$2"; shift; shift;;
    --cipassword) VM_CIPASSWORD="$2"; shift; shift;;
    --sshkey|--sshkeys) VM_SSHKEYS="$2"; shift; shift;;

    --ostype) VM_OSTYPE="$2"; shift; shift;;
    --cores) VM_CORES="$2"; shift; shift;;
    --memory) VM_MEMORY="$2"; shift; shift;;
    --disksize) VM_DISKSIZE="$2"; shift; shift;;
    --balloon) VM_BALLOON="$2"; shift; shift;;
    --install-docker) VM_INSTALL_DOCKER=1; shift;;

    -h|--help) show_usage;;
    *) POSITIONAL_ARGS+=("$1"); shift;;
esac; done
set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters

VM_ID="$1"; shift
if [ -z "$VM_ID" ]; then show_usage "You must inform a VM id."; fi;
if [ -z "$VM_IMAGE" ]; then show_usage "You must inform an image file (--image)."; fi;
if [ -z "$VM_NAME" ]; then show_usage "You must inform a VM name (--name)."; fi;
if [ -z "$VM_CIPASSWORD" ] && [ -z "$VM_SSHKEYS" ]; then show_usage "You must inform either a password (--cipassword) or a public ssh key file (--sshkeys)."; fi;



# Create VM
qm create $VM_ID --name $VM_NAME \
    --cpu host \
    --ostype $VM_OSTYPE \
    --scsihw virtio-scsi-single \
    --agent 1 \
    --bios ovmf \
    --machine pc-q35-6.0 \
    --net0 virtio,bridge=vmbr0 \
    --cores $VM_CORES \
    --numa 1 \
    --memory $VM_MEMORY \
    --balloon $VM_BALLOON \
    --onboot 1 \
    "$@" # pass remaining arguments -- https://stackoverflow.com/a/4824637/33244

# Disk 0: EFI
pvesm alloc local-zfs $VM_ID vm-$VM_ID-efi 1M
qm set $VM_ID --efidisk0 local-zfs:vm-$VM_ID-efi

# Disk 1: Main disk
qm importdisk $VM_ID $VM_IMAGE local-zfs
qm set $VM_ID --scsi1 local-zfs:vm-$VM_ID-disk-0,discard=on,iothread=1,ssd=1 \
    --boot c \
    --bootdisk scsi1
qm resize $VM_ID scsi1 $VM_DISKSIZE

# Disk 2: cloud-init
qm set $VM_ID --ide2 local-zfs:cloudinit 



# Initialize VM via cloud-init
mkdir -p /var/lib/vz/snippets/
CI_USER_FILE="vm-$VM_ID-cloud-init-user.yml"
CI_USER_FILE_FULL="/var/lib/vz/snippets/$CI_USER_FILE"

qm set $VM_ID --serial0 socket \
    --ipconfig0 ip=dhcp \
    --cicustom "user=local:snippets/$CI_USER_FILE"

if [ -n "$VM_CIPASSWORD" ]; then 
    qm set $VM_ID --cipassword $VM_CIPASSWORD
fi;

if [ -n "$VM_SSHKEYS" ]; then 
    qm set $VM_ID --sshkey ~/.ssh/fdcastel.pub
fi;
  
qm cloudinit dump $VM_ID user > $CI_USER_FILE_FULL

INTERFACE_NAME='eth0'
cat >> $CI_USER_FILE_FULL <<EOF
write_files:
 - content: |
     \S{PRETTY_NAME} \n \l

     $INTERFACE_NAME: \4{$INTERFACE_NAME}
     
   path: /etc/issue
   owner: root:root
   permissions: '0644'

power_state:
  mode: reboot
  timeout: 300

runcmd:
 - 'apt update -y'
 - 'apt install -y qemu-guest-agent'
EOF

if [ $VM_INSTALL_DOCKER -eq 1 ]; then
    # Install docker
    #   https://docs.docker.com/engine/install/ubuntu/
    #   https://docs.docker.com/engine/install/debian/
    cat >> $CI_USER_FILE_FULL <<'EOF'
 - 'apt-get update'
 - 'apt-get install -y ca-certificates curl'
 - 'install -m 0755 -d /etc/apt/keyrings'
 - '. /etc/os-release && curl -fsSL https://download.docker.com/linux/$ID/gpg -o /etc/apt/keyrings/docker.asc'
 - 'chmod a+r /etc/apt/keyrings/docker.asc'
 - '. /etc/os-release && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$ID $VERSION_CODENAME stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null'
 - 'apt-get update -y'
 - 'apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin'
EOF
fi



# Start VM
qm start $VM_ID

# Wait for qemu-guest-agent
echo "Waiting for VM $VM_ID..."
until qm agent $VM_ID ping
do
    sleep 2
done

# Remove custom cloud-init configuration
qm set $VM_ID --delete cicustom
rm $CI_USER_FILE_FULL

echo 'All done!'
