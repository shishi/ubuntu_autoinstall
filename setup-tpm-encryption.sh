#!/bin/bash
#
# TPM-based LUKS encryption setup script
# This script should be run after Ubuntu installation with autoinstall-luks.yml
#
# Usage: sudo ./setup-tpm-encryption.sh <username>
#

set -euo pipefail

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

# Step 3: Generate recovery key
log "Generating recovery key for user: $TARGET_USER"
log "Using home directory: $USER_HOME"
RECOVERY_DIR="$USER_HOME/LUKS-Recovery"

mkdir -p "$RECOVERY_DIR"
RECOVERY_KEY="$RECOVERY_DIR/recovery-key.txt"
openssl rand -base64 48 > "$RECOVERY_KEY"
chmod 700 "$RECOVERY_DIR"
chmod 600 "$RECOVERY_KEY"

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
log "Adding recovery key to LUKS device..."
if echo "ubuntuKey" | cryptsetup luksAddKey "$LUKS_DEV" "$RECOVERY_KEY"; then
    log "Recovery key added successfully"
else
    error "Failed to add recovery key!"
    exit 1
fi

# Step 5: Enroll TPM
log "Enrolling TPM2 for LUKS device..."
if systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 "$LUKS_DEV"; then
    log "TPM2 enrolled successfully"
else
    error "Failed to enroll TPM2!"
    echo "The recovery key has been added, but TPM enrollment failed."
    echo "You can try again later with: sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 $LUKS_DEV"
    exit 1
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
    sed -i.bak "/dm_crypt-main/c\dm_crypt-main UUID=$LUKS_UUID none luks,discard,tpm2-device=auto,tpm2-pcrs=0+7" /etc/crypttab
else
    # Add new entry
    echo "dm_crypt-main UUID=$LUKS_UUID none luks,discard,tpm2-device=auto,tpm2-pcrs=0+7" >> /etc/crypttab
fi

log "Updated /etc/crypttab"

# Step 7: Update initramfs
log "Updating initramfs..."
update-initramfs -u -k all

# Step 8: Remove temporary password
log "Removing temporary password (ubuntuKey)..."

# Find all slots containing the temporary password
TEMP_SLOTS=$(cryptsetup luksDump "$LUKS_DEV" | grep -E "^[[:space:]]*[0-9]+: luks2" | cut -d: -f1 | while read slot; do
    if echo "ubuntuKey" | cryptsetup luksOpen --test-passphrase "$LUKS_DEV" --key-slot "$slot" 2>/dev/null; then
        echo "$slot"
    fi
done)

if [ -z "$TEMP_SLOTS" ]; then
    warning "No slots found with temporary password"
else
    for slot in $TEMP_SLOTS; do
        log "Removing temporary password from slot $slot"
        if echo "ubuntuKey" | cryptsetup luksKillSlot "$LUKS_DEV" "$slot"; then
            log "Successfully removed slot $slot"
        else
            error "Failed to remove slot $slot"
        fi
    done
fi

# Step 9: Verify setup
log "Verifying setup..."
echo
echo "=== Current LUKS Configuration ==="

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
cryptsetup luksDump "$LUKS_DEV" 2>/dev/null | grep -E "^\s*[0-9]+: luks2"

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