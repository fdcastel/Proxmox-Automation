#!/bin/bash

set -e    # Exit when any command fails


#
# Constants
#

DEFAULT_FOLDER='/tmp'


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
    echo_err "Usage: $0 <url> <sha256> [target_directory] [OPTIONS]"
    echo_err '    <url>                Url of file to download.'
    echo_err '    <sha256>             Expected SHA-256 hash of the file.'
    echo_err '    [target_directory]   Directory to save the file (default: /tmp).'
    echo_err "    --help, -h           Display this help message."
    echo_err
    exit 1
}

function compute_sha256() {
    local file="$1"
    sha256sum "$file" | awk '{print $1}'
}

function verify_file() {
    local file="$1"
    local expected_hash="$2"
    
    if [ ! -f "$file" ]; then
        return 1
    fi
    
    local actual_hash=$(compute_sha256 "$file")
    
    if [ "$actual_hash" = "$expected_hash" ]; then
        return 0
    else
        return 1
    fi
}


#
# Main
#

# Parse arguments -- https://stackoverflow.com/a/14203146/33244
POSITIONAL_ARGS=()
while [[ "$#" -gt 0 ]]; do case $1 in
    -h|--help) show_usage;;
    -*|--*) show_usage "Unknown option: $1";;
    *) POSITIONAL_ARGS+=("$1"); shift;;
esac; done
set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters

URL="$1"
EXPECTED_SHA256="$2"
TARGET_DIR="${3:-$DEFAULT_FOLDER}"

if [ -z "$URL" ]; then show_usage "You must inform an url."; fi;
if [ -z "$EXPECTED_SHA256" ]; then show_usage "You must inform a SHA-256 hash."; fi;

# Extract the base file name from a URL -- https://unix.stackexchange.com/a/64435
URL_FILE="${URL##*/}"

LOCAL_FILE="$TARGET_DIR/$URL_FILE"

# Ensure target directory exists
mkdir -p "$TARGET_DIR"

# Check if file already exists and verify hash
if [ -f "$LOCAL_FILE" ]; then
    if verify_file "$LOCAL_FILE" "$EXPECTED_SHA256"; then
        echo_err "File already exists and hash is valid."
        echo $LOCAL_FILE
        exit 0
    else
        echo_err "File exists but hash mismatch. Re-downloading..."
        rm -f "$LOCAL_FILE"
    fi
fi

# Download file
wget -O $LOCAL_FILE $URL --show-progress
if [ $? -ne 0 ]; then
    echo_err "Error downloading '$URL'."
    exit 1
fi

# Verify downloaded file
if verify_file "$LOCAL_FILE" "$EXPECTED_SHA256"; then
    echo_err "Download complete. Hash verified successfully."
else
    echo_err "Error: Downloaded file hash does not match expected value."
    echo_err "Expected: $EXPECTED_SHA256"
    echo_err "Actual:   $(compute_sha256 "$LOCAL_FILE")"
    rm -f "$LOCAL_FILE"
    exit 1
fi

# Return the full path of downloaded file
echo $LOCAL_FILE
