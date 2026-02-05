#!/bin/bash
#
# run_tests.sh - Run all tests for pve-installer
#
# Usage:
#   ./run_tests.sh           # Run all tests
#   ./run_tests.sh unit      # Run only unit tests
#   ./run_tests.sh -v        # Verbose output
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if bats is installed
check_bats() {
    if command -v bats &> /dev/null; then
        log_info "Using system bats: $(bats --version)"
        return 0
    fi

    # Check for bats-core in common locations
    if [[ -f "$SCRIPT_DIR/bats-core/bin/bats" ]]; then
        export PATH="$SCRIPT_DIR/bats-core/bin:$PATH"
        log_info "Using local bats"
        return 0
    fi

    log_warn "Bats not found. Installing bats-core..."
    install_bats
}

install_bats() {
    cd "$SCRIPT_DIR"

    if command -v git &> /dev/null; then
        git clone --depth 1 https://github.com/bats-core/bats-core.git
        export PATH="$SCRIPT_DIR/bats-core/bin:$PATH"
        log_info "Bats installed successfully"
    else
        log_error "Git not found. Please install bats manually:"
        log_error "  apt install bats  # Debian/Ubuntu"
        log_error "  brew install bats-core  # macOS"
        exit 1
    fi
}

# Make all scripts executable
prepare_scripts() {
    log_info "Preparing scripts..."

    # Make all shell scripts executable
    find "$PROJECT_ROOT" -name "*.sh" -exec chmod +x {} \;
    find "$SCRIPT_DIR/mocks" -type f -exec chmod +x {} \;

    log_info "Scripts prepared"
}

# Run syntax checks
run_syntax_checks() {
    log_info "Running syntax checks..."

    local errors=0

    for script in "$PROJECT_ROOT"/{build,installer,post-install}/*.sh; do
        if [[ -f "$script" ]]; then
            if ! bash -n "$script" 2>/dev/null; then
                log_error "Syntax error in: $script"
                ((errors++))
            fi
        fi
    done

    if [[ $errors -gt 0 ]]; then
        log_error "$errors script(s) have syntax errors"
        return 1
    fi

    log_info "All scripts have valid syntax"
}

# Run unit tests
run_unit_tests() {
    log_info "Running unit tests..."

    local test_dir="$SCRIPT_DIR/unit"

    if [[ ! -d "$test_dir" ]]; then
        log_warn "No unit tests found"
        return 0
    fi

    local test_files=("$test_dir"/*.bats)

    if [[ ${#test_files[@]} -eq 0 ]]; then
        log_warn "No .bats files found in $test_dir"
        return 0
    fi

    bats "${BATS_OPTS[@]}" "${test_files[@]}"
}

# Run integration tests
run_integration_tests() {
    log_info "Running integration tests..."

    local test_dir="$SCRIPT_DIR/integration"

    if [[ ! -d "$test_dir" ]]; then
        log_warn "No integration tests found"
        return 0
    fi

    local test_files=("$test_dir"/*.bats 2>/dev/null)

    if [[ ${#test_files[@]} -eq 0 ]] || [[ ! -f "${test_files[0]}" ]]; then
        log_warn "No .bats files found in $test_dir"
        return 0
    fi

    bats "${BATS_OPTS[@]}" "${test_files[@]}"
}

# Run all tests
run_all_tests() {
    local exit_code=0

    run_syntax_checks || exit_code=1
    run_unit_tests || exit_code=1
    run_integration_tests || exit_code=1

    return $exit_code
}

# Parse arguments
BATS_OPTS=()
TEST_TYPE="all"

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose)
            BATS_OPTS+=("--verbose-run")
            shift
            ;;
        -t|--tap)
            BATS_OPTS+=("--tap")
            shift
            ;;
        unit)
            TEST_TYPE="unit"
            shift
            ;;
        integration)
            TEST_TYPE="integration"
            shift
            ;;
        syntax)
            TEST_TYPE="syntax"
            shift
            ;;
        all)
            TEST_TYPE="all"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [options] [test-type]"
            echo ""
            echo "Options:"
            echo "  -v, --verbose    Verbose output"
            echo "  -t, --tap        TAP output format"
            echo "  -h, --help       Show this help"
            echo ""
            echo "Test types:"
            echo "  all              Run all tests (default)"
            echo "  unit             Run unit tests only"
            echo "  integration      Run integration tests only"
            echo "  syntax           Run syntax checks only"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Main
echo ""
echo -e "${BLUE}=========================================="
echo -e "  PVE Installer Test Suite"
echo -e "==========================================${NC}"
echo ""

check_bats
prepare_scripts

case $TEST_TYPE in
    all)
        run_all_tests
        ;;
    unit)
        run_unit_tests
        ;;
    integration)
        run_integration_tests
        ;;
    syntax)
        run_syntax_checks
        ;;
esac

exit_code=$?

echo ""
if [[ $exit_code -eq 0 ]]; then
    log_info "All tests passed!"
else
    log_error "Some tests failed"
fi

exit $exit_code
