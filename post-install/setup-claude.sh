#!/bin/bash
#
# setup-claude.sh - Install Claude Code CLI on Proxmox VE
#
# This script installs Node.js and Claude Code on a running Proxmox system,
# allowing continued AI-assisted management of the server.

set -euo pipefail

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

NODE_VERSION="20"

check_requirements() {
    log_step "Checking requirements..."

    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi

    if ! ping -c 1 google.com &> /dev/null; then
        log_error "No network connectivity"
        exit 1
    fi

    log_info "Requirements check passed"
}

install_nodejs() {
    log_step "Installing Node.js ${NODE_VERSION}.x..."

    # Check if Node.js is already installed
    if command -v node &> /dev/null; then
        local current_version=$(node --version)
        log_info "Node.js already installed: $current_version"

        # Check if it's recent enough
        local major_version=$(echo "$current_version" | sed 's/v\([0-9]*\).*/\1/')
        if [[ $major_version -ge 18 ]]; then
            log_info "Node.js version is sufficient, skipping installation"
            return
        fi
        log_warn "Node.js version too old, upgrading..."
    fi

    # Install Node.js from NodeSource
    curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash -
    apt-get install -y nodejs

    # Verify installation
    log_info "Node.js installed: $(node --version)"
    log_info "npm installed: $(npm --version)"
}

install_claude() {
    log_step "Installing Claude Code CLI..."

    # Check if already installed
    if command -v claude &> /dev/null; then
        local current_version=$(claude --version 2>/dev/null || echo "unknown")
        log_info "Claude Code already installed: $current_version"

        read -p "Reinstall/upgrade? (y/n): " confirm
        if [[ "$confirm" != "y" ]]; then
            log_info "Skipping Claude Code installation"
            return
        fi
    fi

    # Install Claude Code globally
    npm install -g @anthropic-ai/claude-code

    # Verify installation
    if command -v claude &> /dev/null; then
        log_info "Claude Code installed successfully"
    else
        log_error "Claude Code installation failed"
        exit 1
    fi
}

configure_environment() {
    log_step "Configuring environment..."

    # Add helpful aliases to root's bashrc
    if ! grep -q "# Claude Code aliases" /root/.bashrc; then
        cat >> /root/.bashrc << 'EOF'

# Claude Code aliases
alias c='claude'

# Proxmox shortcuts
alias vmlist='qm list'
alias ctlist='pct list'
alias storage='pvesm status'
alias cluster='pvecm status'
EOF
        log_info "Added shell aliases"
    fi

    log_info "Environment configured"
}

setup_authentication() {
    log_step "Claude Code Authentication"

    echo ""
    echo "To use Claude Code, you need to authenticate with your Anthropic API key."
    echo ""
    echo "Options:"
    echo "  1. Run 'claude' and follow the prompts to authenticate"
    echo "  2. Set ANTHROPIC_API_KEY environment variable"
    echo ""

    read -p "Would you like to authenticate now? (y/n): " auth_now

    if [[ "$auth_now" == "y" ]]; then
        log_info "Starting Claude Code authentication..."
        claude auth login
    else
        log_info "You can authenticate later by running: claude auth login"
    fi
}

show_completion() {
    echo ""
    echo -e "${GREEN}=========================================="
    echo -e "  Claude Code Installation Complete!"
    echo -e "==========================================${NC}"
    echo ""
    echo "Usage:"
    echo "  claude              - Start Claude Code"
    echo "  claude --help       - Show help"
    echo ""
    echo "Proxmox management examples:"
    echo "  'Create a new Ubuntu VM with 4 cores and 8GB RAM'"
    echo "  'Set up a backup schedule for all VMs'"
    echo "  'Configure static IP 192.168.1.100 on this server'"
    echo "  'Show me the status of all storage pools'"
    echo ""
}

main() {
    echo ""
    echo -e "${BLUE}=========================================="
    echo -e "  Claude Code Installer for Proxmox VE"
    echo -e "==========================================${NC}"
    echo ""

    check_requirements
    install_nodejs
    install_claude
    configure_environment
    setup_authentication
    show_completion
}

main "$@"
