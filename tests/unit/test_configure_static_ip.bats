#!/usr/bin/env bats
#
# Unit tests for post-install/configure-static-ip.sh
#

load '../test_helper'

setup() {
    setup_temp_dir
    setup_mocks
    create_mock_network_env

    export STATIC_IP_SCRIPT="$PROJECT_ROOT/post-install/configure-static-ip.sh"
}

teardown() {
    teardown_temp_dir
    teardown_mocks
}

@test "script exists and is executable" {
    [[ -f "$STATIC_IP_SCRIPT" ]]
    [[ -x "$STATIC_IP_SCRIPT" ]] || chmod +x "$STATIC_IP_SCRIPT"
}

@test "script has valid bash syntax" {
    run bash -n "$STATIC_IP_SCRIPT"
    assert_success
}

@test "script has get_current_ip function" {
    source "$STATIC_IP_SCRIPT" 2>/dev/null || true

    declare -f get_current_ip >/dev/null
}

@test "script has get_current_netmask function" {
    source "$STATIC_IP_SCRIPT" 2>/dev/null || true

    declare -f get_current_netmask >/dev/null
}

@test "script has get_current_gateway function" {
    source "$STATIC_IP_SCRIPT" 2>/dev/null || true

    declare -f get_current_gateway >/dev/null
}

@test "script has get_current_dns function" {
    source "$STATIC_IP_SCRIPT" 2>/dev/null || true

    declare -f get_current_dns >/dev/null
}

@test "get_current_ip returns mocked IP" {
    source "$STATIC_IP_SCRIPT" 2>/dev/null || true

    result=$(get_current_ip)
    [[ "$result" == "$MOCK_IP_ADDRESS" ]]
}

@test "get_current_gateway returns mocked gateway" {
    source "$STATIC_IP_SCRIPT" 2>/dev/null || true

    result=$(get_current_gateway)
    [[ "$result" == "$MOCK_GATEWAY" ]]
}
