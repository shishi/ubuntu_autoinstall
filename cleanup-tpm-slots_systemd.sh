#!/usr/bin/env bash
set -euo pipefail

# TPM Slot Cleanup Script for systemd-cryptenroll
# This script safely removes duplicate TPM slots from LUKS devices
# It allows users to choose which slots to keep/remove

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

# Function to get detailed TPM2 enrollment information
get_tpm2_enrollment_details() {
    local device="$1"
    local -A slot_info
    
    # Parse LUKS dump for detailed information
    local in_tokens=false
    local in_keyslots=false
    local current_token=""
    local current_slot=""
    local token_keyslot=""
    local token_pcrs=""
    
    while IFS= read -r line; do
        # Tokens section parsing
        if [[ "$line" =~ ^Tokens: ]]; then
            in_tokens=true
            in_keyslots=false
        elif [[ "$line" =~ ^Keyslots: ]]; then
            in_tokens=false
            in_keyslots=true
        elif [[ "$line" =~ ^[A-Z] ]] && [[ "$in_tokens" == "true" || "$in_keyslots" == "true" ]]; then
            in_tokens=false
            in_keyslots=false
        fi
        
        # Parse token information
        if [[ "$in_tokens" == "true" ]]; then
            if [[ "$line" =~ ^[[:space:]]+([0-9]+):[[:space:]]*systemd-tpm2 ]]; then
                current_token="${BASH_REMATCH[1]}"
                token_keyslot=""
                token_pcrs=""
            elif [[ -n "$current_token" ]]; then
                if [[ "$line" =~ [[:space:]]+Keyslot:[[:space:]]+([0-9]+) ]]; then
                    token_keyslot="${BASH_REMATCH[1]}"
                elif [[ "$line" =~ [[:space:]]+tpm2-pcrs:[[:space:]]+(.+) ]]; then
                    token_pcrs="${BASH_REMATCH[1]}"
                fi
                
                # Store information when we have keyslot
                if [[ -n "$token_keyslot" ]]; then
                    slot_info["$token_keyslot,token"]="$current_token"
                    slot_info["$token_keyslot,pcrs"]="${token_pcrs:-unknown}"
                fi
            fi
        fi
        
        # Parse keyslot priority information
        if [[ "$in_keyslots" == "true" ]]; then
            if [[ "$line" =~ ^[[:space:]]+([0-9]+):[[:space:]]*luks2 ]]; then
                current_slot="${BASH_REMATCH[1]}"
            elif [[ -n "$current_slot" ]] && [[ "$line" =~ Priority:[[:space:]]+(.+) ]]; then
                slot_info["$current_slot,priority"]="${BASH_REMATCH[1]}"
            fi
        fi
    done < <(cryptsetup luksDump "$device" 2>/dev/null)
    
    # Return associative array as formatted output
    for key in "${!slot_info[@]}"; do
        echo "$key=${slot_info[$key]}"
    done
}

