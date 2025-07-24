#!/usr/bin/env bash
set -euo pipefail

# Fix TPM2 automatic unlocking by updating /etc/crypttab

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root"
   exit 1
fi

# Find LUKS device mapping
print_info "Finding LUKS device mapping..."

# Get device mapper name and UUID
DM_NAME=""
LUKS_UUID=""

# Check common names
for name in dm_crypt-main dm_crypt-0 ubuntu-vg-root; do
    if [[ -e "/dev/mapper/$name" ]] && cryptsetup status "$name" >/dev/null 2>&1; then
        DM_NAME="$name"
        DEVICE=$(cryptsetup status "$name" | grep "device:" | awk '{print $2}')
        LUKS_UUID=$(blkid -s UUID -o value "$DEVICE")
        print_success "Found LUKS mapping: $DM_NAME -> $DEVICE (UUID=$LUKS_UUID)"
        break
    fi
done

if [[ -z "$DM_NAME" ]]; then
    print_error "No active LUKS device mapping found"
    exit 1
fi

# Check TPM2 enrollment
print_info "Checking TPM2 enrollment..."
if ! cryptsetup luksDump "$DEVICE" 2>/dev/null | grep -q "tpm2"; then
    print_error "TPM2 is not enrolled on this device"
    print_info "Please run setup-tpm-luks-unlock_systemd.sh first"
    exit 1
fi

print_success "TPM2 enrollment confirmed"

# Backup crypttab
print_info "Backing up /etc/crypttab..."
cp /etc/crypttab "/etc/crypttab.backup.$(date +%Y%m%d-%H%M%S)"

# Check current crypttab
print_info "Current /etc/crypttab:"
cat /etc/crypttab

# Update crypttab
print_info "Updating /etc/crypttab..."

# Check if entry exists
if grep -q "^$DM_NAME" /etc/crypttab; then
    # Update existing entry
    if grep -q "tpm2-device=auto" /etc/crypttab; then
        print_success "TPM2 auto-unlock already configured in crypttab"
    else
        # Add tpm2-device=auto to existing entry
        sed -i "s/^$DM_NAME.*luks.*/$DM_NAME UUID=$LUKS_UUID none luks,discard,tpm2-device=auto/" /etc/crypttab
        print_success "Updated existing crypttab entry with TPM2 auto-unlock"
    fi
else
    # Add new entry
    echo "$DM_NAME UUID=$LUKS_UUID none luks,discard,tpm2-device=auto" >> /etc/crypttab
    print_success "Added new crypttab entry with TPM2 auto-unlock"
fi

# Show updated crypttab
print_info "Updated /etc/crypttab:"
cat /etc/crypttab

# Update initramfs
print_info "Updating initramfs..."
update-initramfs -u -k all

print_success "Configuration complete!"
print_info "TPM2 automatic unlocking should now work on next boot"
print_info "If it doesn't work, check:"
print_info "  - Secure Boot state hasn't changed"
print_info "  - TPM2 is accessible during boot"
print_info "  - journalctl -b -u systemd-cryptsetup@$DM_NAME.service"