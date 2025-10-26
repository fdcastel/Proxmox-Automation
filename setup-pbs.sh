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
