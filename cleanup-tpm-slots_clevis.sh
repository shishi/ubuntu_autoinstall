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
CYAN='\033[0;36m'
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

print_section() {
    echo
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}▶ $1${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
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

# Function to get detailed Clevis binding information
get_clevis_binding_details() {
    local device="$1"
    local slot="$2"
    local -A details
    
    # Get Clevis configuration for the slot
    local config
    config=$(clevis luks list -d "$device" 2>/dev/null | grep "^${slot}:" | sed "s/^${slot}: //")
    
    # Extract pin type
    if [[ "$config" =~ ^([^[:space:]]+) ]]; then
        details["pin"]="${BASH_REMATCH[1]}"
    fi
    
    # For TPM2 pins, try to extract PCR banks
    if [[ "${details[pin]}" == "tpm2" ]] && [[ "$config" =~ \{.*\} ]]; then
        local json_part="${BASH_REMATCH[0]}"
        # Try to extract pcr_ids
        if [[ "$json_part" =~ \"pcr_ids\":[[:space:]]*\"([^\"]+)\" ]]; then
            details["pcrs"]="${BASH_REMATCH[1]}"
        fi
    fi
    
    # Return details as formatted output
    for key in "${!details[@]}"; do
        echo "$key=${details[$key]}"
    done
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

# Function to display TPM slot information
display_tpm_slot_info() {
    local device="$1"
    shift
    local -a tpm_slots=("$@")
    
    print_section "TPM2 Binding Details for $device"
    
    # Display slot information in a table format
    printf "%-6s %-10s %-15s %-20s\n" "Slot" "Pin Type" "PCRs" "Status"
    printf "%s\n" "──────────────────────────────────────────────────────────────"
    
    for slot in "${tpm_slots[@]}"; do
        local -A details
        while IFS='=' read -r key value; do
            details["$key"]="$value"
        done < <(get_clevis_binding_details "$device" "$slot")
        
        local pin="${details[pin]:-unknown}"
        local pcrs="${details[pcrs]:-unknown}"
        local status="Unknown"
        
        # Test the slot to determine status
        if test_tpm_slot "$device" "$slot" >/dev/null 2>&1; then
            status="Working"
        else
            # Check if device is unlocked
            for mapped in /dev/mapper/*; do
                if [[ -b "$mapped" ]] && cryptsetup status "$(basename "$mapped")" 2>/dev/null | grep -q "$device"; then
                    status="Cannot test (device unlocked)"
                    break
                fi
            done
            if [[ "$status" == "Unknown" ]]; then
                status="Failed/TPM changed"
            fi
        fi
        
        printf "%-6s %-10s %-15s %-20s\n" "$slot" "$pin" "$pcrs" "$status"
    done
    
    echo
    
    # Additional information
    print_info "Additional Information:"
    
    # Show current PCR values for comparison
    if command_exists tpm2_pcrread; then
        echo
        print_info "Current PCR values (for reference):"
        tpm2_pcrread sha256:7 2>/dev/null | grep -A1 "sha256" | tail -1 | sed 's/^/  PCR[7]: /' || true
    fi
    
    # Show full Clevis bindings
    echo
    print_info "Full Clevis bindings:"
    clevis luks list -d "$device" 2>/dev/null | sed 's/^/  /' || print_info "  Unable to list bindings"
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
    
    print_section "TPM2 Slot Analysis for $device"
    
    # Get all slots
    local all_slots
    mapfile -t all_slots < <(get_luks_slots_info "$device")
    print_info "Total enabled key slots: ${#all_slots[@]} (${all_slots[*]})"
    
    # Get TPM slots from Clevis
    print_info "Analyzing Clevis bindings..."
    local tpm_slots_str
    tpm_slots_str=$(analyze_clevis_bindings "$device")
    local -a tpm_slots=()
    if [[ -n "$tpm_slots_str" ]]; then
        IFS=' ' read -r -a tpm_slots <<< "$tpm_slots_str"
    fi
    
    if [[ ${#tpm_slots[@]} -eq 0 ]]; then
        print_info "No TPM2 bindings found on this device"
        return 0
    elif [[ ${#tpm_slots[@]} -eq 1 ]]; then
        print_success "Only one TPM2 binding found (slot ${tpm_slots[0]})"
        print_info "No duplicates to clean up"
        return 0
    fi
    
    # Display detailed information
    display_tpm_slot_info "$device" "${tpm_slots[@]}"
    
    echo
    print_warning "Multiple TPM2 bindings detected!"
    print_info "Possible reasons for duplicates:"
    print_info "  • Re-enrollment after BIOS/firmware updates"
    print_info "  • Changed PCR policies"
    print_info "  • Testing or troubleshooting attempts"
    echo
    
    # Let user choose which slot to keep
    print_warning "Which TPM2 slot do you want to KEEP? (Others will be removed)"
    print_info "Available TPM2 slots: ${tpm_slots[*]}"
    print_info "Recommendation: Keep a working slot if available, or the most recently created slot"
    
    local keep_slot
    while true; do
        read -r -p "Enter slot number to keep: " keep_slot
        if [[ " ${tpm_slots[*]} " =~ " ${keep_slot} " ]]; then
            break
        else
            print_error "Invalid choice. Please select from: ${tpm_slots[*]}"
        fi
    done
    
    # Determine slots to remove
    local -a slots_to_remove=()
    for slot in "${tpm_slots[@]}"; do
        if [[ "$slot" != "$keep_slot" ]]; then
            slots_to_remove+=("$slot")
        fi
    done
    
    # Show removal plan
    echo
    print_section "Removal Plan"
    print_success "Will KEEP TPM2 slot: $keep_slot"
    print_warning "Will REMOVE TPM2 slots: ${slots_to_remove[*]}"
    
    # Dry run mode
    if [[ "$dry_run" == "true" ]]; then
        print_info "DRY RUN: No changes will be made"
        return 0
    fi
    
    # Final confirmation
    echo
    print_warning "⚠️  IMPORTANT: Make sure you have:"
    print_info "  • A working password for this device"
    print_info "  • Your recovery key saved securely"
    print_info "  • Tested that the TPM2 unlock works (or can reboot to test)"
    echo
    
    if ! confirm_action "Are you sure you want to remove the selected TPM2 slots?"; then
        print_info "Operation cancelled"
        return 0
    fi
    
    # Remove slots
    print_section "Removing TPM2 Slots"
    
    local removed_count=0
    for slot in "${slots_to_remove[@]}"; do
        print_info "Removing TPM2 slot $slot..."
        if clevis luks unbind -d "$device" -s "$slot" -f 2>/dev/null; then
            print_success "Removed slot $slot"
            ((removed_count++))
        else
            print_error "Failed to remove slot $slot"
            print_info "Possible reasons: slot is protected or already removed"
        fi
    done
    
    echo
    if [[ $removed_count -gt 0 ]]; then
        print_success "Cleanup complete. Removed $removed_count TPM2 slots."
    else
        print_warning "No slots were removed."
    fi
    
    # Show final state
    echo
    print_section "Final State"
    local final_tpm_slots
    final_tpm_slots=$(analyze_clevis_bindings "$device")
    if [[ -n "$final_tpm_slots" ]]; then
        print_info "Remaining TPM2 slots: $final_tpm_slots"
    else
        print_warning "No TPM2 bindings found (this shouldn't happen!)"
    fi
    
    # Show full Clevis bindings
    echo
    print_info "Final Clevis bindings:"
    clevis luks list -d "$device" 2>/dev/null | sed 's/^/  /' || print_warning "  No Clevis bindings found"
    
    # Remind about testing
    echo
    print_warning "⚠️  IMPORTANT: Test the TPM2 unlock on next reboot!"
    print_info "If TPM2 unlock fails, use your password or recovery key"
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
        if [[ ${#devices[@]} -gt 1 ]]; then
            read -r -p "Press Enter to continue to next device (or Ctrl+C to exit)..."
        fi
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

FEATURES:
    - Shows detailed information about each TPM2 binding
    - Displays PCR values and binding status
    - Allows user to choose which binding to keep
    - Shows current system PCR values for comparison
    - Requires confirmation before making changes
    - Supports dry-run mode to preview changes

SAFETY:
    - Always keep at least one authentication method
    - Test TPM2 unlock after making changes
    - Keep your recovery key accessible

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
    
    print_section "TPM2 Slot Cleanup Utility (Clevis)"
    
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
    print_success "Operation completed"
    
    if [[ "$dry_run" == "true" ]]; then
        print_info "This was a dry run. Run without --dry-run to make actual changes."
    fi
}

# Run main function
main "$@"