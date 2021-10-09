#!/bin/bash

set -e    # Exit when any command fails


#
# Default values
#
DEFAULT_ROOTFS='local-zfs:8'
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
    echo "Usage: $0 <ctid> --ostemplate <file> --hostname <name> --password <password> [OPTIONS]"
    echo '    <ctid>              Proxmox unique ID of the CT.'
    echo '    --ostemplate        The OS template or backup file.'
    echo '    --hostname          Set a host name for the container.'
    echo '    --password          Sets root password inside container.'
    echo
    echo 'Additional options:'
    echo "    --cores             Number of cores per socket (default = $DEFAULT_CORES)."
    echo "    --memory            Amount of RAM for the VM in MB (default = $DEFAULT_MEMORY)."
    echo "    --rootfs            Use volume as container root (default = $DEFAULT_ROOTFS)."
    echo '    --sshkey[s]         Setup public SSH keys (one key per line, OpenSSH format).'
    echo '    --install-docker    Install docker and docker-compose.'
    echo '    --privileged        Makes the container run as privileged user (default = unprivileged).'
    echo
    exit 1
}


#
# Main
#

# Parse arguments
CT_ROOTFS=$DEFAULT_ROOTFS
CT_CORES=$DEFAULT_CORES
CT_MEMORY=$DEFAULT_MEMORY
CT_INSTALL_DOCKER=0
CT_UNPRIVILEGED=1

CT_ID="$1"
shift

while [[ "$#" > 0 ]]; do case $1 in
    --ostemplate) CT_OSTEMPLATE="$2"; shift;shift;;
    --hostname) CT_HOSTNAME="$2"; shift;shift;;
    --password) CT_PASSWORD="$2"; shift;shift;;

    --cores) CT_CORES="$2"; shift;shift;;
    --memory) CT_MEMORY="$2";shift;shift;;
    --rootfs) CT_ROOTFS="$2";shift;shift;;
    --sshkey|--sshkeys) CT_SSHKEYS="$2"; shift;shift;;
    --install-docker) CT_INSTALL_DOCKER=1;shift;;
    --privileged) CT_UNPRIVILEGED=0;shift;;

    *) show_usage "Invalid argument: $1"; shift; shift;;
esac; done

if [ -z "$CT_ID" ]; then show_usage "You must inform a CT id."; fi;
if [ -z "$CT_OSTEMPLATE" ]; then show_usage "You must inform an OS template (--ostemplate)."; fi;
if [ -z "$CT_HOSTNAME" ]; then show_usage "You must inform a host name (--hostname)."; fi;
if [ -z "$CT_PASSWORD" ]; then show_usage "You must inform a password (--password)."; fi;

if [ -n "$CT_SSHKEYS" ]; then 
    SSH_KEYS_ARGS="--ssh-public-keys $CT_SSHKEYS"
fi;

if [ $CT_INSTALL_DOCKER -eq 1 ]; then
    # Source: https://www.reddit.com/r/Proxmox/comments/lsrt28/easy_way_to_run_docker_in_an_unprivileged_lxc_on/
    # Related: https://github.com/moby/moby/issues/31247

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

    # Extra arguments required for Docker
    DOCKER_ARGS="--unprivileged $CT_UNPRIVILEGED --features keyctl=$CT_UNPRIVILEGED,nesting=1 --mp0 $DOCKER_DEV,mp=/var/lib/docker,backup=0"
fi;

# Create CT
CT_INTERFACE_NAME='eth0'
pct create $CT_ID $CT_OSTEMPLATE \
    --ostype ubuntu \
    --cmode shell \
    --hostname $CT_HOSTNAME \
    --password $CT_PASSWORD \
    --rootfs $CT_ROOTFS \
    --net0 name=$CT_INTERFACE_NAME,bridge=vmbr0,ip=dhcp \
    --cores $CT_CORES \
    --memory $CT_MEMORY \
    --onboot 1 \
    $DOCKER_ARGS \
    $SSH_KEYS_ARGS

# Cannot set timezone in 'pct create' (Bug?)
#   Causes "Insecure dependency in symlink while running with -T switch at /usr/share/perl5/PVE/LXC/Setup/Base.pm"
#   pveversion: pve-manager/7.0-11/63d82f4e (running kernel: 5.11.22-4-pve)
pct set $CT_ID --timezone host

# Start container
pct start $CT_ID

# Update /etc/issue
cat | pct exec $CT_ID -- bash -c 'cat > /etc/issue' <<EOF
\S{PRETTY_NAME} \n \l

$CT_INTERFACE_NAME: \4{$CT_INTERFACE_NAME}
EOF

# Install docker
if [ $CT_INSTALL_DOCKER -eq 1 ]; then
    cat | pct exec $CT_ID -- bash <<'EOF'
        # Wait for network -- Source: https://stackoverflow.com/a/24963234
        WAIT_FOR_HOST=archive.ubuntu.com
        while ! (ping -c 1 -W 1 $WAIT_FOR_HOST > /dev/null 2>&1); do
            echo "Waiting for $WAIT_FOR_HOST - network interface might be down..."
            sleep 1
        done

        # Install docker -- Source: https://docs.docker.com/engine/install/ubuntu/
        apt install -y apt-transport-https ca-certificates curl gnupg lsb-release
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list
        apt update -y
        apt install -y docker-ce docker-ce-cli containerd.io docker-compose
EOF
fi

# Assert that storage driver is 'overlay2'
pct exec $CT_ID docker info | grep -i 'storage driver: overlay2' > /dev/null
if [ $? -eq 0 ]; then
   echo 'All done!'
else
    tput setaf 1
    echo 'ERROR: Docker storage driver is not "overlay2".'
    tput sgr0
fi
