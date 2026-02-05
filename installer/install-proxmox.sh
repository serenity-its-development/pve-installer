#!/bin/bash
#
# install-proxmox.sh - Install Proxmox VE on Debian
#
# This script performs a complete Proxmox VE installation:
# 1. Configures hostname and hosts
# 2. Adds Proxmox repositories
# 3. Installs Proxmox VE packages
# 4. Configures ZFS storage (optional)
# 5. Sets up networking
#
# Usage: ./install-proxmox.sh [options]
#
# Options:
#   --hostname NAME      Set the hostname (default: pve)
#   --domain DOMAIN      Set the domain (default: local)
#   --zfs-disks DISKS    Comma-separated list of disks for ZFS (e.g., sda,sdb)
#   --zfs-type TYPE      ZFS pool type: single, mirror, raidz1, raidz2 (default: single)
#   --skip-zfs           Skip ZFS configuration
#   --skip-reboot        Don't reboot after installation

set -euo pipefail

# Default configuration
HOSTNAME="pve"
DOMAIN="local"
ZFS_DISKS=""
ZFS_TYPE="single"
SKIP_ZFS=false
SKIP_REBOOT=false
PROXMOX_RELEASE="bookworm"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --hostname)
                HOSTNAME="$2"
                shift 2
                ;;
            --domain)
                DOMAIN="$2"
                shift 2
                ;;
            --zfs-disks)
                ZFS_DISKS="$2"
                shift 2
                ;;
            --zfs-type)
                ZFS_TYPE="$2"
                shift 2
                ;;
            --skip-zfs)
                SKIP_ZFS=true
                shift
                ;;
            --skip-reboot)
                SKIP_REBOOT=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

show_help() {
    cat << 'EOF'
Proxmox VE Installer

Usage: ./install-proxmox.sh [options]

Options:
  --hostname NAME      Set the hostname (default: pve)
  --domain DOMAIN      Set the domain (default: local)
  --zfs-disks DISKS    Comma-separated list of disks for ZFS (e.g., sda,sdb)
  --zfs-type TYPE      ZFS pool type: single, mirror, raidz1, raidz2
  --skip-zfs           Skip ZFS configuration
  --skip-reboot        Don't reboot after installation
  -h, --help           Show this help message

Examples:
  # Basic installation
  ./install-proxmox.sh --hostname myserver

  # With ZFS mirror on two disks
  ./install-proxmox.sh --hostname pve1 --zfs-disks sda,sdb --zfs-type mirror

  # With RAIDZ1 on three disks
  ./install-proxmox.sh --zfs-disks sda,sdb,sdc --zfs-type raidz1
EOF
}

check_requirements() {
    log_step "Checking requirements..."

    # Must be root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi

    # Check if running on Debian
    if [[ ! -f /etc/debian_version ]]; then
        log_error "This script requires Debian"
        exit 1
    fi

    # Check network connectivity
    if ! ping -c 1 google.com &> /dev/null; then
        log_error "No network connectivity. Please configure network first."
        exit 1
    fi

    # Check if this is a live system or installed system
    if mountpoint -q /run/live/medium 2>/dev/null; then
        log_info "Running from live system - will install to disk"
        INSTALL_MODE="live"
    else
        log_info "Running on installed system - will add Proxmox packages"
        INSTALL_MODE="installed"
    fi

    log_info "Requirements check passed"
}

get_primary_ip() {
    # Get the primary IP address
    ip route get 1 | awk '{print $7; exit}'
}

get_primary_interface() {
    # Get the primary network interface
    ip route get 1 | awk '{print $5; exit}'
}

configure_hostname() {
    log_step "Configuring hostname..."

    local fqdn="${HOSTNAME}.${DOMAIN}"
    local ip=$(get_primary_ip)

    # Set hostname
    hostnamectl set-hostname "$HOSTNAME" 2>/dev/null || echo "$HOSTNAME" > /etc/hostname

    # Configure /etc/hosts
    cat > /etc/hosts << EOF
127.0.0.1       localhost
${ip}           ${fqdn} ${HOSTNAME}

# IPv6
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

    log_info "Hostname set to: $fqdn ($ip)"
}

add_proxmox_repo() {
    log_step "Adding Proxmox VE repository..."

    # Add Proxmox GPG key
    log_info "Downloading Proxmox GPG key..."
    curl -fsSL https://enterprise.proxmox.com/debian/proxmox-release-${PROXMOX_RELEASE}.gpg \
        -o /etc/apt/trusted.gpg.d/proxmox-release-${PROXMOX_RELEASE}.gpg

    # Add Proxmox repository (no-subscription for free use)
    cat > /etc/apt/sources.list.d/pve-no-subscription.list << EOF
# Proxmox VE No-Subscription Repository
deb http://download.proxmox.com/debian/pve ${PROXMOX_RELEASE} pve-no-subscription
EOF

    # Disable enterprise repository if it exists
    if [[ -f /etc/apt/sources.list.d/pve-enterprise.list ]]; then
        mv /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/pve-enterprise.list.disabled
    fi

    log_info "Proxmox repository added"
}

