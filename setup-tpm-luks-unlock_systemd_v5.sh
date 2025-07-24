#!/usr/bin/env bash
set -euo pipefail

# TPM2 LUKS Auto-unlock Setup Script with systemd-cryptenroll (Version 5)
# Fixed version with proper error handling in slot analysis

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

# Global variables
LUKS_DEVICE=""
CURRENT_PASSWORD=""
RECOVERY_KEY=""
RECOVERY_KEY_FILE=""
NEW_USER_PASSWORD=""
OLD_PASSWORD=""

# State tracking
NEEDS_RECOVERY_KEY=true
NEEDS_TPM2_ENROLLMENT=true
NEEDS_NEW_PASSWORD=true
NEEDS_PASSWORD_REMOVAL=true

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to generate a secure random recovery key
generate_recovery_key() {
    # Generate URL-safe base64 to avoid shell-breaking characters
    openssl rand -base64 48 | tr -d '\n' | tr '+/' '-_'
}

# Function to check TPM2 hardware availability
check_tpm2_hardware() {
    print_info "Checking TPM2 hardware availability..."
    
    if [[ -e /dev/tpm0 ]] || [[ -e /dev/tpmrm0 ]]; then
        print_success "TPM2 hardware device found"
        return 0
    fi
    
    if [[ -d /sys/class/tpm/tpm0 ]]; then
        print_success "TPM2 device found in sysfs"
        return 0
    fi
    
    print_error "No TPM2 hardware device found"
    return 1
}

# Function to check systemd version
check_systemd_version() {
    print_info "Checking systemd version..."
    
    local systemd_version
    systemd_version=$(systemctl --version | head -1 | awk '{print $2}')
    
    if [[ -z "$systemd_version" ]]; then
        print_error "Could not determine systemd version"
        return 1
    fi
    
    if [[ "$systemd_version" -lt 248 ]]; then
        print_error "systemd version $systemd_version is too old. Version 248 or newer is required."
        return 1
    fi
    
    print_success "systemd version $systemd_version supports TPM2 enrollment"
    
    # Check for systemd-cryptenroll command
    if ! command_exists systemd-cryptenroll; then
        print_error "systemd-cryptenroll command not found"
        print_info "Ubuntu 22.04 or newer is required"
        return 1
    fi
    
    return 0
}

# Function to install required packages
install_packages() {
    print_info "Checking and installing required packages..."
    
    local packages=(
        "systemd"
        "tpm2-tools"
        "libtss2-dev"
        "cryptsetup"
        "cryptsetup-initramfs"
    )
    
    local missing_packages=()
    
    for pkg in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $pkg "; then
            missing_packages+=("$pkg")
        fi
    done
    
    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        print_info "Installing missing packages: ${missing_packages[*]}"
        apt-get update
        apt-get install -y "${missing_packages[@]}"
    else
        print_success "All required packages are already installed"
    fi
}

# Function to find LUKS encrypted device
find_luks_device() {
    print_info "Looking for LUKS encrypted devices..."
    
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
    
    # Verify it's actually LUKS
    if ! cryptsetup luksDump "$LUKS_DEVICE" >/dev/null 2>&1; then
        print_error "Failed to verify LUKS device: $LUKS_DEVICE"
        return 1
    fi
    
    return 0
}

# Function to display current LUKS slots
show_luks_slots() {
    print_info "Current LUKS key slots for $LUKS_DEVICE:"
    cryptsetup luksDump "$LUKS_DEVICE" | grep -E "^Key Slot|^  [0-9]+: luks2" | head -20
}

# Function to check if systemd-cryptenroll TPM2 binding exists
check_tpm2_enrollment() {
    local device="$1"
    
    if cryptsetup luksDump "$device" 2>/dev/null | grep -q "tpm2"; then
        return 0
    else
        return 1
    fi
}

