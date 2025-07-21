#!/usr/bin/env bash
set -euo pipefail

# TPM Slot Cleanup Script
# This script safely removes duplicate TPM slots from LUKS devices
# It preserves one working TPM binding and all non-TPM slots

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root"
   exit 1
fi

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Safety check function
confirm_action() {
    local prompt="$1"
    local response
    
    echo -e "${YELLOW}$prompt${NC}"
    read -r -p "Type 'yes' to continue, anything else to skip: " response
    
    if [[ "$response" == "yes" ]]; then
        return 0
    else
        return 1
    fi
}

# Function to find LUKS devices
find_luks_devices() {
    local luks_devices=()
    
    for device in /dev/sd* /dev/nvme* /dev/vd* /dev/mapper/*; do
        if [[ -b "$device" ]] && cryptsetup isLuks "$device" 2>/dev/null; then
            luks_devices+=("$device")
        fi
    done
    
    echo "${luks_devices[@]}"
}

# Function to analyze Clevis bindings
analyze_clevis_bindings() {
    local device="$1"
    local -a tpm_slots=()
    local -a other_slots=()
    
    # Get Clevis bindings
    if ! command_exists clevis; then
        print_error "Clevis not installed" >&2
        return 1
    fi
    
    # Parse Clevis slots
    local clevis_output
    clevis_output=$(clevis luks list -d "$device" 2>/dev/null || true)
    
    # Clevis output format: "1: tpm2 '{...}'"
    while IFS= read -r line; do
        if [[ "$line" =~ ^([0-9]+):[[:space:]]*([^[:space:]]+) ]]; then
            local slot="${BASH_REMATCH[1]}"
            local pin="${BASH_REMATCH[2]}"
            
            if [[ "$pin" == "tpm2" ]]; then
                tpm_slots+=("$slot")
            else
                other_slots+=("$slot")
            fi
        fi
    done <<< "$clevis_output"
    
    # Show findings to stderr so they don't affect the return value
    if [[ ${#tpm_slots[@]} -eq 0 ]]; then
        print_info "No TPM2 Clevis bindings found" >&2
    elif [[ ${#tpm_slots[@]} -eq 1 ]]; then
        print_success "Found 1 TPM2 binding in slot ${tpm_slots[0]}" >&2
    else
        print_warning "Found ${#tpm_slots[@]} TPM2 bindings in slots: ${tpm_slots[*]}" >&2
    fi
    
    if [[ ${#other_slots[@]} -gt 0 ]]; then
        print_info "Found non-TPM Clevis bindings in slots: ${other_slots[*]}" >&2
    fi
    
    # Return ONLY TPM slots as a string to stdout
    echo "${tpm_slots[*]}"
}

# Function to test a TPM slot
test_tpm_slot() {
    local device="$1"
    local slot="$2"
    
    print_info "Testing TPM2 slot $slot..."
    
    # Check if device is already unlocked (e.g., root device)
    local mapper_name=""
    
    # Find if this device is already mapped
    for mapped in /dev/mapper/*; do
        if [[ -b "$mapped" ]] && cryptsetup status "$(basename "$mapped")" 2>/dev/null | grep -q "$device"; then
            mapper_name=$(basename "$mapped")
            print_info "Device is already unlocked as /dev/mapper/$mapper_name"
            
            # For already unlocked devices, check if the slot has valid Clevis metadata
            if clevis luks list -d "$device" 2>/dev/null | grep -q "^${slot}:.*tpm2"; then
                print_success "Slot $slot has valid TPM2 binding (device already unlocked)"
                return 0
            else
                print_warning "Slot $slot metadata check failed"
                return 1
            fi
        fi
    done
    
    # Device not unlocked, try normal test
    if clevis luks unlock -d "$device" -s "$slot" -n "test_unlock_$$" 2>/dev/null; then
        # Clean up test unlock
        cryptsetup close "test_unlock_$$" 2>/dev/null || true
        print_success "Slot $slot is working"
        return 0
    else
        print_warning "Slot $slot failed to unlock (this is normal if TPM state changed or device is in use)"
        return 1
    fi
}

# Function to get all LUKS slots info
get_luks_slots_info() {
    local device="$1"
    local -a enabled_slots=()
    
    # Check LUKS version
    local luks_version
    luks_version=$(cryptsetup luksDump "$device" 2>/dev/null | grep "^Version:" | awk '{print $2}')
    
    if [[ "$luks_version" == "2" ]]; then
        # LUKS2 format - parse JSON-like structure
        while IFS=: read -r slot _; do
            if [[ "$slot" =~ ^[[:space:]]*([0-9]+)$ ]]; then
                enabled_slots+=("${BASH_REMATCH[1]}")
            fi
        done < <(cryptsetup luksDump "$device" 2>/dev/null | sed -n '/^Keyslots:/,/^[A-Z]/p' | grep -E "^[[:space:]]+[0-9]+: luks2")
    else
        # LUKS1 format - use old method
        for i in {0..7}; do
            if cryptsetup luksDump "$device" 2>/dev/null | grep -q "Key Slot $i: ENABLED"; then
                enabled_slots+=("$i")
            fi
        done
    fi
    
    echo "${enabled_slots[*]}"
}

# Function to remove duplicate TPM slots
cleanup_device() {
    local device="$1"
    local dry_run="${2:-false}"
    
    print_info "Processing device: $device"
    echo "----------------------------------------"
    
    # Get all slots
    local all_slots
    mapfile -t all_slots < <(get_luks_slots_info "$device")
    print_info "Total enabled key slots: ${#all_slots[@]} (${all_slots[*]})"
    
    # Get TPM slots from Clevis
    print_info "Analyzing Clevis bindings on $device..."
    local tpm_slots_str
    tpm_slots_str=$(analyze_clevis_bindings "$device")
    local -a tpm_slots=()
    if [[ -n "$tpm_slots_str" ]]; then
        IFS=' ' read -r -a tpm_slots <<< "$tpm_slots_str"
    fi
    
    if [[ ${#tpm_slots[@]} -le 1 ]]; then
        print_success "No duplicate TPM slots to clean up"
        return 0
    fi
    
    # Test which TPM slots work
    local -a working_slots=()
    local -a broken_slots=()
    
    for slot in "${tpm_slots[@]}"; do
        if test_tpm_slot "$device" "$slot"; then
            working_slots+=("$slot")
        else
            broken_slots+=("$slot")
        fi
    done
    
    print_info "Summary:"
    print_info "  Working TPM slots: ${#working_slots[@]} (${working_slots[*]:-none})"
    print_info "  Non-working TPM slots: ${#broken_slots[@]} (${broken_slots[*]:-none})"
    
    # Determine which slots to remove
    local -a slots_to_remove=()
    
    # If we have working slots, keep only the first one
    if [[ ${#working_slots[@]} -gt 0 ]]; then
        local keep_slot="${working_slots[0]}"
        print_success "Keeping working TPM slot: $keep_slot"
        
        # Mark other working slots for removal
        for slot in "${working_slots[@]:1}"; do
            slots_to_remove+=("$slot")
        done
        
        # Mark all broken slots for removal
        slots_to_remove+=("${broken_slots[@]}")
    else
        # No working slots, remove all but the most recent
        print_warning "No working TPM slots found. This might be due to TPM state change."
        if [[ ${#tpm_slots[@]} -gt 0 ]]; then
            # Keep the highest numbered slot (usually most recent)
            local keep_slot="${tpm_slots[-1]}"
            print_info "Keeping most recent TPM slot: $keep_slot"
            
            # Mark others for removal
            for slot in "${tpm_slots[@]::${#tpm_slots[@]}-1}"; do
                slots_to_remove+=("$slot")
            done
        fi
    fi
    
    # Show plan
    if [[ ${#slots_to_remove[@]} -eq 0 ]]; then
        print_success "No slots need to be removed"
        return 0
    fi
    
    print_warning "Slots to be removed: ${slots_to_remove[*]}"
    
    # Dry run mode
    if [[ "$dry_run" == "true" ]]; then
        print_info "DRY RUN: No changes will be made"
        return 0
    fi
    
    # Confirm action
    if ! confirm_action "Do you want to remove these duplicate TPM slots?"; then
        print_info "Skipping cleanup for $device"
        return 0
    fi
    
    # Remove slots
    local removed_count=0
    for slot in "${slots_to_remove[@]}"; do
        print_info "Removing TPM slot $slot..."
        if clevis luks unbind -d "$device" -s "$slot" -f 2>/dev/null; then
            print_success "Removed slot $slot"
            ((removed_count++))
        else
            print_error "Failed to remove slot $slot"
        fi
    done
    
    print_success "Cleanup complete. Removed $removed_count slots."
    
    # Show final state
    print_info "Final Clevis bindings:"
    clevis luks list -d "$device" 2>/dev/null | sed 's/^/  /' || print_warning "  No Clevis bindings found"
}

# Function to cleanup all devices
cleanup_all_devices() {
    local dry_run="${1:-false}"
    local devices
    mapfile -t devices < <(find_luks_devices)
    
    if [[ ${#devices[@]} -eq 0 ]]; then
        print_warning "No LUKS devices found"
        return 1
    fi
    
    print_info "Found ${#devices[@]} LUKS device(s)"
    echo
    
    for device in "${devices[@]}"; do
        cleanup_device "$device" "$dry_run"
        echo
    done
}

# Function to show usage
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] [DEVICE]

Clean up duplicate TPM slots from LUKS devices.

OPTIONS:
    -d, --dry-run     Show what would be done without making changes
    -h, --help        Show this help message
    -a, --all         Process all LUKS devices (default if no device specified)

DEVICE:
    Specific LUKS device to clean (e.g., /dev/sda3, /dev/nvme0n1p3)

EXAMPLES:
    $0                    # Clean all LUKS devices (interactive)
    $0 --dry-run          # Show what would be cleaned without changes
    $0 /dev/sda3          # Clean specific device
    $0 -d /dev/nvme0n1p3  # Dry run on specific device

SAFETY FEATURES:
    - Always keeps at least one TPM binding (preferably working)
    - Never touches non-TPM key slots
    - Asks for confirmation before making changes
    - Tests TPM slots before deciding what to keep
    - Supports dry-run mode to preview changes

EOF
}

# Main function
main() {
    local dry_run=false
    local device=""
    # local all_devices=false  # Reserved for future use
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--dry-run)
                dry_run=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            -a|--all)
                # all_devices=true  # Currently unused, keeping for future use
                shift
                ;;
            -*)
                print_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
            *)
                device="$1"
                shift
                ;;
        esac
    done
    
    print_info "TPM Slot Cleanup Utility"
    echo "========================"
    
    if [[ "$dry_run" == "true" ]]; then
        print_warning "Running in DRY RUN mode - no changes will be made"
    fi
    echo
    
    # Check prerequisites
    if ! command_exists clevis; then
        print_error "Clevis is not installed. Please install clevis package first."
        exit 1
    fi
    
    if ! command_exists cryptsetup; then
        print_error "cryptsetup is not installed. Please install cryptsetup package first."
        exit 1
    fi
    
    # Process device(s)
    if [[ -n "$device" ]]; then
        # Specific device
        if [[ ! -b "$device" ]]; then
            print_error "Device $device does not exist or is not a block device"
            exit 1
        fi
        
        if ! cryptsetup isLuks "$device" 2>/dev/null; then
            print_error "Device $device is not a LUKS device"
            exit 1
        fi
        
        cleanup_device "$device" "$dry_run"
    else
        # All devices
        cleanup_all_devices "$dry_run"
    fi
    
    echo
    print_success "Cleanup process completed"
    
    if [[ "$dry_run" == "true" ]]; then
        print_info "This was a dry run. Run without --dry-run to make actual changes."
    fi
}

# Run main function
main "$@"