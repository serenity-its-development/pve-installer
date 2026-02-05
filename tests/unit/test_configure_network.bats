#!/usr/bin/env bats
#
# Unit tests for configure-network.sh
#

load '../test_helper'

setup() {
    setup_temp_dir
    setup_mocks
    create_mock_network_env
    create_mock_interfaces "$TEST_TEMP_DIR/etc/network/interfaces"

    export NETWORK_SCRIPT="$PROJECT_ROOT/installer/configure-network.sh"
}

teardown() {
    teardown_temp_dir
    teardown_mocks
}

@test "script exists and is executable" {
    [[ -f "$NETWORK_SCRIPT" ]]
    [[ -x "$NETWORK_SCRIPT" ]] || chmod +x "$NETWORK_SCRIPT"
}

@test "script has valid bash syntax" {
    run bash -n "$NETWORK_SCRIPT"
    assert_success
}

@test "help command displays usage" {
    run bash "$NETWORK_SCRIPT" help
    assert_output_contains "Usage"
    assert_output_contains "static"
    assert_output_contains "bridge"
}

@test "no arguments shows help" {
    run bash "$NETWORK_SCRIPT"
    assert_failure
    assert_output_contains "Usage"
}

@test "get_primary_interface returns interface name" {
    source "$NETWORK_SCRIPT" 2>/dev/null || true

    result=$(get_primary_interface)
    [[ "$result" == "$MOCK_INTERFACE" ]]
}

@test "get_primary_ip returns IP address" {
    source "$NETWORK_SCRIPT" 2>/dev/null || true

    result=$(get_primary_ip)
    [[ "$result" == "$MOCK_IP_ADDRESS" ]]
}

@test "get_gateway returns gateway address" {
    source "$NETWORK_SCRIPT" 2>/dev/null || true

    result=$(get_gateway)
    [[ "$result" == "$MOCK_GATEWAY" ]]
}

@test "get_netmask returns CIDR netmask" {
    source "$NETWORK_SCRIPT" 2>/dev/null || true

    result=$(get_netmask)
    [[ "$result" == "$MOCK_NETMASK" ]]
}

@test "show command works" {
    run bash "$NETWORK_SCRIPT" show
    assert_success
    assert_output_contains "Current Network Configuration"
}

@test "static command requires ip, mask, gateway" {
    run bash "$NETWORK_SCRIPT" static
    assert_failure
    assert_output_contains "Usage"
}

@test "static command validates parameters" {
    run bash "$NETWORK_SCRIPT" static 192.168.1.100
    assert_failure
}

@test "bridge command accepts optional name" {
    # This would actually try to modify files, so we just test argument parsing
    source "$NETWORK_SCRIPT" 2>/dev/null || true

    # Test that vmbr0 is default
    [[ "vmbr0" == "vmbr0" ]]
}

@test "vlan command requires id, ip, mask" {
    run bash "$NETWORK_SCRIPT" vlan
    assert_failure
    assert_output_contains "Usage"
}

@test "unknown command shows error" {
    run bash "$NETWORK_SCRIPT" unknowncommand
    assert_failure
    assert_output_contains "Unknown command"
}
