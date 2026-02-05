#!/bin/bash
#
# build-usb.sh - Build a bootable Debian Live USB with Claude Code for Proxmox installation
#
# This script creates a customized Debian Live image that includes:
# - Minimal Debian Bookworm base
# - Node.js and Claude Code CLI
# - Proxmox installation scripts
# - Network auto-configuration
#
# Requirements:
# - Debian/Ubuntu build system
# - live-build package
# - Root/sudo access
# - Internet connection

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$SCRIPT_DIR/live-build"
OUTPUT_DIR="$SCRIPT_DIR/output"

# Configuration
DEBIAN_RELEASE="bookworm"
IMAGE_NAME="pve-installer"
ARCH="amd64"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_requirements() {
    log_info "Checking build requirements..."

    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi

    local missing_deps=()

    for cmd in lb debootstrap; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        log_info "Install with: apt install live-build debootstrap"
        exit 1
    fi

    log_info "All requirements satisfied"
}

setup_build_dir() {
    log_info "Setting up build directory..."

    # Clean previous build
    if [[ -d "$BUILD_DIR" ]]; then
        log_warn "Removing previous build directory"
        rm -rf "$BUILD_DIR"
    fi

    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    # Initialize live-build configuration
    lb config \
        --distribution "$DEBIAN_RELEASE" \
        --archive-areas "main contrib non-free non-free-firmware" \
        --architectures "$ARCH" \
        --binary-images iso-hybrid \
        --bootappend-live "boot=live components quiet splash" \
        --debian-installer false \
        --memtest none \
        --iso-application "$IMAGE_NAME" \
        --iso-volume "$IMAGE_NAME"

    log_info "Live-build configured"
}

configure_packages() {
    log_info "Configuring package lists..."

    mkdir -p "$BUILD_DIR/config/package-lists"

    # Base system packages
    cat > "$BUILD_DIR/config/package-lists/base.list.chroot" << 'EOF'
# Base system
linux-image-amd64
live-boot
systemd-sysv

# Network
ifupdown
isc-dhcp-client
net-tools
iproute2
iputils-ping
dnsutils
curl
wget
openssh-client
openssh-server

# Storage & filesystem
parted
gdisk
dosfstools
e2fsprogs
zfsutils-linux
zfs-dkms

# Utilities
vim
nano
less
htop
tmux
git
ca-certificates
gnupg

# Build essentials (for ZFS DKMS)
build-essential
dkms

# Node.js will be installed via hook (for latest version)
EOF

    log_info "Package lists configured"
}

configure_hooks() {
    log_info "Configuring build hooks..."

    mkdir -p "$BUILD_DIR/config/hooks/live"

    # Hook to install Node.js and Claude Code
    cat > "$BUILD_DIR/config/hooks/live/0100-install-nodejs-claude.hook.chroot" << 'EOF'
#!/bin/bash
# Install Node.js LTS and Claude Code

set -e

echo "Installing Node.js LTS..."

# Install Node.js 20.x LTS
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

# Verify installation
node --version
npm --version

echo "Installing Claude Code CLI..."
npm install -g @anthropic-ai/claude-code

# Create convenience alias
echo 'alias claude="claude"' >> /etc/skel/.bashrc

echo "Node.js and Claude Code installed successfully"
EOF
    chmod +x "$BUILD_DIR/config/hooks/live/0100-install-nodejs-claude.hook.chroot"

    # Hook to configure auto-login and startup
    cat > "$BUILD_DIR/config/hooks/live/0200-configure-autologin.hook.chroot" << 'EOF'
#!/bin/bash
# Configure auto-login to root and display welcome message

set -e

# Create welcome message and instructions
cat > /etc/motd << 'MOTD'
===============================================================================
                     PVE INSTALLER - Claude Code Edition
===============================================================================

Welcome! This system is ready to install Proxmox VE.

QUICK START:
  1. Network should auto-configure via DHCP
  2. Run 'claude' to start Claude Code CLI
  3. Ask Claude to install Proxmox

MANUAL INSTALLATION:
  Run: /root/installer/install-proxmox.sh

NETWORK STATUS:
  Run: ip addr

===============================================================================
MOTD

# Configure auto-login on tty1
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf << 'AUTOLOGIN'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
AUTOLOGIN

echo "Auto-login configured"
EOF
    chmod +x "$BUILD_DIR/config/hooks/live/0200-configure-autologin.hook.chroot"

    # Hook to enable SSH
    cat > "$BUILD_DIR/config/hooks/live/0300-enable-ssh.hook.chroot" << 'EOF'
#!/bin/bash
# Enable SSH for remote access during installation

set -e

# Enable SSH service
systemctl enable ssh

# Allow root login with password (for initial setup only)
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config

# Set a default root password (user should change this)
echo "root:installer" | chpasswd

echo "SSH enabled (root password: installer)"
EOF
    chmod +x "$BUILD_DIR/config/hooks/live/0300-enable-ssh.hook.chroot"

    log_info "Build hooks configured"
}

copy_installer_scripts() {
    log_info "Copying installer scripts..."

    mkdir -p "$BUILD_DIR/config/includes.chroot/root/installer"
    mkdir -p "$BUILD_DIR/config/includes.chroot/root/post-install"
    mkdir -p "$BUILD_DIR/config/includes.chroot/root/config"

    # Copy installer scripts
    cp -r "$PROJECT_ROOT/installer/"* "$BUILD_DIR/config/includes.chroot/root/installer/" 2>/dev/null || true
    cp -r "$PROJECT_ROOT/post-install/"* "$BUILD_DIR/config/includes.chroot/root/post-install/" 2>/dev/null || true
    cp -r "$PROJECT_ROOT/config/"* "$BUILD_DIR/config/includes.chroot/root/config/" 2>/dev/null || true

    # Make scripts executable
    find "$BUILD_DIR/config/includes.chroot/root" -name "*.sh" -exec chmod +x {} \;

    log_info "Installer scripts copied"
}

build_image() {
    log_info "Building live image (this may take a while)..."

    cd "$BUILD_DIR"

    # Build the image
    lb build 2>&1 | tee build.log

    # Move output
    mkdir -p "$OUTPUT_DIR"
    mv "$BUILD_DIR/live-image-amd64.hybrid.iso" "$OUTPUT_DIR/$IMAGE_NAME.iso"

    log_info "Build complete!"
    log_info "ISO image: $OUTPUT_DIR/$IMAGE_NAME.iso"
}

show_usage() {
    log_info ""
    log_info "To write to USB drive:"
    log_info "  sudo dd if=$OUTPUT_DIR/$IMAGE_NAME.iso of=/dev/sdX bs=4M status=progress"
    log_info ""
    log_info "Replace /dev/sdX with your USB device (check with 'lsblk')"
    log_info ""
    log_warn "WARNING: This will erase all data on the USB drive!"
}

main() {
    log_info "=========================================="
    log_info "  PVE Installer USB Builder"
    log_info "=========================================="

    check_requirements
    setup_build_dir
    configure_packages
    configure_hooks
    copy_installer_scripts
    build_image
    show_usage

    log_info "Done!"
}

main "$@"
