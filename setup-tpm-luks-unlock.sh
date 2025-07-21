#!/usr/bin/env bash
set -euo pipefail

# TPM2 LUKS Auto-unlock Setup Script with Clevis
# This script sets up automatic LUKS decryption using TPM2 and Clevis
# It removes the installation password and sets up a new password + recovery key

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

# Function to generate a secure random passphrase
generate_recovery_key() {
    # Generate 8 random words from /usr/share/dict/words if available
    if [[ -f /usr/share/dict/words ]]; then
        shuf -n 8 /usr/share/dict/words | tr '\n' '-' | sed 's/-$//' | tr -d "'"
    else
        # Fallback to random base64 string (no single quotes in base64)
        openssl rand -base64 32
    fi
}

# Function to check TPM2 availability
check_tpm2() {
    print_info "Checking TPM2 availability..."
    
    if ! command_exists tpm2_getcap; then
        print_warning "tpm2-tools not installed. Will be installed during setup."
        return 2  # Special return code for "tools missing but can be installed"
    fi
    
    if ! tpm2_getcap properties-fixed 2>/dev/null | grep -q "TPM2_PT_FAMILY_INDICATOR"; then
        print_error "TPM2 device not found or not accessible"
        return 1
    fi
    
    print_success "TPM2 device is available"
    return 0
}

# Function to check TPM2 hardware only
check_tpm2_hardware() {
    print_info "Checking TPM2 hardware availability..."
    
    # Check if TPM device exists
    if [[ -e /dev/tpm0 ]] || [[ -e /dev/tpmrm0 ]]; then
        print_success "TPM device found"
        return 0
    fi
    
    # Check if TPM is visible in sysfs
    if [[ -d /sys/class/tpm/tpm0 ]]; then
        print_success "TPM device found in sysfs"
        return 0
    fi
    
    print_error "No TPM2 hardware device found"
    return 1
}