# Function to check current state
check_current_state() {
    print_info "Checking current system state..."
    
    # Check for existing recovery keys
    local existing_keys=()
    if [[ -d /root ]] && find /root -maxdepth 1 -name ".luks-recovery-key-*.txt" -type f 2>/dev/null | grep -q .; then
        readarray -t existing_keys < <(ls -t /root/.luks-recovery-key-*.txt 2>/dev/null)
        if [[ ${#existing_keys[@]} -gt 0 ]]; then
            # Try to read the most recent recovery key
            local test_key_file="${existing_keys[0]}"
            local test_key=$(grep "Recovery Key:" "$test_key_file" | cut -d: -f2- | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
            if [[ -n "$test_key" ]] && printf '%s' "$test_key" | cryptsetup open --test-passphrase "$LUKS_DEVICE" 2>/dev/null; then
                print_success "Found valid existing recovery key"
                RECOVERY_KEY="$test_key"
                RECOVERY_KEY_FILE="$test_key_file"
                NEEDS_RECOVERY_KEY=false
            fi
        fi
    fi
    
    # Check TPM2 enrollment
    if check_tpm2_enrollment "$LUKS_DEVICE"; then
        print_success "TPM2 enrollment already exists"
        NEEDS_TPM2_ENROLLMENT=false
    else
        print_info "TPM2 enrollment not found"
    fi
    
    # Show summary
    print_info "Current state summary:"
    if [[ "$NEEDS_RECOVERY_KEY" == "false" ]]; then
        print_info "  ✓ Recovery key exists"
    else
        print_info "  ✗ Recovery key needed"
    fi
    
    if [[ "$NEEDS_TPM2_ENROLLMENT" == "false" ]]; then
        print_info "  ✓ TPM2 enrolled"
    else
        print_info "  ✗ TPM2 enrollment needed"
    fi
}

# Function to get and verify current LUKS password
get_current_password() {
    print_info "Please provide a current LUKS password to authenticate operations"
    
    local password_valid=false
    while ! $password_valid; do
        read -r -s -p "Enter current LUKS password: " CURRENT_PASSWORD
        echo
        
        # Verify the password
        if printf '%s' "$CURRENT_PASSWORD" | cryptsetup open --test-passphrase "$LUKS_DEVICE" 2>/dev/null; then
            print_success "Password verified"
            password_valid=true
        else
            print_error "Invalid password. Please try again."
        fi
    done
}

# Function to setup recovery key
setup_recovery_key() {
    if [[ "$NEEDS_RECOVERY_KEY" == "false" ]]; then
        print_info "Recovery key already exists and is valid"
        return 0
    fi
    
    print_info "Setting up new recovery key..."
    
    # Generate new recovery key
    RECOVERY_KEY=$(generate_recovery_key)
    RECOVERY_KEY_FILE="/root/.luks-recovery-key-$(date +%Y%m%d-%H%M%S).txt"
    
    {
        echo "LUKS Recovery Key for $LUKS_DEVICE"
        echo "Generated on: $(date)"
        echo "Recovery Key: $RECOVERY_KEY"
    } > "$RECOVERY_KEY_FILE"
    
    chmod 600 "$RECOVERY_KEY_FILE"
    print_success "Recovery key saved to: $RECOVERY_KEY_FILE"
    print_warning "IMPORTANT: Save this recovery key in a secure location!"
    echo
    echo "Recovery Key: $RECOVERY_KEY"
    echo
}

# Function to get new user password
get_new_password() {
    print_info "Setting up user password..."
    print_info "Note: If you want to keep your current password, just enter it again."
    
    # First, let's get the new password
    local temp_new_password=""
    local password_valid=false
    
    while ! $password_valid; do
        read -r -s -p "Enter new user password: " temp_new_password
        echo
        read -r -s -p "Confirm new user password: " password_confirm
        echo
        
        if [[ "$temp_new_password" != "$password_confirm" ]]; then
            print_error "Passwords do not match"
        elif [[ ${#temp_new_password} -lt 8 ]]; then
            print_error "Password must be at least 8 characters long"
        elif [[ "$temp_new_password" == "$CURRENT_PASSWORD" ]] && [[ "$NEEDS_NEW_PASSWORD" == "true" ]]; then
            print_warning "New password is the same as current password"
            # Check if it's already enrolled
            if printf '%s' "$temp_new_password" | cryptsetup open --test-passphrase "$LUKS_DEVICE" 2>/dev/null; then
                print_info "This password is already enrolled, proceeding..."
                password_valid=true
            else
                print_error "New password must be different from current password"
            fi
        else
            password_valid=true
        fi
    done
    
    # Check if this password already exists in LUKS
    if printf '%s' "$temp_new_password" | cryptsetup open --test-passphrase "$LUKS_DEVICE" 2>/dev/null; then
        print_success "This password is already enrolled in LUKS"
        NEEDS_NEW_PASSWORD=false
    else
        print_success "New password configured"
        NEEDS_NEW_PASSWORD=true
    fi
    
    NEW_USER_PASSWORD="$temp_new_password"
}

# Function to get old password - SIMPLIFIED VERSION
get_old_password() {
    print_info "Checking for old password to remove..."
    
    # Skip if we don't need a new password (everything is already set up)
    if [[ "$NEEDS_NEW_PASSWORD" == "false" ]] && [[ "$NEEDS_TPM2_ENROLLMENT" == "false" ]]; then
        print_info "System is already configured. Skipping old password check."
        NEEDS_PASSWORD_REMOVAL=false
        return 0
    fi
    
    # Simply ask if user wants to remove the old password
    echo
    print_info "Do you want to remove any old password (e.g., ubuntuKey)?"
    read -r -p "Remove old password? (y/N): " response
    
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        print_info "Skipping old password removal"
        NEEDS_PASSWORD_REMOVAL=false
        return 0
    fi
    
    # Get the old password
    read -r -s -p "Enter old password: " OLD_PASSWORD
    echo
    
    if [[ -z "$OLD_PASSWORD" ]]; then
        print_info "No password entered. Skipping removal."
        NEEDS_PASSWORD_REMOVAL=false
        return 0
    fi
    
    # Test if this password exists
    if printf '%s' "$OLD_PASSWORD" | cryptsetup open --test-passphrase "$LUKS_DEVICE" 2>/dev/null; then
        print_success "Old password verified"
        NEEDS_PASSWORD_REMOVAL=true
        return 0
    else
        print_warning "Password doesn't match any slot. Skipping removal."
        OLD_PASSWORD=""
        NEEDS_PASSWORD_REMOVAL=false
        return 0
    fi
}

# Function to enroll recovery key
enroll_recovery_key() {
    print_info "Enrolling recovery key in LUKS..."
    
    # Check if recovery key already exists
    if printf '%s' "$RECOVERY_KEY" | cryptsetup open --test-passphrase "$LUKS_DEVICE" 2>/dev/null; then
        print_success "Recovery key already enrolled"
        return 0
    fi
    
    # Add recovery key using current password
    if printf '%s' "$CURRENT_PASSWORD" | cryptsetup luksAddKey "$LUKS_DEVICE" <(printf '%s' "$RECOVERY_KEY"); then
        print_success "Recovery key enrolled successfully"
    else
        print_error "Failed to enroll recovery key"
        return 1
    fi
}

# Function to enroll TPM2
enroll_tpm2() {
    if [[ "$NEEDS_TPM2_ENROLLMENT" == "false" ]]; then
        print_success "TPM2 already enrolled"
        return 0
    fi
    
    print_info "Enrolling TPM2 for automatic unlock..."
    
    # Enroll TPM2 with PCR 7 (Secure Boot state)
    print_info "Enrolling TPM2 with PCR 7..."
    if PASSWORD="$CURRENT_PASSWORD" systemd-cryptenroll "$LUKS_DEVICE" \
        --tpm2-device=auto \
        --tpm2-pcrs=7 \
        --tpm2-with-pin=no; then
        print_success "TPM2 enrolled successfully"
    else
        print_error "Failed to enroll TPM2"
        print_info "Common causes:"
        print_info "  - TPM2 device not accessible"
        print_info "  - systemd-cryptenroll TPM2 support issues"
        return 1
    fi
    
    # Update initramfs
    print_info "Updating initramfs..."
    update-initramfs -u -k all
}

# Function to enroll new user password
enroll_new_password() {
    if [[ "$NEEDS_NEW_PASSWORD" == "false" ]]; then
        print_success "New password already enrolled"
        return 0
    fi
    
    print_info "Adding new user password to LUKS..."
    
    # Add new password using current password
    if printf '%s' "$CURRENT_PASSWORD" | cryptsetup luksAddKey "$LUKS_DEVICE" <(printf '%s' "$NEW_USER_PASSWORD"); then
        print_success "New user password enrolled successfully"
    else
        print_error "Failed to enroll new password"
        return 1
    fi
}

# Function to remove old passwords
remove_old_passwords() {
    if [[ "$NEEDS_PASSWORD_REMOVAL" == "false" ]]; then
        print_success "No old passwords to remove"
        return 0
    fi
    
    print_info "Removing old passwords..."
    show_luks_slots
    
    # Remove old password if we have it
    if [[ -n "$OLD_PASSWORD" ]]; then
        # Find which slot has this password
        local slot_found=""
        for i in {0..7}; do
            if printf '%s' "$OLD_PASSWORD" | cryptsetup open --test-passphrase "$LUKS_DEVICE" --key-slot "$i" 2>/dev/null; then
                slot_found="$i"
                print_info "Found old password in slot $i"
                break
            fi
        done
        
        if [[ -n "$slot_found" ]]; then
            # Use new password to remove the old slot
            print_info "Removing old password..."
            if printf '%s' "$NEW_USER_PASSWORD" | cryptsetup luksKillSlot "$LUKS_DEVICE" "$slot_found"; then
                print_success "Old password removed from slot $slot_found"
            else
                print_error "Failed to remove old password"
                return 1
            fi
        fi
    fi
    
    # Remove the current password if it's different from the new one
    if [[ "$CURRENT_PASSWORD" != "$NEW_USER_PASSWORD" ]] && [[ "$NEEDS_NEW_PASSWORD" == "true" ]]; then
        print_info "Current password is different from new password"
        print_info "Checking if current password should be removed..."
        
        # Find which slot has the current password
        local current_slot=""
        for i in {0..7}; do
            if printf '%s' "$CURRENT_PASSWORD" | cryptsetup open --test-passphrase "$LUKS_DEVICE" --key-slot "$i" 2>/dev/null; then
                # Make sure it's not a TPM slot or recovery key
                if ! cryptsetup luksDump "$LUKS_DEVICE" 2>/dev/null | grep -A5 "^  $i:" | grep -q "tpm2"; then
                    if ! printf '%s' "$RECOVERY_KEY" | cryptsetup open --test-passphrase "$LUKS_DEVICE" --key-slot "$i" 2>/dev/null; then
                        current_slot="$i"
                        print_info "Found old current password in slot $i"
                        break
                    fi
                fi
            fi
        done
        
        if [[ -n "$current_slot" ]]; then
            # Ask for confirmation before removing
            print_warning "Current password found in slot $current_slot"
            read -r -p "Remove current password? (y/N): " confirm_remove
            if [[ "$confirm_remove" =~ ^[Yy]$ ]]; then
                if printf '%s' "$NEW_USER_PASSWORD" | cryptsetup luksKillSlot "$LUKS_DEVICE" "$current_slot"; then
                    print_success "Old current password removed from slot $current_slot"
                else
                    print_warning "Failed to remove old current password"
                fi
            else
                print_info "Keeping current password in slot $current_slot"
            fi
        fi
    fi
}

# Function to verify final setup
verify_setup() {
    print_info "Verifying final setup..."
    
    local all_good=true
    
    # Check TPM2 enrollment
    if check_tpm2_enrollment "$LUKS_DEVICE"; then
        print_success "✓ TPM2 enrollment active"
    else
        print_error "✗ TPM2 enrollment missing"
        all_good=false
    fi
    
    # Check recovery key
    if printf '%s' "$RECOVERY_KEY" | cryptsetup open --test-passphrase "$LUKS_DEVICE" 2>/dev/null; then
        print_success "✓ Recovery key active"
    else
        print_error "✗ Recovery key not working"
        all_good=false
    fi
    
    # Check new password
    if printf '%s' "$NEW_USER_PASSWORD" | cryptsetup open --test-passphrase "$LUKS_DEVICE" 2>/dev/null; then
        print_success "✓ New user password active"
    else
        print_error "✗ New user password not working"
        all_good=false
    fi
    
    # Show final slot status
    print_info "Final LUKS key slots:"
    show_luks_slots
    
    return $([ "$all_good" = true ] && echo 0 || echo 1)
}

# Main function
main() {
    print_info "TPM2 LUKS Auto-unlock Setup (systemd-cryptenroll) - Version 5"
    echo "======================================================================"
    echo
    echo "This script will:"
    echo "  1. Verify system requirements (TPM2, systemd version)"
    echo "  2. Get current LUKS password for authentication"
    echo "  3. Set up or reuse a recovery key"
    echo "  4. Set a new user password"
    echo "  5. Enroll TPM2 for automatic unlock"
    echo "  6. Remove old passwords (optional)"
    echo
    echo "The script is idempotent and can be run multiple times safely."
    echo
    
    read -r -p "Continue? (y/N): " response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        print_info "Setup cancelled"
        exit 0
    fi
    
    # Step 1: Check prerequisites
    check_tpm2_hardware || exit 1
    check_systemd_version || exit 1
    find_luks_device || exit 1
    install_packages
    
    # Step 2: Check current state
    check_current_state
    
    # Step 3: Get current working password
    get_current_password
    
    # Step 4: Set up recovery key (if needed)
    setup_recovery_key || exit 1
    
    # Step 5: Get new password
    get_new_password
    
    # Step 6: Get old password (if needed)
    get_old_password
    
    # Step 7: Enroll everything in correct order
    enroll_recovery_key || exit 1
    enroll_tpm2 || exit 1
    enroll_new_password || exit 1
    
    # Step 8: Remove old passwords
    if [[ "$NEEDS_PASSWORD_REMOVAL" == "true" ]]; then
        remove_old_passwords || print_warning "Some passwords could not be removed"
    fi
    
    # Step 9: Verify setup
    if verify_setup; then
        echo
        print_success "Setup completed successfully!"
        print_info "The system will now unlock automatically using TPM2 on boot"
        print_warning "Keep your recovery key safe: $RECOVERY_KEY_FILE"
    else
        echo
        print_error "Setup completed with some issues. Please check the errors above."
        exit 1
    fi
}

# Run main function
main "$@"