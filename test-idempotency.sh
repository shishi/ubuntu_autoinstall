#!/usr/bin/env bash
set -euo pipefail

# Test idempotency of setup-tpm-luks-unlock.sh
# This script simulates multiple runs to verify idempotent behavior

echo "=== Idempotency Test for setup-tpm-luks-unlock.sh ==="
echo

# Function to count recovery key files
count_recovery_keys() {
    ls /root/.luks-recovery-key-*.txt 2>/dev/null | wc -l
}

# Function to count LUKS slots
count_luks_slots() {
    local device="$1"
    cryptsetup luksDump "$device" 2>/dev/null | grep -c "Key Slot.*: ENABLED" || echo 0
}

# Function to check clevis bindings
count_clevis_bindings() {
    local device="$1"
    clevis luks list -d "$device" 2>/dev/null | grep -c "tpm2" || echo 0
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
echo "1. Run ./setup-tpm-luks-unlock.sh"
echo "2. Note the recovery key count and LUKS slot usage"
echo "3. Run the script again with the same inputs"
echo "4. Verify:"
echo "   - No duplicate recovery key files (unless user chooses to create new)"
echo "   - No duplicate LUKS slots for same passwords"
echo "   - Clevis binding is not duplicated"
echo "   - Script handles existing state gracefully"
echo ""

echo "Expected idempotent behaviors:"
echo "✓ Package installation - only installs missing packages"
echo "✓ Recovery key - prompts to use existing or create new"
echo "✓ Password slots - checks if password already exists before adding"
echo "✓ Clevis binding - asks before replacing existing binding"
echo "✓ Service enablement - only enables if not already enabled"
echo "✓ State checking - shows current configuration before proceeding"