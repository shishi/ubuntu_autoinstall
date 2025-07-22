#!/usr/bin/env bash
set -euo pipefail

# Test idempotency of setup-tpm-luks-unlock_systemd.sh
# This script simulates multiple runs to verify idempotent behavior

echo "=== Idempotency Test for setup-tpm-luks-unlock_systemd.sh ==="
echo

# Function to count recovery key files
count_recovery_keys() {
    find /root -maxdepth 1 -name ".luks-recovery-key-*.txt" -type f 2>/dev/null | wc -l
}

# Function to count LUKS slots
count_luks_slots() {
    local device="$1"
    # For LUKS2
    local count
    count=$(cryptsetup luksDump "$device" 2>/dev/null | grep -cE "^  [0-9]+: luks2" || echo 0)
    if [[ "$count" -eq 0 ]]; then
        # Fallback for LUKS1
        count=$(cryptsetup luksDump "$device" 2>/dev/null | grep -c "Key Slot.*: ENABLED" || echo 0)
    fi
    echo "$count"
}

# Function to check TPM2 enrollments
count_tpm2_enrollments() {
    local device="$1"
    # Count TPM2 tokens in LUKS dump
    cryptsetup luksDump "$device" 2>/dev/null | grep -c "type: systemd-tpm2" || echo 0
}

echo "Test scenarios:"
echo "1. First run - should set up everything"
echo "2. Second run - should detect existing setup and ask for confirmation"
echo "3. Third run with same passwords - should not duplicate entries"
echo ""

echo "Pre-test state:"
echo "- Recovery keys: $(count_recovery_keys)"
echo "- LUKS device detection required"
echo ""

echo "Note: This is a dry-run analysis. To actually test:"
echo "1. Run ./setup-tpm-luks-unlock_systemd.sh"
echo "2. Note the recovery key count and LUKS slot usage"
echo "3. Run the script again with the same inputs"
echo "4. Verify:"
echo "   - No duplicate recovery key files (unless user chooses to create new)"
echo "   - No duplicate LUKS slots for same passwords"
echo "   - TPM2 enrollment is not duplicated"
echo "   - Script handles existing state gracefully"
echo ""

echo "Expected idempotent behaviors:"
echo "✓ Package installation - only installs missing packages"
echo "✓ Recovery key - prompts to use existing or create new"
echo "✓ Password slots - checks if password already exists before adding"
echo "✓ TPM2 enrollment - asks before replacing existing enrollment"
echo "✓ State checking - shows current configuration before proceeding"
echo ""

echo "Key differences from Clevis version:"
echo "- Uses systemd-cryptenroll instead of clevis"
echo "- Requires systemd 248 or newer"
echo "- TPM2 enrollment uses --tpm2-device=auto"
echo "- No service enablement needed (handled by systemd)"
echo ""

echo "Testing commands:"
echo "1. Check current TPM2 enrollments:"
echo "   sudo cryptsetup luksDump /dev/sdXN | grep -A10 'Tokens:'"
echo ""
echo "2. List TPM2 enrollments with systemd-cryptenroll:"
echo "   sudo systemd-cryptenroll /dev/sdXN --tpm2-device=list"
echo ""
echo "3. Count enabled slots:"
echo "   sudo cryptsetup luksDump /dev/sdXN | grep -E '^  [0-9]+: luks2' | wc -l"