# Function to display TPM slot information
display_tpm_slot_info() {
    local device="$1"
    shift
    local -a tpm_slots=("$@")
    
    print_section "TPM2 Enrollment Details for $device"
    
    # Get detailed information
    local -A slot_details
    while IFS='=' read -r key value; do
        slot_details["$key"]="$value"
    done < <(get_tpm2_enrollment_details "$device")
    
    # Display slot information in a table format
    printf "%-6s %-8s %-10s %-15s %-20s\n" "Slot" "Token" "Priority" "PCRs" "Status"
    printf "%s\n" "──────────────────────────────────────────────────────────────"
    
    for slot in "${tpm_slots[@]}"; do
        local token="${slot_details[$slot,token]:-unknown}"
        local priority="${slot_details[$slot,priority]:-normal}"
        local pcrs="${slot_details[$slot,pcrs]:-unknown}"
        local status="Active"
        
        # Check if device is unlocked
        for mapped in /dev/mapper/*; do
            if [[ -b "$mapped" ]] && cryptsetup status "$(basename "$mapped")" 2>/dev/null | grep -q "$device"; then
                status="Active (device unlocked)"
                break
            fi
        done
        
        printf "%-6s %-8s %-10s %-15s %-20s\n" "$slot" "#$token" "$priority" "$pcrs" "$status"
    done
    
    echo
    
    # Additional information
    print_info "Additional Information:"
    
    # Check if systemd-cryptenroll can list enrollments
    if command_exists systemd-cryptenroll; then
        print_info "systemd-cryptenroll status:"
        systemd-cryptenroll "$device" --tpm2-device=list 2>/dev/null | sed 's/^/  /' || print_info "  Unable to query enrollments"
    fi
    
    # Show current PCR values for comparison
    if command_exists tpm2_pcrread; then
        echo
        print_info "Current PCR values (for reference):"
        tpm2_pcrread sha256:7 2>/dev/null | grep -A1 "sha256" | tail -1 | sed 's/^/  PCR[7]: /' || true
    fi
}

# Function to analyze TPM2 enrollments
analyze_tpm2_enrollments() {
    local device="$1"
    local -a tpm_slots=()
    
    # Parse LUKS dump for TPM2 tokens
    local in_tokens=false
    local current_token=""
    local current_keyslot=""
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^Tokens: ]]; then
            in_tokens=true
        elif [[ "$line" =~ ^[A-Z] ]] && [[ "$in_tokens" == "true" ]]; then
            in_tokens=false
        fi
        
        if [[ "$in_tokens" == "true" ]]; then
            if [[ "$line" =~ ^[[:space:]]+([0-9]+):[[:space:]]*systemd-tpm2 ]]; then
                current_token="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ [[:space:]]+Keyslot:[[:space:]]+([0-9]+) ]]; then
                current_keyslot="${BASH_REMATCH[1]}"
                if [[ -n "$current_token" ]]; then
                    tpm_slots+=("$current_keyslot")
                fi
            fi
        fi
    done < <(cryptsetup luksDump "$device" 2>/dev/null)
    
    if [[ ${#tpm_slots[@]} -eq 0 ]]; then
        print_info "No TPM2 enrollments found" >&2
    elif [[ ${#tpm_slots[@]} -eq 1 ]]; then
        print_success "Found 1 TPM2 enrollment in slot ${tpm_slots[0]}" >&2
    else
        print_warning "Found ${#tpm_slots[@]} TPM2 enrollments in slots: ${tpm_slots[*]}" >&2
    fi
    
    echo "${tpm_slots[*]}"
}

# Function to remove duplicate TPM slots
cleanup_device() {
    local device="$1"
    local dry_run="${2:-false}"
    
    print_section "TPM2 Slot Analysis for $device"
    
    # Get all slots
    local all_slots
    all_slots=$(cryptsetup luksDump "$device" 2>/dev/null | grep -cE "^  [0-9]+: luks2" || echo 0)
    print_info "Total enabled key slots: $all_slots"
    
    # Get TPM slots
    print_info "Analyzing TPM2 enrollments..."
    local tpm_slots_str
    tpm_slots_str=$(analyze_tpm2_enrollments "$device")
    local -a tpm_slots=()
    if [[ -n "$tpm_slots_str" ]]; then
        IFS=' ' read -r -a tpm_slots <<< "$tpm_slots_str"
    fi
    
    if [[ ${#tpm_slots[@]} -eq 0 ]]; then
        print_info "No TPM2 enrollments found on this device"
        return 0
    elif [[ ${#tpm_slots[@]} -eq 1 ]]; then
        print_success "Only one TPM2 enrollment found (slot ${tpm_slots[0]})"
        print_info "No duplicates to clean up"
        return 0
    fi
    
    # Display detailed information
    display_tpm_slot_info "$device" "${tpm_slots[@]}"
    
    echo
    print_warning "Multiple TPM2 enrollments detected!"
    print_info "Possible reasons for duplicates:"
    print_info "  • Re-enrollment after BIOS/firmware updates"
    print_info "  • Changed PCR policies"
    print_info "  • Testing or troubleshooting attempts"
    echo
    
    # Let user choose which slot to keep
    print_warning "Which TPM2 slot do you want to KEEP? (Others will be removed)"
    print_info "Available TPM2 slots: ${tpm_slots[*]}"
    print_info "Recommendation: Keep the most recently created slot (usually the highest number)"
    
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
    
    # Get password for removal
    print_info "Enter a password for $device to remove slots:"
    read -r -s -p "Password: " password
    echo
    echo
    
    # Remove slots
    print_section "Removing TPM2 Slots"
    
    local removed_count=0
    for slot in "${slots_to_remove[@]}"; do
        print_info "Removing TPM2 slot $slot..."
        if printf '%s' "$password" | cryptsetup luksKillSlot "$device" "$slot" 2>/dev/null; then
            print_success "Removed slot $slot"
            ((removed_count++))
        else
            print_error "Failed to remove slot $slot"
            print_info "Possible reasons: incorrect password, or slot is protected"
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
    final_tpm_slots=$(analyze_tpm2_enrollments "$device")
    if [[ -n "$final_tpm_slots" ]]; then
        print_info "Remaining TPM2 slots: $final_tpm_slots"
    else
        print_warning "No TPM2 enrollments found (this shouldn't happen!)"
    fi
    
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

Clean up duplicate TPM2 slots from LUKS devices (systemd-cryptenroll version).

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
    - Shows detailed information about each TPM2 enrollment
    - Displays token numbers, PCR values, and priorities
    - Allows user to choose which enrollment to keep
    - Shows current system PCR values for comparison
    - Requires password to remove slots
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
    
    print_section "TPM2 Slot Cleanup Utility (systemd-cryptenroll)"
    
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
    print_success "Operation completed"
    
    if [[ "$dry_run" == "true" ]]; then
        print_info "This was a dry run. Run without --dry-run to make actual changes."
    fi
}

# Run main function
main "$@"