#!/bin/bash
#
# test_helper.bash - Common test utilities and mocks
#

# Get the project root directory
export PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TESTS_DIR="$PROJECT_ROOT/tests"
export MOCKS_DIR="$TESTS_DIR/mocks"
export FIXTURES_DIR="$TESTS_DIR/fixtures"

# Create a temporary directory for each test
setup_temp_dir() {
    export TEST_TEMP_DIR="$(mktemp -d)"
    export HOME="$TEST_TEMP_DIR/home"
    mkdir -p "$HOME"
}

# Clean up temporary directory
teardown_temp_dir() {
    if [[ -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# Add mocks to PATH
setup_mocks() {
    export ORIGINAL_PATH="$PATH"
    export PATH="$MOCKS_DIR:$PATH"
}

# Restore original PATH
teardown_mocks() {
    export PATH="$ORIGINAL_PATH"
}

# Source a script's functions without executing main
source_script() {
    local script="$1"

    # Create a wrapper that prevents main execution
    (
        # Override main to do nothing
        main() { :; }

        # Source the script
        source "$script"

        # Export all functions
        declare -f
    )
}

# Assert file contains string
assert_file_contains() {
    local file="$1"
    local pattern="$2"

    if ! grep -q "$pattern" "$file"; then
        echo "Expected file '$file' to contain '$pattern'"
        echo "Actual contents:"
        cat "$file"
        return 1
    fi
}

# Assert file does not contain string
assert_file_not_contains() {
    local file="$1"
    local pattern="$2"

    if grep -q "$pattern" "$file"; then
        echo "Expected file '$file' to NOT contain '$pattern'"
        return 1
    fi
}

# Assert command succeeds
assert_success() {
    if [[ $status -ne 0 ]]; then
        echo "Expected success but got exit code $status"
        echo "Output: $output"
        return 1
    fi
}

# Assert command fails
assert_failure() {
    if [[ $status -eq 0 ]]; then
        echo "Expected failure but command succeeded"
        echo "Output: $output"
        return 1
    fi
}

# Assert output contains string
assert_output_contains() {
    local pattern="$1"

    if [[ ! "$output" =~ $pattern ]]; then
        echo "Expected output to contain '$pattern'"
        echo "Actual output: $output"
        return 1
    fi
}

# Create mock /etc/network/interfaces
create_mock_interfaces() {
    local target="${1:-$TEST_TEMP_DIR/etc/network/interfaces}"
    mkdir -p "$(dirname "$target")"

    cat > "$target" << 'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF
}

# Create mock /etc/hosts
create_mock_hosts() {
    local target="${1:-$TEST_TEMP_DIR/etc/hosts}"
    mkdir -p "$(dirname "$target")"

    cat > "$target" << 'EOF'
127.0.0.1	localhost
192.168.1.100	testhost.local testhost
EOF
}

# Create mock disk devices
create_mock_disks() {
    local disk_dir="${1:-$TEST_TEMP_DIR/dev}"
    mkdir -p "$disk_dir"

    # Create mock block device files (just regular files for testing)
    for disk in sda sdb sdc sdd; do
        touch "$disk_dir/$disk"
    done
}

# Simulate network configuration
create_mock_network_env() {
    # These would be used by mocked ip commands
    export MOCK_IP_ADDRESS="192.168.1.100"
    export MOCK_NETMASK="24"
    export MOCK_GATEWAY="192.168.1.1"
    export MOCK_INTERFACE="eth0"
    export MOCK_DNS="8.8.8.8"
}
