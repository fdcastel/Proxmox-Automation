#!/bin/bash

main () {
    URL='https://codeload.github.com/fdcastel/PVE-Automation/zip/master'

    TEMP_FOLDER=$(mktemp -d)

    ZIP_FILE="$TEMP_FOLDER/PVE-Automation-master.zip"
    wget -q -O $ZIP_FILE $URL
    if [ $? -ne 0 ]; then
        echo "Error downloading '$URL'."
        return 1
    fi

    # Install unzip
    apt-get update
    apt-get -y install unzip

    unzip -q $ZIP_FILE -d $TEMP_FOLDER
    if [ $? -eq 127 ]; then
        echo "Command 'unzip' not found. Install it with 'apt-get install unzip -y'."
        return 1
    fi

    cd "$TEMP_FOLDER/PVE-Automation-master"

    cat > ./clean.sh <<EOF
    cd /
    rm -R ${TEMP_FOLDER}
EOF

    sleep .5
    chmod +x ./*.sh

    echo "Ready! Type '. clean.sh' when finished." 
}

main "$@"
