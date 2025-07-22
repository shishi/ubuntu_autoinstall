#!/usr/bin/env bash
set -euo pipefail

# Password Duplicate Cleanup Script for Clevis environments
# This script detects and removes duplicate password entries from LUKS devices
# It allows users to check for specific password duplicates

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

# Function to get all LUKS slots info including type
get_luks_slots_detailed() {
    local device="$1"
    local -a slot_info=()
    
    # Get LUKS version
    local luks_version
    luks_version=$(cryptsetup luksDump "$device" 2>/dev/null | grep "^Version:" | awk '{print $2}')
    
    # Get Clevis bindings if available
    local clevis_slots=""
    if command_exists clevis; then
        clevis_slots=$(clevis luks list -d "$device" 2>/dev/null || true)
    fi
    
    if [[ "$luks_version" == "2" ]]; then
        # LUKS2 format
        local in_keyslots=false
        local current_slot=""
        
        while IFS= read -r line; do
            if [[ "$line" =~ ^Keyslots: ]]; then
                in_keyslots=true
            elif [[ "$line" =~ ^[A-Z] ]] && [[ "$in_keyslots" == "true" ]]; then
                in_keyslots=false
            elif [[ "$in_keyslots" == "true" ]] && [[ "$line" =~ ^[[:space:]]+([0-9]+):[[:space:]]*luks2 ]]; then
                current_slot="${BASH_REMATCH[1]}"
                
                # Determine slot type
                local slot_type="password"
                if echo "$clevis_slots" | grep -q "^$current_slot:"; then
                    slot_type="clevis"
                fi
                
                slot_info+=("$current_slot:$slot_type")
            fi
        done < <(cryptsetup luksDump "$device" 2>/dev/null)
    else
        # LUKS1 format
        for i in {0..7}; do
            if cryptsetup luksDump "$device" 2>/dev/null | grep -q "Key Slot $i: ENABLED"; then
                local slot_type="password"
                if echo "$clevis_slots" | grep -q "^$i:"; then
                    slot_type="clevis"
                fi
                slot_info+=("$i:$slot_type")
            fi
        done
    fi
    
    printf '%s\n' "${slot_info[@]}"
}

# Function to test password on specific slots
test_password_on_slots() {
    local device="$1"
    local password="$2"
    local -a matching_slots=()
    
    # Get all slots with their types
    local -a slot_info
    mapfile -t slot_info < <(get_luks_slots_detailed "$device")
    
    for info in "${slot_info[@]}"; do
        local slot="${info%%:*}"
        local type="${info##*:}"
        
        # Only test password slots (not Clevis-managed slots)
        if [[ "$type" == "password" ]]; then
            if printf '%s' "$password" | cryptsetup luksOpen --test-passphrase "$device" --key-slot "$slot" 2>/dev/null; then
                matching_slots+=("$slot")
            fi
        fi
    done
    
    echo "${matching_slots[@]}"
}

