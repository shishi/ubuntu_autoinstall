#!/bin/bash

# Test script to verify recovery key display

# Color codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "Test 1: Empty variable"
RECOVERY_SLOTS=""
if [ -n "$RECOVERY_SLOTS" ]; then
    echo -e "   - Recovery key: ${GREEN}Configured ✓${NC}"
else
    echo -e "   - Recovery key: ${YELLOW}Unknown ⚠${NC}"
fi

echo -e "\nTest 2: Non-empty variable"
RECOVERY_SLOTS=" 1"
if [ -n "$RECOVERY_SLOTS" ]; then
    echo -e "   - Recovery key: ${GREEN}Configured ✓${NC}"
else
    echo -e "   - Recovery key: ${YELLOW}Unknown ⚠${NC}"
fi

echo -e "\nTest 3: Multiple conditions"
RECOVERY_SLOTS=" 1"
TARGET_USER="shishi"
RECOVERY_KEY="/home/shishi/LUKS-Recovery/recovery-key.txt"

echo "   Quick Status:"
echo -e "   - TPM2 enrollment: ${GREEN}Active ✓${NC}"
if [ -n "$RECOVERY_SLOTS" ]; then
    echo -e "   - Recovery key: ${GREEN}Configured ✓${NC}"
elif [ -n "$TARGET_USER" ] && [ -f "$RECOVERY_KEY" ]; then
    echo -e "   - Recovery key: ${YELLOW}Present (not verified) ⚠${NC}"
else
    echo -e "   - Recovery key: ${YELLOW}Unknown ⚠${NC}"
fi
echo -e "   - Temporary password: ${YELLOW}Still active ⚠${NC}"

echo -e "\nVariables:"
echo "RECOVERY_SLOTS='$RECOVERY_SLOTS'"
echo "TARGET_USER='$TARGET_USER'"
echo "RECOVERY_KEY='$RECOVERY_KEY'"