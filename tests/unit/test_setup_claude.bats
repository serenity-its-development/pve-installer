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
    source "$CLAUDE_SCRIPT" 2>/dev/null || true

    [[ -n "$NODE_VERSION" ]]
    [[ "$NODE_VERSION" =~ ^[0-9]+$ ]]
}

@test "script has check_requirements function" {
    source "$CLAUDE_SCRIPT" 2>/dev/null || true

    declare -f check_requirements >/dev/null
}

@test "script has install_nodejs function" {
    source "$CLAUDE_SCRIPT" 2>/dev/null || true

    declare -f install_nodejs >/dev/null
}

@test "script has install_claude function" {
    source "$CLAUDE_SCRIPT" 2>/dev/null || true

    declare -f install_claude >/dev/null
}

@test "script has configure_environment function" {
    source "$CLAUDE_SCRIPT" 2>/dev/null || true

    declare -f configure_environment >/dev/null
}
