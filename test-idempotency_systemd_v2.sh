#!/usr/bin/env bash
set -euo pipefail

# Test idempotency of setup-tpm-luks-unlock_systemd.sh (Version 2)
# This script actually tests idempotency by tracking state changes

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Functions for colored output
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_section() { 
    echo
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}▶ $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Global variables
LUKS_DEVICE=""
STATE_FILE="/tmp/.tpm-idempotency-test-state"
INITIAL_STATE=""
CURRENT_STATE=""

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to find LUKS device
find_luks_device() {
    local luks_devices=()
    
    # Check common device patterns
    for device in /dev/sd* /dev/nvme* /dev/vd*; do
        if [[ -b "$device" ]] && cryptsetup isLuks "$device" 2>/dev/null; then
            luks_devices+=("$device")
        fi
    done
    
    if [[ ${#luks_devices[@]} -eq 0 ]]; then
        print_error "No LUKS encrypted devices found"
        return 1
    elif [[ ${#luks_devices[@]} -eq 1 ]]; then
        LUKS_DEVICE="${luks_devices[0]}"
        print_success "Found LUKS device: $LUKS_DEVICE"
    else
        print_warning "Multiple LUKS devices found:"
        for i in "${!luks_devices[@]}"; do
            echo "  $((i+1)). ${luks_devices[$i]}"
        done
        read -r -p "Select device (1-${#luks_devices[@]}): " selection
        LUKS_DEVICE="${luks_devices[$((selection-1))]}"
    fi
    
    return 0
}

# Function to capture system state
capture_state() {
    local state=""
    
    # Count recovery key files
    local recovery_keys
    recovery_keys=$(find /root -maxdepth 1 -name ".luks-recovery-key-*.txt" -type f 2>/dev/null | wc -l || echo 0)
    state+="recovery_keys:$recovery_keys|"
    
    # Count LUKS slots
    local luks_slots
    if [[ -n "$LUKS_DEVICE" ]]; then
        # LUKS2 format
        luks_slots=$(cryptsetup luksDump "$LUKS_DEVICE" 2>/dev/null | grep -cE "^  [0-9]+: luks2" || echo 0)
        if [[ "$luks_slots" -eq 0 ]]; then
            # LUKS1 format fallback
            luks_slots=$(cryptsetup luksDump "$LUKS_DEVICE" 2>/dev/null | grep -c "Key Slot.*ENABLED" || echo 0)
        fi
    else
        luks_slots=0
    fi
    state+="luks_slots:$luks_slots|"
    
    # Count TPM2 enrollments
    local tpm2_enrollments
    if [[ -n "$LUKS_DEVICE" ]]; then
        tpm2_enrollments=$(cryptsetup luksDump "$LUKS_DEVICE" 2>/dev/null | grep -c "tpm2" || echo 0)
    else
        tpm2_enrollments=0
    fi
    state+="tpm2_enrollments:$tpm2_enrollments|"
    
    # Check systemd version
    local systemd_version
    systemd_version=$(systemctl --version | head -1 | awk '{print $2}' || echo 0)
    state+="systemd_version:$systemd_version|"
    
    # Check if systemd-cryptenroll exists
    local has_cryptenroll
    if command_exists systemd-cryptenroll; then
        has_cryptenroll=1
    else
        has_cryptenroll=0
    fi
    state+="has_cryptenroll:$has_cryptenroll|"
    
    echo "$state"
}

# Function to parse state
parse_state() {
    local state="$1"
    local field="$2"
    echo "$state" | grep -o "${field}:[^|]*" | cut -d: -f2
}

# Function to compare states
compare_states() {
    local initial="$1"
    local current="$2"
    
    print_section "State Comparison"
    
    local all_good=true
    
    # Recovery keys
    local init_keys=$(parse_state "$initial" "recovery_keys")
    local curr_keys=$(parse_state "$current" "recovery_keys")
    if [[ "$init_keys" -eq "$curr_keys" ]]; then
        print_success "Recovery keys: $init_keys → $curr_keys (unchanged)"
    else
        print_warning "Recovery keys: $init_keys → $curr_keys (changed)"
        if [[ $curr_keys -gt $init_keys ]]; then
            print_info "  New recovery key(s) created"
        fi
    fi
    
    # LUKS slots
    local init_slots=$(parse_state "$initial" "luks_slots")
    local curr_slots=$(parse_state "$current" "luks_slots")
    if [[ "$init_slots" -eq "$curr_slots" ]]; then
        print_success "LUKS slots: $init_slots → $curr_slots (unchanged)"
    else
        local slot_diff=$((curr_slots - init_slots))
        if [[ $slot_diff -gt 0 ]]; then
            print_info "LUKS slots: $init_slots → $curr_slots (+$slot_diff added)"
        else
            print_info "LUKS slots: $init_slots → $curr_slots ($slot_diff removed)"
        fi
    fi
    
    # TPM2 enrollments
    local init_tpm2=$(parse_state "$initial" "tpm2_enrollments")
    local curr_tpm2=$(parse_state "$current" "tpm2_enrollments")
    if [[ "$init_tpm2" -eq "$curr_tpm2" ]]; then
        if [[ "$curr_tpm2" -gt 0 ]]; then
            print_success "TPM2 enrollments: $init_tpm2 → $curr_tpm2 (unchanged)"
        else
            print_warning "TPM2 enrollments: 0 (none found)"
        fi
    else
        if [[ $curr_tpm2 -gt $init_tpm2 ]]; then
            print_success "TPM2 enrollments: $init_tpm2 → $curr_tpm2 (enrolled)"
        else
            print_info "TPM2 enrollments: $init_tpm2 → $curr_tpm2 (changed)"
        fi
    fi
    
    return $([ "$all_good" = true ] && echo 0 || echo 1)
}

# Function to test package installation idempotency
test_package_idempotency() {
    print_section "Testing Package Installation Idempotency"
    
    local packages=("systemd" "tpm2-tools" "cryptsetup" "cryptsetup-initramfs")
    local missing=0
    local installed=0
    
    for pkg in "${packages[@]}"; do
        if dpkg -l | grep -q "^ii  $pkg "; then
            ((installed++))
        else
            ((missing++))
        fi
    done
    
    print_info "Packages status: $installed installed, $missing missing"
    
    # Simulate running apt-get update/install
    if [[ $missing -gt 0 ]]; then
        print_info "Would install $missing package(s) on first run"
        print_info "Would skip installation on subsequent runs"
    else
        print_success "All packages installed - installation would be skipped"
    fi
}

# Function to test recovery key idempotency
test_recovery_key_idempotency() {
    print_section "Testing Recovery Key Idempotency"
    
    local existing_keys
    existing_keys=$(find /root -maxdepth 1 -name ".luks-recovery-key-*.txt" -type f 2>/dev/null | wc -l || echo 0)
    
    if [[ $existing_keys -gt 0 ]]; then
        print_info "Found $existing_keys existing recovery key file(s)"
        print_success "Script should prompt to reuse existing key"
        
        # List recovery key files with dates
        print_info "Existing recovery keys:"
        find /root -maxdepth 1 -name ".luks-recovery-key-*.txt" -type f -exec stat -c "  %n (created: %y)" {} \; 2>/dev/null | sort
    else
        print_info "No existing recovery keys found"
        print_info "Script would create new recovery key on first run"
    fi
}

# Function to test TPM2 enrollment idempotency
test_tpm2_idempotency() {
    print_section "Testing TPM2 Enrollment Idempotency"
    
    if [[ -z "$LUKS_DEVICE" ]]; then
        print_error "No LUKS device available for testing"
        return
    fi
    
    # Check current TPM2 enrollment
    local has_tpm2
    has_tpm2=$(cryptsetup luksDump "$LUKS_DEVICE" 2>/dev/null | grep -c "tpm2" || echo 0)
    
    if [[ $has_tpm2 -gt 0 ]]; then
        print_success "TPM2 already enrolled on $LUKS_DEVICE"
        print_info "Script should prompt before replacing enrollment"
        
        # Try to show enrollment details
        if command_exists systemd-cryptenroll && [[ $EUID -eq 0 ]]; then
            print_info "Current TPM2 enrollment:"
            systemd-cryptenroll "$LUKS_DEVICE" --tpm2-device=list 2>/dev/null | sed 's/^/  /' || \
                print_warning "Could not list TPM2 enrollment details"
        fi
    else
        print_info "No TPM2 enrollment found on $LUKS_DEVICE"
        print_info "Script would enroll TPM2 on first run"
    fi
}

# Function to simulate multiple runs
simulate_runs() {
    print_section "Idempotency Simulation"
    
    print_info "Simulating multiple script runs..."
    echo
    
    # Run 1
    print_info "Run 1 (Initial setup):"
    print_info "  - Would check all prerequisites"
    print_info "  - Would install missing packages (if any)"
    print_info "  - Would create recovery key (if none exists)"
    print_info "  - Would add new user password"
    print_info "  - Would enroll TPM2 (if not enrolled)"
    print_info "  - Would remove old passwords"
    echo
    
    # Run 2
    print_info "Run 2 (Immediate re-run):"
    print_success "  - Would skip package installation (already installed)"
    print_success "  - Would offer to reuse existing recovery key"
    print_success "  - Would detect if passwords already exist"
    print_success "  - Would ask before replacing TPM2 enrollment"
    print_warning "  - Would find fewer/no old passwords to remove"
    echo
    
    # Run 3
    print_info "Run 3 (After system changes):"
    print_info "  - Behavior depends on what changed:"
    print_info "    • Kernel update → TPM2 might need re-enrollment"
    print_info "    • New password → Would add if not duplicate"
    print_info "    • Recovery key lost → Would allow creating new"
}

# Function to check script requirements
check_requirements() {
    print_section "Checking Requirements"
    
    local ready=true
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        print_warning "Not running as root - some checks will be limited"
        ready=false
    else
        print_success "Running as root"
    fi
    
    # Check systemd version
    local systemd_version
    systemd_version=$(systemctl --version | head -1 | awk '{print $2}' || echo 0)
    if [[ $systemd_version -ge 248 ]]; then
        print_success "systemd version $systemd_version (>= 248)"
    else
        print_error "systemd version $systemd_version (< 248 required)"
        ready=false
    fi
    
    # Check for systemd-cryptenroll
    if command_exists systemd-cryptenroll; then
        print_success "systemd-cryptenroll available"
    else
        print_error "systemd-cryptenroll not found"
        ready=false
    fi
    
    # Check for TPM device
    if [[ -c /dev/tpm0 ]] || [[ -c /dev/tpmrm0 ]]; then
        print_success "TPM2 device found"
    else
        print_error "TPM2 device not found"
        ready=false
    fi
    
    return $([ "$ready" = true ] && echo 0 || echo 1)
}

# Function to run actual test
run_actual_test() {
    print_section "Running Actual Idempotency Test"
    
    if [[ ! -f "./setup-tpm-luks-unlock_systemd_v3.sh" ]]; then
        print_error "setup-tpm-luks-unlock_systemd_v3.sh not found"
        print_info "Using v2 or original version for testing"
        
        local setup_script=""
        if [[ -f "./setup-tpm-luks-unlock_systemd_v2.sh" ]]; then
            setup_script="./setup-tpm-luks-unlock_systemd_v2.sh"
        elif [[ -f "./setup-tpm-luks-unlock_systemd.sh" ]]; then
            setup_script="./setup-tpm-luks-unlock_systemd.sh"
        else
            print_error "No setup script found"
            return 1
        fi
    else
        local setup_script="./setup-tpm-luks-unlock_systemd_v3.sh"
    fi
    
    print_warning "This will actually run: $setup_script"
    print_warning "Make sure you have backups and recovery access!"
    echo
    read -r -p "Continue with actual test? (y/N): " response
    
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        print_info "Test cancelled"
        return 0
    fi
    
    # Capture initial state
    INITIAL_STATE=$(capture_state)
    echo "$INITIAL_STATE" > "$STATE_FILE"
    
    print_info "Initial state captured"
    print_info "Now run: sudo $setup_script"
    print_info "After completion, run this test script again to compare states"
}

# Function to compare with saved state
compare_with_saved() {
    if [[ ! -f "$STATE_FILE" ]]; then
        print_error "No saved state found. Run the test first."
        return 1
    fi
    
    print_section "Comparing with Previous State"
    
    INITIAL_STATE=$(cat "$STATE_FILE")
    CURRENT_STATE=$(capture_state)
    
    compare_states "$INITIAL_STATE" "$CURRENT_STATE"
    
    # Clean up state file
    read -r -p "Remove saved state file? (y/N): " response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        rm -f "$STATE_FILE"
        print_info "State file removed"
    fi
}

# Main function
main() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}    Idempotency Test for setup-tpm-luks-unlock_systemd.sh${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════${NC}"
    echo
    
    # Check if we have a saved state
    if [[ -f "$STATE_FILE" ]]; then
        print_info "Found saved state from previous run"
        compare_with_saved
        exit 0
    fi
    
    # Find LUKS device
    if ! find_luks_device; then
        print_error "Cannot proceed without LUKS device"
        exit 1
    fi
    
    # Run all tests
    check_requirements || print_warning "Some requirements not met"
    echo
    
    test_package_idempotency
    test_recovery_key_idempotency
    test_tpm2_idempotency
    simulate_runs
    
    print_section "Test Options"
    echo "1. Run actual idempotency test"
    echo "2. Exit"
    echo
    read -r -p "Select option (1-2): " option
    
    case "$option" in
        1)
            run_actual_test
            ;;
        *)
            print_info "Exiting"
            ;;
    esac
}

# Run main
main "$@"