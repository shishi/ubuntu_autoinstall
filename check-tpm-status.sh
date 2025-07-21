#!/bin/bash
#
# Check TPM and LUKS encryption status
# Shows detailed information about key slots, TPM enrollment, and overall security status
#
# Usage: sudo ./check-tpm-status.sh [username]
#
# Version: 2.1

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

info() {
    echo -e "${CYAN}[INFO]${NC} $*"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root (use sudo)"
   exit 1
fi

# Optional username argument for checking recovery key
TARGET_USER="${1:-}"
RECOVERY_KEY=""

if [ -n "$TARGET_USER" ]; then
    if id "$TARGET_USER" &>/dev/null; then
        USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
        RECOVERY_KEY="$USER_HOME/LUKS-Recovery/recovery-key.txt"
        if [ ! -f "$RECOVERY_KEY" ]; then
            warning "Recovery key not found at: $RECOVERY_KEY"
            RECOVERY_KEY=""
        fi
    else
        warning "User '$TARGET_USER' not found"
        TARGET_USER=""
    fi
fi

echo
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${MAGENTA}            TPM2 & LUKS Encryption Status Report${NC}"
echo -e "${MAGENTA}                          Version 2.1${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo

# Find LUKS device
info "Searching for LUKS encrypted devices..."
LUKS_DEVICES=$(blkid -t TYPE="crypto_LUKS" -o device 2>/dev/null || true)

if [ -z "$LUKS_DEVICES" ]; then
    error "No LUKS encrypted devices found!"
    exit 1
fi

# Process each LUKS device
for LUKS_DEV in $LUKS_DEVICES; do
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}Device: $LUKS_DEV${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # Get device UUID
    LUKS_UUID=$(blkid -s UUID -o value "$LUKS_DEV" 2>/dev/null || echo "Unknown")
    echo -e "UUID: ${CYAN}$LUKS_UUID${NC}"
    
    # Get LUKS version
    LUKS_VERSION=$(cryptsetup luksDump "$LUKS_DEV" 2>/dev/null | grep "Version:" | awk '{print $2}' || echo "Unknown")
    echo -e "LUKS Version: ${CYAN}$LUKS_VERSION${NC}"
    
    # Check if device is currently open
    DM_NAME=$(lsblk -no NAME,TYPE "$LUKS_DEV" 2>/dev/null | grep -A1 "crypt" | tail -1 | awk '{print $1}' | sed 's/[├─└│]//g' || true)
    if [ -n "$DM_NAME" ]; then
        echo -e "Status: ${GREEN}Open${NC} (mapped as /dev/mapper/$DM_NAME)"
    else
        echo -e "Status: ${YELLOW}Closed${NC}"
    fi
    
    echo
    
    # 1. TPM2 Status
    echo -e "\n${CYAN}1. TPM2 Configuration${NC}"
    echo "   ────────────────────"
    
    # Check TPM2 hardware
    if systemd-cryptenroll --tpm2-device=list &>/dev/null; then
        echo -e "   ${GREEN}$CHECK_MARK${NC} TPM2 hardware: Available"
        
        # List TPM2 devices
        TPM_DEVICES=$(systemd-cryptenroll --tpm2-device=list 2>/dev/null | grep -E "^/dev" || true)
        if [ -n "$TPM_DEVICES" ]; then
            echo "   TPM2 devices:"
            echo "$TPM_DEVICES" | sed 's/^/     - /'
        fi
    else
        echo -e "   ${RED}$CROSS_MARK${NC} TPM2 hardware: Not available"
    fi
    
    # Check TPM2 enrollment in LUKS
    if cryptsetup luksDump "$LUKS_DEV" 2>/dev/null | grep -q "systemd-tpm2"; then
        echo -e "   ${GREEN}$CHECK_MARK${NC} TPM2 enrollment: Active"
        
        # Get TPM2 token details
        TPM_TOKENS=$(cryptsetup luksDump "$LUKS_DEV" 2>/dev/null | grep -B1 "systemd-tpm2" | grep -E "^\s*[0-9]+:" || true)
        if [ -n "$TPM_TOKENS" ]; then
            echo "   TPM2 token(s):"
            while read -r token_line; do
                TOKEN_ID=$(echo "$token_line" | awk -F: '{print $1}' | tr -d ' ')
                echo -e "     - Token $TOKEN_ID: systemd-tpm2"
                
                # Get PCR banks
                PCR_INFO=$(cryptsetup luksDump "$LUKS_DEV" 2>/dev/null | grep -A20 "^\s*$TOKEN_ID:" | grep "tpm2-pcrs" | head -1 || true)
                if [ -n "$PCR_INFO" ]; then
                    echo "       PCRs: $(echo "$PCR_INFO" | awk -F: '{print $2}' | tr -d ' ')"
                fi
            done <<< "$TPM_TOKENS"
        fi
    else
        echo -e "   ${RED}$CROSS_MARK${NC} TPM2 enrollment: Not configured"
    fi
    
    # 2. Key Slots Analysis
    echo -e "\n${CYAN}2. LUKS Key Slots${NC}"
    echo "   ───────────────"
    
    # Get all key slots
    ALL_SLOTS=$(cryptsetup luksDump "$LUKS_DEV" 2>/dev/null | grep -E "^[ 	]*[0-9]+: luks2" | awk '{print $1}' | tr -d ':')
    TOTAL_SLOTS=$(echo "$ALL_SLOTS" | wc -w)
    echo "   Total active slots: $TOTAL_SLOTS"
    echo
    
    # Arrays to categorize slots
    TEMP_SLOTS=""
    RECOVERY_SLOTS=""
    UNKNOWN_SLOTS=""
    
    # Test each slot
    for slot in $ALL_SLOTS; do
        echo -n "   Slot $slot: "
        
        # Test if it's the temporary password
        if echo "ubuntuKey" | timeout 2 cryptsetup luksOpen --test-passphrase "$LUKS_DEV" --key-slot "$slot" 2>/dev/null; then
            echo -e "${YELLOW}Temporary password (ubuntuKey) $WARNING_MARK${NC}"
            TEMP_SLOTS="$TEMP_SLOTS $slot"
        # Test if it's the recovery key (if we have it)
        elif [ -n "$RECOVERY_KEY" ] && timeout 2 cryptsetup luksOpen --test-passphrase "$LUKS_DEV" --key-slot "$slot" < "$RECOVERY_KEY" 2>/dev/null; then
            echo -e "${GREEN}Recovery key $CHECK_MARK${NC}"
            RECOVERY_SLOTS="$RECOVERY_SLOTS $slot"
        else
            echo -e "${BLUE}Protected/Unknown key${NC}"
            UNKNOWN_SLOTS="$UNKNOWN_SLOTS $slot"
        fi
    done
    
    # 3. Security Assessment
    echo -e "\n${CYAN}3. Security Assessment${NC}"
    echo "   ──────────────────"
    
    SECURITY_SCORE=0
    MAX_SCORE=5
    
    # Summary at the top for quick view
    echo -e "   Quick Status:"
    
    # Check 1: TPM2 enrollment
    if cryptsetup luksDump "$LUKS_DEV" 2>/dev/null | grep -q "systemd-tpm2"; then
        echo -e "   - TPM2 enrollment: ${GREEN}Active ✓${NC}"
        ((SECURITY_SCORE++))
    else
        echo -e "   - TPM2 enrollment: ${RED}Not configured ✗${NC}"
    fi
    
    # Check 2: Recovery key
    # Debug: Show RECOVERY_SLOTS value
    echo "[DEBUG] RECOVERY_SLOTS='$RECOVERY_SLOTS'" >&2
    if [ -n "$RECOVERY_SLOTS" ]; then
        echo -e "   - Recovery key: ${GREEN}Configured ✓${NC}"
    elif [ -n "$TARGET_USER" ] && [ -f "$RECOVERY_KEY" ]; then
        echo -e "   - Recovery key: ${YELLOW}Present (not verified) ⚠${NC}"
    else
        echo -e "   - Recovery key: ${YELLOW}Unknown ⚠${NC}"
    fi
    
    # Check 3: Temporary password
    if [ -n "$TEMP_SLOTS" ]; then
        echo -e "   - Temporary password: ${YELLOW}Still active ⚠${NC}"
    else
        echo -e "   - Temporary password: ${GREEN}Removed ✓${NC}"
    fi
    
    echo
    echo "   Detailed Checks:"
    
    # Detailed Check 1: TPM2 enrollment
    if cryptsetup luksDump "$LUKS_DEV" 2>/dev/null | grep -q "systemd-tpm2"; then
        echo -e "   ${GREEN}$CHECK_MARK${NC} TPM2 protection enabled"
    else
        echo -e "   ${RED}$CROSS_MARK${NC} No TPM2 protection"
    fi
    
    # Check 2: Recovery key
    if [ -n "$RECOVERY_SLOTS" ]; then
        echo -e "   ${GREEN}$CHECK_MARK${NC} Recovery key configured"
        ((SECURITY_SCORE++))
    elif [ -n "$TARGET_USER" ] && [ -f "$RECOVERY_KEY" ]; then
        echo -e "   ${YELLOW}$WARNING_MARK${NC} Recovery key exists but not verified (run with username to verify)"
    else
        echo -e "   ${YELLOW}$WARNING_MARK${NC} Recovery key status unknown"
    fi
    
    # Check 3: Temporary password
    if [ -z "$TEMP_SLOTS" ]; then
        echo -e "   ${GREEN}$CHECK_MARK${NC} No temporary passwords found"
        ((SECURITY_SCORE++))
    else
        echo -e "   ${YELLOW}$WARNING_MARK${NC} Temporary password still active"
    fi
    
    # Check 4: LUKS2 version
    if [ "$LUKS_VERSION" = "2" ]; then
        echo -e "   ${GREEN}$CHECK_MARK${NC} Using LUKS version 2 (latest)"
        ((SECURITY_SCORE++))
    else
        echo -e "   ${YELLOW}$WARNING_MARK${NC} Using LUKS version $LUKS_VERSION"
    fi
    
    # Check 5: Reasonable number of slots
    if [ "$TOTAL_SLOTS" -le 3 ]; then
        echo -e "   ${GREEN}$CHECK_MARK${NC} Reasonable number of key slots ($TOTAL_SLOTS)"
        ((SECURITY_SCORE++))
    else
        echo -e "   ${YELLOW}$WARNING_MARK${NC} Many key slots active ($TOTAL_SLOTS) - consider cleanup"
    fi
    
    # Overall score
    echo
    echo -n "   Overall Security Score: "
    if [ $SECURITY_SCORE -eq $MAX_SCORE ]; then
        echo -e "${GREEN}$SECURITY_SCORE/$MAX_SCORE - Excellent${NC}"
    elif [ $SECURITY_SCORE -ge 3 ]; then
        echo -e "${YELLOW}$SECURITY_SCORE/$MAX_SCORE - Good${NC}"
    else
        echo -e "${RED}$SECURITY_SCORE/$MAX_SCORE - Needs Improvement${NC}"
    fi
    
    # 4. System Integration
    echo -e "\n${CYAN}4. System Integration${NC}"
    echo "   ─────────────────"
    
    # Check crypttab
    if grep -q "UUID=$LUKS_UUID" /etc/crypttab 2>/dev/null; then
        echo -e "   ${GREEN}$CHECK_MARK${NC} Device in /etc/crypttab"
        CRYPTTAB_ENTRY=$(grep "UUID=$LUKS_UUID" /etc/crypttab | head -1)
        echo "     Entry: $CRYPTTAB_ENTRY"
        
        # Check for TPM2 options
        if echo "$CRYPTTAB_ENTRY" | grep -q "tpm2-device"; then
            echo -e "     ${GREEN}$CHECK_MARK${NC} TPM2 options configured"
        else
            echo -e "     ${YELLOW}$WARNING_MARK${NC} No TPM2 options in crypttab"
        fi
    else
        echo -e "   ${YELLOW}$WARNING_MARK${NC} Device not found in /etc/crypttab"
    fi
    
    # Check initramfs
    INITRAMFS_DATE=$(stat -c %y /boot/initrd.img-$(uname -r) 2>/dev/null | cut -d' ' -f1 || echo "Unknown")
    echo -e "   ${INFO_MARK} Initramfs last updated: $INITRAMFS_DATE"
done

# 5. Recommendations
echo -e "\n${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${MAGENTA}                        Recommendations${NC}"
echo -e "${MAGENTA}═══════════════════════════════════════════════════════════════${NC}"

if [ -n "$TEMP_SLOTS" ]; then
    echo -e "\n${YELLOW}$WARNING_MARK Security Risk: Temporary password detected${NC}"
    echo "  Remove it with:"
    echo "    sudo ./cleanup-duplicate-slots.sh $TARGET_USER"
    echo "  Or manually:"
    echo "    sudo cryptsetup luksKillSlot $LUKS_DEV <slot_number>"
fi

if [ -z "$RECOVERY_SLOTS" ] && [ -n "$TARGET_USER" ]; then
    echo -e "\n${YELLOW}$WARNING_MARK No recovery key detected${NC}"
    echo "  Ensure you have a recovery method in case TPM fails"
fi

if ! cryptsetup luksDump "$LUKS_DEV" 2>/dev/null | grep -q "systemd-tpm2"; then
    echo -e "\n${YELLOW}$WARNING_MARK TPM2 not enrolled${NC}"
    echo "  Run: sudo ./setup-tpm-encryption.sh $TARGET_USER"
fi

if [ "$TOTAL_SLOTS" -gt 3 ]; then
    echo -e "\n${YELLOW}$WARNING_MARK Too many active key slots${NC}"
    echo "  Run: sudo ./cleanup-duplicate-slots.sh $TARGET_USER"
fi

echo
echo -e "${GREEN}Report completed at $(date '+%Y-%m-%d %H:%M:%S')${NC}"
echo