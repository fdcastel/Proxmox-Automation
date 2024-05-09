#!/bin/bash

set -e    # Exit when any command fails


#
# Constants
#

DEFAULT_OSTYPE='ubuntu'
DEFAULT_CORES=2
DEFAULT_MEMORY=2048
DEFAULT_ROOTFS='local-zfs:120'
DEFAULT_BRIDGE='vmbr0'
DEFAULT_DOCKER_VOLSIZE='8G'

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
    echo_err "Usage: $0 <ctid> --ostemplate <file> --hostname <name> --password <password> [OPTIONS]"
    echo_err '    <ctid>              Proxmox unique ID of the CT.'
    echo_err '    --ostemplate        The OS template or backup file.'
    echo_err '    --hostname          Set a host name for the container.'
    echo_err '    --password          Sets root password inside container.'
    echo_err '    --sshkey[s]         Setup public SSH keys (one key per line, OpenSSH format).'
    echo_err
    echo_err 'Additional options:'
    echo_err "    --ostype            OS type (default = $DEFAULT_OSTYPE)."
    echo_err "    --cores             Number of cores per socket (default = $DEFAULT_CORES)."
    echo_err "    --memory            Amount of RAM for the VM in MB (default = $DEFAULT_MEMORY)."
    echo_err "    --rootfs            Use volume as container root (default = $DEFAULT_ROOTFS)."
    echo_err '    --privileged        Makes the container run as privileged user (default = unprivileged).'
    echo_err "    --bridge            Use bridge for container networking (default = $DEFAULT_BRIDGE)"
    echo_err '    --install-docker    Install docker and docker-compose.'
    echo_err '    --no-docker-volume  Do not create a new volume for /var/lib/docker (default for PVE 8.1+).'
    echo_err "    --docker-volsize    Set container volume size (default = $DEFAULT_DOCKER_VOLSIZE)"
    echo_err "    --help, -h          Display this help message."
    echo_err
    echo_err "Any additional arguments are passed to 'pct create' command."
    echo_err
    exit 1
}


#
# Main
#

CT_OSTEMPLATE=
CT_HOSTNAME=
CT_PASSWORD=
CT_SSHKEYS=
CT_OSTYPE=$DEFAULT_OSTYPE
CT_CORES=$DEFAULT_CORES
CT_MEMORY=$DEFAULT_MEMORY
CT_ROOTFS=$DEFAULT_ROOTFS
CT_UNPRIVILEGED=1
CT_BRIDGE=$DEFAULT_BRIDGE
CT_INSTALL_DOCKER=0
CT_USE_DOCKER_VOLUME=1
CT_DOCKER_VOLSIZE=$DEFAULT_DOCKER_VOLSIZE

# Do not use docker volume from Proxmox VE 8.1 or higher.
PVE_VERSION=$([[ $(pveversion) =~ ^pve-manager/([0-9]+\.[0-9]+) ]] && echo "${BASH_REMATCH[1]}")
if [ "$PVE_VERSION" \> "8.0" ]; then CT_USE_DOCKER_VOLUME=0; fi;

# Parse arguments -- https://stackoverflow.com/a/14203146/33244
POSITIONAL_ARGS=()
while [[ "$#" -gt 0 ]]; do case $1 in
    --ostemplate) CT_OSTEMPLATE="$2"; shift; shift;;
    --hostname) CT_HOSTNAME="$2"; shift; shift;;
    --password) CT_PASSWORD="$2"; shift; shift;;
    --sshkey|--sshkeys) CT_SSHKEYS="$2"; shift; shift;;

    --ostype) CT_OSTYPE="$2"; shift; shift;;
    --cores) CT_CORES="$2"; shift; shift;;
    --memory) CT_MEMORY="$2"; shift; shift;;
    --rootfs) CT_ROOTFS="$2"; shift; shift;;
    --bridge) CT_BRIDGE="$2"; shift; shift;;
    --privileged) CT_UNPRIVILEGED=0; shift;;

    --install-docker) CT_INSTALL_DOCKER=1; shift;;
    --no-docker-volume) CT_USE_DOCKER_VOLUME=0; shift;;
    --docker-volsize) CT_DOCKER_VOLSIZE="$2"; shift; shift;;

    -h|--help) show_usage;;
    *) POSITIONAL_ARGS+=("$1"); shift;;
esac; done
set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters

