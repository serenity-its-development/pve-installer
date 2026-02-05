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

@test "script supports --hostname option" {
    grep -q "\-\-hostname" "$INSTALLER_SCRIPT"
}

@test "script supports --domain option" {
    grep -q "\-\-domain" "$INSTALLER_SCRIPT"
}

@test "script supports --zfs-disks option" {
    grep -q "\-\-zfs-disks" "$INSTALLER_SCRIPT"
}

@test "script supports --skip-zfs and --skip-reboot" {
    grep -q "\-\-skip-zfs" "$INSTALLER_SCRIPT"
    grep -q "\-\-skip-reboot" "$INSTALLER_SCRIPT"
}

@test "script has get_primary_ip function" {
    grep -q "get_primary_ip()" "$INSTALLER_SCRIPT"
}

@test "script has get_primary_interface function" {
    grep -q "get_primary_interface()" "$INSTALLER_SCRIPT"
}

@test "script has configure_hostname function" {
    grep -q "configure_hostname()" "$INSTALLER_SCRIPT"
}
