#!/usr/bin/env bash
set -euo pipefail

# Fix TPM2 auto-unlock for systemd-boot systems

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

print_info "systemd-boot TPM2 Auto-unlock Configuration"
echo "==========================================="
echo

# Verify systemd-boot is active
print_info "Verifying systemd-boot is active..."
if bootctl status >/dev/null 2>&1; then
    print_success "systemd-boot is active"
else
    print_error "systemd-boot is not active or bootctl failed"
    exit 1
fi

# Find LUKS device
print_info "Finding LUKS device..."
LUKS_DEVICE=""
DM_NAME=""

# Check common device mapper names
for name in dm_crypt-0 dm_crypt-1 dm_crypt-main ubuntu-vg-root; do
    if [[ -e "/dev/mapper/$name" ]] && cryptsetup status "$name" >/dev/null 2>&1; then
        DM_NAME="$name"
        DEVICE=$(cryptsetup status "$name" | grep "device:" | awk '{print $2}')
        if cryptsetup isLuks "$DEVICE" 2>/dev/null; then
            LUKS_DEVICE="$DEVICE"
            print_success "Found LUKS device: $LUKS_DEVICE (mapped as $DM_NAME)"
            break
        fi
    fi
done

if [[ -z "$LUKS_DEVICE" ]]; then
    print_error "No LUKS device found"
    exit 1
fi

# Check TPM2 enrollment
print_info "Checking TPM2 enrollment..."
if cryptsetup luksDump "$LUKS_DEVICE" 2>/dev/null | grep -q "systemd-tpm2"; then
    print_success "TPM2 is already enrolled with systemd-cryptenroll"
else
    print_error "TPM2 is not enrolled. Please run setup-tpm-luks-unlock_systemd.sh first"
    exit 1
fi

# Get LUKS UUID
LUKS_UUID=$(cryptsetup luksDump "$LUKS_DEVICE" | grep "UUID:" | awk '{print $2}')
print_info "LUKS UUID: $LUKS_UUID"

# Backup crypttab
print_info "Backing up /etc/crypttab..."
cp /etc/crypttab "/etc/crypttab.backup.$(date +%Y%m%d-%H%M%S)"

# Check current crypttab
print_info "Current /etc/crypttab:"
cat /etc/crypttab

# Fix crypttab for systemd-boot
print_info "Updating /etc/crypttab for systemd-boot TPM2..."

# Create proper crypttab entry
NEW_ENTRY="$DM_NAME UUID=$LUKS_UUID none luks,discard,tpm2-device=auto"

# Check if entry exists
if grep -q "^$DM_NAME" /etc/crypttab; then
    # Update existing entry
    sed -i "/^$DM_NAME/c\\$NEW_ENTRY" /etc/crypttab
    print_success "Updated existing crypttab entry"
else
    # Add new entry
    echo "$NEW_ENTRY" >> /etc/crypttab
    print_success "Added new crypttab entry"
fi

# Show updated crypttab
print_info "Updated /etc/crypttab:"
cat /etc/crypttab

# Update kernel command line if needed
print_info "Checking kernel command line..."
if [ -d /boot/efi/loader/entries ]; then
    for entry in /boot/efi/loader/entries/*.conf; do
        if [ -f "$entry" ]; then
            if grep -q "rd.luks.name=$LUKS_UUID=$DM_NAME" "$entry"; then
                print_success "Kernel cmdline already configured in $(basename "$entry")"
            else
                print_info "Updating $(basename "$entry")..."
                # Add luks parameters to options line
                sed -i "/^options/ s/$/ rd.luks.name=$LUKS_UUID=$DM_NAME/" "$entry"
            fi
        fi
    done
fi

# Update initramfs
print_info "Updating initramfs..."
update-initramfs -u -k all

# Fix /boot/efi permissions (security)
print_info "Fixing /boot/efi permissions..."
chmod 700 /boot/efi
if [ -d /boot/efi/loader ]; then
    chmod 700 /boot/efi/loader
fi

print_success "Configuration complete!"
echo
print_info "Summary:"
echo "  - crypttab updated with tpm2-device=auto"
echo "  - initramfs updated"
echo "  - boot entries configured"
echo "  - permissions fixed"
echo
print_info "TPM2 automatic unlocking should work on next boot!"
print_info "If it doesn't work, check:"
echo "  - journalctl -b -u systemd-cryptsetup@$DM_NAME.service"
echo "  - Secure Boot state hasn't changed (PCR7)"