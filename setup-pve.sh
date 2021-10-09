#!/bin/bash

PVE_ENTERPRISE_SOURCES_FILE='/etc/apt/sources.list.d/pve-enterprise.list'

#
# Check PVE version
#
pveversion | grep 'pve-manager/7'
if [ $? -ne 0 ]; then
    echo 'This script only works with Proxmox VE 7.'
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
# deb https://enterprise.proxmox.com/debian bullseye pve-enterprise
EOF

cat >> /etc/apt/sources.list <<EOF

# Proxmox no-subscription sources
deb http://download.proxmox.com/debian bullseye pve-no-subscription
EOF

#
# Disable nag subscription dialog (working with v7.0)
#
PROXMOXLIB_FILE=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
cp $PROXMOXLIB_FILE $PROXMOXLIB_FILE.bak
SEARCH_REGEX="Ext\.Msg\.show\(\{\s*title: gettext\('No valid subscription'\),"
REPLACE_TEXT="void\(\{\n                            title: gettext\('No valid subscription'\),"
perl -0777 -i -p -e "s/\b$SEARCH_REGEX/$REPLACE_TEXT/igs" $PROXMOXLIB_FILE
systemctl restart pveproxy.service

#
# Update everything
#
apt update && apt dist-upgrade -y
