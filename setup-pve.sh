#!/bin/bash

PVE_ENTERPRISE_SOURCES_FILE='/etc/apt/sources.list.d/pve-enterprise.sources'
PVE_NO_SUBSCRIPTION_SOURCES_FILE='/etc/apt/sources.list.d/proxmox.sources'
CEPH_SOURCES_FILE='/etc/apt/sources.list.d/ceph.sources'

# Check PVE version
pveversion | grep 'pve-manager/9'
if [ $? -ne 0 ]; then
    echo 'This script only works with Proxmox VE 9.x.'
    exit 1
fi

# Remove Proxmox VE Enterprise Repository (subscription-only) sources
rm -rf $PVE_ENTERPRISE_SOURCES_FILE

# Remove Ceph sources
rm -rf $CEPH_SOURCES_FILE

# Add Proxmox VE No-Subscription Repository sources
cat > $PVE_NO_SUBSCRIPTION_SOURCES_FILE <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

# Heads-up: PVE/Ceph packages may re-ship pve-enterprise.sources / ceph.sources during
# `apt-get install` or dist-upgrade, after which `apt-get update` returns 401 from
# enterprise.proxmox.com until the file is removed again. This script is idempotent,
# so the fix is simply to re-run it after installing or upgrading PVE.
if ! dpkg-query -W -f='${Status}' proxmox-ve 2>/dev/null | grep -q 'install ok installed'; then
    echo "NOTE: proxmox-ve is not installed yet. After 'apt-get install proxmox-ve' (or any future"
    echo "      dist-upgrade), re-run this script -- packages can re-ship pve-enterprise.sources"
    echo "      and 'apt-get update' will fail with 401 Unauthorized until you do."
fi
