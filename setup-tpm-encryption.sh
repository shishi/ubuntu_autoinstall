#!/bin/bash
#
# TPM-based LUKS encryption setup script
# This script should be run after Ubuntu installation with autoinstall-luks.yml
#
# Usage: sudo ./setup-tpm-encryption.sh <username>
#

set -euo pipefail

# Error trap for debugging
trap 'echo "Error occurred at line $LINENO. Exit code: $?"; exit 1' ERR

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

# Usage function
usage() {
    echo "Usage: $0 <username>"
    echo
    echo "Setup TPM-based LUKS encryption for the specified user"
    echo
    echo "Arguments:"
    echo "  <username>    The username to save recovery keys for"
    echo
    echo "Example:"
    echo "  sudo $0 ubuntu"
    echo
    echo "Note: This script must be run as root (use sudo)"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root (use sudo)"
   usage
   exit 1
fi

# Check if username argument is provided
if [ $# -ne 1 ]; then
    error "Username argument is required"
    usage
    exit 1
fi

# Get username from argument
TARGET_USER="$1"

# Validate user exists
if ! id "$TARGET_USER" &>/dev/null; then
    error "User '$TARGET_USER' does not exist"
    echo
    echo "Available users with UID >= 1000:"
    awk -F: '$3 >= 1000 && $3 < 65534 {print "  - " $1}' /etc/passwd | grep -v nobody || echo "  No regular users found"
    echo
    usage
    exit 1
fi

# Get user's home directory
USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
if [ -z "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
    error "User '$TARGET_USER' has no valid home directory"
    exit 1
fi

log "Starting TPM-based LUKS encryption setup"

# Quick status check
log "Checking current setup status..."
SETUP_COMPLETE=true
STATUS_MESSAGE=""

# Step 1: Find LUKS device
log "Finding LUKS encrypted device..."
LUKS_DEV=$(blkid -t TYPE="crypto_LUKS" -o device | head -1)

if [ -z "$LUKS_DEV" ]; then
    error "No LUKS device found!"
    exit 1
fi

log "Found LUKS device: $LUKS_DEV"

# Verify it's actually LUKS
if ! cryptsetup isLuks "$LUKS_DEV" 2>/dev/null; then
    error "$LUKS_DEV is not a valid LUKS device"
    exit 1
fi

# Step 2: Check TPM availability
log "Checking TPM availability..."
if ! command -v systemd-cryptenroll &> /dev/null; then
    error "systemd-cryptenroll not found. Please install systemd (version 248+)"
    exit 1
fi

if ! systemd-cryptenroll --tpm2-device=list &>/dev/null; then
    error "TPM2 device not available!"
    echo "Please enable TPM 2.0 in your BIOS/UEFI settings"
    exit 1
fi

log "TPM2 device is available"

# Disable systemd password agents to prevent interactive prompts
export SYSTEMD_ASK_PASSWORD_AGENT=/bin/false

# Step 3: Generate recovery key
log "Generating recovery key for user: $TARGET_USER"
log "Using home directory: $USER_HOME"
RECOVERY_DIR="$USER_HOME/LUKS-Recovery"

mkdir -p "$RECOVERY_DIR"
RECOVERY_KEY="$RECOVERY_DIR/recovery-key.txt"

# Check if recovery key already exists
if [ -f "$RECOVERY_KEY" ]; then
    warning "Recovery key already exists at $RECOVERY_KEY"
    echo "Do you want to:"
    echo "  1) Use existing recovery key"
    echo "  2) Generate new recovery key (old key will be backed up)"
    echo "  3) Exit"
    read -p "Choose [1-3]: " choice
    
    case $choice in
        1)
            log "Using existing recovery key"
            ;;
        2)
            backup_file="$RECOVERY_KEY.backup.$(date +%Y%m%d_%H%M%S)"
            log "Backing up existing key to $backup_file"
            cp "$RECOVERY_KEY" "$backup_file"
            openssl rand -base64 48 > "$RECOVERY_KEY"
            chmod 600 "$RECOVERY_KEY"
            log "Generated new recovery key"
            ;;
        3)
            log "Exiting as requested"
            exit 0
            ;;
        *)
            error "Invalid choice"
            exit 1
            ;;
    esac
else
    openssl rand -base64 48 > "$RECOVERY_KEY"
    chmod 600 "$RECOVERY_KEY"
    log "Generated new recovery key"
fi

chmod 700 "$RECOVERY_DIR"

cat > "$RECOVERY_DIR/README.txt" << 'EOF'
LUKS Recovery Key
=================

This directory contains your LUKS disk encryption recovery key.

IMPORTANT:
- Backup recovery-key.txt immediately to a secure external location
- This is your only way to recover data if TPM fails
- Without this key or TPM, you cannot access your encrypted data

