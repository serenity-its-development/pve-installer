#!/bin/bash
#
# first-boot-setup.sh - Automatic first boot setup for Proxmox VE
#
# This script runs automatically on first boot (via systemd) or manually.
# It sets up Claude Code for AI-assisted server management.
#
# Usage:
#   ./first-boot-setup.sh          # Interactive mode
#   ./first-boot-setup.sh --auto   # Automatic mode (no prompts)
#

set -euo pipefail

# Configuration
AUTO_MODE=false
MAX_NETWORK_WAIT=60
LOG_FILE="/var/log/pve-claude-setup.log"

# Parse arguments
for arg in "$@"; do
    case $arg in
        --auto|-a)
            AUTO_MODE=true
            ;;
    esac
done

# Colors (disabled in auto mode for clean logs)
if [[ "$AUTO_MODE" == "true" ]]; then
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' NC=''
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m'
fi

log() {
    local msg="[$(date '+%H:%M:%S')] $1"
    echo -e "${GREEN}[SETUP]${NC} $1"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

warn() {
    local msg="[$(date '+%H:%M:%S')] WARNING: $1"
    echo -e "${YELLOW}[SETUP]${NC} $1"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

error() {
    local msg="[$(date '+%H:%M:%S')] ERROR: $1"
    echo -e "${RED}[SETUP]${NC} $1"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

step() {
    echo -e "\n${BLUE}━━━ $1 ━━━${NC}\n"
    echo "" >> "$LOG_FILE" 2>/dev/null || true
    echo "=== $1 ===" >> "$LOG_FILE" 2>/dev/null || true
}

# Get network info
get_ip() { ip route get 1 2>/dev/null | awk '{print $7; exit}'; }
get_gateway() { ip route | grep default | awk '{print $3; exit}'; }
get_interface() { ip route get 1 2>/dev/null | awk '{print $5; exit}'; }

# Wait for network to be ready
wait_for_network() {
    step "Waiting for Network"

    local waited=0
    while [[ $waited -lt $MAX_NETWORK_WAIT ]]; do
        if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
            log "Network is ready"
            return 0
        fi
        log "Waiting for network... ($waited/$MAX_NETWORK_WAIT seconds)"
        sleep 5
        ((waited+=5))
    done

    warn "Network wait timeout, continuing anyway..."
    return 1
}

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

    local tests_passed=0

    # Test gateway
    if ping -c 1 -W 2 "$gw" &>/dev/null; then
        log "Gateway ping: ✓"
        ((tests_passed++))
    else
        warn "Gateway ping: ✗"
    fi

    # Test internet
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        log "Internet (8.8.8.8): ✓"
        ((tests_passed++))
    else
        warn "Internet (8.8.8.8): ✗"
    fi

    # Test DNS
    if ping -c 1 -W 2 google.com &>/dev/null; then
        log "DNS resolution: ✓"
        ((tests_passed++))
    else
        warn "DNS resolution: ✗"
    fi

    # Test HTTPS
    if curl -s --connect-timeout 3 https://www.proxmox.com &>/dev/null; then
        log "HTTPS access: ✓"
        ((tests_passed++))
    else
        warn "HTTPS access: ✗"
    fi

    echo ""

    if [[ $tests_passed -lt 2 ]]; then
        error "Network connectivity issues detected"
        return 1
    fi

    return 0
}

# Disable enterprise repo (if no subscription)
configure_repos() {
    step "Configuring Repositories"

    # Disable enterprise repo
    if [[ -f /etc/apt/sources.list.d/pve-enterprise.list ]]; then
        log "Disabling enterprise repository..."
        sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list
    fi

    # Disable ceph enterprise repo if present
    if [[ -f /etc/apt/sources.list.d/ceph.list ]]; then
        log "Disabling Ceph enterprise repository..."
        sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/ceph.list
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
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        curl \
        wget \
        git \
        tmux \
        htop \
        vim \
        jq

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
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs

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
    tmux send-keys -t claude "echo '  ╔═══════════════════════════════════════════════╗'" Enter
    tmux send-keys -t claude "echo '  ║  Welcome to Claude Code on Proxmox VE        ║'" Enter
    tmux send-keys -t claude "echo '  ╚═══════════════════════════════════════════════╝'" Enter
    tmux send-keys -t claude "echo ''" Enter
    tmux send-keys -t claude "echo '  Claude will help you configure your server.'" Enter
    tmux send-keys -t claude "echo ''" Enter
    tmux send-keys -t claude "echo '  To authenticate (if needed):  claude auth login'" Enter
    tmux send-keys -t claude "echo '  To detach from this session:  Ctrl+B then D'" Enter
    tmux send-keys -t claude "echo '  To reattach later:            tm'" Enter
    tmux send-keys -t claude "echo ''" Enter
    tmux send-keys -t claude "claude" Enter

    log "Claude session started"
}

# Add helpful aliases
configure_shell() {
    step "Configuring Shell"

    if ! grep -q "# PVE Claude Setup" /root/.bashrc; then
        cat >> /root/.bashrc << 'EOF'

# PVE Claude Setup
alias c='claude'
alias tm='tmux attach -t claude 2>/dev/null || tmux new -s claude -n main "claude"'
alias vmlist='qm list'
alias ctlist='pct list'
alias storage='pvesm status'
alias logs='journalctl -f'

# Show Claude session hint on login
if [ -n "$PS1" ] && [ -z "$TMUX" ]; then
    if tmux has-session -t claude 2>/dev/null; then
        echo ""
        echo "  Claude Code is running. Attach with: tm"
        echo ""
    else
        echo ""
        echo "  Start Claude Code with: tm"
        echo ""
    fi
fi
EOF
        log "Shell aliases added"
    else
        log "Shell already configured"
    fi
}

# Create login banner
create_banner() {
    step "Creating Login Banner"

    local ip=$(get_ip)

    cat > /etc/motd << EOF

  ╔═══════════════════════════════════════════════════════════════╗
  ║                    PROXMOX VE + CLAUDE CODE                   ║
  ╠═══════════════════════════════════════════════════════════════╣
  ║                                                               ║
  ║  Type 'tm' to start Claude   ◄── Just type this!             ║
  ║                                                               ║
  ║  Web UI:  https://${ip}:8006                            ║
  ║                                                               ║
  ╚═══════════════════════════════════════════════════════════════╝

EOF

    log "Login banner created"
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
    echo -e "  ${CYAN}Claude Session:${NC}  tm"
    echo ""

    if [[ "$AUTO_MODE" == "false" ]]; then
        echo -e "  ${YELLOW}If Claude needs authentication:${NC}"
        echo -e "    Run: ${CYAN}claude auth login${NC}"
        echo ""
        echo -e "  ${YELLOW}Example Claude commands:${NC}"
        echo "    'Set static IP 192.168.1.100/24 gateway 192.168.1.1'"
        echo "    'Create a VM with Ubuntu 24.04, 4 cores, 8GB RAM'"
        echo "    'Set up a backup schedule for all VMs'"
        echo ""
    fi
}

# Main
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Proxmox VE - First Boot Setup${NC}"
    if [[ "$AUTO_MODE" == "true" ]]; then
        echo -e "${CYAN}  (Automatic Mode)${NC}"
    fi
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Check root
    if [[ $EUID -ne 0 ]]; then
        error "Please run as root"
        exit 1
    fi

    # Initialize log
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "=== PVE Claude Setup Started: $(date) ===" > "$LOG_FILE"

    # Wait for network in auto mode
    if [[ "$AUTO_MODE" == "true" ]]; then
        wait_for_network || true
    fi

    # Run setup steps
    test_network || warn "Network tests had issues, continuing..."
    configure_repos
    install_dependencies
    install_nodejs
    install_claude
    configure_shell
    create_banner
    start_claude_session
    show_completion

    echo "=== Setup Complete: $(date) ===" >> "$LOG_FILE"

    # In interactive mode, offer to attach
    if [[ "$AUTO_MODE" == "false" ]]; then
        echo ""
        log "Attaching to Claude session in 3 seconds..."
        log "Press Ctrl+C to skip, or Ctrl+B then D to detach later"
        sleep 3
        tmux attach -t claude
    else
        log "Setup complete. Attach to Claude with: tm"
    fi
}

main "$@"
