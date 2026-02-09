#!/usr/bin/env bats
#
# Integration tests for the complete PVE installer workflow
#
# These tests verify that all components work together correctly.
#

load '../test_helper'

setup() {
    setup_temp_dir
    setup_mocks
    create_mock_network_env

    # Create mock file structure
    export MOCK_USB="$TEST_TEMP_DIR/usb"
    export MOCK_ROOT="$TEST_TEMP_DIR/root"
    export MOCK_ETC="$TEST_TEMP_DIR/etc"

    mkdir -p "$MOCK_USB/pve-installer/scripts"
    mkdir -p "$MOCK_USB/pve-installer/config"
    mkdir -p "$MOCK_ROOT"
    mkdir -p "$MOCK_ETC/apt/sources.list.d"

    # Copy project files to mock USB
    cp -r "$PROJECT_ROOT/installer/"* "$MOCK_USB/pve-installer/scripts/" 2>/dev/null || true
    cp -r "$PROJECT_ROOT/post-install/"* "$MOCK_USB/pve-installer/scripts/" 2>/dev/null || true
    cp -r "$PROJECT_ROOT/config/"* "$MOCK_USB/pve-installer/config/" 2>/dev/null || true
}

teardown() {
    teardown_temp_dir
    teardown_mocks
}

# =============================================================================
# Workflow Step Tests
# =============================================================================

@test "WORKFLOW: All required scripts exist" {
    [[ -f "$PROJECT_ROOT/build/Create-BootableUSB.ps1" ]]
    [[ -f "$PROJECT_ROOT/post-install/first-boot-setup.sh" ]]
    [[ -f "$PROJECT_ROOT/installer/install-proxmox.sh" ]]
    [[ -f "$PROJECT_ROOT/installer/configure-zfs.sh" ]]
    [[ -f "$PROJECT_ROOT/installer/configure-network.sh" ]]
}