CT_ID="$1"; shift
if [ -z "$CT_ID" ]; then show_usage "You must inform a CT id."; fi;
if [ -z "$CT_OSTEMPLATE" ]; then show_usage "You must inform an OS template (--ostemplate)."; fi;
if [ -z "$CT_HOSTNAME" ]; then show_usage "You must inform a host name (--hostname)."; fi;
if [ -z "$CT_PASSWORD" ] && [ -z "$CT_SSHKEYS" ]; then show_usage "You must inform either a password (--password) or a public ssh key file (--sshkeys)."; fi;

PASSWORD_ARGS=
if [ -n "$CT_PASSWORD" ]; then
    PASSWORD_ARGS="--password $CT_PASSWORD"
fi;

SSH_KEYS_ARGS=
if [ -n "$CT_SSHKEYS" ]; then
    SSH_KEYS_ARGS="--ssh-public-keys $CT_SSHKEYS"
fi;

if [ $CT_INSTALL_DOCKER -eq 1 ]; then
    if [ "$CT_OSTYPE" != 'ubuntu' ] && [ "$CT_OSTYPE" != 'debian' ] && [ "$CT_OSTYPE" != 'alpine' ]; then
        show_usage "Don't know how to install docker on '$OSTYPE'.";
    fi

    # Extra arguments required for Docker
    DOCKER_ARGS="--features keyctl=1,nesting=1"

    if [ $CT_USE_DOCKER_VOLUME -eq 1 ]; then
        DOCKER_VOL=$(./new-ct-docker-volume.sh --volsize $CT_DOCKER_VOLSIZE $CT_ID)
        DOCKER_ARGS="--features keyctl=1,nesting=1 --mp0 local-zfs:$DOCKER_VOL,mp=/var/lib/docker,backup=0"
    fi;
fi;

# Create CT
CT_INTERFACE_NAME='eth0'
pct create $CT_ID $CT_OSTEMPLATE \
    --ostype $CT_OSTYPE \
    --cmode shell \
    --hostname $CT_HOSTNAME \
    --rootfs $CT_ROOTFS \
    --net0 name=$CT_INTERFACE_NAME,bridge=$CT_BRIDGE,ip=dhcp \
    --cores $CT_CORES \
    --memory $CT_MEMORY \
    --onboot 1 \
    --unprivileged $CT_UNPRIVILEGED \
    $DOCKER_ARGS \
    $PASSWORD_ARGS \
    $SSH_KEYS_ARGS \
    "$@" # pass remaining arguments -- https://stackoverflow.com/a/4824637/33244

# Cannot set timezone in 'pct create' (Bug?)
#   Causes "Insecure dependency in symlink while running with -T switch at /usr/share/perl5/PVE/LXC/Setup/Base.pm"
#   pveversion: pve-manager/7.0-11/63d82f4e (running kernel: 5.11.22-4-pve)
pct set $CT_ID --timezone host

# Start container
pct start $CT_ID

 # Update /etc/issue
pct exec $CT_ID sh <<EOF
cat >/etc/issue <<'EOC'
\S{PRETTY_NAME} \n \l

$CT_INTERFACE_NAME: \4{$CT_INTERFACE_NAME}
EOC
EOF

# Install docker
if [ $CT_INSTALL_DOCKER -eq 1 ]; then
    # Wait for network -- Source: https://stackoverflow.com/a/24963234
    pct exec $CT_ID -- sh <<EOF
WAIT_FOR_HOST=google.com
while ! (ping -c 1 -W 1 \$WAIT_FOR_HOST > /dev/null 2>&1); do
    echo "Waiting for \$WAIT_FOR_HOST - network interface might be down..."
    sleep 1
done
EOF

    if [ "$CT_OSTYPE" == 'ubuntu' ] || [ "$CT_OSTYPE" == 'debian' ]; then
        # Install docker
        #   https://docs.docker.com/engine/install/ubuntu/
        #   https://docs.docker.com/engine/install/debian/
        pct exec $CT_ID -- sh <<'EOF'
apt-get update
apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
. /etc/os-release && curl -fsSL https://download.docker.com/linux/$ID/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$ID $VERSION_CODENAME stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
EOF
    fi

    if [ "$CT_OSTYPE" == 'alpine' ]; then
        # Install docker
        #   https://wiki.alpinelinux.org/wiki/Docker
        pct exec $CT_ID -- sh <<EOF
apk update
apk add docker docker-cli-compose
rc-update add docker default
service docker start
EOF
    fi

    # Assert that storage driver is 'overlay2'
    pct exec $CT_ID docker info | grep -i 'storage driver: overlay2' > /dev/null
    if [ $? -ne 0 ]; then
        tput setaf 1
        echo_err 'WARNING: Docker storage driver is not "overlay2".'
        tput sgr0
    fi
fi
