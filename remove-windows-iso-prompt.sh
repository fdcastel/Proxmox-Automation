#!/bin/bash

set -e    # Exit when any command fails


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
    echo_err "Usage: $0 <iso_file> [output_file] [OPTIONS]"
    echo_err '    <iso_file>           Path to Windows ISO file.'
    echo_err '    [output_file]        Path for modified ISO (default: <iso_file>.noprompt.iso).'
    echo_err "    --help, -h           Display this help message."
    echo_err
    exit 1
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

ISO_FILE="$1"
if [ -z "$ISO_FILE" ]; then show_usage "You must inform an ISO file."; fi;

if [ ! -f "$ISO_FILE" ]; then
    echo_err "Error: ISO file '$ISO_FILE' not found"
    exit 1
fi

if [ -n "$2" ]; then
    OUTPUT_FILE="$2"
else
    OUTPUT_FILE="${ISO_FILE%.iso}.noprompt.iso"
fi

TEMP_DIR="/tmp/iso-mod-$$"

cleanup() {
    if mountpoint -q "$TEMP_DIR/mount" 2>/dev/null; then
        umount "$TEMP_DIR/mount" 2>/dev/null || true
    fi
    [ -d "$TEMP_DIR" ] && rm -rf "$TEMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TEMP_DIR/mount"

# Get volume label using isoinfo (part of genisoimage)
VOLUME_LABEL=$(isoinfo -d -i "$ISO_FILE" 2>/dev/null | grep "Volume id:" | cut -d: -f2 | tr -d ' ')
if [ -z "$VOLUME_LABEL" ]; then
    VOLUME_LABEL="WINISO"
fi

echo "Processing ISO: $ISO_FILE"
echo "Output: $OUTPUT_FILE"
echo "Volume label: $VOLUME_LABEL"

# Mount the ISO
echo "Mounting ISO..."
mount -o loop,ro "$ISO_FILE" "$TEMP_DIR/mount"

# Copy contents to writable directory
echo "Copying ISO contents..."
cp -r "$TEMP_DIR/mount" "$TEMP_DIR/contents"

# Unmount early
umount "$TEMP_DIR/mount"

# Check for no-prompt EFI image
EFI_DIR="$TEMP_DIR/contents/efi/microsoft/boot"
EFI_SYS_BIN="$EFI_DIR/efisys.bin"
EFI_SYS_NOPROMPT="$EFI_DIR/efisys_noprompt.bin"

if [ ! -f "$EFI_SYS_NOPROMPT" ]; then
    echo_err "Error: efisys_noprompt.bin not found. This indicates the ISO image may be corrupted."
    echo_err "Official Windows ISO images should always contain this file."
    exit 1
fi

echo "Found no-prompt EFI image, replacing efisys.bin..."
# Replace the default efisys.bin with the noprompt version
cp "$EFI_SYS_NOPROMPT" "$EFI_SYS_BIN"

# Create new ISO from mount point with proper dual boot support
echo "Creating modified ISO..."
(
    cd "$TEMP_DIR/contents"
    genisoimage \
        -allow-limited-size \
        -iso-level 4 \
        -U \
        -D \
        -N \
        -joliet \
        -joliet-long \
        -relaxed-filenames \
        -V "$VOLUME_LABEL" \
        -b boot/etfsboot.com \
        -no-emul-boot \
        -boot-load-size 8 \
        -hide boot.catalog \
        -eltorito-alt-boot \
        -e efi/microsoft/boot/efisys.bin \
        -no-emul-boot \
        -o "$OUTPUT_FILE" \
        .
)

echo "Done! Modified ISO created: $OUTPUT_FILE"
