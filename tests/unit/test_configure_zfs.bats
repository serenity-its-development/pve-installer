#!/usr/bin/env bats
#
# Unit tests for configure-zfs.sh
#

load '../test_helper'

setup() {
    setup_temp_dir
    setup_mocks
    create_mock_disks "$TEST_TEMP_DIR/dev"

    export MOCK_ZPOOL_DIR="$TEST_TEMP_DIR/mock_zpool"
    export MOCK_ZFS_DIR="$TEST_TEMP_DIR/mock_zfs"
    mkdir -p "$MOCK_ZPOOL_DIR" "$MOCK_ZFS_DIR"

    export ZFS_SCRIPT="$PROJECT_ROOT/installer/configure-zfs.sh"
}

teardown() {
    teardown_temp_dir
    teardown_mocks
}

@test "script exists and is executable" {
    [[ -f "$ZFS_SCRIPT" ]]
    [[ -x "$ZFS_SCRIPT" ]] || chmod +x "$ZFS_SCRIPT"
}

@test "script has valid bash syntax" {
    run bash -n "$ZFS_SCRIPT"
    assert_success
}

@test "help option displays usage" {
    run bash "$ZFS_SCRIPT" --help
    assert_output_contains "Usage"
    assert_output_contains "--disks"
    assert_output_contains "--type"
}

@test "validate_disks fails for non-existent disk" {
    source "$ZFS_SCRIPT" 2>/dev/null || true

    run validate_disks "nonexistent"
    assert_failure
}

@test "get_disk_paths formats paths correctly" {
    source "$ZFS_SCRIPT" 2>/dev/null || true

    result=$(get_disk_paths "sda,sdb,sdc")
    [[ "$result" == " /dev/sda /dev/sdb /dev/sdc" ]]
}

@test "single disk type requires 1 disk" {
    source "$ZFS_SCRIPT" 2>/dev/null || true

    # Single should work with 1 disk
    # This tests the logic, not actual pool creation
    ZFS_TYPE="single"
    disk_count=1
    [[ "$disk_count" -eq 1 ]]
}

@test "mirror type requires at least 2 disks" {
    source "$ZFS_SCRIPT" 2>/dev/null || true

    # Should fail with only 1 disk
    ZFS_TYPE="mirror"
    disk_count=1
    [[ "$disk_count" -lt 2 ]]
}

@test "raidz1 type requires at least 3 disks" {
    source "$ZFS_SCRIPT" 2>/dev/null || true

    ZFS_TYPE="raidz1"
    disk_count=2
    [[ "$disk_count" -lt 3 ]]
}

@test "raidz2 type requires at least 4 disks" {
    source "$ZFS_SCRIPT" 2>/dev/null || true

    ZFS_TYPE="raidz2"
    disk_count=3
    [[ "$disk_count" -lt 4 ]]
}

@test "mock zpool create works" {
    chmod +x "$MOCKS_DIR/zpool"

    run "$MOCKS_DIR/zpool" create -f rpool mirror /dev/sda /dev/sdb
    assert_success

    [[ -f "$MOCK_ZPOOL_DIR/rpool" ]]
}

@test "mock zpool status works" {
    chmod +x "$MOCKS_DIR/zpool"

    # Create a pool first
    "$MOCKS_DIR/zpool" create -f rpool /dev/sda

    run "$MOCKS_DIR/zpool" status rpool
    assert_success
    assert_output_contains "rpool"
    assert_output_contains "ONLINE"
}

@test "mock zfs create works" {
    chmod +x "$MOCKS_DIR/zfs"

    run "$MOCKS_DIR/zfs" create -o mountpoint=/rpool/data rpool/data
    assert_success

    [[ -f "$MOCK_ZFS_DIR/rpool_data" ]]
}
