#!/usr/bin/env bash
set -euo pipefail

# TPM2 LUKS Auto-unlock Setup Script with systemd-cryptenroll (Version 2)
# Complete rewrite with correct flow

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
    print_info "Setting up recovery key..."
    
    # Check for existing recovery keys
    local existing_keys=()
    if [[ -d /root ]] && find /root -maxdepth 1 -name ".luks-recovery-key-*.txt" -type f 2>/dev/null | grep -q .; then
        readarray -t existing_keys < <(ls -t /root/.luks-recovery-key-*.txt 2>/dev/null)
    fi
    
    if [[ ${#existing_keys[@]} -gt 0 ]]; then
        print_warning "Found ${#existing_keys[@]} existing recovery key file(s):"
        for key in "${existing_keys[@]}"; do
            echo "  - $key (created: $(stat -c %y "$key" 2>/dev/null | awk '{print $1}'))"
        done
        
        read -r -p "Use existing recovery key? (y/N): " use_existing
        if [[ "$use_existing" =~ ^[Yy]$ ]]; then
            RECOVERY_KEY_FILE="${existing_keys[0]}"
            RECOVERY_KEY=$(grep "Recovery Key:" "$RECOVERY_KEY_FILE" | cut -d: -f2- | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
            if [[ -z "$RECOVERY_KEY" ]]; then
                print_error "Could not read recovery key from file"
                return 1
            fi
            print_success "Using existing recovery key"
            return 0
        fi
    fi
    
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
    print_info "Setting up new user password..."
    
    local password_valid=false
    
    while ! $password_valid; do
        read -r -s -p "Enter new user password: " NEW_USER_PASSWORD
        echo
        read -r -s -p "Confirm new user password: " password_confirm
        echo
        
        if [[ "$NEW_USER_PASSWORD" != "$password_confirm" ]]; then
            print_error "Passwords do not match"
        elif [[ ${#NEW_USER_PASSWORD} -lt 8 ]]; then
            print_error "Password must be at least 8 characters long"
        elif [[ "$NEW_USER_PASSWORD" == "$CURRENT_PASSWORD" ]]; then
            print_error "New password must be different from current password"
        else
            password_valid=true
            print_success "New password configured"
        fi
    done
}

# Function to enroll recovery key
enroll_recovery_key() {
    print_info "Enrolling recovery key in LUKS..."
    
    # Check if recovery key already exists
    if printf '%s' "$RECOVERY_KEY" | cryptsetup open --test-passphrase "$LUKS_DEVICE" 2>/dev/null; then
        print_warning "Recovery key already enrolled"
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
    print_info "Enrolling TPM2 for automatic unlock..."
    
    # Check if already enrolled
    if check_tpm2_enrollment "$LUKS_DEVICE"; then
        print_warning "TPM2 enrollment already exists"
        read -r -p "Replace existing TPM2 enrollment? (y/N): " response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            print_info "Keeping existing TPM2 enrollment"
            return 0
        fi
        
        # Remove existing enrollment
        print_info "Removing existing TPM2 enrollment..."
        if ! PASSWORD="$CURRENT_PASSWORD" systemd-cryptenroll "$LUKS_DEVICE" --wipe-slot=tpm2; then
            print_error "Failed to remove existing TPM2 enrollment"
            return 1
        fi
    fi
    
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
    print_info "Adding new user password to LUKS..."
    
    # Check if new password already exists
    if printf '%s' "$NEW_USER_PASSWORD" | cryptsetup open --test-passphrase "$LUKS_DEVICE" 2>/dev/null; then
        print_warning "New password already enrolled"
        return 0
    fi
    
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
    print_info "Removing old installation password..."
    show_luks_slots
    
    print_info "Current setup has:"
    print_info "  - Your new user password"
    print_info "  - Recovery key"
    print_info "  - TPM2 enrollment"
    print_info "  - Old passwords (to be removed)"
    
    print_info "To remove the installation password (ubuntuKey), please enter it:"
    
    local install_password_found=false
    local attempts=0
    
    while ! $install_password_found && [[ $attempts -lt 3 ]]; do
        read -r -s -p "Enter installation password (ubuntuKey): " install_password
        echo
        
        # Find which slot has this password
        local slot_found=""
        for i in {0..7}; do
            if printf '%s' "$install_password" | cryptsetup open --test-passphrase "$LUKS_DEVICE" --key-slot "$i" 2>/dev/null; then
                slot_found="$i"
                print_success "Found installation password in slot $i"
                install_password_found=true
                break
            fi
        done
        
        if [[ -n "$slot_found" ]]; then
            # Use new password to remove the old slot
            print_info "Removing installation password..."
            if printf '%s' "$NEW_USER_PASSWORD" | cryptsetup luksKillSlot "$LUKS_DEVICE" "$slot_found"; then
                print_success "Installation password removed from slot $slot_found"
            else
                print_error "Failed to remove installation password"
                return 1
            fi
        else
            ((attempts++))
            if [[ $attempts -lt 3 ]]; then
                print_error "Invalid password. Please try again. ($attempts/3)"
            else
                print_error "Failed to identify installation password after 3 attempts"
                print_warning "You may need to manually remove it later with:"
                print_info "  cryptsetup luksKillSlot $LUKS_DEVICE <slot-number>"
                return 1
            fi
        fi
    done
    
    # Also remove the current password if it's different from the new one
    if [[ "$CURRENT_PASSWORD" != "$NEW_USER_PASSWORD" ]]; then
        print_info "Removing the old current password..."
        
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
            if printf '%s' "$NEW_USER_PASSWORD" | cryptsetup luksKillSlot "$LUKS_DEVICE" "$current_slot"; then
                print_success "Old current password removed from slot $current_slot"
            else
                print_warning "Failed to remove old current password"
            fi
        fi
    fi
}

# Function to verify final setup
verify_setup() {
    print_info "Verifying final setup..."
    
    # Check TPM2 enrollment
    if check_tpm2_enrollment "$LUKS_DEVICE"; then
        print_success "✓ TPM2 enrollment active"
    else
        print_error "✗ TPM2 enrollment missing"
    fi
    
    # Check recovery key
    if printf '%s' "$RECOVERY_KEY" | cryptsetup open --test-passphrase "$LUKS_DEVICE" 2>/dev/null; then
        print_success "✓ Recovery key active"
    else
        print_error "✗ Recovery key not working"
    fi
    
    # Check new password
    if printf '%s' "$NEW_USER_PASSWORD" | cryptsetup open --test-passphrase "$LUKS_DEVICE" 2>/dev/null; then
        print_success "✓ New user password active"
    else
        print_error "✗ New user password not working"
    fi
    
    # Show final slot status
    print_info "Final LUKS key slots:"
    show_luks_slots
}

# Main function
main() {
    print_info "TPM2 LUKS Auto-unlock Setup (systemd-cryptenroll)"
    echo "=================================================="
    echo
    echo "This script will:"
    echo "  1. Verify system requirements (TPM2, systemd version)"
    echo "  2. Get current LUKS password for authentication"
    echo "  3. Set up or reuse a recovery key"
    echo "  4. Set a new user password"
    echo "  5. Enroll TPM2 for automatic unlock"
    echo "  6. Remove old passwords"
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
    
    # Step 2: Get current working password
    get_current_password
    
    # Step 3: Set up recovery key
    setup_recovery_key || exit 1
    
    # Step 4: Get new password
    get_new_password
    
    # Step 5: Enroll everything in correct order
    enroll_recovery_key || exit 1
    enroll_tpm2 || exit 1
    enroll_new_password || exit 1
    
    # Step 6: Remove old passwords
    remove_old_passwords || exit 1
    
    # Step 7: Verify setup
    verify_setup
    
    echo
    print_success "Setup completed successfully!"
    print_info "The system will now unlock automatically using TPM2 on boot"
    print_warning "Keep your recovery key safe: $RECOVERY_KEY_FILE"
}

# Run main function
main "$@"