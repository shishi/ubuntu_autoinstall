#!/usr/bin/env bash
set -euo pipefail

# Test script to demonstrate LUKS2 parsing improvements

echo "=== LUKS Parsing Test Script ==="
echo "This script demonstrates the improved LUKS2 parsing"
echo

# Function to parse LUKS slots (supports both LUKS1 and LUKS2)
parse_luks_slots() {
    local device="$1"
    local -a enabled_slots=()
    
    # Check LUKS version
    local luks_version
    luks_version=$(cryptsetup luksDump "$device" 2>/dev/null | grep "^Version:" | awk '{print $2}')
    
    echo "Device: $device"
    echo "LUKS Version: ${luks_version:-unknown}"
    
    if [[ "$luks_version" == "2" ]]; then
        echo "Using LUKS2 parsing method..."
        # LUKS2 format - parse JSON-like structure
        while IFS=: read -r slot _; do
            if [[ "$slot" =~ ^[[:space:]]*([0-9]+)$ ]]; then
                enabled_slots+=("${BASH_REMATCH[1]}")
            fi
        done < <(cryptsetup luksDump "$device" 2>/dev/null | sed -n '/^Keyslots:/,/^[A-Z]/p' | grep -E "^[[:space:]]+[0-9]+: luks2")
    else
        echo "Using LUKS1 parsing method..."
        # LUKS1 format - use old method
        for i in {0..7}; do
            if cryptsetup luksDump "$device" 2>/dev/null | grep -q "Key Slot $i: ENABLED"; then
                enabled_slots+=("$i")
            fi
        done
    fi
    
    echo "Enabled slots: ${enabled_slots[*]:-none}"
    echo "Total slots: ${#enabled_slots[@]}"
    echo
}

# Test on available LUKS devices
echo "Searching for LUKS devices..."
found=0

for device in /dev/sd* /dev/nvme* /dev/vd* /dev/mapper/*; do
    if [[ -b "$device" ]] && cryptsetup isLuks "$device" 2>/dev/null; then
        found=1
        parse_luks_slots "$device"
    fi
done

if [[ $found -eq 0 ]]; then
    echo "No LUKS devices found on this system"
    echo
    echo "Example LUKS2 output format:"
    echo "---"
    echo "Version:        2"
    echo "Keyslots:"
    echo "  0: luks2"
    echo "     Key:        512 bits"
    echo "     Priority:   normal"
    echo "  1: luks2"
    echo "     Key:        512 bits"
    echo "     Priority:   normal"
    echo "---"
    echo
    echo "Example LUKS1 output format:"
    echo "---"
    echo "Version:        1"
    echo "Key Slot 0: ENABLED"
    echo "Key Slot 1: ENABLED"
    echo "Key Slot 2: DISABLED"
    echo "---"
fi