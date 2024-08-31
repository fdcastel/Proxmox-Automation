#!/bin/bash

PBS_ENTERPRISE_SOURCES_FILE='/etc/apt/sources.list.d/pbs-enterprise.list'

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
# deb https://enterprise.proxmox.com/debian/pbs bookworm pbs-enterprise
EOF

rm /etc/apt/sources.list.d/pbs-enterprise.list

cat >> /etc/apt/sources.list <<EOF

# Proxmox Backup Server pbs-no-subscription repository provided by proxmox.com,
# NOT recommended for production use
deb http://download.proxmox.com/debian/pbs bookworm pbs-no-subscription
EOF
