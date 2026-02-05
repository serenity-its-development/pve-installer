#!/bin/bash
#
# configure-zfs.sh - Configure ZFS storage pool for Proxmox VE
#
# This script creates a ZFS pool for VM/container storage.
# It can be sourced by install-proxmox.sh or run standalone.
#
# Usage:
#   Standalone: ./configure-zfs.sh --disks sda,sdb --type mirror
#   Sourced:    source configure-zfs.sh && setup_zfs_pool "sda,sdb" "mirror"

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[ZFS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[ZFS]${NC} $1"; }
log_error() { echo -e "${RED}[ZFS]${NC} $1"; }

# Pool configuration
POOL_NAME="rpool"
MOUNT_POINT="/rpool"

validate_disks() {
    local disks="$1"
    local disk_count=0

    IFS=',' read -ra DISK_ARRAY <<< "$disks"

    for disk in "${DISK_ARRAY[@]}"; do
        local disk_path="/dev/$disk"

        if [[ ! -b "$disk_path" ]]; then
            log_error "Disk not found: $disk_path"
            return 1
        fi

        # Check if disk is in use
        if mount | grep -q "^$disk_path"; then
            log_error "Disk is mounted: $disk_path"
            return 1
        fi

        ((disk_count++))
    done

    log_info "Found $disk_count valid disk(s)"
    return 0
}

get_disk_paths() {
    local disks="$1"
    local paths=""

    IFS=',' read -ra DISK_ARRAY <<< "$disks"

    for disk in "${DISK_ARRAY[@]}"; do
        paths="$paths /dev/$disk"
    done

    echo "$paths"
}

wipe_disks() {
    local disks="$1"

    log_info "Wiping disk partition tables..."

    IFS=',' read -ra DISK_ARRAY <<< "$disks"

    for disk in "${DISK_ARRAY[@]}"; do
        local disk_path="/dev/$disk"
        log_info "Wiping $disk_path..."

        # Clear partition table
        wipefs -a "$disk_path" 2>/dev/null || true
        sgdisk --zap-all "$disk_path" 2>/dev/null || true

        # Clear any existing ZFS labels
        zpool labelclear -f "$disk_path" 2>/dev/null || true
    done

    # Wait for udev to settle
    sleep 2
    udevadm settle

    log_info "Disks wiped"
}

setup_zfs_pool() {
    local disks="${1:-}"
    local pool_type="${2:-single}"

    if [[ -z "$disks" ]]; then
        log_error "No disks specified"
        return 1
    fi

    log_info "Setting up ZFS pool: $POOL_NAME"
    log_info "Disks: $disks"
    log_info "Type: $pool_type"

    # Validate disks
    if ! validate_disks "$disks"; then
        return 1
    fi

    # Count disks
    IFS=',' read -ra DISK_ARRAY <<< "$disks"
    local disk_count=${#DISK_ARRAY[@]}

    # Validate pool type vs disk count
    case $pool_type in
        single)
            if [[ $disk_count -ne 1 ]]; then
                log_warn "Single mode but $disk_count disks provided, using first disk only"
            fi
            ;;
        mirror)
            if [[ $disk_count -lt 2 ]]; then
                log_error "Mirror requires at least 2 disks"
                return 1
            fi
            ;;
        raidz1)
            if [[ $disk_count -lt 3 ]]; then
                log_error "RAIDZ1 requires at least 3 disks"
                return 1
            fi
            ;;
        raidz2)
            if [[ $disk_count -lt 4 ]]; then
                log_error "RAIDZ2 requires at least 4 disks"
                return 1
            fi
            ;;
        *)
            log_error "Unknown pool type: $pool_type"
            return 1
            ;;
    esac

    # Confirm with user
    echo ""
    log_warn "WARNING: This will DESTROY all data on the following disks:"
    for disk in "${DISK_ARRAY[@]}"; do
        echo "  - /dev/$disk"
    done
    echo ""
    read -p "Continue? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        log_info "Aborted by user"
        return 1
    fi

    # Wipe disks
    wipe_disks "$disks"

    # Get disk paths
    local disk_paths=$(get_disk_paths "$disks")

    # Create the pool
    log_info "Creating ZFS pool..."

    local zpool_args=""
    case $pool_type in
        single)
            # Just use the first disk
            disk_paths="/dev/${DISK_ARRAY[0]}"
            ;;
        mirror)
            zpool_args="mirror"
            ;;
        raidz1)
            zpool_args="raidz1"
            ;;
        raidz2)
            zpool_args="raidz2"
            ;;
    esac

    # Create pool with optimal settings for Proxmox
    zpool create -f \
        -o ashift=12 \
        -O acltype=posixacl \
        -O compression=lz4 \
        -O dnodesize=auto \
        -O normalization=formD \
        -O relatime=on \
        -O xattr=sa \
        -O mountpoint=$MOUNT_POINT \
        $POOL_NAME $zpool_args $disk_paths

    log_info "ZFS pool created successfully"

    # Create datasets for Proxmox
    create_proxmox_datasets

    # Add storage to Proxmox
    add_to_proxmox_storage

    # Show pool status
    echo ""
    log_info "Pool status:"
    zpool status $POOL_NAME
    echo ""
    zfs list
}

create_proxmox_datasets() {
    log_info "Creating Proxmox datasets..."

    # Dataset for VM disk images
    zfs create -o mountpoint=/rpool/data $POOL_NAME/data

    # Dataset for container templates
    zfs create -o mountpoint=/rpool/template $POOL_NAME/template

    # Dataset for ISO images
    zfs create -o mountpoint=/rpool/iso $POOL_NAME/iso

    # Dataset for backups
    zfs create -o mountpoint=/rpool/backup $POOL_NAME/backup

    log_info "Datasets created"
}

add_to_proxmox_storage() {
    log_info "Adding storage to Proxmox..."

    # Check if pvesm command exists (Proxmox is installed)
    if ! command -v pvesm &> /dev/null; then
        log_warn "Proxmox not installed yet, skipping storage configuration"
        log_info "Run this after Proxmox installation to add storage:"
        echo "  pvesm add zfspool local-zfs -pool $POOL_NAME/data"
        return
    fi

    # Add ZFS pool as storage
    pvesm add zfspool local-zfs -pool $POOL_NAME/data -content images,rootdir

    # Add directory storage for ISOs, templates, backups
    pvesm add dir local-iso -path /rpool/iso -content iso
    pvesm add dir local-template -path /rpool/template -content vztmpl
    pvesm add dir local-backup -path /rpool/backup -content backup

    log_info "Storage added to Proxmox"
}

# Standalone mode
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    DISKS=""
    TYPE="single"

    while [[ $# -gt 0 ]]; do
        case $1 in
            --disks)
                DISKS="$2"
                shift 2
                ;;
            --type)
                TYPE="$2"
                shift 2
                ;;
            -h|--help)
                echo "Usage: $0 --disks sda,sdb --type mirror"
                echo ""
                echo "Options:"
                echo "  --disks DISKS   Comma-separated list of disks"
                echo "  --type TYPE     Pool type: single, mirror, raidz1, raidz2"
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    if [[ -z "$DISKS" ]]; then
        echo "Error: --disks is required"
        exit 1
    fi

    setup_zfs_pool "$DISKS" "$TYPE"
fi
