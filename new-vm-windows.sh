#!/bin/bash

set -e    # Exit when any command fails


#
# Constants
#

DEFAULT_STORAGE='local-zfs'
DEFAULT_OSTYPE='win11'
DEFAULT_CORES=2
DEFAULT_MEMORY=4096
DEFAULT_DISKSIZE='120'
DEFAULT_IMAGE_INDEX=1
VIRTIO_ISO='/var/lib/vz/template/iso/virtio-win.iso'


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
    echo_err "Usage: $0 <vmid> --iso <file> --name <name> --cipassword <password> [OPTIONS]"
    echo_err '    <vmid>              Proxmox unique ID of the VM.'
    echo_err '    --iso               Path to Windows ISO file.'
    echo_err '    --name              A name for the VM (hostname).'
    echo_err '    --cipassword        Password for the Administrator account.'
    echo_err
    echo_err 'Additional options:'
    echo_err "    --ostype            Guest OS type (default = $DEFAULT_OSTYPE)."
    echo_err "    --cores             Number of cores per socket (default = $DEFAULT_CORES)."
    echo_err "    --memory            Amount of RAM for the VM in MB (default = $DEFAULT_MEMORY)."
    echo_err "    --storage           Storage to use for VM disks (default = $DEFAULT_STORAGE)."
    echo_err "    --disksize          Size of VM main disk (default = $DEFAULT_DISKSIZE)."
    echo_err "    --image-index       Windows image index to install (default = $DEFAULT_IMAGE_INDEX)."
    echo_err "    --virtio-iso        Path to VirtIO drivers ISO (default = $VIRTIO_ISO)."
    echo_err "    --no-start          Do not start the VM after creation."
    echo_err "    --no-guest          Do not wait for QEMU Guest Agent after start."
    echo_err "    --help, -h          Display this help message."
    echo_err
    echo_err "Any additional arguments are passed to 'qm create' command."
    echo_err
    exit 1
}

function cleanup() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        umount "$TEMP_DIR/drivers" 2>/dev/null || true
        rm -rf "$TEMP_DIR"
    fi
    if [ -n "$UNATTENDED_ISO" ] && [ -f "$UNATTENDED_ISO" ]; then
        rm -f "$UNATTENDED_ISO"
    fi
}



#
# Main
#

VM_ISO=
VM_NAME=
VM_CIPASSWORD=
VM_OSTYPE=$DEFAULT_OSTYPE
VM_CORES=$DEFAULT_CORES
VM_MEMORY=$DEFAULT_MEMORY
VM_STORAGE=$DEFAULT_STORAGE
VM_DISKSIZE=$DEFAULT_DISKSIZE
VM_IMAGE_INDEX=$DEFAULT_IMAGE_INDEX
VM_VIRTIO_ISO=$VIRTIO_ISO
VM_NO_START=0
VM_NO_GUEST=0

# Parse arguments -- https://stackoverflow.com/a/14203146/33244
POSITIONAL_ARGS=()
while [[ "$#" -gt 0 ]]; do case $1 in
    --iso) VM_ISO="$2"; shift; shift;;
    --name) VM_NAME="$2"; shift; shift;;
    --cipassword) VM_CIPASSWORD="$2"; shift; shift;;

    --ostype) VM_OSTYPE="$2"; shift; shift;;
    --cores) VM_CORES="$2"; shift; shift;;
    --memory) VM_MEMORY="$2"; shift; shift;;
    --storage) VM_STORAGE="$2"; shift; shift;;
    --disksize) VM_DISKSIZE="$2"; shift; shift;;
    --image-index) VM_IMAGE_INDEX="$2"; shift; shift;;
    --virtio-iso) VM_VIRTIO_ISO="$2"; shift; shift;;

    --no-start) VM_NO_START=1; shift;;
    --no-guest) VM_NO_GUEST=1; shift;;

    -h|--help) show_usage;;
    *) POSITIONAL_ARGS+=("$1"); shift;;
esac; done
set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters

