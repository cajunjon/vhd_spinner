#!/bin/bash
# provision_vm.sh - Multi-OS VM provisioning script with dynamic profile loading, CRC check, libvirt preflight, dry-run mode, and smart boot mode
# Author: CajunJon
# Version: 0.1.0
# Last Modified: 2025-09-13

LOG_FILE="provision_vm.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

fail() {
    log "ERROR: $1"
    exit 1
}

DRY_RUN=false
if [[ "$1" == "--dry-run" ]]; then
    DRY_RUN=true
    shift
fi

TARGET_ISO_DIR="$HOME/vhd_spinner/isos"
CONFIG_DIR="$HOME/vhd_spinner/configs"
VMS_DIR="$HOME/vhd_spinner/vms"
VIRTIO_ISO="$TARGET_ISO_DIR/virtio-win.iso"
CHECKSUM_FILE="$TARGET_ISO_DIR/.iso_crc32"
touch "$CHECKSUM_FILE"

check_and_install() {
    local cmd=$1
    local pkg=$2
    if ! command -v "$cmd" &> /dev/null; then
        if $DRY_RUN; then
            log "[DRY-RUN] Would install missing dependency: $pkg"
        else
            log "Installing missing dependency: $pkg..."
            sudo apt-get update && sudo apt-get install -y "$pkg" || fail "Failed to install $pkg"
        fi
    else
        log "Dependency '$cmd' is already installed."
    fi
}

check_and_install crc32 libarchive-tools
check_and_install qemu-img qemu-utils
check_and_install cloud-localds cloud-image-utils
check_and_install virt-install virtinst
check_and_install virsh libvirt-clients

