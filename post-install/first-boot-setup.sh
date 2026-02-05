#!/bin/bash
#
# first-boot-setup.sh - Run this after Proxmox VE installation
#
# This script:
# 1. Sets up network (converts DHCP to static if needed)
# 2. Tests connectivity
# 3. Installs Claude Code
# 4. Starts Claude in a tmux session for authentication
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[SETUP]${NC} $1"; }
warn() { echo -e "${YELLOW}[SETUP]${NC} $1"; }
error() { echo -e "${RED}[SETUP]${NC} $1"; }
step() { echo -e "\n${BLUE}━━━ $1 ━━━${NC}\n"; }

# Get network info
get_ip() { ip route get 1 2>/dev/null | awk '{print $7; exit}'; }
get_gateway() { ip route | grep default | awk '{print $3; exit}'; }
get_interface() { ip route get 1 2>/dev/null | awk '{print $5; exit}'; }

# Test network connectivity
test_network() {
    step "Testing Network Connectivity"

    local ip=$(get_ip)
    local gw=$(get_gateway)
    local iface=$(get_interface)

    log "Interface: $iface"
    log "IP Address: $ip"
    log "Gateway: $gw"

    echo ""

    # Test gateway
    if ping -c 1 -W 2 "$gw" &>/dev/null; then
        log "Gateway ping: ✓"
    else
        warn "Gateway ping: ✗"
    fi

    # Test internet
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        log "Internet (8.8.8.8): ✓"
    else
        warn "Internet (8.8.8.8): ✗"
    fi

    # Test DNS
    if ping -c 1 -W 2 google.com &>/dev/null; then
        log "DNS resolution: ✓"
    else
        warn "DNS resolution: ✗"
    fi

    # Test HTTPS
    if curl -s --connect-timeout 3 https://www.proxmox.com &>/dev/null; then
        log "HTTPS access: ✓"
    else
        warn "HTTPS access: ✗"
    fi

    echo ""
}

# Disable enterprise repo (if no subscription)
configure_repos() {
    step "Configuring Repositories"

    # Disable enterprise repo
    if [[ -f /etc/apt/sources.list.d/pve-enterprise.list ]]; then
        log "Disabling enterprise repository..."
        sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list
    fi

    # Add no-subscription repo
    if ! grep -q "pve-no-subscription" /etc/apt/sources.list.d/*.list 2>/dev/null; then
        log "Adding no-subscription repository..."
        echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list
    fi

    # Update package lists
    log "Updating package lists..."
    apt-get update -qq

    log "Repositories configured"
}

# Install dependencies
install_dependencies() {
    step "Installing Dependencies"

    log "Installing required packages..."
    apt-get install -y -qq \
        curl \
        wget \
        git \
        tmux \
        htop \
        vim

    log "Dependencies installed"
}

# Install Node.js
install_nodejs() {
    step "Installing Node.js"

    if command -v node &>/dev/null; then
        local version=$(node --version)
        log "Node.js already installed: $version"

        # Check version
        local major=$(echo "$version" | sed 's/v\([0-9]*\).*/\1/')
        if [[ $major -ge 18 ]]; then
            log "Version is compatible"
            return 0
        fi
        warn "Version too old, upgrading..."
    fi

    log "Installing Node.js 20.x LTS..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y -qq nodejs

    log "Node.js installed: $(node --version)"
}

# Install Claude Code
install_claude() {
    step "Installing Claude Code"

    if command -v claude &>/dev/null; then
        log "Claude Code already installed"
        return 0
    fi

    log "Installing Claude Code CLI..."
    npm install -g @anthropic-ai/claude-code

    if command -v claude &>/dev/null; then
        log "Claude Code installed successfully!"
    else
        error "Claude Code installation failed"
        return 1
    fi
}

# Start Claude session
start_claude_session() {
    step "Starting Claude Code Session"

    # Kill any existing claude tmux session
    tmux kill-session -t claude 2>/dev/null || true

    # Create new session
    log "Starting Claude in tmux session..."
    tmux new-session -d -s claude -n main

    # Send startup commands
    tmux send-keys -t claude "clear" Enter
    tmux send-keys -t claude "echo ''" Enter
    tmux send-keys -t claude "echo '  Welcome to Claude Code on Proxmox VE'" Enter
    tmux send-keys -t claude "echo '  ====================================='" Enter
    tmux send-keys -t claude "echo ''" Enter
    tmux send-keys -t claude "echo '  Claude will help you configure your server.'" Enter
    tmux send-keys -t claude "echo '  If not authenticated, run: claude auth login'" Enter
    tmux send-keys -t claude "echo ''" Enter
    tmux send-keys -t claude "claude" Enter

    log "Claude session started"
}

# Add helpful aliases
configure_shell() {
    step "Configuring Shell"

    if ! grep -q "# PVE Installer additions" /root/.bashrc; then
        cat >> /root/.bashrc << 'EOF'

# PVE Installer additions
alias c='claude'
alias tm='tmux attach -t claude || tmux new -s claude'
alias vmlist='qm list'
alias ctlist='pct list'
alias logs='journalctl -f'

# Show Claude session hint on login
if [ -n "$PS1" ]; then
    if tmux has-session -t claude 2>/dev/null; then
        echo ""
        echo "  Claude Code is running. Attach with: tm"
        echo ""
    fi
fi
EOF
        log "Shell aliases added"
    else
        log "Shell already configured"
    fi
}

# Show completion message
show_completion() {
    local ip=$(get_ip)

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  First Boot Setup Complete!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${CYAN}Proxmox Web UI:${NC}  https://${ip}:8006"
    echo -e "  ${CYAN}SSH:${NC}             ssh root@${ip}"
    echo ""
    echo -e "  ${CYAN}Claude Session:${NC}  tmux attach -t claude"
    echo -e "  ${CYAN}Quick attach:${NC}    tm"
    echo ""
    echo -e "  ${YELLOW}If Claude needs authentication:${NC}"
    echo -e "    1. Attach to session: ${CYAN}tm${NC}"
    echo -e "    2. Run: ${CYAN}claude auth login${NC}"
    echo ""
    echo -e "  ${YELLOW}Example Claude commands:${NC}"
    echo "    'Set static IP 192.168.1.100/24 gateway 192.168.1.1'"
    echo "    'Create a VM with Ubuntu 24.04, 4 cores, 8GB RAM'"
    echo "    'Set up a backup schedule for all VMs'"
    echo ""
}

# Main
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Proxmox VE - First Boot Setup${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Check root
    if [[ $EUID -ne 0 ]]; then
        error "Please run as root"
        exit 1
    fi

    # Run setup steps
    test_network
    configure_repos
    install_dependencies
    install_nodejs
    install_claude
    configure_shell
    start_claude_session
    show_completion

    echo ""
    log "Attaching to Claude session in 3 seconds..."
    log "Press Ctrl+C to skip, or Ctrl+B then D to detach later"
    sleep 3

    tmux attach -t claude
}

main "$@"