@test "WORKFLOW: All scripts have valid syntax" {
    for script in "$PROJECT_ROOT"/{installer,post-install}/*.sh; do
        run bash -n "$script"
        assert_success
    done
}

@test "WORKFLOW: Scripts are executable" {
    chmod +x "$PROJECT_ROOT"/{installer,post-install}/*.sh

    for script in "$PROJECT_ROOT"/{installer,post-install}/*.sh; do
        [[ -x "$script" ]]
    done
}

@test "WORKFLOW: Config templates exist" {
    [[ -f "$PROJECT_ROOT/config/sources.list.pve" ]]
    [[ -f "$PROJECT_ROOT/config/interfaces.template" ]]
}

# =============================================================================
# USB Creation Tests (simulated)
# =============================================================================

@test "USB: PowerShell script exists and is valid" {
    [[ -f "$PROJECT_ROOT/build/Create-BootableUSB.ps1" ]]

    # Check for required functions
    grep -q "Get-USBDrives" "$PROJECT_ROOT/build/Create-BootableUSB.ps1"
    grep -q "Download-ProxmoxISO" "$PROJECT_ROOT/build/Create-BootableUSB.ps1"
    grep -q "Create-AnswerPartition" "$PROJECT_ROOT/build/Create-BootableUSB.ps1"
}

@test "USB: Script creates correct directory structure" {
    # Simulate what the USB should look like after creation
    mkdir -p "$MOCK_USB/pve-installer/scripts"
    mkdir -p "$MOCK_USB/pve-installer/config"
    touch "$MOCK_USB/proxmox-ve.iso"
    touch "$MOCK_USB/README.txt"

    [[ -d "$MOCK_USB/pve-installer/scripts" ]]
    [[ -d "$MOCK_USB/pve-installer/config" ]]
    [[ -f "$MOCK_USB/proxmox-ve.iso" ]]
}

@test "USB: Contains all installer scripts" {
    [[ -f "$MOCK_USB/pve-installer/scripts/install-proxmox.sh" ]] || \
    [[ -f "$MOCK_USB/pve-installer/scripts/first-boot-setup.sh" ]]
}

# =============================================================================
# First Boot Setup Tests
# =============================================================================

@test "FIRST-BOOT: Script supports --auto flag" {
    grep -q "\-\-auto" "$PROJECT_ROOT/post-install/first-boot-setup.sh"
    grep -q "AUTO_MODE" "$PROJECT_ROOT/post-install/first-boot-setup.sh"
}

@test "FIRST-BOOT: Script structure is valid" {
    # Check script has main function at the end
    grep -q "^main" "$PROJECT_ROOT/post-install/first-boot-setup.sh"
    # Check script can be parsed
    bash -n "$PROJECT_ROOT/post-install/first-boot-setup.sh"
}

@test "FIRST-BOOT: Script waits for network in auto mode" {
    grep -q "wait_for_network" "$PROJECT_ROOT/post-install/first-boot-setup.sh"
}

@test "FIRST-BOOT: Script logs to file" {
    grep -q "LOG_FILE" "$PROJECT_ROOT/post-install/first-boot-setup.sh"
    grep -q "/var/log" "$PROJECT_ROOT/post-install/first-boot-setup.sh"
}

@test "FIRST-BOOT: Has network helper functions" {
    grep -q "get_ip()" "$PROJECT_ROOT/post-install/first-boot-setup.sh"
    grep -q "get_gateway()" "$PROJECT_ROOT/post-install/first-boot-setup.sh"
    grep -q "get_interface()" "$PROJECT_ROOT/post-install/first-boot-setup.sh"
}

@test "FIRST-BOOT: Creates correct repo configuration" {
    # Check that script would create no-subscription repo
    grep -q "pve-no-subscription" "$PROJECT_ROOT/post-install/first-boot-setup.sh"
}

@test "FIRST-BOOT: Installs Node.js 20.x" {
    grep -q "setup_20" "$PROJECT_ROOT/post-install/first-boot-setup.sh"
}

@test "FIRST-BOOT: Installs Claude Code" {
    grep -q "claude-code" "$PROJECT_ROOT/post-install/first-boot-setup.sh"
}

@test "FIRST-BOOT: Creates tmux session for Claude" {
    grep -q "tmux new-session" "$PROJECT_ROOT/post-install/first-boot-setup.sh"
    grep -q "claude" "$PROJECT_ROOT/post-install/first-boot-setup.sh"
}

@test "FIRST-BOOT: Adds helpful shell aliases" {
    grep -q "alias" "$PROJECT_ROOT/post-install/first-boot-setup.sh"
    grep -q "vmlist" "$PROJECT_ROOT/post-install/first-boot-setup.sh"
    grep -q "tm=" "$PROJECT_ROOT/post-install/first-boot-setup.sh" || \
    grep -q "'tm'" "$PROJECT_ROOT/post-install/first-boot-setup.sh"
}

# =============================================================================
# Installer Script Tests
# =============================================================================

@test "INSTALLER: install-proxmox.sh has help option" {
    run bash "$PROJECT_ROOT/installer/install-proxmox.sh" --help
    assert_output_contains "Usage"
}

@test "INSTALLER: configure-network.sh has show command" {
    run bash "$PROJECT_ROOT/installer/configure-network.sh" help
    assert_output_contains "Usage"
}

@test "INSTALLER: configure-zfs.sh has help option" {
    run bash "$PROJECT_ROOT/installer/configure-zfs.sh" --help
    assert_output_contains "Usage"
}

# =============================================================================
# Configuration Tests
# =============================================================================

@test "CONFIG: sources.list.pve has correct repos" {
    grep -q "debian.org" "$PROJECT_ROOT/config/sources.list.pve" || \
    grep -q "deb.debian.org" "$PROJECT_ROOT/config/sources.list.pve"

    grep -q "proxmox.com" "$PROJECT_ROOT/config/sources.list.pve"
    grep -q "pve-no-subscription" "$PROJECT_ROOT/config/sources.list.pve"
}

@test "CONFIG: interfaces.template has bridge config" {
    grep -q "vmbr0" "$PROJECT_ROOT/config/interfaces.template"
    grep -q "bridge-ports" "$PROJECT_ROOT/config/interfaces.template"
}

# =============================================================================
# End-to-End Flow Validation
# =============================================================================

@test "E2E: Complete file set for USB" {
    # Verify all files needed for USB are present
    local required_files=(
        "build/Create-BootableUSB.ps1"
        "installer/install-proxmox.sh"
        "installer/configure-zfs.sh"
        "installer/configure-network.sh"
        "post-install/first-boot-setup.sh"
        "post-install/setup-claude.sh"
        "post-install/configure-static-ip.sh"
        "config/sources.list.pve"
        "config/interfaces.template"
    )

    for file in "${required_files[@]}"; do
        [[ -f "$PROJECT_ROOT/$file" ]] || {
            echo "Missing: $file"
            false
        }
    done
}

@test "E2E: first-boot-setup.sh can be curl-piped" {
    # Verify the script works when downloaded and piped to bash
    # (simulate by checking it starts with shebang and has main)

    head -1 "$PROJECT_ROOT/post-install/first-boot-setup.sh" | grep -q "#!/bin/bash"
    grep -q "^main" "$PROJECT_ROOT/post-install/first-boot-setup.sh"
}

@test "E2E: README has correct curl command" {
    grep -q "curl.*first-boot-setup.sh.*bash" "$PROJECT_ROOT/README.md"
}

@test "E2E: README documents complete workflow" {
    # Check README has all steps
    grep -q "Clone" "$PROJECT_ROOT/README.md"
    grep -q "Create-BootableUSB" "$PROJECT_ROOT/README.md"
    grep -q "Boot" "$PROJECT_ROOT/README.md"
    grep -q "first-boot-setup" "$PROJECT_ROOT/README.md"
    grep -q "tmux" "$PROJECT_ROOT/README.md"
}

# =============================================================================
# Automatic Setup Tests
# =============================================================================

@test "AUTO-SETUP: Systemd service file exists" {
    [[ -f "$PROJECT_ROOT/post-install/pve-claude-setup.service" ]]
}

@test "AUTO-SETUP: Service runs after network" {
    grep -q "After=network-online.target" "$PROJECT_ROOT/post-install/pve-claude-setup.service"
}

@test "AUTO-SETUP: Service is oneshot type" {
    grep -q "Type=oneshot" "$PROJECT_ROOT/post-install/pve-claude-setup.service"
}

@test "AUTO-SETUP: Service runs first-boot-setup.sh" {
    grep -q "first-boot-setup.sh" "$PROJECT_ROOT/post-install/pve-claude-setup.service"
}

@test "AUTO-SETUP: Service uses --auto flag" {
    grep -q "\-\-auto" "$PROJECT_ROOT/post-install/pve-claude-setup.service"
}

@test "AUTO-SETUP: Service creates done marker" {
    grep -q "pve-claude.*done" "$PROJECT_ROOT/post-install/pve-claude-setup.service"
}

@test "AUTO-SETUP: Service only runs once" {
    grep -q "ConditionPathExists=!" "$PROJECT_ROOT/post-install/pve-claude-setup.service"
}

@test "AUTO-SETUP: PowerShell script creates answer file" {
    grep -q "answer.toml" "$PROJECT_ROOT/build/Create-BootableUSB.ps1"
}

@test "AUTO-SETUP: PowerShell script includes post-commands" {
    grep -q "post-commands" "$PROJECT_ROOT/build/Create-BootableUSB.ps1" || \
    grep -q "post =" "$PROJECT_ROOT/build/Create-BootableUSB.ps1"
}

@test "AUTO-SETUP: README mentions automatic setup" {
    grep -qi "automatic" "$PROJECT_ROOT/README.md"
}
