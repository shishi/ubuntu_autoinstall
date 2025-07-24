#!/usr/bin/env bash
set -euo pipefail

# TPM2 LUKS Auto-unlock Setup Script with systemd-cryptenroll (Version 7)
# Properly structured flow with correct error handling

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

# Error handler
error_handler() {
    local line_no=$1
    print_error "An error occurred at line $line_no"
    exit 1
}

trap 'error_handler ${LINENO}' ERR

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root"
   exit 1
fi

# Global variables - properly initialized
LUKS_DEVICE=""
CURRENT_PASSWORD=""
RECOVERY_KEY=""
RECOVERY_KEY_FILE=""
NEW_USER_PASSWORD=""

# State tracking - with defaults
NEEDS_RECOVERY_KEY=true
NEEDS_TPM2_ENROLLMENT=true
NEEDS_NEW_PASSWORD=true
HAS_EXISTING_RECOVERY_KEY=false

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to generate a secure random recovery key
generate_recovery_key() {
    # Generate URL-safe base64 to avoid shell-breaking characters
    openssl rand -base64 48 | tr -d '\n' | tr '+/' '-_'
}

# Function to validate prerequisites
validate_prerequisites() {
    local failed=false
    
    print_info "Validating prerequisites..."
    
    # Check TPM2 hardware
    if [[ -e /dev/tpm0 ]] || [[ -e /dev/tpmrm0 ]] || [[ -d /sys/class/tpm/tpm0 ]]; then
        print_success "TPM2 hardware found"
    else
        print_error "No TPM2 hardware device found"
        failed=true
    fi
    
    # Check systemd version
    local systemd_version
    systemd_version=$(systemctl --version | head -1 | awk '{print $2}' || echo "0")
    
    if [[ "$systemd_version" -ge 248 ]]; then
        print_success "systemd version $systemd_version (≥248)"
    else
        print_error "systemd version $systemd_version (<248 required)"
        failed=true
    fi
    
    # Check for systemd-cryptenroll
    if command_exists systemd-cryptenroll; then
        print_success "systemd-cryptenroll available"
    else
        print_error "systemd-cryptenroll not found"
        failed=true
    fi
    
    if [[ "$failed" == "true" ]]; then
        return 1
    fi
    
    return 0
}

