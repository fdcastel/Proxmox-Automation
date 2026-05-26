#!/bin/bash

PBS_ENTERPRISE_SOURCES_FILE='/etc/apt/sources.list.d/pbs-enterprise.sources'
PBS_NO_SUBSCRIPTION_SOURCES_FILE='/etc/apt/sources.list.d/pbs-no-subscription.sources'

# Remove Proxmox Backup Server Enterprise Repository (subscription-only) sources
rm -rf $PBS_ENTERPRISE_SOURCES_FILE

# Add Proxmox Backup Server No-Subscription Repository sources
cat > $PBS_NO_SUBSCRIPTION_SOURCES_FILE <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pbs
Suites: trixie
Components: pbs-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

# Heads-up: the proxmox-backup-server package re-ships pbs-enterprise.sources during
# `apt-get install` / dist-upgrade, after which `apt-get update` returns 401 from
# enterprise.proxmox.com until the file is removed again. This script is idempotent,
# so the fix is simply to re-run it after installing or upgrading PBS.
if ! dpkg-query -W -f='${Status}' proxmox-backup-server 2>/dev/null | grep -q 'install ok installed'; then
    echo "NOTE: proxmox-backup-server is not installed yet. After 'apt-get install proxmox-backup-server',"
    echo "      re-run this script -- the package re-ships pbs-enterprise.sources and 'apt-get update'"
    echo "      will fail with 401 Unauthorized until you do."
fi
