#!/bin/bash

set -e    # Exit when any command fails


#
# Constants
#

ISO_FOLDER='/var/lib/vz/template/iso/'


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
    echo_err "Usage: $0 <url> [OPTIONS]"
    echo_err '    <url>                Url of image to download.'
    echo_err "    --no-clobber, -nc    Doesn't overwrite an existing image."
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

URL="$1"
if [ -z "$URL" ]; then show_usage "You must inform an url."; fi;

# Extract the base file name from a URL -- https://unix.stackexchange.com/a/64435
URL_FILE="${URL##*/}"

LOCAL_FILE="$ISO_FOLDER/$URL_FILE"

UNCOMPRESSED_LOCAL_FILE="$LOCAL_FILE"
case $LOCAL_FILE in
  *"gz"|*"xz"|*"zip") UNCOMPRESSED_LOCAL_FILE=${LOCAL_FILE%.*};;
esac

if [ $NO_CLOBBER -eq 1 ] && [ -f "$UNCOMPRESSED_LOCAL_FILE" ]; then
    echo $UNCOMPRESSED_LOCAL_FILE
    exit 0
fi

wget -O $LOCAL_FILE $URL --show-progress
if [ $? -ne 0 ]; then
    echo_err "Error downloading '$URL'."
    exit 1
fi

# Uncompress file (if needed)
case $LOCAL_FILE in
  *"gz") echo_err "Extracting (.gz)..."; gunzip -d $LOCAL_FILE -f -v;;
  *"xz") echo_err "Extracting (.xz)..."; xz -d $LOCAL_FILE -f -v;;
  *"zip") echo_err "Extracting (.zip)..."; unzip -o $LOCAL_FILE -d $ISO_FOLDER 1>&2 && rm $LOCAL_FILE;;    # unzip outputs info to stdout
esac

# Return the full path of downloaded file
echo $UNCOMPRESSED_LOCAL_FILE
