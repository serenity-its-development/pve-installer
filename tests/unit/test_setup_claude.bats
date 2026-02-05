#!/usr/bin/env bats
#
# Unit tests for post-install/setup-claude.sh
#

load '../test_helper'

setup() {
    setup_temp_dir
    setup_mocks

    export CLAUDE_SCRIPT="$PROJECT_ROOT/post-install/setup-claude.sh"
}

teardown() {
    teardown_temp_dir
    teardown_mocks
}

@test "script exists and is executable" {
    [[ -f "$CLAUDE_SCRIPT" ]]
    [[ -x "$CLAUDE_SCRIPT" ]] || chmod +x "$CLAUDE_SCRIPT"
}

@test "script has valid bash syntax" {
    run bash -n "$CLAUDE_SCRIPT"
    assert_success
}

@test "script defines NODE_VERSION" {
    grep -q "NODE_VERSION" "$CLAUDE_SCRIPT"
}

@test "script has check_requirements function" {
    grep -q "check_requirements()" "$CLAUDE_SCRIPT"
}

@test "script has install_nodejs function" {
    grep -q "install_nodejs()" "$CLAUDE_SCRIPT"
}

@test "script has install_claude function" {
    grep -q "install_claude()" "$CLAUDE_SCRIPT"
}

@test "script has configure_environment function" {
    grep -q "configure_environment()" "$CLAUDE_SCRIPT"
}