# Function to install required packages
install_packages() {
    print_info "Checking and installing required packages..."
    
    local packages=(
        "clevis"
        "clevis-tpm2"
        "clevis-luks"
        "clevis-initramfs"
        "clevis-systemd"
        "clevis-udisks2"
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
        read -p "Select device (1-${#luks_devices[@]}): " selection
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
    cryptsetup luksDump "$LUKS_DEVICE" | grep -E "^Key Slot|^\s+Key material offset"
}

# Function to check if Clevis is already bound
check_clevis_binding() {
    if clevis luks list -d "$LUKS_DEVICE" 2>/dev/null | grep -q "tpm2"; then
        print_warning "Clevis TPM2 binding already exists on $LUKS_DEVICE"
        local slots=$(clevis luks list -d "$LUKS_DEVICE" | grep "tpm2" | cut -d: -f1)
        print_info "TPM2 bound to slot(s): $slots"
        return 0
    else
        return 1
    fi
}

# Function to setup new password and recovery key
setup_new_credentials() {
    print_info "Setting up new credentials..."
    
    # Check for existing recovery keys
    local existing_keys=()
    if [[ -d /root ]] && ls /root/.luks-recovery-key-*.txt 2>/dev/null | grep -q .; then
        readarray -t existing_keys < <(ls -t /root/.luks-recovery-key-*.txt 2>/dev/null)
    fi
    
    if [[ ${#existing_keys[@]} -gt 0 ]]; then
        print_warning "Found ${#existing_keys[@]} existing recovery key file(s):"
        for key in "${existing_keys[@]}"; do
            echo "  - $key (created: $(stat -c %y "$key" 2>/dev/null | awk '{print $1}'))"
        done
        
        read -p "Use existing recovery key? (y/N): " use_existing
        if [[ "$use_existing" =~ ^[Yy]$ ]]; then
            RECOVERY_KEY_FILE="${existing_keys[0]}"
            # Extract recovery key from file
            RECOVERY_KEY=$(grep "Recovery Key:" "$RECOVERY_KEY_FILE" | cut -d: -f2- | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
            if [[ -z "$RECOVERY_KEY" ]]; then
                print_error "Could not read recovery key from file"
                return 1
            fi
            print_success "Using existing recovery key from: $RECOVERY_KEY_FILE"
            echo
            echo "Recovery Key: $RECOVERY_KEY"
            echo
        else
            # Generate new recovery key
            RECOVERY_KEY=$(generate_recovery_key)
            
            # Save recovery key to a temporary secure location
            RECOVERY_KEY_FILE="/root/.luks-recovery-key-$(date +%Y%m%d-%H%M%S).txt"
            echo "LUKS Recovery Key for $LUKS_DEVICE" > "$RECOVERY_KEY_FILE"
            echo "Generated on: $(date)" >> "$RECOVERY_KEY_FILE"
            echo "Recovery Key: $RECOVERY_KEY" >> "$RECOVERY_KEY_FILE"
            chmod 600 "$RECOVERY_KEY_FILE"
            
            print_success "New recovery key saved to: $RECOVERY_KEY_FILE"
            print_warning "IMPORTANT: Save this recovery key in a secure location and remove the file!"
            echo
            echo "Recovery Key: $RECOVERY_KEY"
            echo
            
            # Optionally clean up old recovery key files
            if [[ ${#existing_keys[@]} -gt 3 ]]; then
                print_warning "Found more than 3 recovery key files."
                read -p "Keep only the 3 most recent files? (y/N): " cleanup_old
                if [[ "$cleanup_old" =~ ^[Yy]$ ]]; then
                    # Keep the 3 most recent files
                    for i in "${!existing_keys[@]}"; do
                        if [[ $i -ge 3 ]]; then
                            rm -f "${existing_keys[$i]}"
                            print_info "Removed old recovery key file: ${existing_keys[$i]}"
                        fi
                    done
                fi
            fi
        fi
    else
        # Generate recovery key
        RECOVERY_KEY=$(generate_recovery_key)
        
        # Save recovery key to a temporary secure location
        RECOVERY_KEY_FILE="/root/.luks-recovery-key-$(date +%Y%m%d-%H%M%S).txt"
        echo "LUKS Recovery Key for $LUKS_DEVICE" > "$RECOVERY_KEY_FILE"
        echo "Generated on: $(date)" >> "$RECOVERY_KEY_FILE"
        echo "Recovery Key: $RECOVERY_KEY" >> "$RECOVERY_KEY_FILE"
        chmod 600 "$RECOVERY_KEY_FILE"
        
        print_success "Recovery key saved to: $RECOVERY_KEY_FILE"
        print_warning "IMPORTANT: Save this recovery key in a secure location and remove the file!"
        echo
        echo "Recovery Key: $RECOVERY_KEY"
        echo
    fi
    
    # Get new password from user
    local password_needed=true
    
    # First check if we need a new password at all
    print_info "Checking if a user password is needed..."
    
    while $password_needed; do
        read -s -p "Enter new LUKS password (or press Enter to skip if already set): " NEW_PASSWORD
        echo
        
        if [[ -z "$NEW_PASSWORD" ]]; then
            print_info "Skipping new password setup"
            # We'll need to get the existing password for operations
            read -s -p "Enter existing LUKS password for operations: " NEW_PASSWORD
            echo
            if echo -n "$NEW_PASSWORD" | cryptsetup luksOpen --test-passphrase "$LUKS_DEVICE" 2>/dev/null; then
                print_success "Using existing password for operations"
                password_needed=false
            else
                print_error "Invalid password"
            fi
        else
            read -s -p "Confirm new LUKS password: " NEW_PASSWORD_CONFIRM
            echo
            
            if [[ "$NEW_PASSWORD" == "$NEW_PASSWORD_CONFIRM" ]]; then
                if [[ ${#NEW_PASSWORD} -lt 8 ]]; then
                    print_error "Password must be at least 8 characters long"
                else
                    password_needed=false
                    print_success "New password configured"
                fi
            else
                print_error "Passwords do not match"
            fi
        fi
    done
}

# Function to bind LUKS to TPM2 using Clevis
bind_tpm2() {
    print_info "Binding LUKS to TPM2..."
    
    # Check if already bound
    if check_clevis_binding; then
        read -p "TPM2 binding already exists. Replace it? (y/N): " response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            print_info "Keeping existing TPM2 binding"
            return 0
        fi
        
        # Remove existing binding
        local slots=$(clevis luks list -d "$LUKS_DEVICE" | grep "tpm2" | cut -d: -f1)
        for slot in $slots; do
            print_info "Removing existing TPM2 binding from slot $slot"
            clevis luks unbind -d "$LUKS_DEVICE" -s "$slot" -f
        done
    fi
    
    # Need current password to bind
    print_info "You'll need to enter the current LUKS password to bind TPM2"
    
    # Bind to TPM2 with PCR 7 (Secure Boot state)
    if clevis luks bind -d "$LUKS_DEVICE" tpm2 '{"pcr_bank":"sha256","pcr_ids":"7"}'; then
        print_success "Successfully bound LUKS to TPM2"
    else
        print_error "Failed to bind LUKS to TPM2"
        return 1
    fi
    
    # Update initramfs
    print_info "Updating initramfs..."
    update-initramfs -u -k all
    
    return 0
}

# Function to check if a password already exists in LUKS
check_password_exists() {
    local password="$1"
    echo -n "$password" | cryptsetup luksOpen --test-passphrase "$LUKS_DEVICE" 2>/dev/null
}

# Function to manage LUKS key slots
manage_key_slots() {
    print_info "Managing LUKS key slots..."
    
    # Show current slots
    show_luks_slots
    
    # Get current password
    print_info "Enter current LUKS password to continue:"
    read -s -p "Current password: " CURRENT_PASSWORD
    echo
    
    # Test current password
    if ! echo -n "$CURRENT_PASSWORD" | cryptsetup luksOpen --test-passphrase "$LUKS_DEVICE" 2>/dev/null; then
        print_error "Invalid password"
        return 1
    fi
    
    # Check if new password already exists
    if check_password_exists "$NEW_PASSWORD"; then
        print_warning "New password already exists in LUKS slots"
        local new_password_exists=true
    else
        local new_password_exists=false
        
        # Find an empty slot for new password
        local new_slot=""
        for i in 1 2 3 4 5 6 7 0; do  # Try slots 1-7 first, then 0
            if ! cryptsetup luksDump "$LUKS_DEVICE" | grep -q "Key Slot $i: ENABLED"; then
                new_slot=$i
                break
            fi
        done
        
        if [[ -z "$new_slot" ]]; then
            print_error "No empty key slots available"
            return 1
        fi
        
        # Add new password
        print_info "Adding new password to slot $new_slot..."
        if echo -n "$CURRENT_PASSWORD" | cryptsetup luksAddKey "$LUKS_DEVICE" --key-slot "$new_slot" <(echo -n "$NEW_PASSWORD"); then
            print_success "New password added to slot $new_slot"
        else
            print_warning "Failed to add to slot $new_slot, trying without specific slot..."
            if echo -n "$CURRENT_PASSWORD" | cryptsetup luksAddKey "$LUKS_DEVICE" <(echo -n "$NEW_PASSWORD"); then
                print_success "New password added to an available slot"
            else
                print_error "Failed to add new password"
                return 1
            fi
        fi
    fi
    
    # Check if recovery key already exists
    if check_password_exists "$RECOVERY_KEY"; then
        print_warning "Recovery key already exists in LUKS slots"
    else
        # Find an empty slot for recovery key
        local recovery_slot=""
        for i in 1 2 3 4 5 6 7 0; do  # Try slots 1-7 first, then 0
            if ! cryptsetup luksDump "$LUKS_DEVICE" | grep -q "Key Slot $i: ENABLED"; then
                recovery_slot=$i
                break
            fi
        done
        
        if [[ -z "$recovery_slot" ]]; then
            print_warning "No empty slot for recovery key, will skip"
        else
            print_info "Adding recovery key to slot $recovery_slot..."
            # Use the appropriate password for adding the key
            local auth_password="$NEW_PASSWORD"
            if [[ "$new_password_exists" == "true" ]] || [[ -z "$NEW_PASSWORD" ]]; then
                auth_password="$CURRENT_PASSWORD"
            fi
            
            if echo -n "$auth_password" | cryptsetup luksAddKey "$LUKS_DEVICE" --key-slot "$recovery_slot" <(echo -n "$RECOVERY_KEY"); then
                print_success "Recovery key added to slot $recovery_slot"
            else
                print_warning "Failed to add to slot $recovery_slot, trying without specific slot..."
                if echo -n "$auth_password" | cryptsetup luksAddKey "$LUKS_DEVICE" <(echo -n "$RECOVERY_KEY"); then
                    print_success "Recovery key added to an available slot"
                else
                    print_warning "Failed to add recovery key - you may need to add it manually later"
                fi
            fi
        fi
    fi
    
    # Show updated slots
    print_info "Updated LUKS key slots:"
    show_luks_slots
    
    # Ask about removing old password
    print_warning "The original installation password is still active"
    read -p "Remove the original installation password? (y/N): " response
    
    if [[ "$response" =~ ^[Yy]$ ]]; then
        # Find which slot has the installation password
        print_info "Identifying installation password slot..."
        
        # We need to be careful here - only remove if we're sure
        local slots_to_check=()
        for i in {0..7}; do
            if cryptsetup luksDump "$LUKS_DEVICE" | grep -q "Key Slot $i: ENABLED"; then
                if [[ "$i" != "$new_slot" ]] && [[ "$i" != "$recovery_slot" ]]; then
                    # Skip Clevis slots
                    if ! clevis luks list -d "$LUKS_DEVICE" 2>/dev/null | grep -q "^$i:"; then
                        slots_to_check+=("$i")
                    fi
                fi
            fi
        done
        
        if [[ ${#slots_to_check[@]} -eq 1 ]]; then
            local old_slot="${slots_to_check[0]}"
            print_info "Removing old password from slot $old_slot..."
            echo -n "$NEW_PASSWORD" | cryptsetup luksKillSlot "$LUKS_DEVICE" "$old_slot"
            print_success "Old password removed"
        else
            print_warning "Could not automatically identify installation password slot"
            print_info "Current non-Clevis slots: ${slots_to_check[*]}"
            print_info "You can manually remove slots later using: cryptsetup luksKillSlot $LUKS_DEVICE <slot>"
        fi
    fi
}

# Function to check current setup state
check_setup_state() {
    print_info "Checking current TPM2 LUKS setup state..."
    
    local state_summary=""
    local is_fully_configured=true
    
    # Check TPM2 availability
    if check_tpm2 >/dev/null 2>&1; then
        state_summary+="  ✓ TPM2 device available\n"
    else
        state_summary+="  ✗ TPM2 device not available\n"
        is_fully_configured=false
    fi
    
    # Check required packages
    local missing_packages=0
    for pkg in clevis clevis-tpm2 clevis-luks tpm2-tools; do
        if ! dpkg -l | grep -q "^ii  $pkg "; then
            ((missing_packages++))
        fi
    done
    
    if [[ $missing_packages -eq 0 ]]; then
        state_summary+="  ✓ All required packages installed\n"
    else
        state_summary+="  ✗ $missing_packages required packages missing\n"
        is_fully_configured=false
    fi
    
    # Check Clevis binding
    if check_clevis_binding >/dev/null 2>&1; then
        state_summary+="  ✓ Clevis TPM2 binding exists\n"
    else
        state_summary+="  ✗ Clevis TPM2 binding not configured\n"
        is_fully_configured=false
    fi
    
    # Check for recovery keys
    local recovery_key_count=0
    if [[ -d /root ]]; then
        recovery_key_count=$(ls /root/.luks-recovery-key-*.txt 2>/dev/null | wc -l)
    fi
    
    if [[ $recovery_key_count -gt 0 ]]; then
        state_summary+="  ✓ $recovery_key_count recovery key file(s) found\n"
    else
        state_summary+="  ⚠ No recovery key files found\n"
    fi
    
    # Check service status
    if systemctl is-enabled clevis-luks-askpass.path >/dev/null 2>&1; then
        state_summary+="  ✓ clevis-luks-askpass service enabled\n"
    else
        state_summary+="  ✗ clevis-luks-askpass service not enabled\n"
        is_fully_configured=false
    fi
    
    echo -e "\nCurrent Setup State:\n$state_summary"
    
    if [[ "$is_fully_configured" == "true" ]]; then
        print_success "System appears to be fully configured for TPM2 auto-unlock"
        return 0
    else
        return 1
    fi
}

# Function to verify setup
verify_setup() {
    print_info "Verifying TPM2 LUKS unlock setup..."
    
    # Check Clevis binding
    if ! check_clevis_binding; then
        print_error "Clevis TPM2 binding not found"
        return 1
    fi
    
    # Check if clevis-luks-askpass is enabled
    if systemctl is-enabled clevis-luks-askpass.path >/dev/null 2>&1; then
        print_success "clevis-luks-askpass service is enabled"
    else
        print_warning "Enabling clevis-luks-askpass service..."
        systemctl enable clevis-luks-askpass.path
    fi
    
    # Final slot status
    print_info "Final LUKS key slot status:"
    show_luks_slots
    
    print_success "TPM2 LUKS unlock setup completed successfully!"
    print_info "The system will now unlock automatically using TPM2 on boot"
    print_warning "Make sure to save the recovery key in a secure location!"
    
    return 0
}

# Function to confirm action
confirm_action() {
    local prompt="$1"
    read -p "$prompt (y/N): " response
    [[ "$response" =~ ^[Yy]$ ]]
}

# Function to show setup plan
show_setup_plan() {
    echo
    echo "TPM2 LUKS Auto-unlock Setup Plan:"
    echo "================================="
    echo "This script will:"
    echo "  1. Check TPM2 device availability"
    echo "  2. Install required packages (if needed)"
    echo "  3. Set up or reuse recovery key"
    echo "  4. Configure user password (optional if already set)"
    echo "  5. Bind LUKS to TPM2 for auto-unlock"
    echo "  6. Manage LUKS key slots"
    echo "  7. Enable systemd services"
    echo
    echo "The script is idempotent and can be run multiple times safely."
    echo "Existing configurations will be detected and preserved."
    echo
}

# Main execution
main() {
    print_info "Starting TPM2 LUKS Auto-unlock Setup"
    echo "======================================"
    
    # Show what we're going to do
    show_setup_plan
    
    if ! confirm_action "Continue with setup?"; then
        print_info "Setup cancelled by user"
        exit 0
    fi
    
    # Step 1: Check TPM2 hardware (not tools)
    if ! check_tpm2_hardware; then
        print_error "TPM2 hardware is required for this setup"
        exit 1
    fi
    
    # Step 2: Find LUKS device
    if ! find_luks_device; then
        exit 1
    fi
    
    # Step 3: Install packages first (before checking TPM2 tools)
    install_packages
    
    # Step 4: Now check TPM2 with tools
    local tpm_check_result
    check_tpm2
    tpm_check_result=$?
    
    if [[ $tpm_check_result -eq 1 ]]; then
        print_error "TPM2 device not accessible even after installing tools"
        exit 1
    elif [[ $tpm_check_result -eq 2 ]]; then
        print_error "This should not happen - tools should be installed by now"
        exit 1
    fi
    
    # Check current state
    if check_setup_state; then
        print_warning "System appears to be already configured for TPM2 auto-unlock"
        if ! confirm_action "Continue with reconfiguration?"; then
            print_info "Exiting without changes"
            exit 0
        fi
    fi
    
    # Step 5: Setup new credentials
    setup_new_credentials
    
    # Step 6: Bind to TPM2
    if ! bind_tpm2; then
        exit 1
    fi
    
    # Step 7: Manage key slots
    if ! manage_key_slots; then
        exit 1
    fi
    
    # Step 8: Verify setup
    verify_setup
    
    echo
    print_success "Setup completed!"
    print_info "Recovery key file: $RECOVERY_KEY_FILE"
    print_warning "IMPORTANT: Save the recovery key securely and delete the file!"
    
    # Final state check
    echo
    check_setup_state
}

# Run main function
main "$@"