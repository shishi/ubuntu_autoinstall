#!/usr/bin/env bash
set -euo pipefail

# Password Duplicate Cleanup Script for systemd-cryptenroll (Version 4)
# Fixed flow with proper variable scoping and error handling

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

# Global configuration
AUDIT_LOG="/var/log/luks-cleanup-audit.log"
BACKUP_DIR="/var/backups/luks-cleanup"
DRY_RUN=false
VERBOSE=false

# Initialize environment
init_environment() {
    # Check root
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi
    
    # Create directories
    [[ ! -d "$BACKUP_DIR" ]] && mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
    [[ ! -f "$AUDIT_LOG" ]] && touch "$AUDIT_LOG" && chmod 600 "$AUDIT_LOG"
    
    # Check cryptsetup
    if ! command -v cryptsetup >/dev/null 2>&1; then
        print_error "cryptsetup not installed"
        exit 1
    fi
}

# Log action to audit log
log_action() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1: $2" >> "$AUDIT_LOG"
}

# Backup device information
backup_device_info() {
    local device="$1"
    local backup_file="$BACKUP_DIR/luks-$(basename "$device")-$(date +%Y%m%d-%H%M%S).info"
    
    {
        echo "# LUKS Device: $device"
        echo "# Date: $(date)"
        echo
        cryptsetup luksDump "$device" 2>/dev/null
    } > "$backup_file"
    
    chmod 600 "$backup_file"
    print_info "Backup saved: $backup_file"
    log_action "BACKUP" "Device $device backed up to $backup_file"
}

