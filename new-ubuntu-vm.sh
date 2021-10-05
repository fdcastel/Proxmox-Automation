#!/bin/bash



#
# Default values
#
DEFAULT_CORES=2
DEFAULT_MEMORY=2048



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
    echo "Usage: $0 <vmid> --image <file> --name <name> [--cipassword <password>] | [--sshkey[s] <filepath>] [OPTIONS]"
    echo '    <vmid>              Proxmox unique ID of the VM.'
    echo '    --image             Path to image file.'
    echo '    --name              A name for the VM.'
    echo '    --cipassword        Password to assign the user. Using this is generally not recommended. Use ssh keys instead.'
    echo '    --sshkey[s]         Setup public SSH keys (one key per line, OpenSSH format).'
    echo
    echo 'Additional options:'
    echo "    --cores             Number of cores per socket (default = $DEFAULT_CORES)."
    echo "    --memory            Amount of RAM for the VM in MB (default = $DEFAULT_MEMORY)."
    echo '    --balloon           Amount of target RAM for the VM in MB. Using zero (default) disables the ballon driver.'
    echo '    --install-docker    Install docker and docker-compose.'
    echo
    exit 1
}



#
# Main
#

# Parse arguments
VM_CORES=$DEFAULT_CORES
VM_MEMORY=$DEFAULT_MEMORY
VM_BALLOON=0
VM_INSTALL_DOCKER=0

VM_ID="$1"
shift

while [[ "$#" > 0 ]]; do case $1 in
    --image) VM_IMAGE="$2"; shift;shift;;
    --name) VM_NAME="$2"; shift;shift;;
    --cipassword) VM_CIPASSWORD="$2"; shift;shift;;
    --sshkey|--sshkeys) VM_SSHKEYS="$2"; shift;shift;;

    --cores) VM_CORES="$2"; shift;shift;;
    --memory) VM_MEMORY="$2";shift;shift;;
    --balloon) VM_BALLOON="$2";shift;shift;;
    --install-docker) VM_INSTALL_DOCKER=1;shift;;

    *) show_usage "Invalid argument: $1"; shift; shift;;
esac; done

if [ -z "$VM_ID" ]; then show_usage "You must inform a VM id."; fi;
if [ -z "$VM_IMAGE" ]; then show_usage "You must inform an image file (--image)."; fi;
if [ -z "$VM_NAME" ]; then show_usage "You must inform a VM name (--name)."; fi;
if [ -z "$VM_CIPASSWORD" ] && [ -z "$VM_SSHKEYS" ]; then show_usage "You must inform either a password (--cipassword) or a public ssh key file (--sshkeys)."; fi;



# Create VM
qm create $VM_ID --name $VM_NAME \
    --ostype l26 \
    --scsihw virtio-scsi-single \
    --agent 1 \
    --bios ovmf \
    --machine pc-q35-6.0 \
    --net0 virtio,bridge=vmbr0 \
    --cores $VM_CORES \
    --numa 1 \
    --memory $VM_MEMORY \
    --balloon $VM_BALLOON \
    --onboot 1

# Disk 0: EFI
pvesm alloc local-zfs $VM_ID vm-$VM_ID-efi 1M
qm set $VM_ID --efidisk0 local-zfs:vm-$VM_ID-efi

# Disk 1: Main disk
qm importdisk $VM_ID $VM_IMAGE local-zfs
qm set $VM_ID --scsi1 local-zfs:vm-$VM_ID-disk-0,discard=on,iothread=1,ssd=1 \
    --boot c \
    --bootdisk scsi1
qm resize $VM_ID scsi1 120G

# Disk 2: cloud-init
qm set $VM_ID --ide2 local-zfs:cloudinit 



# Initialize VM via cloud-init
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
    # Source: https://docs.docker.com/engine/install/ubuntu/
    cat >> $CI_USER_FILE_FULL <<'EOF'
 - 'apt install -y apt-transport-https ca-certificates curl gnupg lsb-release'
 - 'curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg'
 - 'echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list'
 - 'apt update -y'
 - 'apt install -y docker-ce docker-ce-cli containerd.io docker-compose'
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
qm set 201 --delete cicustom
rm $CI_USER_FILE_FULL

echo 'All done!'
