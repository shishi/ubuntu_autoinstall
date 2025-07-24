#!/usr/bin/env bash
set -euo pipefail

# Password Duplicate Cleanup Script for systemd-cryptenroll (Version 2)
# Idempotent version with improved safety and better systemd integration

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

# Global variables
AUDIT_LOG="/var/log/luks-cleanup-audit.log"
BACKUP_DIR="/var/backups/luks-cleanup"
DRY_RUN=false
VERBOSE=false

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root"
        exit 1
    fi
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Initialize environment
init_environment() {
    # Create backup directory if needed
    if [[ ! -d "$BACKUP_DIR" ]]; then
        mkdir -p "$BACKUP_DIR"
        chmod 700 "$BACKUP_DIR"
    fi
    
    # Initialize audit log
    if [[ ! -f "$AUDIT_LOG" ]]; then
        touch "$AUDIT_LOG"
        chmod 600 "$AUDIT_LOG"
    fi
}

# Function to log actions
log_action() {
    local action="$1"
    local details="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $action: $details" >> "$AUDIT_LOG"
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

# Function to create device backup metadata
backup_device_info() {
    local device="$1"
    local backup_file="$BACKUP_DIR/luks-header-$(basename "$device")-$(date +%Y%m%d-%H%M%S).info"
    
    {
        echo "# LUKS Device Information Backup"
        echo "# Device: $device"
        echo "# Date: $(date)"
        echo ""
        cryptsetup luksDump "$device" 2>/dev/null
    } > "$backup_file"
    
    chmod 600 "$backup_file"
    print_info "Device information backed up to: $backup_file"
    log_action "BACKUP" "Device info for $device saved to $backup_file"
}

# Function to find LUKS devices
find_luks_devices() {
    local luks_devices=()
    
    # Check common device patterns
    local patterns=("/dev/sd*" "/dev/nvme*" "/dev/vd*" "/dev/mapper/*")
    
    for pattern in "${patterns[@]}"; do
        # Use nullglob to handle no matches
        shopt -s nullglob
        for device in $pattern; do
            if [[ -b "$device" ]] && cryptsetup isLuks "$device" 2>/dev/null; then
                luks_devices+=("$device")
            fi
        done
        shopt -u nullglob
    done
    
    printf '%s\n' "${luks_devices[@]}"
}

# Function to classify slot types
classify_slot() {
    local device="$1"
    local slot="$2"
    
    # Check if LUKS2 with tokens
    local luks_version
    luks_version=$(cryptsetup luksDump "$device" 2>/dev/null | grep "^Version:" | awk '{print $2}')
    
    if [[ "$luks_version" == "2" ]]; then
        # Check if slot is associated with any token
        local token_info
        token_info=$(cryptsetup luksDump "$device" 2>/dev/null | awk '/^Tokens:/,/^[A-Z]/' | grep -B2 "Keyslot:[[:space:]]*$slot" || true)
        
        if [[ -n "$token_info" ]]; then
            # Check token type
            if echo "$token_info" | grep -q "systemd-tpm2"; then
                echo "tpm2"
            elif echo "$token_info" | grep -q "systemd-fido2"; then
                echo "fido2"
            elif echo "$token_info" | grep -q "systemd-recovery"; then
                echo "recovery"
            else
                echo "token-other"
            fi
        else
            echo "password"
        fi
    else
        # LUKS1 - all slots are password
        echo "password"
    fi
}

# Function to get slot information with safety checks
get_safe_password_slots() {
    local device="$1"
    local -a password_slots=()
    
    # Get all active slots
    local slot_pattern
    local luks_version
    luks_version=$(cryptsetup luksDump "$device" 2>/dev/null | grep "^Version:" | awk '{print $2}')
    
    if [[ "$luks_version" == "2" ]]; then
        slot_pattern="^[[:space:]]+([0-9]+):[[:space:]]*luks2"
    else
        slot_pattern="^Key Slot ([0-9]+): ENABLED"
    fi
    
    while IFS= read -r line; do
        if [[ "$line" =~ $slot_pattern ]]; then
            local slot="${BASH_REMATCH[1]}"
            local slot_type
            slot_type=$(classify_slot "$device" "$slot")
            
            if [[ "$slot_type" == "password" ]]; then
                password_slots+=("$slot")
            elif [[ "$VERBOSE" == "true" ]]; then
                print_info "Skipping slot $slot (type: $slot_type)"
            fi
        fi
    done < <(cryptsetup luksDump "$device" 2>/dev/null)
    
    printf '%s\n' "${password_slots[@]}"
}

# Function to test password on specific slots (idempotent)
test_password_on_slots() {
    local device="$1"
    local password="$2"
    local -a matching_slots=()
    
    # Get only password slots
    local -a password_slots
    mapfile -t password_slots < <(get_safe_password_slots "$device")
    
    if [[ ${#password_slots[@]} -eq 0 ]]; then
        return 0
    fi
    
    # Test each password slot
    for slot in "${password_slots[@]}"; do
        if printf '%s' "$password" | cryptsetup open --test-passphrase "$device" --key-slot "$slot" 2>/dev/null; then
            matching_slots+=("$slot")
        fi
    done
    
    printf '%s\n' "${matching_slots[@]}"
}

# Function to display comprehensive slot information
display_slot_analysis() {
    local device="$1"
    shift
    local -a matching_slots=("$@")
    
    print_section "Slot Analysis for $device"
    
    # Get device info
    local luks_version
    luks_version=$(cryptsetup luksDump "$device" 2>/dev/null | grep "^Version:" | awk '{print $2}')
    print_info "LUKS Version: $luks_version"
    
    # Count slot types
    local total_slots=0
    local password_slots=0
    local tpm2_slots=0
    local other_slots=0
    
    # Analyze all slots
    print_info "Slot breakdown:"
    
    local slot_pattern
    if [[ "$luks_version" == "2" ]]; then
        slot_pattern="^[[:space:]]+([0-9]+):[[:space:]]*luks2"
    else
        slot_pattern="^Key Slot ([0-9]+): ENABLED"
    fi
    
    while IFS= read -r line; do
        if [[ "$line" =~ $slot_pattern ]]; then
            local slot="${BASH_REMATCH[1]}"
            local slot_type
            slot_type=$(classify_slot "$device" "$slot")
            ((total_slots++))
            
            case "$slot_type" in
                password)
                    ((password_slots++))
                    if [[ " ${matching_slots[*]} " =~ " ${slot} " ]]; then
                        print_warning "  Slot $slot: Password (DUPLICATE FOUND)"
                    else
                        print_info "  Slot $slot: Password"
                    fi
                    ;;
                tpm2)
                    ((tpm2_slots++))
                    print_success "  Slot $slot: TPM2 (systemd-cryptenroll)"
                    ;;
                *)
                    ((other_slots++))
                    print_info "  Slot $slot: $slot_type"
                    ;;
            esac
        fi
    done < <(cryptsetup luksDump "$device" 2>/dev/null)
    
    # Summary
    echo
    print_info "Summary:"
    print_info "  Total slots: $total_slots"
    print_info "  Password slots: $password_slots"
    print_info "  TPM2 slots: $tpm2_slots"
    print_info "  Other slots: $other_slots"
    
    if [[ ${#matching_slots[@]} -gt 0 ]]; then
        echo
        print_warning "Duplicate password found in ${#matching_slots[@]} slots: ${matching_slots[*]}"
    fi
}

# Function to safely remove duplicate slots
remove_duplicate_slots() {
    local device="$1"
    local keep_slot="$2"
    shift 2
    local -a remove_slots=("$@")
    
    local removed_count=0
    local failed_count=0
    
    for slot in "${remove_slots[@]}"; do
        print_info "Removing duplicate slot $slot..."
        
        # Log the attempt
        log_action "REMOVE_ATTEMPT" "Device: $device, Slot: $slot"
        
        # Use the password to authenticate removal
        if printf '%s' "$check_password" | cryptsetup luksKillSlot "$device" "$slot" 2>/dev/null; then
            print_success "Removed slot $slot"
            log_action "REMOVE_SUCCESS" "Device: $device, Slot: $slot"
            ((removed_count++))
        else
            print_error "Failed to remove slot $slot"
            log_action "REMOVE_FAILED" "Device: $device, Slot: $slot"
            ((failed_count++))
        fi
    done
    
    return $([ $failed_count -eq 0 ] && echo 0 || echo 1)
}

# Main cleanup function
cleanup_password_duplicates() {
    local device="$1"
    
    print_section "Password Duplicate Detection for $device"
    
    # Create backup first
    if [[ "$DRY_RUN" == "false" ]]; then
        backup_device_info "$device"
    fi
    
    # Get password slots
    local -a password_slots
    mapfile -t password_slots < <(get_safe_password_slots "$device")
    
    if [[ ${#password_slots[@]} -eq 0 ]]; then
        print_warning "No password slots found on $device"
        return 0
    fi
    
    print_info "Found ${#password_slots[@]} password slot(s): ${password_slots[*]}"
    
    # Get password to check
    print_info "Enter the password to check for duplicates:"
    local check_password
    read -r -s -p "Password: " check_password
    echo
    echo
    
    # Test password
    print_info "Checking for duplicates..."
    local -a matching_slots
    mapfile -t matching_slots < <(test_password_on_slots "$device" "$check_password")
    
    if [[ ${#matching_slots[@]} -eq 0 ]]; then
        print_error "Password does not match any slots"
        return 1
    elif [[ ${#matching_slots[@]} -eq 1 ]]; then
        print_success "Password found in only one slot: ${matching_slots[0]}"
        print_info "No duplicates to remove"
        return 0
    fi
    
    # Show analysis
    display_slot_analysis "$device" "${matching_slots[@]}"
    
    # Choose slot to keep
    echo
    print_warning "Which slot should be KEPT? (others will be removed)"
    print_info "Available slots: ${matching_slots[*]}"
    
    local keep_slot
    while true; do
        read -r -p "Slot to keep: " keep_slot
        if [[ " ${matching_slots[*]} " =~ " ${keep_slot} " ]]; then
            break
        else
            print_error "Invalid choice. Select from: ${matching_slots[*]}"
        fi
    done
    
    # Determine slots to remove
    local -a remove_slots=()
    for slot in "${matching_slots[@]}"; do
        if [[ "$slot" != "$keep_slot" ]]; then
            remove_slots+=("$slot")
        fi
    done
    
    # Show plan
    echo
    print_section "Removal Plan"
    print_success "KEEP: Slot $keep_slot"
    print_warning "REMOVE: Slots ${remove_slots[*]}"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_info "DRY RUN: No changes will be made"
        return 0
    fi
    
    # Confirm
    echo
    if ! confirm_action "Proceed with removing duplicate slots?"; then
        print_info "Operation cancelled"
        return 0
    fi
    
    # Remove duplicates
    print_section "Removing Duplicates"
    remove_duplicate_slots "$device" "$keep_slot" "${remove_slots[@]}"
    
    # Show final state
    echo
    print_section "Final State"
    local -a final_slots
    mapfile -t final_slots < <(get_safe_password_slots "$device")
    print_info "Password slots remaining: ${#final_slots[@]}"
    for slot in "${final_slots[@]}"; do
        print_info "  Slot $slot"
    done
}

# Function to show usage
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] [DEVICE]

Remove duplicate password entries from LUKS devices (systemd-cryptenroll aware).

OPTIONS:
    -d, --dry-run     Show what would be done without making changes
    -v, --verbose     Show detailed information
    -h, --help        Show this help message

DEVICE:
    Specific LUKS device to clean (e.g., /dev/sda3)
    If not specified, all LUKS devices will be processed

SAFETY FEATURES:
    - Creates backup of device information before changes
    - Audit log at: $AUDIT_LOG
    - Preserves systemd-managed slots (TPM2, FIDO2, etc.)
    - Requires explicit confirmation
    - Supports dry-run mode

This script is idempotent and can be run multiple times safely.
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
    
    # Check prerequisites
    check_root
    init_environment
    
    if ! command_exists cryptsetup; then
        print_error "cryptsetup not installed"
        exit 1
    fi
    
    print_section "Password Duplicate Cleanup (systemd-cryptenroll aware)"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_warning "DRY RUN MODE - No changes will be made"
    fi
    
    # Process devices
    if [[ -n "$device" ]]; then
        # Specific device
        if [[ ! -b "$device" ]] || ! cryptsetup isLuks "$device" 2>/dev/null; then
            print_error "$device is not a valid LUKS device"
            exit 1
        fi
        
        cleanup_password_duplicates "$device"
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
            echo
            cleanup_password_duplicates "$dev"
            
            if [[ $? -eq 0 ]] && [[ ${#devices[@]} -gt 1 ]]; then
                echo
                read -r -p "Press Enter to continue to next device..."
            fi
        done
    fi
    
    echo
    print_success "Operation completed"
    
    if [[ "$DRY_RUN" == "false" ]]; then
        print_info "Audit log: $AUDIT_LOG"
        print_info "Backups: $BACKUP_DIR"
    fi
}

# Export for testing
export -f classify_slot get_safe_password_slots

# Run main
main "$@"