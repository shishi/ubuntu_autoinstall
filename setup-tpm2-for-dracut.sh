#!/usr/bin/env bash
set -euo pipefail

# Setup TPM2 auto-unlock for dracut-based systems

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

print_info "TPM2 Setup for dracut-based systems"
echo "===================================="
echo

# Check if dracut is available
if ! command -v dracut >/dev/null 2>&1; then
    print_error "dracut not found. This script is for dracut-based systems only."
    exit 1
fi

print_success "dracut is available"

# Check for systemd-boot
if bootctl status >/dev/null 2>&1; then
    print_success "systemd-boot is active (good for tpm2-device=auto)"
else
    print_info "Not using systemd-boot, but dracut should still work"
fi

# Find LUKS device
print_info "Finding LUKS device..."
LUKS_DEVICE=""
DM_NAME=""

for name in dm_crypt-0 dm_crypt-1 dm_crypt-main ubuntu-vg-root; do
    if [[ -e "/dev/mapper/$name" ]] && cryptsetup status "$name" >/dev/null 2>&1; then
        DM_NAME="$name"
        DEVICE=$(cryptsetup status "$name" | grep "device:" | awk '{print $2}')
        if [[ -n "$DEVICE" ]] && cryptsetup isLuks "$DEVICE" 2>/dev/null; then
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
HAS_TPM2=false
if cryptsetup luksDump "$LUKS_DEVICE" 2>/dev/null | grep -q "systemd-tpm2"; then
    print_success "systemd-cryptenroll TPM2 token found"
    HAS_TPM2=true
elif command -v clevis >/dev/null 2>&1 && clevis luks list -d "$LUKS_DEVICE" 2>/dev/null | grep -q "tpm2"; then
    print_success "Clevis TPM2 binding found"
    HAS_TPM2=true
fi

if [[ "$HAS_TPM2" == "false" ]]; then
    print_error "No TPM2 enrollment found. Please run setup script first."
    exit 1
fi

# Configure dracut for TPM2
print_info "Configuring dracut for TPM2 support..."

# Create dracut config directory if it doesn't exist
mkdir -p /etc/dracut.conf.d

# Create TPM2 configuration
cat > /etc/dracut.conf.d/tpm2-cryptsetup.conf << 'EOF'
# Enable systemd and cryptsetup with TPM2 support
add_dracutmodules+=" systemd systemd-cryptsetup tpm2-tss "
add_drivers+=" tpm_tis tpm_crb "
install_items+=" /usr/lib/systemd/systemd-cryptsetup "

# Force inclusion of systemd units
add_systemd_units+=" systemd-cryptsetup@.service "

# Ensure crypttab is included
install_items+=" /etc/crypttab "
EOF

print_success "Created /etc/dracut.conf.d/tpm2-cryptsetup.conf"

# Get LUKS UUID
LUKS_UUID=$(cryptsetup luksDump "$LUKS_DEVICE" | grep "UUID:" | head -1 | awk '{print $2}')
print_info "LUKS UUID: $LUKS_UUID"

# Update crypttab
print_info "Checking /etc/crypttab..."
if grep -q "tpm2-device=auto" /etc/crypttab; then
    print_success "crypttab already has tpm2-device=auto"
else
    # Backup crypttab
    cp /etc/crypttab "/etc/crypttab.backup.$(date +%Y%m%d-%H%M%S)"
    
    # Update or add entry
    if grep -q "^$DM_NAME" /etc/crypttab; then
        sed -i "/^$DM_NAME/c\\$DM_NAME UUID=$LUKS_UUID none luks,discard,tpm2-device=auto" /etc/crypttab
    else
        echo "$DM_NAME UUID=$LUKS_UUID none luks,discard,tpm2-device=auto" >> /etc/crypttab
    fi
    print_success "Updated /etc/crypttab with tpm2-device=auto"
fi

# Show crypttab
print_info "Current /etc/crypttab:"
cat /etc/crypttab

# Regenerate initramfs with dracut
print_info "Regenerating initramfs with dracut..."
if dracut -f --regenerate-all; then
    print_success "initramfs regenerated successfully"
else
    print_error "Failed to regenerate initramfs"
    exit 1
fi

# List generated initramfs files
print_info "Generated initramfs files:"
ls -la /boot/initramfs* 2>/dev/null || ls -la /boot/initrd* 2>/dev/null

print_success "Configuration complete!"
echo
print_info "With dracut and systemd-boot, tpm2-device=auto should work!"
print_info "Reboot to test TPM2 auto-unlock"
echo
print_info "If it doesn't work, check:"
echo "  - journalctl -b | grep -E 'tpm2|cryptsetup'"
echo "  - dmesg | grep -i tpm"