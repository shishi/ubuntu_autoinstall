#!/usr/bin/env bash
set -euo pipefail

# Check current boot loader status

echo "=== Boot Loader Status Check ==="
echo

# 1. Check which boot loader is currently active
echo "1. Currently booted with:"
if [ -d /sys/firmware/efi ]; then
    echo "   System is UEFI boot"
    
    # Check current boot loader
    if [ -f /sys/firmware/efi/efivars/LoaderInfo-* ]; then
        echo "   Booted with: systemd-boot"
    elif grep -q "grub" /proc/cmdline; then
        echo "   Booted with: GRUB"
    else
        echo "   Boot loader: Unknown (probably GRUB)"
    fi
else
    echo "   System is Legacy BIOS boot"
fi

echo
echo "2. Installed boot loaders:"

# Check GRUB
if [ -f /boot/grub/grub.cfg ]; then
    echo "   ✓ GRUB is installed"
    if [ -f /boot/efi/EFI/ubuntu/grubx64.efi ]; then
        echo "     - GRUB EFI binary present"
    fi
fi

# Check systemd-boot
if [ -f /boot/efi/EFI/systemd/systemd-bootx64.efi ]; then
    echo "   ✓ systemd-boot is installed"
    if [ -f /boot/efi/EFI/BOOT/BOOTX64.EFI ]; then
        echo "     - Default boot binary present"
    fi
fi

echo
echo "3. EFI boot entries:"
if command -v efibootmgr >/dev/null 2>&1; then
    efibootmgr -v | grep -E "^Boot[0-9]+" | head -10
else
    echo "   efibootmgr not available"
fi

echo
echo "4. systemd-boot status:"
if command -v bootctl >/dev/null 2>&1; then
    bootctl status 2>&1 | grep -E "(System|Current|Product|Firmware|Secure Boot|Default)" | head -20 || echo "   bootctl cannot determine status"
else
    echo "   bootctl not available"
fi

echo
echo "5. /boot/efi permissions (security warning cause):"
ls -ld /boot/efi
ls -la /boot/efi/loader/ 2>/dev/null | grep -E "(random-seed|\.#)" || true

echo
echo "=== Summary ==="
echo "systemd-boot is INSTALLED but may not be ACTIVE."
echo "To make systemd-boot the default boot loader, you need to:"
echo "1. Run: sudo bootctl install --make-entry-directory=yes"
echo "2. Or use efibootmgr to change boot order"
echo
echo "WARNING: Changing boot loaders can make system unbootable!"
echo "Make sure you have a recovery plan before proceeding."