# Find LUKS devices
find_luks_devices() {
    local -a devices=()
    
    shopt -s nullglob
    for device in /dev/sd* /dev/nvme* /dev/vd* /dev/mapper/*; do
        if [[ -b "$device" ]] && cryptsetup isLuks "$device" 2>/dev/null; then
            devices+=("$device")
        fi
    done
    shopt -u nullglob
    
    printf '%s\n' "${devices[@]}"
}

# Get password slots only (exclude TPM2, FIDO2, etc.)
get_password_slots() {
    local device="$1"
    local -a slots=()
    
    # Get LUKS version
    local version
    version=$(cryptsetup luksDump "$device" 2>/dev/null | grep "^Version:" | awk '{print $2}')
    
    if [[ "$version" == "2" ]]; then
        # LUKS2: Check for non-token slots
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]+([0-9]+):[[:space:]]*luks2 ]]; then
                local slot="${BASH_REMATCH[1]}"
                
                # Check if this slot has a token (TPM2, FIDO2, etc.)
                local has_token=false
                if cryptsetup luksDump "$device" 2>/dev/null | 
                   awk '/^Tokens:/,/^[A-Z]/' | 
                   grep -q "Keyslot:[[:space:]]*$slot"; then
                    has_token=true
                fi
                
                if [[ "$has_token" == "false" ]]; then
                    slots+=("$slot")
                fi
            fi
        done < <(cryptsetup luksDump "$device" 2>/dev/null)
    else
        # LUKS1: All enabled slots are password slots
        while IFS= read -r line; do
            if [[ "$line" =~ ^Key\ Slot\ ([0-9]+):\ ENABLED ]]; then
                slots+=("${BASH_REMATCH[1]}")
            fi
        done < <(cryptsetup luksDump "$device" 2>/dev/null)
    fi
    
    printf '%s\n' "${slots[@]}"
}

# Test password on slots
test_password() {
    local device="$1"
    local password="$2"
    local -a matching_slots=()
    
    local -a password_slots
    mapfile -t password_slots < <(get_password_slots "$device")
    
    for slot in "${password_slots[@]}"; do
        if printf '%s' "$password" | cryptsetup open --test-passphrase "$device" --key-slot "$slot" 2>/dev/null; then
            matching_slots+=("$slot")
        fi
    done
    
    printf '%s\n' "${matching_slots[@]}"
}

# Process single device
process_device() {
    local device="$1"
    
    print_section "Processing $device"
    
    # Get password slots
    local -a password_slots
    mapfile -t password_slots < <(get_password_slots "$device")
    
    if [[ ${#password_slots[@]} -eq 0 ]]; then
        print_warning "No password slots found"
        return 0
    fi
    
    print_info "Found ${#password_slots[@]} password slot(s): ${password_slots[*]}"
    
    # Get password to check
    print_info "Enter password to check for duplicates:"
    local check_password
    read -r -s -p "Password: " check_password
    echo
    echo
    
    # Find matching slots
    local -a matching_slots
    mapfile -t matching_slots < <(test_password "$device" "$check_password")
    
    # Handle results
    if [[ ${#matching_slots[@]} -eq 0 ]]; then
        print_error "Password not found in any slot"
        return 1
    elif [[ ${#matching_slots[@]} -eq 1 ]]; then
        print_success "Password found in slot ${matching_slots[0]} only (no duplicates)"
        return 0
    fi
    
    # Multiple matches - handle duplicates
    print_warning "Password found in ${#matching_slots[@]} slots: ${matching_slots[*]}"
    
    # Create backup before changes
    if [[ "$DRY_RUN" == "false" ]]; then
        backup_device_info "$device"
    fi
    
    # Choose slot to keep
    local keep_slot
    while true; do
        read -r -p "Which slot to KEEP? (${matching_slots[*]}): " keep_slot
        if [[ " ${matching_slots[*]} " =~ " ${keep_slot} " ]]; then
            break
        fi
        print_error "Invalid choice"
    done
    
    # Build removal list
    local -a remove_slots=()
    for slot in "${matching_slots[@]}"; do
        [[ "$slot" != "$keep_slot" ]] && remove_slots+=("$slot")
    done
    
    # Show plan
    echo
    print_info "Plan:"
    print_success "  KEEP: Slot $keep_slot"
    print_warning "  REMOVE: Slots ${remove_slots[*]}"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "DRY RUN - no changes made"
        return 0
    fi
    
    # Confirm
    read -r -p "Continue? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        print_info "Cancelled"
        return 0
    fi
    
    # Remove duplicate slots
    local removed=0
    local failed=0
    
    for slot in "${remove_slots[@]}"; do
        print_info "Removing slot $slot..."
        if printf '%s' "$check_password" | cryptsetup luksKillSlot "$device" "$slot" 2>/dev/null; then
            print_success "Removed slot $slot"
            log_action "REMOVE_SUCCESS" "Device: $device, Slot: $slot"
            ((removed++))
        else
            print_error "Failed to remove slot $slot"
            log_action "REMOVE_FAILED" "Device: $device, Slot: $slot"
            ((failed++))
        fi
    done
    
    # Summary
    echo
    if [[ $failed -eq 0 ]]; then
        print_success "Successfully removed $removed duplicate slot(s)"
    else
        print_warning "Removed $removed slot(s), failed to remove $failed slot(s)"
    fi
    
    return 0
}

# Show usage
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] [DEVICE]

Remove duplicate password entries from LUKS devices.

OPTIONS:
    -d, --dry-run     Show what would be done without making changes
    -v, --verbose     Show detailed information
    -h, --help        Show this help message

DEVICE:
    Specific LUKS device to clean (e.g., /dev/sda3)
    If not specified, all LUKS devices will be processed

FEATURES:
    - Preserves systemd-managed slots (TPM2, FIDO2, etc.)
    - Creates backups before making changes
    - Audit log at: $AUDIT_LOG
    - Supports dry-run mode

EOF
}

# Main function
main() {
    local device=""
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
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
    
    # Initialize
    init_environment
    
    print_section "Password Duplicate Cleanup"
    [[ "$DRY_RUN" == "true" ]] && print_warning "DRY RUN MODE"
    
    # Process device(s)
    if [[ -n "$device" ]]; then
        # Single device
        if [[ ! -b "$device" ]] || ! cryptsetup isLuks "$device" 2>/dev/null; then
            print_error "$device is not a valid LUKS device"
            exit 1
        fi
        process_device "$device"
    else
        # All devices
        local -a devices
        mapfile -t devices < <(find_luks_devices)
        
        if [[ ${#devices[@]} -eq 0 ]]; then
            print_error "No LUKS devices found"
            exit 1
        fi
        
        print_info "Found ${#devices[@]} LUKS device(s)"
        
        for dev in "${devices[@]}"; do
            process_device "$dev"
            if [[ ${#devices[@]} -gt 1 ]]; then
                echo
                read -r -p "Press Enter to continue..."
            fi
        done
    fi
    
    echo
    print_success "Operation completed"
    [[ "$DRY_RUN" == "false" ]] && print_info "Audit log: $AUDIT_LOG"
}

# Run main
main "$@"