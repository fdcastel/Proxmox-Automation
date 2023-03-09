#!/bin/bash

main () {
    URL='https://codeload.github.com/fdcastel/Proxmox-Automation/zip/master'

    TEMP_FOLDER=$(mktemp -d)

    ZIP_FILE="$TEMP_FOLDER/Proxmox-Automation-master.zip"
    wget -q -O $ZIP_FILE $URL
    if [ $? -ne 0 ]; then
        echo "Error downloading '$URL'."
        return 1
    fi

    unzip -q $ZIP_FILE -d $TEMP_FOLDER
    if [ $? -eq 127 ]; then
        # Unzip not found. Try to install.
        apt-get update
        apt-get -y install unzip

        unzip -q $ZIP_FILE -d $TEMP_FOLDER
        if [ $? -eq 127 ]; then
            echo "Command 'unzip' not found. Install it with 'apt-get install unzip -y'."
            return 1
        fi
    fi

    cd "$TEMP_FOLDER/Proxmox-Automation-master"
    sleep .5
    chmod +x ./*.sh
}

main "$@"