VM_ID="$1"; shift
if [ -z "$VM_ID" ]; then show_usage "You must inform a VM id."; fi;
if [ -z "$VM_ISO" ]; then show_usage "You must inform a Windows ISO file (--iso)."; fi;
if [ -z "$VM_NAME" ]; then show_usage "You must inform a VM name (--name)."; fi;
if [ -z "$VM_CIPASSWORD" ]; then show_usage "You must inform a password for Administrator (--cipassword)."; fi;

if [ ! -f "$VM_ISO" ]; then
    echo_err "Windows ISO not found at $VM_ISO"
    exit 1
fi

if [ ! -f "$VM_VIRTIO_ISO" ]; then
    echo_err "VirtIO ISO not found at $VM_VIRTIO_ISO"
    echo_err "Please download it with: ./download-virtio-image.sh"
    exit 1
fi

# Setup cleanup trap
trap cleanup EXIT



# Create temporary directory
TEMP_DIR="/tmp/win-vm-setup-$$"
mkdir -p "$TEMP_DIR/drivers"
mkdir -p "$TEMP_DIR/iso_root"

# Extract VirtIO drivers
echo_err "Extracting VirtIO drivers..."
mount -o loop,ro "$VM_VIRTIO_ISO" "$TEMP_DIR/drivers"

# List of drivers to copy
DRIVERS=(
    "Balloon"
    "fwcfg"
    "NetKVM"
    "pvpanic"
    "qemupciserial"
    "viofs"
    "viogpudo"
    "vioinput"
    "viomem"
    "viorng"
    "vioscsi"
    "vioserial"
    "viostor"
)

for driver in "${DRIVERS[@]}"; do
    dest_name=$(echo "$driver" | tr '[:upper:]' '[:lower:]')
    mkdir -p "$TEMP_DIR/iso_root/drivers/$dest_name"
    cp -r "$TEMP_DIR/drivers/$driver/2k22/amd64/"* "$TEMP_DIR/iso_root/drivers/$dest_name/" 2>/dev/null || \
    cp -r "$TEMP_DIR/drivers/$driver/w11/amd64/"* "$TEMP_DIR/iso_root/drivers/$dest_name/" 2>/dev/null || true
done

# qxldod is special (w10)
mkdir -p "$TEMP_DIR/iso_root/drivers/qxldod"
cp -r "$TEMP_DIR/drivers/qxldod/w10/amd64/"* "$TEMP_DIR/iso_root/drivers/qxldod/" 2>/dev/null || true

# Copy QEMU Guest Agent installer
mkdir -p "$TEMP_DIR/iso_root/guest-agent"
cp "$TEMP_DIR/drivers/guest-agent/qemu-ga-x86_64.msi" "$TEMP_DIR/iso_root/guest-agent/"

umount "$TEMP_DIR/drivers"

# Copy Cloud-Init Network Script
echo_err "Copying win-cloud-init.ps1..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/win-cloud-init.ps1" ]; then
    cp "$SCRIPT_DIR/win-cloud-init.ps1" "$TEMP_DIR/iso_root/win-cloud-init.ps1"
elif [ -f "win-cloud-init.ps1" ]; then
    cp "win-cloud-init.ps1" "$TEMP_DIR/iso_root/win-cloud-init.ps1"
else
    echo_err "Error: win-cloud-init.ps1 not found."
    echo_err "Please ensure win-cloud-init.ps1 is in the same directory as this script."
    exit 1
fi

# Create SetupComplete.cmd
echo_err "Creating SetupComplete.cmd..."
cat > "$TEMP_DIR/iso_root/SetupComplete.cmd" <<'SETUPCMD'
@echo off
echo Configuring network from cloud-init...
powershell.exe -ExecutionPolicy Bypass -File E:\win-cloud-init.ps1
echo Network configuration completed with exit code: %ERRORLEVEL%

echo Installing QEMU Guest Agent...
msiexec /i E:\guest-agent\qemu-ga-x86_64.msi /qn /norestart /log C:\Windows\Panther\qemu-ga-install.log
echo QEMU Guest Agent installation completed with exit code: %ERRORLEVEL%
SETUPCMD

