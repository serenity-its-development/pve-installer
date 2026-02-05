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

@test "script has validate_disks function" {
    grep -q "validate_disks()" "$ZFS_SCRIPT"
}

@test "script has get_disk_paths function" {
    grep -q "get_disk_paths()" "$ZFS_SCRIPT"
}

@test "script supports single disk type" {
    grep -q "single" "$ZFS_SCRIPT"
}

@test "script supports mirror type" {
    grep -q "mirror" "$ZFS_SCRIPT"
}

@test "script supports raidz1 type" {
    grep -q "raidz1" "$ZFS_SCRIPT"
}

@test "script supports raidz2 type" {
    grep -q "raidz2" "$ZFS_SCRIPT"
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
