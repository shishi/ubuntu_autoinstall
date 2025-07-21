#!/bin/bash
#
# Fix recovery key format and re-add to LUKS
# This script fixes the "Operation not permitted" error
#
# Usage: sudo ./fix-recovery-key.sh <username>
#

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root (use sudo)"
   exit 1
fi

# Check argument
if [ $# -ne 1 ]; then
    error "Usage: $0 <username>"
    exit 1
fi

TARGET_USER="$1"
USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
RECOVERY_DIR="$USER_HOME/LUKS-Recovery"
RECOVERY_KEY="$RECOVERY_DIR/recovery-key.txt"

# Find LUKS device
LUKS_DEV=$(blkid -t TYPE="crypto_LUKS" -o device | head -1)

if [ -z "$LUKS_DEV" ]; then
    error "No LUKS device found!"
    exit 1
fi

log "Found LUKS device: $LUKS_DEV"

# Step 1: Create new recovery key without newline
log "Creating new recovery key..."
NEW_KEY="$RECOVERY_DIR/recovery-key-fixed.txt"
openssl rand -base64 48 | tr -d '\n' > "$NEW_KEY"
chmod 600 "$NEW_KEY"
chown "$TARGET_USER:$TARGET_USER" "$NEW_KEY"

# Step 2: Add the new key
log "Adding new recovery key to LUKS..."
echo -n "ubuntuKey" | cryptsetup luksAddKey "$LUKS_DEV" "$NEW_KEY" || {
    error "Failed to add new recovery key"
    exit 1
}

log "New recovery key added successfully"

# Step 3: Test the new key
log "Testing new recovery key..."
if cryptsetup luksOpen --test-passphrase "$LUKS_DEV" < "$NEW_KEY"; then
    log "New recovery key works!"
else
    error "New recovery key test failed"
    exit 1
fi

# Step 4: Replace old key with new one
log "Backing up old recovery key..."
cp "$RECOVERY_KEY" "$RECOVERY_KEY.old"
mv "$NEW_KEY" "$RECOVERY_KEY"

log "Recovery key fixed successfully!"
echo
echo "Next steps:"
echo "1. Test TPM enrollment again: sudo ./setup-tpm-encryption.sh $TARGET_USER"
echo "2. Remove temporary password slots: sudo ./cleanup-duplicate-slots.sh $TARGET_USER"
echo
echo "Recovery key location: $RECOVERY_KEY"
echo "Old key backup: $RECOVERY_KEY.old"