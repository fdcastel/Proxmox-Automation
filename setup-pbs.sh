#!/bin/bash

PBS_ENTERPRISE_SOURCES_FILE='/etc/apt/sources.list.d/pbs-enterprise.list'

#
# Check PBS version
#
proxmox-backup-manager version | grep 'proxmox-backup-server 2'
if [ $? -ne 0 ]; then
    echo 'This script only works with Proxmox Backup Server 2.x.'
    exit 1
fi

#
# Run-only-once check
#
FIRST_LINE=$(head -1 $PBS_ENTERPRISE_SOURCES_FILE)
if [ "$FIRST_LINE" == '# Disable pbs-enterprise' ]; then
    echo 'This script must be run only once.'
    exit 1
fi

#
# Remove enterprise (subscription-only) sources
#
cat > $PBS_ENTERPRISE_SOURCES_FILE <<EOF
# Disable pbs-enterprise
# deb https://enterprise.proxmox.com/debian/pbs bullseye pbs-enterprise
EOF

cat >> /etc/apt/sources.list <<EOF

# PBS pbs-no-subscription repository provided by proxmox.com,
# NOT recommended for production use
deb http://download.proxmox.com/debian/pbs bullseye pbs-no-subscription
EOF
