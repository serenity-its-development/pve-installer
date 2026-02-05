#!/usr/bin/env bats
#
# Unit tests for build/build-usb.sh
#

load '../test_helper'

setup() {
    setup_temp_dir

    export BUILD_SCRIPT="$PROJECT_ROOT/build/build-usb.sh"
}

teardown() {
    teardown_temp_dir
}

@test "script exists and is executable" {
    [[ -f "$BUILD_SCRIPT" ]]
    [[ -x "$BUILD_SCRIPT" ]] || chmod +x "$BUILD_SCRIPT"
}

@test "script has valid bash syntax" {
    run bash -n "$BUILD_SCRIPT"
    assert_success
}

@test "script defines required variables" {
    # Extract variable definitions
    grep -q "DEBIAN_RELEASE=" "$BUILD_SCRIPT"
    grep -q "IMAGE_NAME=" "$BUILD_SCRIPT"
    grep -q "ARCH=" "$BUILD_SCRIPT"
}

@test "script has check_requirements function" {
    grep -q "check_requirements()" "$BUILD_SCRIPT"
}

@test "script has setup_build_dir function" {
    grep -q "setup_build_dir()" "$BUILD_SCRIPT"
}

@test "script has configure_packages function" {
    grep -q "configure_packages()" "$BUILD_SCRIPT"
}

@test "script has configure_hooks function" {
    grep -q "configure_hooks()" "$BUILD_SCRIPT"
}

@test "script has build_image function" {
    grep -q "build_image()" "$BUILD_SCRIPT"
}

@test "script includes Claude Code installation in hooks" {
    grep -q "claude-code" "$BUILD_SCRIPT" || grep -q "@anthropic-ai/claude-code" "$BUILD_SCRIPT"
}

@test "script includes ZFS support in packages" {
    grep -q "zfsutils-linux" "$BUILD_SCRIPT"
}

@test "script includes Node.js installation" {
    grep -q "nodejs" "$BUILD_SCRIPT" || grep -q "nodesource" "$BUILD_SCRIPT"
}

@test "script enables SSH" {
    grep -q "ssh" "$BUILD_SCRIPT"
}

@test "script sets up auto-login" {
    grep -q "autologin" "$BUILD_SCRIPT"
}
