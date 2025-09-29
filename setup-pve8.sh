#!/bin/bash

PVE_ENTERPRISE_SOURCES_FILE='/etc/apt/sources.list.d/pve-enterprise.list'

#
# Check PVE version
#
pveversion | grep 'pve-manager/8'
if [ $? -ne 0 ]; then
    echo 'This script only works with Proxmox VE 8.x.'
    exit 1
fi

#
# Run-only-once check
#
FIRST_LINE=$(head -1 $PVE_ENTERPRISE_SOURCES_FILE)
if [ "$FIRST_LINE" == '# Disable pve-enterprise' ]; then
    echo 'This script must be run only once.'
    exit 1
fi

#
# Remove enterprise (subscription-only) sources
#
cat > $PVE_ENTERPRISE_SOURCES_FILE <<EOF
# Disable pve-enterprise
# deb https://enterprise.proxmox.com/debian/pve bookworm pve-enterprise
EOF

rm /etc/apt/sources.list.d/pve-enterprise.list
rm /etc/apt/sources.list.d/ceph.list

cat >> /etc/apt/sources.list <<EOF

# Proxmox VE pve-no-subscription repository provided by proxmox.com,
# NOT recommended for production use
deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription
EOF
