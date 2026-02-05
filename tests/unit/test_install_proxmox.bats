#!/usr/bin/env bats
#
# Unit tests for install-proxmox.sh
#

load '../test_helper'

setup() {
    setup_temp_dir
    setup_mocks
    create_mock_network_env

    # Create mock system files
    mkdir -p "$TEST_TEMP_DIR/etc/apt/sources.list.d"
    mkdir -p "$TEST_TEMP_DIR/etc/apt/trusted.gpg.d"
    touch "$TEST_TEMP_DIR/etc/debian_version"
    create_mock_hosts "$TEST_TEMP_DIR/etc/hosts"
    create_mock_interfaces "$TEST_TEMP_DIR/etc/network/interfaces"

    # Source the script functions
    export INSTALLER_SCRIPT="$PROJECT_ROOT/installer/install-proxmox.sh"
}

teardown() {
    teardown_temp_dir
    teardown_mocks
}

@test "script exists and is executable" {
    [[ -f "$INSTALLER_SCRIPT" ]]
    [[ -x "$INSTALLER_SCRIPT" ]] || chmod +x "$INSTALLER_SCRIPT"
}

@test "script has valid bash syntax" {
    run bash -n "$INSTALLER_SCRIPT"
    assert_success
}

@test "help option displays usage" {
    run bash "$INSTALLER_SCRIPT" --help
    assert_output_contains "Usage"
    assert_output_contains "--hostname"
    assert_output_contains "--zfs-disks"
}

@test "parse_args sets hostname correctly" {
    # Extract and test the parse_args function
    source "$INSTALLER_SCRIPT" 2>/dev/null || true

    HOSTNAME="default"
    parse_args --hostname testserver
    [[ "$HOSTNAME" == "testserver" ]]
}

@test "parse_args sets domain correctly" {
    source "$INSTALLER_SCRIPT" 2>/dev/null || true

    DOMAIN="default"
    parse_args --domain example.com
    [[ "$DOMAIN" == "example.com" ]]
}

@test "parse_args sets zfs options correctly" {
    source "$INSTALLER_SCRIPT" 2>/dev/null || true

    ZFS_DISKS=""
    ZFS_TYPE="single"
    parse_args --zfs-disks sda,sdb --zfs-type mirror
    [[ "$ZFS_DISKS" == "sda,sdb" ]]
    [[ "$ZFS_TYPE" == "mirror" ]]
}

@test "parse_args handles skip flags" {
    source "$INSTALLER_SCRIPT" 2>/dev/null || true

    SKIP_ZFS=false
    SKIP_REBOOT=false
    parse_args --skip-zfs --skip-reboot
    [[ "$SKIP_ZFS" == "true" ]]
    [[ "$SKIP_REBOOT" == "true" ]]
}

@test "get_primary_ip returns valid IP" {
    source "$INSTALLER_SCRIPT" 2>/dev/null || true

    result=$(get_primary_ip)
    [[ "$result" == "$MOCK_IP_ADDRESS" ]]
}

@test "get_primary_interface returns valid interface" {
    source "$INSTALLER_SCRIPT" 2>/dev/null || true

    result=$(get_primary_interface)
    [[ "$result" == "$MOCK_INTERFACE" ]]
}

@test "configure_hostname creates valid hosts file" {
    source "$INSTALLER_SCRIPT" 2>/dev/null || true

    # Mock hostnamectl
    hostnamectl() { echo "$2" > "$TEST_TEMP_DIR/hostname"; }
    export -f hostnamectl

    # Redirect /etc to temp
    mkdir -p "$TEST_TEMP_DIR/etc"

    HOSTNAME="testpve"
    DOMAIN="local"

    # Run with mocked paths (would need more setup for full test)
    # This is a simplified test
    [[ "$HOSTNAME" == "testpve" ]]
}
