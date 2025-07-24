#!/usr/bin/env bash
set -euo pipefail

# Fix dracut systemd-cryptsetup issues

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

print_info "Fixing dracut systemd-cryptsetup setup"
echo "====================================="
echo

# 1. Check what's installed
print_info "Checking installed packages..."

PACKAGES_TO_CHECK=(
    "systemd"
    "systemd-boot"
    "systemd-boot-efi"
    "dracut"
    "dracut-core"
    "cryptsetup"
    "cryptsetup-bin"
    "cryptsetup-initramfs"
    "libcryptsetup12"
    "tpm2-tools"
    "libtss2-dev"
    "libtss2-mu0"
    "libtss2-tcti-device0"
)

print_info "Installed packages:"
for pkg in "${PACKAGES_TO_CHECK[@]}"; do
    if dpkg -l | grep -q "^ii  $pkg "; then
        echo "  ✓ $pkg"
    else
        echo "  ✗ $pkg (not installed)"
    fi
done

# 2. Install missing packages
print_info "Installing required packages..."
apt-get update
apt-get install -y \
    systemd \
    cryptsetup \
    cryptsetup-bin \
    libcryptsetup12 \
    tpm2-tools \
    libtss2-mu0 \
    libtss2-tcti-device0

# 3. Check systemd-cryptsetup location
print_info "Locating systemd-cryptsetup..."
if [ -f /usr/lib/systemd/systemd-cryptsetup ]; then
    print_success "Found: /usr/lib/systemd/systemd-cryptsetup"
elif [ -f /lib/systemd/systemd-cryptsetup ]; then
    print_success "Found: /lib/systemd/systemd-cryptsetup"
else
    print_error "systemd-cryptsetup binary not found!"
    print_info "Searching for it..."
    find /usr -name "systemd-cryptsetup" 2>/dev/null || true
    find /lib -name "systemd-cryptsetup" 2>/dev/null || true
fi

# 4. Create comprehensive dracut configuration
print_info "Creating dracut configuration..."
mkdir -p /etc/dracut.conf.d

cat > /etc/dracut.conf.d/01-tpm2-systemd.conf << 'EOF'
# Force include systemd modules
add_dracutmodules+=" systemd "
add_dracutmodules+=" systemd-cryptsetup "

# TPM2 support
add_dracutmodules+=" tpm2-tss "

# Include necessary drivers
add_drivers+=" tpm_tis tpm_tis_core tpm_crb "

# Force include binaries
install_items+=" /usr/lib/systemd/systemd-cryptsetup "
install_items+=" /lib/systemd/systemd-cryptsetup "
install_items+=" /usr/bin/systemd-cryptenroll "
install_items+=" /etc/crypttab "

# Include systemd units
install_optional_items+=" /usr/lib/systemd/system/systemd-cryptsetup@.service "
install_optional_items+=" /lib/systemd/system/systemd-cryptsetup@.service "

# Use systemd in initramfs
use_systemd="yes"
EOF

print_success "Created /etc/dracut.conf.d/01-tpm2-systemd.conf"

# 5. Check dracut modules
print_info "Available dracut modules:"
ls -la /usr/lib/dracut/modules.d/ | grep -E "(systemd|crypt|tpm)" || true

# 6. Try to create a test initramfs
print_info "Testing dracut configuration..."
if dracut --list-modules 2>&1 | grep -E "(systemd-cryptsetup|systemd)"; then
    print_success "Modules found in dracut"
else
    print_warning "Modules might be missing"
fi

# 7. Alternative: Use generic dracut modules
print_info "Creating fallback configuration..."
cat > /etc/dracut.conf.d/02-crypt-generic.conf << 'EOF'
# Use generic crypt module if systemd-cryptsetup is not available
add_dracutmodules+=" crypt "
add_dracutmodules+=" crypt-loop "

# Still try to use systemd
add_dracutmodules+=" systemd "

# Ensure cryptsetup tools are included
install_items+=" /usr/sbin/cryptsetup "
install_items+=" /sbin/cryptsetup "
EOF

print_info "Instructions:"
echo "1. Try regenerating initramfs:"
echo "   sudo dracut -f --regenerate-all"
echo
echo "2. If systemd-cryptsetup is still not found, use:"
echo "   sudo dracut -f --omit systemd-cryptsetup --add crypt"
echo
echo "3. For verbose output to debug:"
echo "   sudo dracut -f -v"
echo
echo "4. To force include even if module check fails:"
echo "   sudo dracut -f --force-add systemd-cryptsetup"
echo
echo "Note: Ubuntu's dracut might not have full systemd-cryptsetup support."
echo "In that case, tpm2-device=auto won't work even with dracut."