# Generate Autounattend.xml
echo_err "Generating autounattend.xml..."
cat > "$TEMP_DIR/iso_root/autounattend.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <SetupUILanguage>
                <UILanguage>en-US</UILanguage>
            </SetupUILanguage>
            <InputLocale>en-US</InputLocale>
            <SystemLocale>en-US</SystemLocale>
            <UILanguage>en-US</UILanguage>
            <UserLocale>en-US</UserLocale>
        </component>
        <component name="Microsoft-Windows-PnpCustomizationsWinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <DriverPaths>
                <PathAndCredentials wcm:action="add" wcm:keyValue="1">
                    <Path>E:\drivers\vioscsi</Path>
                </PathAndCredentials>
                <PathAndCredentials wcm:action="add" wcm:keyValue="2">
                    <Path>E:\drivers\netkvm</Path>
                </PathAndCredentials>
                <PathAndCredentials wcm:action="add" wcm:keyValue="3">
                    <Path>E:\drivers\balloon</Path>
                </PathAndCredentials>
                <PathAndCredentials wcm:action="add" wcm:keyValue="4">
                    <Path>E:\drivers\vioserial</Path>
                </PathAndCredentials>
                <PathAndCredentials wcm:action="add" wcm:keyValue="5">
                    <Path>E:\drivers\viostor</Path>
                </PathAndCredentials>
                <PathAndCredentials wcm:action="add" wcm:keyValue="6">
                    <Path>E:\drivers\viogpudo</Path>
                </PathAndCredentials>
                <PathAndCredentials wcm:action="add" wcm:keyValue="7">
                    <Path>E:\drivers\vioinput</Path>
                </PathAndCredentials>
                <PathAndCredentials wcm:action="add" wcm:keyValue="8">
                    <Path>E:\drivers\viorng</Path>
                </PathAndCredentials>
                <PathAndCredentials wcm:action="add" wcm:keyValue="9">
                    <Path>E:\drivers\viofs</Path>
                </PathAndCredentials>
                <PathAndCredentials wcm:action="add" wcm:keyValue="10">
                    <Path>E:\drivers\pvpanic</Path>
                </PathAndCredentials>
                <PathAndCredentials wcm:action="add" wcm:keyValue="11">
                    <Path>E:\drivers\qemupciserial</Path>
                </PathAndCredentials>
                <PathAndCredentials wcm:action="add" wcm:keyValue="12">
                    <Path>E:\drivers\fwcfg</Path>
                </PathAndCredentials>
                <PathAndCredentials wcm:action="add" wcm:keyValue="13">
                    <Path>E:\drivers\viomem</Path>
                </PathAndCredentials>
                <PathAndCredentials wcm:action="add" wcm:keyValue="14">
                    <Path>E:\drivers\qxldod</Path>
                </PathAndCredentials>
            </DriverPaths>
        </component>
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <DiskConfiguration>
                <Disk wcm:action="add">
                    <CreatePartitions>
                        <CreatePartition wcm:action="add">
                            <Order>1</Order>
                            <Size>500</Size>
                            <Type>EFI</Type>
                        </CreatePartition>
                        <CreatePartition wcm:action="add">
                            <Order>2</Order>
                            <Size>128</Size>
                            <Type>MSR</Type>
                        </CreatePartition>
                        <CreatePartition wcm:action="add">
                            <Order>3</Order>
                            <Extend>true</Extend>
                            <Type>Primary</Type>
                        </CreatePartition>
                    </CreatePartitions>
                    <ModifyPartitions>
                        <ModifyPartition wcm:action="add">
                            <Order>1</Order>
                            <PartitionID>1</PartitionID>
                            <Format>FAT32</Format>
                            <Label>System</Label>
                        </ModifyPartition>
                        <ModifyPartition wcm:action="add">
                            <Order>2</Order>
                            <PartitionID>2</PartitionID>
                        </ModifyPartition>
                        <ModifyPartition wcm:action="add">
                            <Order>3</Order>
                            <PartitionID>3</PartitionID>
                            <Format>NTFS</Format>
                            <Label>Windows</Label>
                        </ModifyPartition>
                    </ModifyPartitions>
                    <DiskID>0</DiskID>
                    <WillWipeDisk>true</WillWipeDisk>
                </Disk>
            </DiskConfiguration>
            <ImageInstall>
                <OSImage>
                    <InstallFrom>
                        <MetaData wcm:action="add">
                            <Key>/IMAGE/INDEX</Key>
                            <Value>$VM_IMAGE_INDEX</Value>
                        </MetaData>
                    </InstallFrom>
                    <InstallTo>
                        <DiskID>0</DiskID>
                        <PartitionID>3</PartitionID>
                    </InstallTo>
                    <InstallToAvailablePartition>false</InstallToAvailablePartition>
                </OSImage>
            </ImageInstall>
            <UserData>
                <AcceptEula>true</AcceptEula>
            </UserData>
        </component>
    </settings>
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <ComputerName>$VM_NAME</ComputerName>
        </component>
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>pnputil.exe /add-driver E:\drivers\qxldod\qxl.inf /install</Path>
                    <Description>Install QXL Video Driver</Description>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <Path>cmd.exe /c if not exist C:\Windows\Setup\Scripts mkdir C:\Windows\Setup\Scripts</Path>
                    <Description>Create Scripts Directory</Description>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <Path>cmd.exe /c copy E:\SetupComplete.cmd C:\Windows\Setup\Scripts\SetupComplete.cmd</Path>
                    <Description>Copy SetupComplete Script</Description>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <UserAccounts>
                <AdministratorPassword>
                    <Value>$VM_CIPASSWORD</Value>
                    <PlainText>true</PlainText>
                </AdministratorPassword>
            </UserAccounts>
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <ProtectYourPC>3</ProtectYourPC>
                <SkipUserOOBE>true</SkipUserOOBE>
                <SkipMachineOOBE>true</SkipMachineOOBE>
            </OOBE>
        </component>
    </settings>