Recovery Usage:
  sudo cryptsetup luksOpen /dev/[device] dm_crypt-main < recovery-key.txt

Keep this key safe!
EOF

# Set ownership to the target user
chown -R "$TARGET_USER:$TARGET_USER" "$RECOVERY_DIR"

log "Recovery key generated at: $RECOVERY_KEY"

# Step 4: Add recovery key to LUKS
log "Checking if recovery key is already added to LUKS..."

# Check which slots contain the recovery key
RECOVERY_SLOTS=""
ALL_SLOTS=$(cryptsetup luksDump "$LUKS_DEV" 2>/dev/null | grep -E "^[ 	]*[0-9]+: luks2" | awk '{print $1}' | tr -d ':')
for slot in $ALL_SLOTS; do
    if cryptsetup luksOpen --test-passphrase "$LUKS_DEV" --key-slot "$slot" < "$RECOVERY_KEY" 2>/dev/null; then
        RECOVERY_SLOTS="$RECOVERY_SLOTS $slot"
    fi
done

if [ -n "$RECOVERY_SLOTS" ]; then
    log "Recovery key is already in slot(s):$RECOVERY_SLOTS"
    log "Skipping recovery key addition to prevent duplicates"
else
    log "Adding recovery key to LUKS device..."
    if echo "ubuntuKey" | cryptsetup luksAddKey "$LUKS_DEV" "$RECOVERY_KEY"; then
        log "Recovery key added successfully"
    else
        error "Failed to add recovery key!"
        error "Make sure the temporary password 'ubuntuKey' is still valid"
        exit 1
    fi
fi

# Step 5: Enroll TPM
log "Checking TPM2 enrollment status..."

# Check if TPM2 is already enrolled
if cryptsetup luksDump "$LUKS_DEV" 2>/dev/null | grep -q "systemd-tpm2"; then
    log "TPM2 is already enrolled for this device"
    echo "Do you want to re-enroll TPM2? (y/N): "
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        log "Re-enrolling TPM2..."
        # Try with recovery key first
        if systemd-cryptenroll --wipe-slot=tpm2 "$LUKS_DEV" < "$RECOVERY_KEY" 2>/dev/null; then
            log "Removed existing TPM2 enrollment"
        else
            # Try with temporary password
            if echo "ubuntuKey" | systemd-cryptenroll --wipe-slot=tpm2 "$LUKS_DEV" 2>/dev/null; then
                log "Removed existing TPM2 enrollment"
            else
                warning "Could not remove existing TPM2 enrollment, continuing anyway"
            fi
        fi
    else
        log "Keeping existing TPM2 enrollment"
    fi
fi

