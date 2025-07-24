#!/usr/bin/env bash
set -euo pipefail

# TPM2 Auto-unlock Diagnostic Script
# Diagnoses why TPM2 automatic unlocking might not be working

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
    echo -e "${GREEN}[✓]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_header() {
    echo
    echo -e "${BLUE}=== $1 ===${NC}"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root"
   exit 1
fi

print_header "TPM2 Auto-unlock Diagnostic Report"
echo "Date: $(date)"
echo

# 1. Check Boot Loader
print_header "Boot Loader Check"

BOOT_LOADER="unknown"
if [ -d /boot/efi/loader/entries ] && command -v bootctl >/dev/null 2>&1; then
    if bootctl status >/dev/null 2>&1; then
        BOOT_LOADER="systemd-boot"
        print_success "Using systemd-boot (supports tpm2-device=auto)"
    fi
elif [ -d /boot/grub ] || [ -f /boot/grub/grub.cfg ]; then
    BOOT_LOADER="grub"
    print_warning "Using GRUB (does NOT support tpm2-device=auto)"
    print_info "Consider using Clevis for TPM2 auto-unlock with GRUB"
fi

# 2. Check System Version
print_header "System Information"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    print_info "OS: $PRETTY_NAME"
fi

SYSTEMD_VERSION=$(systemctl --version | head -1 | awk '{print $2}')
print_info "systemd version: $SYSTEMD_VERSION"

if [[ "$SYSTEMD_VERSION" -ge 248 ]]; then
    print_success "systemd version supports TPM2 enrollment"
else
    print_error "systemd version too old (need 248+)"
fi

# 3. Check TPM2 Hardware
print_header "TPM2 Hardware"

if [ -e /dev/tpm0 ] || [ -e /dev/tpmrm0 ]; then
    print_success "TPM2 device found"
    
    if command -v tpm2_getcap >/dev/null 2>&1; then
        print_info "TPM2 manufacturer:"
        tpm2_getcap properties-fixed | grep -i manufacturer || true
    fi
else
    print_error "No TPM2 device found (/dev/tpm0 or /dev/tpmrm0)"
fi

# 4. Check Required Software
print_header "Required Software"

COMMANDS=(
    "systemd-cryptenroll:systemd (248+)"
    "cryptsetup:cryptsetup"
    "tpm2_getcap:tpm2-tools"
    "clevis:clevis (for GRUB systems)"
)

for cmd_pkg in "${COMMANDS[@]}"; do
    IFS=':' read -r cmd pkg <<< "$cmd_pkg"
    if command -v "$cmd" >/dev/null 2>&1; then
        print_success "$cmd found (from $pkg)"
    else
        print_warning "$cmd not found (install $pkg)"
    fi
done

# 5. Check LUKS Devices
print_header "LUKS Devices"

LUKS_DEVICES=()
for device in /dev/sd* /dev/nvme* /dev/vd* /dev/mapper/*; do
    if [ -b "$device" ] && cryptsetup isLuks "$device" 2>/dev/null; then
        LUKS_DEVICES+=("$device")
    fi
done

if [ ${#LUKS_DEVICES[@]} -eq 0 ]; then
    print_error "No LUKS devices found"
else
    for device in "${LUKS_DEVICES[@]}"; do
        print_info "Found LUKS device: $device"
        
        # Check for TPM2 tokens
        if cryptsetup luksDump "$device" 2>/dev/null | grep -q "tpm2"; then
            print_success "  → TPM2 token found"
        else
            print_warning "  → No TPM2 token found"
        fi
        
        # Check for Clevis tokens
        if command -v clevis >/dev/null 2>&1 && clevis luks list -d "$device" 2>/dev/null | grep -q "tpm2"; then
            print_success "  → Clevis TPM2 binding found"
        fi
    done
fi

# 6. Check crypttab
print_header "Crypttab Configuration"

if [ -f /etc/crypttab ]; then
    print_info "Contents of /etc/crypttab:"
    cat /etc/crypttab | while IFS= read -r line; do
        if [ -z "$line" ] || [[ "$line" =~ ^# ]]; then
            continue
        fi
        
        echo "  $line"
        
        # Check for tpm2-device option
        if echo "$line" | grep -q "tpm2-device=auto"; then
            if [ "$BOOT_LOADER" = "systemd-boot" ]; then
                print_success "    → tpm2-device=auto found (OK with systemd-boot)"
            else
                print_error "    → tpm2-device=auto found (NOT supported with $BOOT_LOADER)"
            fi
        fi
    done
else
    print_error "/etc/crypttab not found"
fi

# 7. Check Boot Logs
print_header "Recent Boot Logs (TPM2/Crypt related)"

print_info "Checking systemd-cryptsetup services..."
for service in $(systemctl list-units --all 'systemd-cryptsetup@*.service' --no-legend | awk '{print $1}'); do
    STATUS=$(systemctl is-active "$service" 2>/dev/null || echo "unknown")
    if [ "$STATUS" = "active" ]; then
        print_success "$service is active"
    else
        print_warning "$service status: $STATUS"
        # Show recent errors
        journalctl -u "$service" -b -n 5 --no-pager | grep -E "error|fail|warn" | head -3 | while read -r line; do
            echo "    $line"
        done
    fi
done

# 8. Recommendations
print_header "Recommendations"

if [ "$BOOT_LOADER" = "grub" ]; then
    print_warning "You are using GRUB. TPM2 auto-unlock options:"
    echo "  1. Use Clevis (recommended):"
    echo "     sudo apt-get install clevis clevis-tpm2 clevis-luks clevis-initramfs"
    echo "     sudo clevis luks bind -d /dev/device tpm2 '{\"pcr_ids\":\"7\"}'"
    echo "  2. Switch to systemd-boot (advanced)"
elif [ "$BOOT_LOADER" = "systemd-boot" ]; then
    print_info "You are using systemd-boot. TPM2 auto-unlock setup:"
    echo "  1. Enroll TPM2:"
    echo "     sudo systemd-cryptenroll /dev/device --tpm2-device=auto --tpm2-pcrs=7"
    echo "  2. Update /etc/crypttab with 'tpm2-device=auto' option"
    echo "  3. Update initramfs:"
    echo "     sudo update-initramfs -u"
fi

# 9. Check for common issues
print_header "Common Issues Check"

# Check if Secure Boot state changed
if command -v mokutil >/dev/null 2>&1; then
    SB_STATE=$(mokutil --sb-state 2>/dev/null | grep "SecureBoot" | awk '{print $2}')
    if [ "$SB_STATE" = "enabled" ]; then
        print_success "Secure Boot is enabled"
    else
        print_warning "Secure Boot is disabled (PCR7 might have changed)"
    fi
fi

# Check initramfs
if [ -f /boot/initrd.img-$(uname -r) ]; then
    print_info "Checking initramfs for TPM2 support..."
    if lsinitramfs /boot/initrd.img-$(uname -r) | grep -q "tpm"; then
        print_success "TPM modules found in initramfs"
    else
        print_warning "TPM modules might be missing from initramfs"
    fi
fi

print_header "Diagnostic Complete"
echo
print_info "For detailed logs, check:"
echo "  - journalctl -b | grep -E 'tpm2|cryptsetup|clevis'"
echo "  - dmesg | grep -i tpm"