</unattend>
EOF

# Create unattended ISO
echo_err "Creating unattended ISO..."
UNATTENDED_ISO="/var/lib/vz/template/iso/unattended-${VM_ID}.iso"
genisoimage -J -r -V "Unattended" -input-charset utf-8 -o "$UNATTENDED_ISO" "$TEMP_DIR/iso_root" >/dev/null 2>&1

# Disables balloon driver due poor performance on Windows
#   Source: https://pve.proxmox.com/wiki/Performance_Tweaks#Do_not_use_the_Virtio_Balloon_Driver
VM_BALLOON=0

# Create VM
#   Disk 0: EFI
#   Disk 1: Main drive
#   IDE 0: Windows ISO
#   IDE 1: cloud-init
#   IDE 2: Unattended ISO
echo_err "Creating VM $VM_ID..."
qm create $VM_ID --name $VM_NAME \
    --cpu host \
    --ostype $VM_OSTYPE \
    --scsihw virtio-scsi-single \
    --agent 1 \
    --bios ovmf \
    --machine q35 \
    --net0 virtio,bridge=vmbr0 \
    --cores $VM_CORES \
    --numa 1 \
    --memory $VM_MEMORY \
    --balloon $VM_BALLOON \
    --vga type=virtio \
    --onboot 1 \
    --efidisk0 "$VM_STORAGE:1,efitype=4m,pre-enrolled-keys=1" \
    --scsi0 "$VM_STORAGE:$VM_DISKSIZE" \
    --ide0 "file=$VM_ISO,media=cdrom" \
    --ide1 "$VM_STORAGE:cloudinit" \
    --ide2 "file=$UNATTENDED_ISO,media=cdrom" \
    --boot "order=scsi0;ide0" \
    --citype configdrive2 \
    "$@" # pass remaining arguments -- https://stackoverflow.com/a/4824637/33244

# Start VM
if [ $VM_NO_START -eq 1 ]; then exit 0; fi;
echo_err "Starting VM $VM_ID..."
qm start $VM_ID

# Wait for qemu-guest-agent
if [ $VM_NO_GUEST -eq 1 ]; then exit 0; fi;
echo_err "Waiting for QEMU Guest Agent..."
until qm agent $VM_ID ping 2>/dev/null
do
    sleep 2
    echo_err -n "."
done
echo_err ""

# Cleanup installation media
echo_err "Cleaning up installation media..."
sleep 10
qm set $VM_ID --delete ide0 >/dev/null 2>&1 || true
qm set $VM_ID --delete ide1 >/dev/null 2>&1 || true
qm set $VM_ID --delete ide2 >/dev/null 2>&1 || true

echo_err "VM $VM_ID is ready."