# Function to display slot information
display_slot_info() {
    local device="$1"
    local -a slots=("${@:2}")
    
    print_section "Slot Details for $device"
    
    # Show all slots first
    print_info "All key slots:"
    cryptsetup luksDump "$device" 2>/dev/null | grep -E "^Key Slot|^  [0-9]+: luks2" | head -20
    
    # Show Clevis bindings if available
    if command_exists clevis; then
        echo
        print_info "Clevis bindings:"
        clevis luks list -d "$device" 2>/dev/null || print_info "  No Clevis bindings found"
    fi
    
    # Highlight matching slots
    if [[ ${#slots[@]} -gt 0 ]]; then
        echo
        print_warning "Password matches found in slots: ${slots[*]}"
    fi
}

# Function to cleanup duplicate passwords
cleanup_password_duplicates() {
    local device="$1"
    local dry_run="${2:-false}"
    
    print_section "Password Duplicate Detection for $device"
    
    # Get password to check
    print_info "Enter the password you want to check for duplicates:"
    print_info "(This password will be tested against all password slots)"
    read -r -s -p "Password to check: " check_password
    echo
    echo
    
    # Test password on all slots
    print_info "Checking password against all slots..."
    local matching_slots_str
    matching_slots_str=$(test_password_on_slots "$device" "$check_password")
    
    local -a matching_slots=()
    if [[ -n "$matching_slots_str" ]]; then
        IFS=' ' read -r -a matching_slots <<< "$matching_slots_str"
    fi
    
    if [[ ${#matching_slots[@]} -eq 0 ]]; then
        print_error "The provided password does not match any slots"
        return 1
    elif [[ ${#matching_slots[@]} -eq 1 ]]; then
        print_success "Password found in only one slot: ${matching_slots[0]}"
        print_info "No duplicates to remove"
        return 0
    fi
    
    # Display duplicate information
    print_warning "Password duplicates found!"
    display_slot_info "$device" "${matching_slots[@]}"
    
    echo
    print_info "Summary:"
    print_info "  Total matching slots: ${#matching_slots[@]}"
    print_info "  Slots with this password: ${matching_slots[*]}"
    
    # Ask which slot to keep
    echo
    print_warning "Which slot do you want to KEEP? (Others will be removed)"
    print_info "Available slots: ${matching_slots[*]}"
    
    local keep_slot
    while true; do
        read -r -p "Enter slot number to keep: " keep_slot
        if [[ " ${matching_slots[*]} " =~ " ${keep_slot} " ]]; then
            break
        else
            print_error "Invalid choice. Please select from: ${matching_slots[*]}"
        fi
    done
    
    # Determine slots to remove
    local -a slots_to_remove=()
    for slot in "${matching_slots[@]}"; do
        if [[ "$slot" != "$keep_slot" ]]; then
            slots_to_remove+=("$slot")
        fi
    done
    
    # Show removal plan
    echo
    print_section "Removal Plan"
    print_success "Will KEEP slot: $keep_slot"
    print_warning "Will REMOVE slots: ${slots_to_remove[*]}"
    
    # Dry run mode
    if [[ "$dry_run" == "true" ]]; then
        print_info "DRY RUN: No changes will be made"
        return 0
    fi
    
    # Final confirmation
    echo
    if ! confirm_action "Are you sure you want to remove the duplicate slots?"; then
        print_info "Operation cancelled"
        return 0
    fi
    
    # Remove duplicate slots
    print_section "Removing Duplicate Slots"
    
    local removed_count=0
    for slot in "${slots_to_remove[@]}"; do
        print_info "Removing slot $slot..."
        if printf '%s' "$check_password" | cryptsetup luksKillSlot "$device" "$slot" 2>/dev/null; then
            print_success "Removed slot $slot"
            ((removed_count++))
        else
            print_error "Failed to remove slot $slot"
        fi
    done
    
    echo
    print_success "Cleanup complete. Removed $removed_count duplicate slots."
    
    # Show final state
    echo
    print_section "Final State"
    cryptsetup luksDump "$device" 2>/dev/null | grep -E "^Key Slot|^  [0-9]+: luks2" | head -20
}

# Function to process all devices
process_all_devices() {
    local dry_run="${1:-false}"
    local devices
    mapfile -t devices < <(find_luks_devices)
    
    if [[ ${#devices[@]} -eq 0 ]]; then
        print_error "No LUKS devices found"
        return 1
    fi
    
    print_info "Found ${#devices[@]} LUKS device(s)"
    
    for device in "${devices[@]}"; do
        echo
        cleanup_password_duplicates "$device" "$dry_run"
        echo
        read -r -p "Press Enter to continue to next device (or Ctrl+C to exit)..."
    done
}

# Function to show usage
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] [DEVICE]

Remove duplicate password entries from LUKS devices.

OPTIONS:
    -d, --dry-run     Show what would be done without making changes
    -h, --help        Show this help message
    -a, --all         Process all LUKS devices (default if no device specified)

DEVICE:
    Specific LUKS device to clean (e.g., /dev/sda3, /dev/nvme0n1p3)

EXAMPLES:
    $0                    # Check all devices for password duplicates
    $0 --dry-run          # Dry run on all devices
    $0 /dev/sda3          # Check specific device
    $0 -d /dev/nvme0n1p3  # Dry run on specific device

SAFETY FEATURES:
    - Shows all duplicate slots before removal
    - Requires user to choose which slot to keep
    - Asks for confirmation before making changes
    - Only removes password slots (preserves Clevis bindings)
    - Supports dry-run mode

NOTE:
    This script only checks regular password slots.
    Clevis-managed slots (TPM, Tang, etc.) are ignored.

EOF
}

# Main function
main() {
    local dry_run=false
    local device=""
    
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
    
    print_section "Password Duplicate Cleanup Utility"
    
    if [[ "$dry_run" == "true" ]]; then
        print_warning "Running in DRY RUN mode - no changes will be made"
    fi
    
    # Check prerequisites
    if ! command_exists cryptsetup; then
        print_error "cryptsetup is not installed"
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
        
        cleanup_password_duplicates "$device" "$dry_run"
    else
        # All devices
        process_all_devices "$dry_run"
    fi
    
    echo
    print_success "Operation completed"
}

# Run main function
main "$@"