# Function to install required packages
install_packages() {
    print_info "Checking required packages..."
    
    local packages=(
        "systemd"
        "tpm2-tools"
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
        print_info "Installing: ${missing_packages[*]}"
        apt-get update
        apt-get install -y "${missing_packages[@]}"
    else
        print_success "All packages installed"
    fi
}

# Function to find LUKS device
find_luks_device() {
    print_info "Searching for LUKS devices..."
    
    local luks_devices=()
    local device
    
    # Safe pattern matching
    shopt -s nullglob
    for device in /dev/sd* /dev/nvme* /dev/vd*; do
        if [[ -b "$device" ]] && cryptsetup isLuks "$device" 2>/dev/null; then
            luks_devices+=("$device")
        fi
    done
    shopt -u nullglob
    
    if [[ ${#luks_devices[@]} -eq 0 ]]; then
        print_error "No LUKS devices found"
        return 1
    elif [[ ${#luks_devices[@]} -eq 1 ]]; then
        LUKS_DEVICE="${luks_devices[0]}"
        print_success "Found LUKS device: $LUKS_DEVICE"
    else
        print_warning "Multiple LUKS devices found:"
        local i
        for i in "${!luks_devices[@]}"; do
            echo "  $((i+1)). ${luks_devices[$i]}"
        done
        local selection
        read -r -p "Select device (1-${#luks_devices[@]}): " selection
        LUKS_DEVICE="${luks_devices[$((selection-1))]}"
    fi
    
    return 0
}

# Function to show LUKS slots
show_luks_slots() {
    print_info "LUKS key slots for $LUKS_DEVICE:"
    cryptsetup luksDump "$LUKS_DEVICE" 2>/dev/null | grep -E "^Key Slot|^  [0-9]+: luks2" | head -20 || true
}

# Function to check existing state
check_existing_state() {
    print_info "Checking existing configuration..."
    
    # Check for recovery keys
    local recovery_key_files=()
    if [[ -d /root ]]; then
        shopt -s nullglob
        recovery_key_files=(/root/.luks-recovery-key-*.txt)
        shopt -u nullglob
    fi
    
    if [[ ${#recovery_key_files[@]} -gt 0 ]]; then
        print_info "Found ${#recovery_key_files[@]} recovery key file(s)"
        
        # Test the most recent one
        local latest_key_file="${recovery_key_files[-1]}"
        local test_key
        test_key=$(grep "Recovery Key:" "$latest_key_file" 2>/dev/null | cut -d: -f2- | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' || true)
        
        if [[ -n "$test_key" ]] && printf '%s' "$test_key" | cryptsetup open --test-passphrase "$LUKS_DEVICE" 2>/dev/null; then
            print_success "Existing recovery key is valid"
            RECOVERY_KEY="$test_key"
            RECOVERY_KEY_FILE="$latest_key_file"
            NEEDS_RECOVERY_KEY=false
            HAS_EXISTING_RECOVERY_KEY=true
        else
            print_warning "Existing recovery key is invalid or doesn't match"
        fi
    fi
    
    # Check TPM2 enrollment
    if cryptsetup luksDump "$LUKS_DEVICE" 2>/dev/null | grep -q "tpm2"; then
        print_success "TPM2 already enrolled"
        NEEDS_TPM2_ENROLLMENT=false
    else
        print_info "TPM2 not enrolled"
    fi
}

# Function to get current password
get_current_password() {
    print_info "Authentication required"
    
    local attempts=0
    local max_attempts=3
    
    while [[ $attempts -lt $max_attempts ]]; do
        read -r -s -p "Enter current LUKS password: " CURRENT_PASSWORD
        echo
        
        if printf '%s' "$CURRENT_PASSWORD" | cryptsetup open --test-passphrase "$LUKS_DEVICE" 2>/dev/null; then
            print_success "Password verified"
            return 0
        else
            ((attempts++))
            if [[ $attempts -lt $max_attempts ]]; then
                print_error "Invalid password ($attempts/$max_attempts)"
            fi
        fi
    done
    
    print_error "Failed to verify password after $max_attempts attempts"
    return 1
}

# Function to setup recovery key
setup_recovery_key() {
    if [[ "$NEEDS_RECOVERY_KEY" == "false" ]]; then
        print_info "Using existing recovery key"
        return 0
    fi
    
    print_info "Creating new recovery key..."
    
    RECOVERY_KEY=$(generate_recovery_key)
    RECOVERY_KEY_FILE="/root/.luks-recovery-key-$(date +%Y%m%d-%H%M%S).txt"
    
    {
        echo "LUKS Recovery Key for $LUKS_DEVICE"
        echo "Generated on: $(date)"
        echo "Recovery Key: $RECOVERY_KEY"
    } > "$RECOVERY_KEY_FILE"
    
    chmod 600 "$RECOVERY_KEY_FILE"
    
    # Add to LUKS
    if printf '%s' "$CURRENT_PASSWORD" | cryptsetup luksAddKey "$LUKS_DEVICE" <(printf '%s' "$RECOVERY_KEY"); then
        print_success "Recovery key created and enrolled"
        print_warning "SAVE THIS KEY: $RECOVERY_KEY"
        echo
    else
        print_error "Failed to enroll recovery key"
        return 1
    fi
    
    return 0
}

# Function to get new password
get_new_password() {
    print_info "Setting up new user password..."
    
    local attempts=0
    local password_set=false
    
    while [[ "$password_set" == "false" ]]; do
        local temp_password=""
        read -r -s -p "Enter new password: " temp_password
        echo
        local confirm_password=""
        read -r -s -p "Confirm new password: " confirm_password
        echo
        
        if [[ "$temp_password" != "$confirm_password" ]]; then
            print_error "Passwords don't match"
            continue
        fi
        
        if [[ ${#temp_password} -lt 8 ]]; then
            print_error "Password too short (minimum 8 characters)"
            continue
        fi
        
        # Check if already exists
        if printf '%s' "$temp_password" | cryptsetup open --test-passphrase "$LUKS_DEVICE" 2>/dev/null; then
            print_info "This password already exists in LUKS"
            NEEDS_NEW_PASSWORD=false
        else
            NEEDS_NEW_PASSWORD=true
        fi
        
        NEW_USER_PASSWORD="$temp_password"
        password_set=true
    done
    
    return 0
}

# Function to enroll TPM2
enroll_tpm2() {
    if [[ "$NEEDS_TPM2_ENROLLMENT" == "false" ]]; then
        read -r -p "TPM2 already enrolled. Re-enroll? (y/N): " response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            return 0
        fi
    fi
    
    print_info "Enrolling TPM2..."
    
    # Remove existing TPM2 enrollment if any
    if [[ "$NEEDS_TPM2_ENROLLMENT" == "false" ]]; then
        print_info "Removing existing TPM2 enrollment..."
        if ! PASSWORD="$CURRENT_PASSWORD" systemd-cryptenroll "$LUKS_DEVICE" --wipe-slot=tpm2 2>/dev/null; then
            print_warning "Could not remove existing TPM2 enrollment"
        fi
    fi
    
    # Enroll new
    if PASSWORD="$CURRENT_PASSWORD" systemd-cryptenroll "$LUKS_DEVICE" \
        --tpm2-device=auto \
        --tpm2-pcrs=7 \
        --tpm2-with-pin=no; then
        print_success "TPM2 enrolled successfully"
        
        # Update initramfs
        print_info "Updating initramfs..."
        update-initramfs -u -k all
        
        return 0
    else
        print_error "Failed to enroll TPM2"
        return 1
    fi
}

# Function to add new password
add_new_password() {
    if [[ "$NEEDS_NEW_PASSWORD" == "false" ]]; then
        print_info "New password already exists"
        return 0
    fi
    
    print_info "Adding new password..."
    
    if printf '%s' "$CURRENT_PASSWORD" | cryptsetup luksAddKey "$LUKS_DEVICE" <(printf '%s' "$NEW_USER_PASSWORD"); then
        print_success "New password added"
        return 0
    else
        print_error "Failed to add new password"
        return 1
    fi
}

# Function to cleanup old passwords
cleanup_old_passwords() {
    # Skip if passwords are the same
    if [[ "$CURRENT_PASSWORD" == "$NEW_USER_PASSWORD" ]]; then
        print_info "No old passwords to remove"
        return 0
    fi
    
    print_info "Checking for old passwords to remove..."
    
    # Find slot with current password
    local current_slot=""
    local i
    for i in {0..7}; do
        if printf '%s' "$CURRENT_PASSWORD" | cryptsetup open --test-passphrase "$LUKS_DEVICE" --key-slot "$i" 2>/dev/null; then
            # Skip if it's recovery key or TPM
            if [[ -n "$RECOVERY_KEY" ]] && printf '%s' "$RECOVERY_KEY" | cryptsetup open --test-passphrase "$LUKS_DEVICE" --key-slot "$i" 2>/dev/null; then
                continue
            fi
            if cryptsetup luksDump "$LUKS_DEVICE" 2>/dev/null | grep -A5 "^  $i:" | grep -q "tpm2"; then
                continue
            fi
            current_slot="$i"
            break
        fi
    done
    
    if [[ -n "$current_slot" ]]; then
        print_warning "Old password found in slot $current_slot"
        read -r -p "Remove old password? (y/N): " response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            if printf '%s' "$NEW_USER_PASSWORD" | cryptsetup luksKillSlot "$LUKS_DEVICE" "$current_slot" 2>/dev/null; then
                print_success "Old password removed"
            else
                print_warning "Could not remove old password"
            fi
        fi
    fi
    
    return 0
}

# Function to verify final setup
verify_final_setup() {
    print_info "Verifying configuration..."
    
    local all_good=true
    
    # Check TPM2
    if cryptsetup luksDump "$LUKS_DEVICE" 2>/dev/null | grep -q "tpm2"; then
        print_success "✓ TPM2 enrollment active"
    else
        print_error "✗ TPM2 enrollment missing"
        all_good=false
    fi
    
    # Check recovery key
    if [[ -n "$RECOVERY_KEY" ]] && printf '%s' "$RECOVERY_KEY" | cryptsetup open --test-passphrase "$LUKS_DEVICE" 2>/dev/null; then
        print_success "✓ Recovery key active"
    else
        print_error "✗ Recovery key not working"
        all_good=false
    fi
    
    # Check new password
    if printf '%s' "$NEW_USER_PASSWORD" | cryptsetup open --test-passphrase "$LUKS_DEVICE" 2>/dev/null; then
        print_success "✓ User password active"
    else
        print_error "✗ User password not working"
        all_good=false
    fi
    
    echo
    show_luks_slots
    
    if [[ "$all_good" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

# Main function with proper flow control
main() {
    print_info "TPM2 LUKS Auto-unlock Setup (systemd-cryptenroll) v7"
    echo "========================================================"
    echo
    
    # Step 1: Validate prerequisites
    if ! validate_prerequisites; then
        print_error "Prerequisites not met"
        exit 1
    fi
    
    # Step 2: Install packages
    install_packages
    
    # Step 3: Find LUKS device
    if ! find_luks_device; then
        exit 1
    fi
    
    # Step 4: Check existing state
    check_existing_state
    
    # Step 5: Get authentication
    if ! get_current_password; then
        exit 1
    fi
    
    # Step 6: Setup recovery key
    if ! setup_recovery_key; then
        print_error "Failed to setup recovery key"
        exit 1
    fi
    
    # Step 7: Get new password
    get_new_password
    
    # Step 8: Perform enrollments
    add_new_password
    enroll_tpm2
    
    # Step 9: Cleanup
    cleanup_old_passwords
    
    # Step 10: Verify
    if verify_final_setup; then
        echo
        print_success "Setup completed successfully!"
        print_info "Recovery key file: $RECOVERY_KEY_FILE"
        print_warning "Keep your recovery key safe!"
    else
        echo
        print_warning "Setup completed with some issues"
        exit 1
    fi
}

# Run main function
main "$@"