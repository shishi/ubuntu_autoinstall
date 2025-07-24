#!/usr/bin/env bash
set -euo pipefail

# Check which initramfs system is in use

echo "=== Initramfs System Check ==="
echo

# Check for initramfs-tools
echo "1. Checking for initramfs-tools:"
if command -v update-initramfs >/dev/null 2>&1; then
    echo "   ✓ update-initramfs found"
    dpkg -l | grep initramfs-tools || echo "   Package not found"
else
    echo "   ✗ update-initramfs NOT found"
fi

# Check for dracut
echo
echo "2. Checking for dracut:"
if command -v dracut >/dev/null 2>&1; then
    echo "   ✓ dracut found"
    dracut --version
    dpkg -l | grep dracut || echo "   Package info not available"
else
    echo "   ✗ dracut NOT found"
fi

# Check current initramfs files
echo
echo "3. Current initramfs files:"
ls -la /boot/initrd* 2>/dev/null || ls -la /boot/initramfs* 2>/dev/null || echo "   No initramfs files found in /boot"

# Check if using systemd in initramfs
echo
echo "4. Checking initramfs content:"
INITRD_FILE=$(ls -t /boot/initrd* 2>/dev/null | head -1 || ls -t /boot/initramfs* 2>/dev/null | head -1)
if [ -n "$INITRD_FILE" ] && [ -f "$INITRD_FILE" ]; then
    echo "   Analyzing $INITRD_FILE..."
    # Check for systemd-cryptsetup
    if lsinitramfs "$INITRD_FILE" 2>/dev/null | grep -q "systemd-cryptsetup"; then
        echo "   ✓ systemd-cryptsetup found in initramfs"
    else
        echo "   ✗ systemd-cryptsetup NOT found in initramfs"
    fi
    
    # Check for clevis
    if lsinitramfs "$INITRD_FILE" 2>/dev/null | grep -q "clevis"; then
        echo "   ✓ clevis found in initramfs"
    else
        echo "   ✗ clevis NOT found in initramfs"
    fi
else
    echo "   Could not find initramfs file to analyze"
fi

# Check kernel command line
echo
echo "5. Kernel command line:"
cat /proc/cmdline

# Check for mkinitcpio (Arch-based)
echo
echo "6. Checking for mkinitcpio (Arch/Manjaro):"
if command -v mkinitcpio >/dev/null 2>&1; then
    echo "   ✓ mkinitcpio found (Arch-based system)"
    mkinitcpio --version
else
    echo "   ✗ mkinitcpio NOT found"
fi

echo
echo "=== Summary ==="
if command -v dracut >/dev/null 2>&1; then
    echo "This system appears to use DRACUT"
    echo "To update initramfs, use: sudo dracut -f"
    echo
    echo "For TPM2 with dracut:"
    echo "1. Ensure tpm2-tss is installed"
    echo "2. Add to /etc/dracut.conf.d/tpm2.conf:"
    echo '   add_dracutmodules+=" tpm2-tss "'
    echo "3. Regenerate: sudo dracut -f"
elif command -v mkinitcpio >/dev/null 2>&1; then
    echo "This system appears to use MKINITCPIO (Arch-based)"
    echo "To update initramfs, use: sudo mkinitcpio -P"
elif command -v update-initramfs >/dev/null 2>&1; then
    echo "This system uses INITRAMFS-TOOLS (Ubuntu/Debian)"
    echo "To update initramfs, use: sudo update-initramfs -u"
else
    echo "Could not determine initramfs system!"
fi