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
