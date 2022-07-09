#!/bin/bash

#
# Disable nag subscription dialog (working with v7.x)
#
PROXMOXLIB_FILE=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
cp $PROXMOXLIB_FILE $PROXMOXLIB_FILE.bak
SEARCH_REGEX="Ext\.Msg\.show\(\{\s*title: gettext\('No valid subscription'\),"
REPLACE_TEXT="void\(\{\n                            title: gettext\('No valid subscription'\),"
perl -0777 -i -p -e "s/\b$SEARCH_REGEX/$REPLACE_TEXT/igs" $PROXMOXLIB_FILE
systemctl restart pveproxy.service
