#!/usr/bin/env bash
set -euo pipefail

# TPM2 Unlock Setup Checker
# Determines the best method for TPM2 auto-unlock based on system configuration

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

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root"
   exit 1
fi

print_info "TPM2 Auto-unlock Setup Checker"
echo "=============================="
echo

# Detect boot loader
BOOT_LOADER="unknown"
if [ -d /boot/efi/loader/entries ] && command -v bootctl >/dev/null 2>&1; then
    if bootctl status >/dev/null 2>&1; then
        BOOT_LOADER="systemd-boot"
    fi
elif [ -d /boot/grub ] || [ -f /boot/grub/grub.cfg ]; then
    BOOT_LOADER="grub"
fi

print_info "Current boot loader: $BOOT_LOADER"

# Check for existing TPM2 setup
HAS_SYSTEMD_ENROLLMENT=false
HAS_CLEVIS=false

# Find LUKS devices
for device in /dev/sd* /dev/nvme* /dev/vd* /dev/mapper/*; do
    if [ -b "$device" ] && cryptsetup isLuks "$device" 2>/dev/null; then
        if cryptsetup luksDump "$device" 2>/dev/null | grep -q "systemd-tpm2"; then
            HAS_SYSTEMD_ENROLLMENT=true
        fi
        if command -v clevis >/dev/null 2>&1 && clevis luks list -d "$device" 2>/dev/null | grep -q "tpm2"; then
            HAS_CLEVIS=true
        fi
    fi
done

# Check crypttab
HAS_TPM2_DEVICE_OPTION=false
if grep -q "tpm2-device=auto" /etc/crypttab 2>/dev/null; then
    HAS_TPM2_DEVICE_OPTION=true
fi

echo
print_info "Current configuration:"
echo "  Boot loader: $BOOT_LOADER"
echo "  systemd-cryptenroll TPM2: $([ "$HAS_SYSTEMD_ENROLLMENT" = true ] && echo "YES" || echo "NO")"
echo "  Clevis TPM2: $([ "$HAS_CLEVIS" = true ] && echo "YES" || echo "NO")"
echo "  crypttab has tpm2-device=auto: $([ "$HAS_TPM2_DEVICE_OPTION" = true ] && echo "YES" || echo "NO")"
echo

# Provide recommendations
print_info "Recommendations:"
echo

if [ "$BOOT_LOADER" = "grub" ]; then
    if [ "$HAS_TPM2_DEVICE_OPTION" = true ]; then
        print_error "PROBLEM: You have 'tpm2-device=auto' in crypttab but are using GRUB!"
        print_warning "This option is not supported with GRUB and will cause errors."
        echo
        print_info "Solution: Use Clevis instead"
        echo "1. Remove 'tpm2-device=auto' from /etc/crypttab"
        echo "2. Install Clevis:"
        echo "   sudo apt-get install -y clevis clevis-tpm2 clevis-luks clevis-initramfs"
        echo "3. Bind to TPM2:"
        echo "   sudo clevis luks bind -d /dev/YOUR_DEVICE tpm2 '{\"pcr_ids\":\"7\"}'"
        echo "4. Update initramfs:"
        echo "   sudo update-initramfs -u"
    elif [ "$HAS_SYSTEMD_ENROLLMENT" = true ] && [ "$HAS_CLEVIS" = false ]; then
        print_warning "You have systemd-cryptenroll TPM2 but are using GRUB."
        print_info "This won't work properly. Switch to Clevis (see above)."
    elif [ "$HAS_CLEVIS" = true ]; then
        print_success "You are correctly using Clevis with GRUB!"
        print_info "Make sure /etc/crypttab does NOT contain 'tpm2-device=auto'"
    else
        print_info "To enable TPM2 auto-unlock with GRUB, use Clevis (see above)"
    fi
elif [ "$BOOT_LOADER" = "systemd-boot" ]; then
    if [ "$HAS_SYSTEMD_ENROLLMENT" = true ] && [ "$HAS_TPM2_DEVICE_OPTION" = true ]; then
        print_success "Your system is correctly configured for TPM2 auto-unlock!"
    elif [ "$HAS_SYSTEMD_ENROLLMENT" = true ] && [ "$HAS_TPM2_DEVICE_OPTION" = false ]; then
        print_warning "You have TPM2 enrolled but crypttab is missing 'tpm2-device=auto'"
        print_info "Add 'tpm2-device=auto' to the options in /etc/crypttab"
    elif [ "$HAS_CLEVIS" = true ]; then
        print_info "You are using Clevis with systemd-boot."
        print_info "This works, but you could use native systemd-cryptenroll instead."
    else
        print_info "To enable TPM2 auto-unlock with systemd-boot:"
        echo "1. Use systemd-cryptenroll:"
        echo "   sudo systemd-cryptenroll /dev/YOUR_DEVICE --tpm2-device=auto --tpm2-pcrs=7"
        echo "2. Add 'tpm2-device=auto' to /etc/crypttab options"
        echo "3. Update initramfs:"
        echo "   sudo update-initramfs -u"
    fi
else
    print_warning "Unknown boot loader. Manual configuration may be required."
fi

echo
print_info "For detailed diagnostics, run: ./diagnose-tpm2-unlock.sh"