#!/bin/bash

set -e    # Exit when any command fails


#
# Constants
#

ISO_FOLDER='/var/lib/vz/template/cache/'


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
    echo_err '    <url>                Url of template to download.'
    echo_err "    --filename, -f       Renames the downloaded file."
    echo_err "    --no-clobber, -nc    Doesn't overwrite an existing template."
    echo_err "    --help, -h           Display this help message."
    echo_err
    exit 1
}


#
# Main
#

NO_CLOBBER=0
FILENAME=

# Parse arguments -- https://stackoverflow.com/a/14203146/33244
POSITIONAL_ARGS=()
while [[ "$#" -gt 0 ]]; do case $1 in
    -nc|--no-clobber) NO_CLOBBER=1; shift;;
    -f|--filename) FILENAME="$2"; shift; shift;;

    -h|--help) show_usage;;
    -*|--*) show_usage "Unknown option: $1";;
    *) POSITIONAL_ARGS+=("$1"); shift;;
esac; done
set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters

URL="$1"
if [ -z "$URL" ]; then show_usage "You must inform an url."; fi;

if [ -n "$FILENAME" ]; then
    LOCAL_FILE="$ISO_FOLDER/$FILENAME"
else
    # Extract the base file name from a URL -- https://unix.stackexchange.com/a/64435
    URL_FILE="${URL##*/}"
    LOCAL_FILE="$ISO_FOLDER/$URL_FILE"
fi

if [ $NO_CLOBBER -eq 1 ] && [ -f "$LOCAL_FILE" ]; then
    echo $LOCAL_FILE
    exit 0
fi

wget -O $LOCAL_FILE $URL --show-progress
if [ $? -ne 0 ]; then
    echo_err "Error downloading '$URL'."
    exit 1
fi

# Return the full path of downloaded file
echo $LOCAL_FILE
