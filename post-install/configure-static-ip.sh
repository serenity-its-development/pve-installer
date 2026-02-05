#!/bin/bash
#
# configure-static-ip.sh - Convert DHCP to static IP on Proxmox VE
#
# This is a user-friendly wrapper that captures current DHCP settings
# and converts them to a static configuration.

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

get_primary_interface() {
    ip route get 1 | awk '{print $5; exit}'
}

get_current_ip() {
    ip route get 1 | awk '{print $7; exit}'
}

get_current_netmask() {
    local iface=$(get_primary_interface)
    ip -o -f inet addr show "$iface" | awk '{print $4}' | cut -d'/' -f2
}

get_current_gateway() {
    ip route | grep default | awk '{print $3}'
}

get_current_dns() {
    grep "^nameserver" /etc/resolv.conf | head -1 | awk '{print $2}'
}

main() {
    echo ""
    echo -e "${BLUE}=========================================="
    echo -e "  Static IP Configuration"
    echo -e "==========================================${NC}"
    echo ""

    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi

    # Get current settings
    local iface=$(get_primary_interface)
    local current_ip=$(get_current_ip)
    local current_mask=$(get_current_netmask)
    local current_gw=$(get_current_gateway)
    local current_dns=$(get_current_dns)

    echo "Current Network Configuration:"
    echo "  Interface: $iface"
    echo "  IP Address: $current_ip"
    echo "  Netmask: /$current_mask"
    echo "  Gateway: $current_gw"
    echo "  DNS: $current_dns"
    echo ""

    # Ask for new values (default to current)
    read -p "IP Address [$current_ip]: " new_ip
    new_ip="${new_ip:-$current_ip}"

    read -p "Netmask (CIDR) [$current_mask]: " new_mask
    new_mask="${new_mask:-$current_mask}"

    read -p "Gateway [$current_gw]: " new_gw
    new_gw="${new_gw:-$current_gw}"

    read -p "DNS Server [$current_dns]: " new_dns
    new_dns="${new_dns:-$current_dns}"

    echo ""
    echo "New Configuration:"
    echo "  IP Address: $new_ip/$new_mask"
    echo "  Gateway: $new_gw"
    echo "  DNS: $new_dns"
    echo ""

    read -p "Apply this configuration? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        log_info "Aborted"
        exit 0
    fi

    # Backup current config
    local backup="/etc/network/interfaces.backup.$(date +%Y%m%d%H%M%S)"
    cp /etc/network/interfaces "$backup"
    log_info "Backed up to $backup"

    # Check if bridge exists
    if grep -q "vmbr0" /etc/network/interfaces; then
        # Update bridge configuration
        cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

iface ${iface} inet manual

auto vmbr0
iface vmbr0 inet static
    address ${new_ip}/${new_mask}
    gateway ${new_gw}
    bridge-ports ${iface}
    bridge-stp off
    bridge-fd 0
EOF
    else
        # Update interface configuration
        cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

auto ${iface}
iface ${iface} inet static
    address ${new_ip}/${new_mask}
    gateway ${new_gw}
EOF
    fi

    # Update DNS
    cat > /etc/resolv.conf << EOF
nameserver ${new_dns}
EOF

    # Update /etc/hosts
    local hostname=$(hostname)
    local fqdn=$(hostname -f 2>/dev/null || echo "$hostname.local")
    sed -i "s/^${current_ip}.*/${new_ip}    ${fqdn} ${hostname}/" /etc/hosts

    log_info "Configuration updated"
    echo ""
    log_warn "Network restart required!"
    read -p "Restart networking now? (yes/no): " restart

    if [[ "$restart" == "yes" ]]; then
        log_info "Restarting networking..."
        systemctl restart networking

        # Wait and check
        sleep 3
        local check_ip=$(get_current_ip)
        if [[ "$check_ip" == "$new_ip" ]]; then
            log_info "Success! New IP: $check_ip"
        else
            log_error "IP address mismatch. Check configuration."
            log_info "Restore backup with: cp $backup /etc/network/interfaces"
        fi
    else
        log_info "Run 'systemctl restart networking' to apply changes"
    fi
}

main "$@"
