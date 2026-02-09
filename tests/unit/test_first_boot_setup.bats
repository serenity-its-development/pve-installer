#!/usr/bin/env bats
#
# Unit tests for post-install/first-boot-setup.sh
#

load '../test_helper'

setup() {
    setup_temp_dir
    setup_mocks
    create_mock_network_env

    export SCRIPT="$PROJECT_ROOT/post-install/first-boot-setup.sh"
}

teardown() {
    teardown_temp_dir
    teardown_mocks
}

@test "script exists and is executable" {
    [[ -f "$SCRIPT" ]]
    [[ -x "$SCRIPT" ]] || chmod +x "$SCRIPT"
}

@test "script has valid bash syntax" {
    run bash -n "$SCRIPT"
    assert_success
}

@test "script defines color codes" {
    grep -q "RED=" "$SCRIPT"
    grep -q "GREEN=" "$SCRIPT"
    grep -q "YELLOW=" "$SCRIPT"
    grep -q "BLUE=" "$SCRIPT"
}

@test "script supports --auto flag" {
    grep -q "\-\-auto" "$SCRIPT"
    grep -q "AUTO_MODE" "$SCRIPT"
}

@test "script has wait_for_network function" {
    grep -q "wait_for_network()" "$SCRIPT"
}

@test "script logs to file in auto mode" {
    grep -q "LOG_FILE" "$SCRIPT"
}

@test "script creates login banner" {
    grep -q "create_banner" "$SCRIPT" || grep -q "/etc/motd" "$SCRIPT"
}

@test "script has get_ip function" {
    grep -q "get_ip()" "$SCRIPT"
}

@test "script has get_gateway function" {
    grep -q "get_gateway()" "$SCRIPT"
}

@test "script has get_interface function" {
    grep -q "get_interface()" "$SCRIPT"
}

@test "script has test_network function" {
    grep -q "test_network()" "$SCRIPT"
}

@test "script has configure_repos function" {
    grep -q "configure_repos()" "$SCRIPT"
}

@test "script has install_dependencies function" {
    grep -q "install_dependencies()" "$SCRIPT"
}

@test "script has install_nodejs function" {
    grep -q "install_nodejs()" "$SCRIPT"
}

@test "script has install_claude function" {
    grep -q "install_claude()" "$SCRIPT"
}

@test "script has start_claude_session function" {
    grep -q "start_claude_session()" "$SCRIPT"
}

@test "script has configure_shell function" {
    grep -q "configure_shell()" "$SCRIPT"
}

@test "script has show_completion function" {
    grep -q "show_completion()" "$SCRIPT"
}

@test "script checks for root privileges" {
    grep -q "EUID" "$SCRIPT"
}

@test "script uses tmux for Claude session" {
    grep -q "tmux" "$SCRIPT"
}

@test "script configures no-subscription repo" {
    grep -q "pve-no-subscription" "$SCRIPT"
}

@test "script disables enterprise repo" {
    grep -q "pve-enterprise" "$SCRIPT"
}

@test "script installs Node.js 20.x" {
    grep -q "setup_20" "$SCRIPT" || grep -q "nodesource" "$SCRIPT"
}

@test "script installs claude-code package" {
    grep -q "@anthropic-ai/claude-code" "$SCRIPT" || grep -q "claude-code" "$SCRIPT"
}

@test "script adds shell aliases" {
    grep -q "alias" "$SCRIPT"
    grep -q "vmlist" "$SCRIPT"
}

@test "script displays web UI URL" {
    grep -q "8006" "$SCRIPT"
}

@test "script has cleanup_previous_pve function" {
    grep -q "cleanup_previous_pve()" "$SCRIPT"
}

@test "script handles orphan ZFS pools" {
    grep -q "zpool" "$SCRIPT"
    grep -q "orphan" "$SCRIPT" || grep -q "export" "$SCRIPT"
}

@test "script cleans stale cluster config" {
    grep -q "/etc/pve" "$SCRIPT"
    grep -q "corosync" "$SCRIPT"
}
