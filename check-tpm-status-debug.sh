#!/bin/bash
#
# Debug version of check-tpm-status.sh
# Shows why recovery key is not displayed in Quick Status
#

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Symbols
CHECK_MARK="✓"
CROSS_MARK="✗"
WARNING_MARK="⚠"
INFO_MARK="ℹ"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERROR]${NC} This script must be run as root (use sudo)" >&2
   exit 1
fi

# Optional username argument for checking recovery key
TARGET_USER="${1:-}"
RECOVERY_KEY=""

echo -e "\n${MAGENTA}=== DEBUG MODE ===${NC}"
echo "TARGET_USER: '$TARGET_USER'"

if [ -n "$TARGET_USER" ]; then
    if id "$TARGET_USER" &>/dev/null; then
        USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
        RECOVERY_KEY="$USER_HOME/LUKS-Recovery/recovery-key.txt"
        echo "USER_HOME: $USER_HOME"
        echo "RECOVERY_KEY: $RECOVERY_KEY"
        if [ ! -f "$RECOVERY_KEY" ]; then
            echo "Recovery key file does NOT exist"
            RECOVERY_KEY=""
        else
            echo "Recovery key file EXISTS"
        fi
    else
        echo "User '$TARGET_USER' not found"
        TARGET_USER=""
    fi
fi

# Find LUKS device
LUKS_DEVICES=$(blkid -t TYPE="crypto_LUKS" -o device 2>/dev/null || true)

for LUKS_DEV in $LUKS_DEVICES; do
    echo -e "\n${BLUE}Device: $LUKS_DEV${NC}"
    
    # Get all key slots
    ALL_SLOTS=$(cryptsetup luksDump "$LUKS_DEV" 2>/dev/null | grep -E "^[ 	]*[0-9]+: luks2" | awk '{print $1}' | tr -d ':')
    echo "ALL_SLOTS: $ALL_SLOTS"
    
    # Arrays to categorize slots
    TEMP_SLOTS=""
    RECOVERY_SLOTS=""
    UNKNOWN_SLOTS=""
    
    # Test each slot
    for slot in $ALL_SLOTS; do
        echo -e "\n${YELLOW}Testing Slot $slot:${NC}"
        
        # Test if it's the temporary password
        if echo "ubuntuKey" | timeout 2 cryptsetup luksOpen --test-passphrase "$LUKS_DEV" --key-slot "$slot" 2>/dev/null; then
            echo "  → Temporary password (ubuntuKey) detected"
            TEMP_SLOTS="$TEMP_SLOTS $slot"
        # Test if it's the recovery key (if we have it)
        elif [ -n "$RECOVERY_KEY" ] && timeout 2 cryptsetup luksOpen --test-passphrase "$LUKS_DEV" --key-slot "$slot" < "$RECOVERY_KEY" 2>/dev/null; then
            echo "  → Recovery key detected"
            RECOVERY_SLOTS="$RECOVERY_SLOTS $slot"
        else
            echo "  → Protected/Unknown key"
            UNKNOWN_SLOTS="$UNKNOWN_SLOTS $slot"
        fi
    done
    
    echo -e "\n${CYAN}Variable States:${NC}"
    echo "TEMP_SLOTS: '$TEMP_SLOTS'"
    echo "RECOVERY_SLOTS: '$RECOVERY_SLOTS'"
    echo "UNKNOWN_SLOTS: '$UNKNOWN_SLOTS'"
    
    echo -e "\n${CYAN}Quick Status Logic:${NC}"
    
    # Check 2: Recovery key
    if [ -n "$RECOVERY_SLOTS" ]; then
        echo "RECOVERY_SLOTS is not empty: '$RECOVERY_SLOTS'"
        echo -e "   - Recovery key: ${GREEN}Configured ✓${NC}"
    elif [ -n "$TARGET_USER" ] && [ -f "$RECOVERY_KEY" ]; then
        echo "TARGET_USER='$TARGET_USER' and RECOVERY_KEY exists at '$RECOVERY_KEY'"
        echo -e "   - Recovery key: ${YELLOW}Present (not verified) ⚠${NC}"
    else
        echo "Neither condition met"
        echo -e "   - Recovery key: ${YELLOW}Unknown ⚠${NC}"
    fi
done

echo -e "\n${MAGENTA}=== END DEBUG ===${NC}"