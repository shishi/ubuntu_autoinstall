#!/bin/bash
#
# Cleanup duplicate LUKS key slots
# This script identifies and removes duplicate recovery key slots
#
# Usage: sudo ./cleanup-duplicate-slots.sh <username>
#

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
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
    echo "Cleanup duplicate LUKS key slots"
    echo
    echo "Arguments:"
    echo "  <username>    The username whose recovery key to use"
    echo
    echo "Example:"
    echo "  sudo $0 ubuntu"
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
    exit 1
fi

# Get user's home directory
USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
RECOVERY_KEY="$USER_HOME/LUKS-Recovery/recovery-key.txt"

# Check if recovery key exists
if [ ! -f "$RECOVERY_KEY" ]; then
    error "Recovery key not found at: $RECOVERY_KEY"
    exit 1
fi

log "Starting LUKS slot cleanup"

# Find LUKS device
log "Finding LUKS encrypted device..."
LUKS_DEV=$(blkid -t TYPE="crypto_LUKS" -o device | head -1)

if [ -z "$LUKS_DEV" ]; then
    error "No LUKS device found!"
    exit 1
fi

log "Found LUKS device: $LUKS_DEV"

# Get all key slots
log "Analyzing current key slots..."
ALL_SLOTS=$(cryptsetup luksDump "$LUKS_DEV" 2>/dev/null | grep -E "^[ 	]*[0-9]+: luks2" | awk '{print $1}' | tr -d ':')

# Arrays to store slot information
declare -a TEMP_SLOTS
declare -a RECOVERY_SLOTS
declare -a UNKNOWN_SLOTS

# Test each slot
echo
echo "=== Key Slot Analysis ==="
echo
for slot in $ALL_SLOTS; do
    echo -n "Testing slot $slot... "
    
    # Test if it's the temporary password
    if echo "ubuntuKey" | cryptsetup luksOpen --test-passphrase "$LUKS_DEV" --key-slot "$slot" 2>/dev/null; then
        echo -e "${YELLOW}ubuntuKey (temporary password)${NC}"
        TEMP_SLOTS+=("$slot")
    # Test if it's the recovery key
    elif cryptsetup luksOpen --test-passphrase "$LUKS_DEV" --key-slot "$slot" < "$RECOVERY_KEY" 2>/dev/null; then
        echo -e "${GREEN}Recovery key${NC}"
        RECOVERY_SLOTS+=("$slot")
    else
        echo -e "${RED}Unknown/inaccessible${NC}"
        UNKNOWN_SLOTS+=("$slot")
    fi
done

# Summary
echo
echo "=== Summary ==="
echo "Temporary password (ubuntuKey) slots: ${TEMP_SLOTS[@]:-none}"
echo "Recovery key slots: ${RECOVERY_SLOTS[@]:-none}"
echo "Unknown/other slots: ${UNKNOWN_SLOTS[@]:-none}"
echo

# Check for duplicates
RECOVERY_COUNT=${#RECOVERY_SLOTS[@]}
if [ "$RECOVERY_COUNT" -gt 1 ]; then
    warning "Found $RECOVERY_COUNT duplicate recovery key slots!"
    echo "Keeping the first slot (${RECOVERY_SLOTS[0]}) and removing duplicates..."
    echo
    
    # Remove duplicate recovery key slots
    for ((i=1; i<$RECOVERY_COUNT; i++)); do
        slot="${RECOVERY_SLOTS[$i]}"
        log "Removing duplicate recovery key from slot $slot..."
        
        if cryptsetup luksKillSlot "$LUKS_DEV" "$slot" < "$RECOVERY_KEY" 2>/dev/null; then
            log "Successfully removed slot $slot"
        else
            error "Failed to remove slot $slot"
        fi
    done
elif [ "$RECOVERY_COUNT" -eq 0 ]; then
    error "No recovery key slots found!"
    echo "Please run setup-tpm-encryption.sh first to add a recovery key."
else
    log "No duplicate recovery key slots found."
fi

# Offer to remove temporary password slots
if [ ${#TEMP_SLOTS[@]} -gt 0 ]; then
    echo
    echo "Found temporary password (ubuntuKey) in slots: ${TEMP_SLOTS[@]}"
    
    # Check if we have at least one other valid slot
    if [ "$RECOVERY_COUNT" -gt 0 ] || cryptsetup luksDump "$LUKS_DEV" 2>/dev/null | grep -q "systemd-tpm2"; then
        echo "Do you want to remove the temporary password? (y/N): "
        read -r response
        
        if [[ "$response" =~ ^[Yy]$ ]]; then
            for slot in "${TEMP_SLOTS[@]}"; do
                log "Removing temporary password from slot $slot..."
                
                # Try with recovery key first
                if cryptsetup luksKillSlot "$LUKS_DEV" "$slot" < "$RECOVERY_KEY" 2>/dev/null; then
                    log "Successfully removed slot $slot"
                # For slot 0, might need special handling
                elif [ "$slot" -eq 0 ]; then
                    warning "Slot 0 removal failed. You may need to remove it manually:"
                    echo "  sudo cryptsetup luksKillSlot $LUKS_DEV 0"
                    echo "  (Enter the recovery key when prompted)"
                else
                    error "Failed to remove slot $slot"
                fi
            done
        else
            log "Keeping temporary password slots."
        fi
    else
        error "Cannot remove temporary password - no other valid authentication method found!"
    fi
fi

# Show final state
echo
echo "=== Final Key Slot State ==="
cryptsetup luksDump "$LUKS_DEV" 2>/dev/null | grep -E "^[ 	]*[0-9]+: luks2"

# Check for TPM2 token
echo
if cryptsetup luksDump "$LUKS_DEV" 2>/dev/null | grep -q "systemd-tpm2"; then
    echo -e "${GREEN}✓${NC} TPM2 token is present"
else
    echo -e "${YELLOW}!${NC} No TPM2 token found"
fi

echo
log "Cleanup complete!"

# Recommendations
if [ "$RECOVERY_COUNT" -eq 0 ]; then
    echo
    echo -e "${RED}WARNING:${NC} No recovery key found!"
    echo "Run setup-tpm-encryption.sh to add a recovery key."
elif [ ${#TEMP_SLOTS[@]} -gt 0 ]; then
    echo
    echo -e "${YELLOW}Note:${NC} Temporary password still present."
    echo "Consider removing it for better security."
fi