# Check again if we need to enroll
if ! cryptsetup luksDump "$LUKS_DEV" 2>/dev/null | grep -q "systemd-tpm2"; then
    log "TPM2 not enrolled yet, proceeding with enrollment..."
    
    # Debug: Show current LUKS state
    log "Current LUKS tokens:"
    cryptsetup luksDump "$LUKS_DEV" 2>/dev/null | grep -A5 "^Tokens:" | head -10 || log "No tokens section found"
    
    # Clean up any corrupted tokens first
    log "Checking for any existing tokens..."
    
    # Safer approach: get full dump first
    LUKS_DUMP=$(cryptsetup luksDump "$LUKS_DEV" 2>&1) || {
        error "Failed to dump LUKS header"
        echo "$LUKS_DUMP"
        exit 1
    }
    
    # Check if Tokens section exists
    if echo "$LUKS_DUMP" | grep -q "^Tokens:"; then
        log "Tokens section found, checking for existing tokens..."
        
        # Get token IDs more safely (using space/tab instead of \s for better compatibility)
        TOKEN_IDS=$(echo "$LUKS_DUMP" | grep -E "^[ 	]*[0-9]+:" | grep -v "Keyslots:" | awk '{print $1}' | tr -d ':' | sort -n || true)
        
        if [ -n "$TOKEN_IDS" ]; then
            log "Found token IDs: $TOKEN_IDS"
            for token_id in $TOKEN_IDS; do
                log "Processing token $token_id..."
                
                # Remove any existing token that might interfere
                warning "Attempting to remove token $token_id..."
                if cryptsetup token remove --token-id "$token_id" "$LUKS_DEV" < "$RECOVERY_KEY" 2>/dev/null; then
                    log "Removed token $token_id using recovery key"
                elif echo "ubuntuKey" | cryptsetup token remove --token-id "$token_id" "$LUKS_DEV" 2>/dev/null; then
                    log "Removed token $token_id using temporary password"
                else
                    warning "Could not remove token $token_id - may not be problematic"
                fi
            done
        else
            log "No token IDs found"
        fi
    else
        log "No Tokens section found in LUKS header"
    fi
    
    # Try enrolling TPM2 with explicit password options
    log "Starting TPM2 enrollment process..."
    
    # Debug: Check if we can access the device
    log "Verifying device access..."
    if ! [ -b "$LUKS_DEV" ]; then
        error "Device $LUKS_DEV is not a block device"
        exit 1
    fi
    
    # Create temporary file with password for non-interactive use
    TEMP_PASS_FILE=$(mktemp)
    chmod 600 "$TEMP_PASS_FILE"
    echo "ubuntuKey" > "$TEMP_PASS_FILE"
    log "Created temporary password file: $TEMP_PASS_FILE"
    
    # First attempt: using temporary password file
    log "Attempting TPM2 enrollment with temporary password file..."
    log "Running: systemd-cryptenroll --unlock-key-file=$TEMP_PASS_FILE --tpm2-device=auto --tpm2-pcrs=0+7 $LUKS_DEV"
    
    # Run with timeout to prevent hanging
    if timeout 30 systemd-cryptenroll --unlock-key-file="$TEMP_PASS_FILE" --tpm2-device=auto --tpm2-pcrs=0+7 "$LUKS_DEV" >/tmp/tpm-enroll.log 2>&1; then
        log "TPM2 enrolled successfully using temporary password file"
        rm -f "$TEMP_PASS_FILE"
    else
        log "Failed with temporary password file. Error:"
        cat /tmp/tpm-enroll.log | head -5
        
        # Second attempt: using recovery key as unlock file
        log "Attempting TPM2 enrollment with recovery key file..."
        log "Running: systemd-cryptenroll --unlock-key-file=$RECOVERY_KEY --tpm2-device=auto --tpm2-pcrs=0+7 $LUKS_DEV"
        
        if timeout 30 systemd-cryptenroll --unlock-key-file="$RECOVERY_KEY" --tpm2-device=auto --tpm2-pcrs=0+7 "$LUKS_DEV" >/tmp/tpm-enroll.log 2>&1; then
            log "TPM2 enrolled successfully using recovery key file"
            rm -f "$TEMP_PASS_FILE"
        else
            log "Failed with recovery key file. Error:"
            cat /tmp/tpm-enroll.log | head -5
            
            # Third attempt: manual approach
            rm -f "$TEMP_PASS_FILE"
            log "Both automated attempts failed."
            echo
            echo "=== Manual TPM2 Enrollment Required ==="
            echo "The script couldn't automatically enroll TPM2."
            echo "Please run the following command manually:"
            echo
            echo "  sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 $LUKS_DEV"
            echo
            echo "When prompted for password, enter: ubuntuKey"
            echo
            echo "After successful enrollment, you can continue with the rest of the setup."
            exit 1
        fi
    fi
fi

# Step 6: Update crypttab for TPM
log "Updating /etc/crypttab for TPM..."
LUKS_UUID=$(blkid -s UUID -o value "$LUKS_DEV")

# Backup existing crypttab
if [ -f /etc/crypttab ]; then
    cp /etc/crypttab /etc/crypttab.backup.$(date +%Y%m%d_%H%M%S)
fi

# Check if entry exists
if grep -q "dm_crypt-main" /etc/crypttab 2>/dev/null; then
    # Update existing entry
    # Note: tpm2-device=auto may show warnings but is the correct syntax for systemd >= 248
    sed -i.bak "/dm_crypt-main/c\dm_crypt-main UUID=$LUKS_UUID none luks,discard,tpm2-device=auto" /etc/crypttab
else
    # Add new entry
    echo "dm_crypt-main UUID=$LUKS_UUID none luks,discard,tpm2-device=auto" >> /etc/crypttab
fi

warning "Note: You may see 'ignoring unknown option tpm2-device' warnings. This is normal and can be ignored."

log "Updated /etc/crypttab"

# Step 7: Update initramfs
log "Updating initramfs..."
update-initramfs -u -k all

# Step 8: Remove temporary password
log "Removing temporary password (ubuntuKey)..."

# Get all key slots (using space/tab instead of \s for better compatibility)
ALL_SLOTS=$(cryptsetup luksDump "$LUKS_DEV" 2>/dev/null | grep -E "^[ 	]*[0-9]+: luks2" | awk '{print $1}' | tr -d ':')
log "All key slots: $ALL_SLOTS"

# First, let's identify what each slot contains
log "Identifying key slot contents..."
TEMP_SLOTS=""
RECOVERY_SLOTS=""
UNKNOWN_SLOTS=""

for slot in $ALL_SLOTS; do
    log "Testing slot $slot..."
    
    # Test if it's the temporary password
    if echo "ubuntuKey" | cryptsetup luksOpen --test-passphrase "$LUKS_DEV" --key-slot "$slot" 2>/dev/null; then
        log "  Slot $slot: Contains temporary password (ubuntuKey)"
        TEMP_SLOTS="$TEMP_SLOTS $slot"
    # Test if it's the recovery key
    elif cryptsetup luksOpen --test-passphrase "$LUKS_DEV" --key-slot "$slot" < "$RECOVERY_KEY" 2>/dev/null; then
        log "  Slot $slot: Contains recovery key"
        RECOVERY_SLOTS="$RECOVERY_SLOTS $slot"
    else
        log "  Slot $slot: Unknown key (possibly corrupted or another key)"
        UNKNOWN_SLOTS="$UNKNOWN_SLOTS $slot"
    fi
