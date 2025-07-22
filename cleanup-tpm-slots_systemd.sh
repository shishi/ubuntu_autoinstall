#!/usr/bin/env bash
set -euo pipefail

# TPM Slot Cleanup Script for systemd-cryptenroll
# This script safely removes duplicate TPM slots from LUKS devices
# It preserves one working TPM enrollment and all non-TPM slots

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

# Function to analyze TPM2 enrollments
analyze_tpm2_enrollments() {
    local device="$1"
    local -a tpm_slots=()
    local -a tpm_tokens=()
    
    # Parse LUKS dump for TPM2 tokens
    local in_tokens=false
    local current_token=""
    local current_keyslot=""
    
    while IFS= read -r line; do
        # Check if we're in the Tokens section
        if [[ "$line" =~ ^Tokens: ]]; then
            in_tokens=true
            continue
        elif [[ "$line" =~ ^[A-Z] ]] && [[ "$in_tokens" == "true" ]]; then
            # We've left the Tokens section
            in_tokens=false
            continue
        fi
        
        # Parse token information
        if [[ "$in_tokens" == "true" ]]; then
            if [[ "$line" =~ ^[[:space:]]+([0-9]+):[[:space:]]* ]]; then
                current_token="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ [[:space:]]+type:[[:space:]]+systemd-tpm2 ]]; then
                # Found a TPM2 token
                if [[ -n "$current_token" ]]; then
                    tpm_tokens+=("$current_token")
                fi
            elif [[ "$line" =~ [[:space:]]+Keyslot:[[:space:]]+([0-9]+) ]]; then
                current_keyslot="${BASH_REMATCH[1]}"
                if [[ -n "$current_token" ]] && [[ "${tpm_tokens[-1]}" == "$current_token" ]]; then
                    tpm_slots+=("$current_keyslot")
                fi
            fi
        fi
    done < <(cryptsetup luksDump "$device" 2>/dev/null)
    
    # Show findings to stderr so they don't affect the return value
    if [[ ${#tpm_slots[@]} -eq 0 ]]; then
        print_info "No TPM2 enrollments found" >&2
    elif [[ ${#tpm_slots[@]} -eq 1 ]]; then
        print_success "Found 1 TPM2 enrollment in slot ${tpm_slots[0]}" >&2
    else
        print_warning "Found ${#tpm_slots[@]} TPM2 enrollments in slots: ${tpm_slots[*]}" >&2
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
            
            # For already unlocked devices, check if the slot has valid TPM2 metadata
            if cryptsetup luksDump "$device" 2>/dev/null | grep -A20 "Keyslots:" | grep -E "^[[:space:]]+$slot:" >/dev/null; then
                print_success "Slot $slot exists and device is unlocked (assuming TPM2 works)"
                return 0
            else
                print_warning "Slot $slot not found"
                return 1
            fi
        fi
    done
    
    # Note: systemd-cryptenroll doesn't provide a direct unlock test like clevis
    # We can only verify the enrollment exists and assume it works
    print_info "Cannot directly test TPM2 unlock (systemd-cryptenroll limitation)"
    print_info "Slot $slot appears valid based on metadata"
    return 0
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
    
    # Get TPM slots from systemd-cryptenroll
    print_info "Analyzing TPM2 enrollments on $device..."
    local tpm_slots_str
    tpm_slots_str=$(analyze_tpm2_enrollments "$device")
    local -a tpm_slots=()
    if [[ -n "$tpm_slots_str" ]]; then
        IFS=' ' read -r -a tpm_slots <<< "$tpm_slots_str"
    fi
    
    if [[ ${#tpm_slots[@]} -le 1 ]]; then
        print_success "No duplicate TPM slots to clean up"
        return 0
    fi
    
    # For systemd-cryptenroll, we can't easily test which slots work
    # So we'll keep the most recent one (highest slot number)
    print_warning "Found ${#tpm_slots[@]} TPM2 enrollments"
    print_info "systemd-cryptenroll doesn't support testing individual slots"
    print_info "Will keep the most recent enrollment (highest slot number)"
    
    # Sort slots numerically and keep the highest
    local keep_slot
    keep_slot=$(printf '%s\n' "${tpm_slots[@]}" | sort -nr | head -1)
    print_success "Keeping TPM2 slot: $keep_slot"
    
    # Determine which slots to remove
    local -a slots_to_remove=()
    for slot in "${tpm_slots[@]}"; do
        if [[ "$slot" != "$keep_slot" ]]; then
            slots_to_remove+=("$slot")
        fi
    done
    
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
    
    # We need a password to remove slots
    print_info "Enter a password for $device to remove slots:"
    read -r -s -p "Password: " password
    echo
    
    # Remove slots
    local removed_count=0
    for slot in "${slots_to_remove[@]}"; do
        print_info "Removing TPM slot $slot..."
        if printf '%s' "$password" | cryptsetup luksKillSlot "$device" "$slot" 2>/dev/null; then
            print_success "Removed slot $slot"
            ((removed_count++))
        else
            print_error "Failed to remove slot $slot"
        fi
    done
    
    print_success "Cleanup complete. Removed $removed_count slots."
    
    # Show final state
    print_info "Final TPM2 enrollments:"
    local final_tpm_slots
    final_tpm_slots=$(analyze_tpm2_enrollments "$device")
    if [[ -z "$final_tpm_slots" ]]; then
        print_warning "  No TPM2 enrollments found"
    else
        print_success "  TPM2 slots: $final_tpm_slots"
    fi
    
    # Show systemd-cryptenroll status if available
    if command_exists systemd-cryptenroll; then
        print_info "systemd-cryptenroll status:"
        systemd-cryptenroll "$device" --tpm2-device=list 2>/dev/null | sed 's/^/  /' || true
    fi
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

Clean up duplicate TPM slots from LUKS devices (systemd-cryptenroll version).

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
    - Always keeps at least one TPM enrollment (most recent)
    - Never touches non-TPM key slots
    - Asks for confirmation before making changes
    - Requires password to remove slots
    - Supports dry-run mode to preview changes

NOTE:
    Unlike the Clevis version, systemd-cryptenroll doesn't support
    testing individual TPM slots. This script keeps the most recent
    enrollment (highest slot number) by default.

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
    
    print_info "TPM Slot Cleanup Utility (systemd-cryptenroll)"
    echo "=============================================="
    
    if [[ "$dry_run" == "true" ]]; then
        print_warning "Running in DRY RUN mode - no changes will be made"
    fi
    echo
    
    # Check prerequisites
    if ! command_exists systemd-cryptenroll; then
        print_warning "systemd-cryptenroll not found. Checking systemd version..."
        local systemd_version
        systemd_version=$(systemctl --version | head -1 | awk '{print $2}')
        if [[ "$systemd_version" -lt 248 ]]; then
            print_error "systemd version $systemd_version is too old. Version 248 or newer is required."
            exit 1
        fi
        print_error "systemd-cryptenroll is not available despite having systemd $systemd_version"
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