#!/bin/bash

set -e    # Exit when any command fails


#
# Constants
#

ISO_FOLDER='/var/lib/vz/template/iso/'
URL_ROOT="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/"
URL_FILE="virtio-win.iso"
URL="${URL_ROOT}${URL_FILE}"


#
# Functions
#

function echo_err() { 
    >&2 echo "$@"
}

function show_usage() {
    if [ -n "$1" ]; then
        tput setaf 1
        echo_err "Error: $1";
        tput sgr0
    fi
    echo_err
    echo_err "Usage: $0 [output_path] [OPTIONS]"
    echo_err '    output_path          Path to save the ISO (directory or full file path). Defaults to /var/lib/vz/template/iso/.'
    echo_err "    --no-clobber, -nc    Doesn't overwrite an existing ISO."
    echo_err "    --help, -h           Display this help message."
    echo_err
    exit 1
}


#
# Main
#

NO_CLOBBER=0

# Parse arguments -- https://stackoverflow.com/a/14203146/33244
POSITIONAL_ARGS=()
while [[ "$#" -gt 0 ]]; do case $1 in
    -nc|--no-clobber) NO_CLOBBER=1; shift;;

    -h|--help) show_usage;;
    -*|--*) show_usage "Unknown option: $1";;
    *) POSITIONAL_ARGS+=("$1"); shift;;
esac; done
set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters

OUTPUT_PATH="${1:-$ISO_FOLDER}"

# Handle case where output path is a directory vs file
if [[ -d "$OUTPUT_PATH" ]]; then
    IMG_FILE="${OUTPUT_PATH}/${URL_FILE}"
else
    # If user provided a full path including filename
    IMG_FILE="$OUTPUT_PATH"
fi

if [ $NO_CLOBBER -eq 1 ] && [ -f "$IMG_FILE" ]; then
    echo $IMG_FILE
    exit 0
fi

wget -O "$IMG_FILE" "$URL" --show-progress
if [ $? -ne 0 ]; then
    echo_err "Error downloading '$URL'."
    exit 1
fi

# Return the full path of downloaded file
echo $IMG_FILE
