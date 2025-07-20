#!/bin/bash
set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== LUKS Recovery Key Regeneration Tool ===${NC}"
echo

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Error: This script must be run as root${NC}"
    echo "Please run: sudo $0"
    exit 1
fi

# Find LUKS device
echo "Searching for LUKS devices..."
LUKS_DEV=$(blkid -t TYPE="crypto_LUKS" -o device | head -n 1)

if [ -z "$LUKS_DEV" ]; then
    echo -e "${RED}ERROR: No LUKS device found${NC}"
    echo "This system does not appear to have LUKS encryption."
    exit 1
fi

echo -e "${GREEN}Found LUKS device:${NC} $LUKS_DEV"
echo

# Check current key slots
echo "Current LUKS key slots:"
cryptsetup luksDump "$LUKS_DEV" | grep -E "Key Slot|Keyslot" | head -8
echo

# Confirm action
echo -e "${YELLOW}WARNING: This will replace your current recovery key.${NC}"
echo "Make sure you have access to the disk via:"
echo "  - Current recovery key"
echo "  - TPM (if enrolled)"
echo "  - Any other existing password"
echo
read -p "Do you want to continue? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Operation cancelled."
    exit 0
fi

# Test current access
echo
echo "First, we need to verify you can unlock the device."
echo "You'll be prompted for a working key/password."
echo "(TPM will be tried automatically if available)"
echo

if ! cryptsetup luksOpen --test-passphrase "$LUKS_DEV"; then
    echo -e "${RED}ERROR: Cannot verify access to the device${NC}"
    echo "Please make sure you have a working key/password."
    exit 1
fi

echo -e "${GREEN}✓ Access verified${NC}"

# Generate new recovery key
echo
echo "Generating new recovery key..."
TEMP_KEY="/tmp/new-recovery-key-$$.txt"
openssl rand -base64 48 > "$TEMP_KEY"
chmod 600 "$TEMP_KEY"

# Show the new key (for immediate backup)
echo
echo -e "${YELLOW}NEW RECOVERY KEY (save this immediately):${NC}"
echo "================================================"
cat "$TEMP_KEY"
echo "================================================"
echo

# Add new key
echo "Adding new recovery key to LUKS..."
echo "You'll need to provide a working key/password again:"

if ! cryptsetup luksAddKey "$LUKS_DEV" "$TEMP_KEY"; then
    echo -e "${RED}ERROR: Failed to add new key${NC}"
    rm -f "$TEMP_KEY"
    exit 1
fi

echo -e "${GREEN}✓ New recovery key added${NC}"

# Test new key
echo
echo "Testing new recovery key..."
if ! cryptsetup luksOpen --test-passphrase --key-file "$TEMP_KEY" "$LUKS_DEV"; then
    echo -e "${RED}ERROR: New key test failed!${NC}"
    echo "The key was added but doesn't work. This should not happen."
    rm -f "$TEMP_KEY"
    exit 1
fi

echo -e "${GREEN}✓ New recovery key works correctly${NC}"

# Determine recovery key location
# Get the first regular user (UID >= 1000)
FIRST_USER=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' | head -1)

RECOVERY_DIR=""
# First, check existing locations
for dir in /home/*/LUKS-Recovery /root/LUKS-Recovery; do
    if [ -d "$dir" ]; then
        RECOVERY_DIR="$dir"
        break
    fi
done

# If not found, create in appropriate location
if [ -z "$RECOVERY_DIR" ]; then
    if [ -n "$FIRST_USER" ]; then
        RECOVERY_DIR="/home/$FIRST_USER/LUKS-Recovery"
        mkdir -p "$RECOVERY_DIR"
        chown "$FIRST_USER:$FIRST_USER" "$RECOVERY_DIR"
    else
        RECOVERY_DIR="/root/LUKS-Recovery"
        mkdir -p "$RECOVERY_DIR"
    fi
fi

# Backup old key if exists
if [ -f "$RECOVERY_DIR/recovery-key.txt" ]; then
    BACKUP_NAME="$RECOVERY_DIR/recovery-key.old.$(date +%Y%m%d-%H%M%S)"
    cp "$RECOVERY_DIR/recovery-key.txt" "$BACKUP_NAME"
    echo
    echo -e "${YELLOW}Old key backed up to:${NC} $BACKUP_NAME"
fi

# Install new key
cp "$TEMP_KEY" "$RECOVERY_DIR/recovery-key.txt"
chmod 600 "$RECOVERY_DIR/recovery-key.txt"
rm -f "$TEMP_KEY"

echo -e "${GREEN}✓ New recovery key installed at:${NC} $RECOVERY_DIR/recovery-key.txt"

# Offer to remove old key
echo
echo -e "${YELLOW}Would you like to remove the old recovery key from LUKS?${NC}"
echo "Note: Only do this after you've backed up the new key!"
echo "      Make sure you have at least one other way to unlock the disk."
echo
read -p "Remove old key? (yes/no): " remove_old

if [ "$remove_old" = "yes" ]; then
    echo
    echo "Current key slots after adding new key:"
    cryptsetup luksDump "$LUKS_DEV" | grep -E "Key Slot|Keyslot" | head -8
    echo
    echo "To remove the old key, you need to provide it one last time."
    if [ -n "${BACKUP_NAME:-}" ]; then
        echo "You can copy it from: $BACKUP_NAME"
    fi
    echo
    
    if cryptsetup luksRemoveKey "$LUKS_DEV"; then
        echo -e "${GREEN}✓ Old recovery key removed${NC}"
        if [ -n "${BACKUP_NAME:-}" ]; then
            echo
            echo "You can now safely delete the backup file:"
            echo "  rm $BACKUP_NAME"
        fi
    else
        echo -e "${YELLOW}Failed to remove old key (this is not critical)${NC}"
        echo "The old key may have already been removed or you entered the wrong key."
    fi
fi

# Final summary
echo
echo -e "${GREEN}=== Recovery Key Regeneration Complete ===${NC}"
echo
echo "IMPORTANT NEXT STEPS:"
echo "1. Back up the new key from: $RECOVERY_DIR/recovery-key.txt"
echo "   - Copy to USB drive"
echo "   - Save in password manager"
echo "   - Print and store securely"
echo
echo "2. Test the new key after next reboot"
echo
echo "3. Delete any old key backups after confirming the new key works"
echo

# Show final key slot status
echo "Final LUKS key slots:"
cryptsetup luksDump "$LUKS_DEV" | grep -E "Key Slot|Keyslot" | head -8