# === CRC Check for ISOs in ISO Folder ===
log "Verifying ISOs in $TARGET_ISO_DIR..."
shopt -s nullglob
for iso_path in "$TARGET_ISO_DIR"/*.iso; do
    filename=$(basename "$iso_path")
    new_crc=$(crc32 "$iso_path")
    existing_crc=$(grep "^$filename|" "$CHECKSUM_FILE" | cut -d'|' -f2)

    if [[ "$new_crc" == "$existing_crc" ]]; then
        log "ISO '$filename' already verified with CRC32: $new_crc"
    else
        if $DRY_RUN; then
            log "[DRY-RUN] Would update CRC32 for: $filename"
        else
            sed -i "/^$filename|/d" "$CHECKSUM_FILE"
            echo "$filename|$new_crc" >> "$CHECKSUM_FILE"
            log "Updated CRC32 for '$filename': $new_crc"
        fi
    fi
done
shopt -u nullglob

declare -A VM_PROFILES

load_profiles() {
    shopt -s nullglob
    for iso_path in "$TARGET_ISO_DIR"/*.iso; do
        iso_file=$(basename "$iso_path")
        key="${iso_file%%.iso}"
        os_variant=""
        mem="2048"
        vcpus="2"
        format="vpc"

        if [[ "$iso_file" =~ ubuntu ]]; then
            os_variant="ubuntu$(echo "$iso_file" | grep -oP '\d{2}\.\d{2}' | head -1)"
            mem="3072"
        elif [[ "$iso_file" =~ debian ]]; then
            os_variant="debian$(echo "$iso_file" | grep -oP '\d+' | head -1)"
            mem="1024"
        elif [[ "$iso_file" =~ centos ]]; then
            os_variant="centos-stream8"
        elif [[ "$iso_file" =~ win ]]; then
            os_variant="win10"
            mem="4096"
        elif [[ "$iso_file" =~ Server2022 ]]; then
            os_variant="win2k22"
            mem="4096"
            vcpus="4"
        else
            os_variant="generic"
        fi

        VM_PROFILES["$key"]="$iso_file|$os_variant|$format|$mem|$vcpus"
    done
    shopt -u nullglob
}

load_profiles

AVAILABLE_PROFILES=()
for key in "${!VM_PROFILES[@]}"; do
    IFS='|' read -r iso _ <<< "${VM_PROFILES[$key]}"
    [[ -f "$TARGET_ISO_DIR/$iso" ]] && AVAILABLE_PROFILES+=("$key")
done

if [[ "$1" == "--help" || -z "$1" ]]; then
    echo "Usage: $0 [--dry-run] <vm-name>"
    echo ""
    echo "Provision a VM using available profiles."
    echo ""
    echo "Available VM profiles (ISO found):"
    for profile in "${AVAILABLE_PROFILES[@]}"; do
        echo "  - $profile"
    done
    echo ""
    echo "Options:"
    echo "  --dry-run         Simulate provisioning without making changes"
    echo "  --list            Show available profiles"
    echo "  --help            Show this help message"
    exit 0
fi

if [[ "$1" == "--list" ]]; then
    echo "Available VM profiles (ISO found):"
    for profile in "${AVAILABLE_PROFILES[@]}"; do
        echo "  - $profile"
    done
    exit 0
fi

VM_NAME="$1"
PROFILE="${VM_PROFILES[$VM_NAME]}"
if [[ ! " ${AVAILABLE_PROFILES[*]} " =~ " $VM_NAME " ]]; then
    fail "Profile '$VM_NAME' is not available or ISO is missing."
fi

IFS='|' read -r ISO_FILE OS_VARIANT VHD_FORMAT MEMORY_MB VCPUS <<< "$PROFILE"
ISO_PATH="$TARGET_ISO_DIR/$ISO_FILE"
VHD_PATH="$VMS_DIR/${VM_NAME}.vhd"
CONFIG_ISO="$CONFIG_DIR/${VM_NAME}-config.iso"

validate_iso() {
    local iso_path=$1
    [[ -f "$iso_path" ]] || fail "ISO not found: $iso_path"
    file "$iso_path" | grep -q "ISO 9660" || fail "Invalid ISO format: $iso_path"
    log "ISO '$iso_path' validated successfully."
}

check_libvirt() {
    if ! command -v libvirtd &> /dev/null; then
        fail "libvirtd is not installed. Please install libvirt-daemon-system and start the service."
    fi

    if ! systemctl is-active --quiet libvirtd; then
        fail "libvirtd is installed but not running. Try: sudo systemctl start libvirtd"
    fi

    if ! virsh list &> /dev/null; then
        fail "Cannot connect to libvirt. You may need to add your user to the 'libvirt' group and re-login."
    fi

    log "libvirtd is installed, running, and accessible."
}

log "Starting provisioning for VM: $VM_NAME"

validate_iso "$ISO_PATH"

mkdir -p "$(dirname "$VHD_PATH")"
if $DRY_RUN; then
    log "[DRY-RUN] Would create VHD at $VHD_PATH"
else
    log "Creating VHD at $VHD_PATH..."
    qemu-img create -f "$VHD_FORMAT" "$VHD_PATH" 20G || fail "Failed to create VHD"
fi

if $DRY_RUN; then
    log "[DRY-RUN] Would check libvirtd status and connectivity"
else
    check_libvirt
fi

if [[ "$OS_VARIANT" == win* ]]; then
    DRIVER_DISK=""
    [[ -f "$VIRTIO_ISO" ]] && DRIVER_DISK="--disk path=$VIRTIO_ISO,device=cdrom"
    CONFIG_DISK=""
else
    [[ -f "$CONFIG_DIR/user-data" ]] || fail "Missing user-data file"
    [[ -f "$CONFIG_DIR/meta-data" ]] || fail "Missing meta-data file"
    if $DRY_RUN; then
        log "[DRY-RUN] Would generate autoinstall config ISO at $CONFIG_ISO"
    else
        cloud-localds "$CONFIG_ISO" "$CONFIG_DIR/user-data" "$CONFIG_DIR/meta-data" || fail "Failed to generate config ISO"
    fi
    CONFIG_DISK="--disk path=$CONFIG_ISO,device=cdrom"
    DRIVER_DISK=""
fi

# === Smart Boot Mode Detection ===
BOOT_MODE=""
if file "$ISO_PATH" | grep -qi "bootable"; then
    BOOT_MODE="--cdrom \"$ISO_PATH\""
else
    BOOT_MODE="--location \"$ISO_PATH\""
fi

if $DRY_RUN; then
    log "[DRY-RUN] Would launch VM '$VM_NAME' using $BOOT_MODE"
else
    eval virt-install \
      --name "$VM_NAME" \
      --memory "$MEMORY_MB" \
      --vcpus "$VCPUS" \
      --disk path="$VHD_PATH",format="$VHD_FORMAT" \
      $CONFIG_DISK \
      $DRIVER_DISK \
      --os-variant "$OS_VARIANT" \
      --graphics spice \
      --console pty,target_type=serial \
      $BOOT_MODE \
      --extra-args "$( [[ "$OS_VARIANT" == win* ]] && echo "autounattend.xml" || echo "console=ttyS0" )" || fail "VM creation failed"
    log "VM '$VM_NAME' created and booting."
fi