done

# Summary
echo
echo "Key slot analysis:"
echo "  Temporary password slots: ${TEMP_SLOTS:-none}"
echo "  Recovery key slots: ${RECOVERY_SLOTS:-none}"
echo "  Unknown/other slots: ${UNKNOWN_SLOTS:-none}"
echo

# Check if we have a valid recovery key slot
if [ -z "$RECOVERY_SLOTS" ]; then
    error "No recovery key slot found! Cannot remove temporary password safely."
    echo "Please ensure the recovery key is properly added before removing the temporary password."
    exit 1
fi

# Now remove temporary password slots
if [ -z "$TEMP_SLOTS" ]; then
    warning "No slots found with temporary password"
else
    log "Found temporary password in slots:$TEMP_SLOTS"
    
    # Remove each temporary password slot
    for slot in $TEMP_SLOTS; do
        # Skip slot 0 initially if it's the only working slot
        if [ "$slot" = "0" ] && [ "$(echo "$RECOVERY_SLOTS" | wc -w)" -eq 0 ]; then
            warning "Skipping slot 0 as no other valid slots exist"
            continue
        fi
        
        log "Removing temporary password from slot $slot..."
        
        # Method 1: Use recovery key to authorize removal
        if cryptsetup luksKillSlot "$LUKS_DEV" "$slot" < "$RECOVERY_KEY" 2>&1 | tee /tmp/kill-slot.log | grep -q "successfully"; then
            log "Successfully removed slot $slot using recovery key"
        # Method 2: Use temporary password to authorize its own removal
        elif echo "ubuntuKey" | cryptsetup luksKillSlot "$LUKS_DEV" "$slot" 2>&1 | tee /tmp/kill-slot.log | grep -q "successfully"; then
            log "Successfully removed slot $slot using temporary password"
        # Method 3: If slot 0 is stubborn, try a different approach
        elif [ "$slot" = "0" ]; then
            warning "Slot 0 is difficult to remove. This is a known issue with some LUKS configurations."
            echo "You may need to manually remove it later with:"
            echo "  sudo cryptsetup luksKillSlot $LUKS_DEV 0"
            echo "Enter the recovery key when prompted."
        else
            error "Failed to remove slot $slot"
            cat /tmp/kill-slot.log
        fi
    done
fi

# Step 9: Verify setup
log "Verifying setup..."
echo
echo "=== Current LUKS Configuration ==="

# Show LUKS tokens
echo
echo "LUKS Tokens:"
cryptsetup luksDump "$LUKS_DEV" 2>/dev/null | grep -A20 "^Tokens:" || echo "No token section found"

# Check TPM token
if cryptsetup luksDump "$LUKS_DEV" 2>/dev/null | grep -q "systemd-tpm2"; then
    echo -e "${GREEN}✓${NC} TPM2 token present"
else
    echo -e "${RED}✗${NC} TPM2 token missing"
fi

# Check recovery key
if [ -f "$RECOVERY_KEY" ]; then
    echo -e "${GREEN}✓${NC} Recovery key saved at: $RECOVERY_KEY"
else
    echo -e "${RED}✗${NC} Recovery key missing"
fi

# Check temporary password
if echo "ubuntuKey" | cryptsetup luksOpen --test-passphrase "$LUKS_DEV" 2>/dev/null; then
    echo -e "${RED}✗${NC} Temporary password (ubuntuKey) still active!"
else
    echo -e "${GREEN}✓${NC} Temporary password removed"
fi

# Show key slots
echo
echo "Key slots:"
cryptsetup luksDump "$LUKS_DEV" 2>/dev/null | grep -E "^[ 	]*[0-9]+: luks2"

echo
echo "=== Setup Complete ==="
echo
echo -e "${GREEN}IMPORTANT NEXT STEPS:${NC}"
echo "1. Backup the recovery key immediately:"
echo "   $RECOVERY_KEY"
echo
echo "2. Test TPM unlock by rebooting the system"
echo
echo "3. If TPM unlock fails, use the recovery key:"
echo "   sudo cryptsetup luksOpen $LUKS_DEV dm_crypt-main < $RECOVERY_KEY"
echo
echo "4. Store the recovery key in a secure location (USB drive, password manager, etc.)"
echo

echo "Recovery key location: $RECOVERY_DIR"
echo "Owner: $TARGET_USER"

log "TPM encryption setup completed successfully!"

