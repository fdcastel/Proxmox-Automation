#!/bin/bash

URL_ROOT='https://cloud-images.ubuntu.com/releases/focal/release/'
URL_FILE='ubuntu-20.04-server-cloudimg-amd64.img'

URL="$URL_ROOT/$URL_FILE"

ISO_FOLDER='/var/lib/vz/template/iso/'

IMG_FILE="$ISO_FOLDER/ubuntu-20.04-server-cloudimg-amd64.img"
wget -nc -O $IMG_FILE $URL
if [ $? -ne 0 ]; then
    echo "Error downloading '$URL'."
    exit 1
fi

EXPECTED_HASH=$(curl -s "$URL_ROOT/SHA256SUMS" | grep $URL_FILE)
ACTUAL_HASH=$(sha256sum "$ISO_FOLDER/$URL_FILE")

echo "expected: $EXPECTED_HASH"
echo "  actual: $ACTUAL_HASH"