update_system() {
    log_step "Updating system packages..."

    apt-get update
    apt-get full-upgrade -y

    log_info "System updated"
}

install_proxmox_packages() {
    log_step "Installing Proxmox VE packages..."

    # Set non-interactive frontend
    export DEBIAN_FRONTEND=noninteractive

    # Install Proxmox VE
    apt-get install -y \
        proxmox-ve \
        postfix \
        open-iscsi \
        chrony

    # Configure postfix for local only
    postconf -e "inet_interfaces = loopback-only"
    systemctl restart postfix

    log_info "Proxmox VE packages installed"
}

remove_debian_kernel() {
    log_step "Removing Debian default kernel..."

    # Remove the default Debian kernel (Proxmox uses its own)
    apt-get remove -y linux-image-amd64 'linux-image-6.1*' || true
    update-grub

    log_info "Debian kernel removed, using Proxmox kernel"
}

configure_zfs_storage() {
    if [[ "$SKIP_ZFS" == "true" ]] || [[ -z "$ZFS_DISKS" ]]; then
        log_info "Skipping ZFS configuration"
        return
    fi

    log_step "Configuring ZFS storage..."

    # Source the ZFS configuration script
    local script_dir="$(dirname "${BASH_SOURCE[0]}")"
    if [[ -f "$script_dir/configure-zfs.sh" ]]; then
        source "$script_dir/configure-zfs.sh"
        setup_zfs_pool "$ZFS_DISKS" "$ZFS_TYPE"
    else
        log_warn "ZFS configuration script not found, skipping"
    fi
}

configure_network_static() {
    log_step "Configuring network for Proxmox..."

    local iface=$(get_primary_interface)
    local ip=$(get_primary_ip)
    local gateway=$(ip route | grep default | awk '{print $3}')
    local netmask=$(ip -o -f inet addr show "$iface" | awk '{print $4}' | cut -d'/' -f2)

    # Create Proxmox-style network configuration
    cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

auto ${iface}
iface ${iface} inet static
    address ${ip}/${netmask}
    gateway ${gateway}

# For VM bridge (optional, uncomment to use)
#auto vmbr0
#iface vmbr0 inet static
#    address ${ip}/${netmask}
#    gateway ${gateway}
#    bridge-ports ${iface}
#    bridge-stp off
#    bridge-fd 0
EOF

    log_info "Network configured for static IP: ${ip}/${netmask}"
}

setup_post_install() {
    log_step "Setting up post-installation scripts..."

    # Copy post-install scripts to final system
    local script_dir="$(dirname "${BASH_SOURCE[0]}")"
    local post_install_dir="$script_dir/../post-install"

    if [[ -d "$post_install_dir" ]]; then
        mkdir -p /root/post-install
        cp -r "$post_install_dir/"* /root/post-install/ 2>/dev/null || true
        chmod +x /root/post-install/*.sh 2>/dev/null || true
    fi

    # Copy Claude setup script
    if [[ -f "$post_install_dir/setup-claude.sh" ]]; then
        cp "$post_install_dir/setup-claude.sh" /root/setup-claude.sh
        chmod +x /root/setup-claude.sh
        log_info "Claude Code setup script available at /root/setup-claude.sh"
    fi

    log_info "Post-installation scripts ready"
}

show_completion_message() {
    local ip=$(get_primary_ip)

    echo ""
    echo -e "${GREEN}=========================================="
    echo -e "  Proxmox VE Installation Complete!"
    echo -e "==========================================${NC}"
    echo ""
    echo -e "Web Interface: ${BLUE}https://${ip}:8006${NC}"
    echo -e "Username: ${BLUE}root${NC}"
    echo -e "Password: ${BLUE}(your root password)${NC}"
    echo ""
    echo "Post-installation:"
    echo "  - Run /root/setup-claude.sh to install Claude Code"
    echo "  - Run /root/post-install/configure-static-ip.sh for static IP"
    echo ""
    if [[ "$SKIP_REBOOT" == "false" ]]; then
        echo -e "${YELLOW}System will reboot in 10 seconds...${NC}"
        echo "Press Ctrl+C to cancel"
    fi
    echo ""
}

main() {
    parse_args "$@"

    echo ""
    echo -e "${BLUE}=========================================="
    echo -e "  Proxmox VE Installer"
    echo -e "==========================================${NC}"
    echo ""

    check_requirements
    configure_hostname
    add_proxmox_repo
    update_system
    install_proxmox_packages
    remove_debian_kernel
    configure_zfs_storage
    configure_network_static
    setup_post_install

    show_completion_message

    if [[ "$SKIP_REBOOT" == "false" ]]; then
        sleep 10
        reboot
    fi
}

main "$@"
