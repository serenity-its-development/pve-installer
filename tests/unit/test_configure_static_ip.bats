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
    grep -q "get_current_ip()" "$STATIC_IP_SCRIPT"
}

@test "script has get_current_netmask function" {
    grep -q "get_current_netmask()" "$STATIC_IP_SCRIPT"
}

@test "script has get_current_gateway function" {
    grep -q "get_current_gateway()" "$STATIC_IP_SCRIPT"
}

@test "script has get_current_dns function" {
    grep -q "get_current_dns()" "$STATIC_IP_SCRIPT"
}

@test "script uses ip command for current IP" {
    grep -q "ip route" "$STATIC_IP_SCRIPT"
}

@test "script backs up existing config" {
    grep -q "backup" "$STATIC_IP_SCRIPT"
}
