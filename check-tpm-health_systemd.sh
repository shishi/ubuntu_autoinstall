#!/usr/bin/env bash
set -euo pipefail

# TPM Health Check Script for systemd-cryptenroll
# This script checks if TPM auto-unlock is likely to work after system changes

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info() { echo -e "[INFO] $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[FAIL]${NC} $1"; }

# Check before system updates
check_pre_update() {
    print_info "Pre-update TPM health check (systemd-cryptenroll)"
    
    # Save current PCR values
    local pcr_file
    pcr_file="$HOME/.tpm-pcr-backup-$(date +%Y%m%d-%H%M%S).txt"
    
    if command -v tpm2_pcrread >/dev/null 2>&1; then
        tpm2_pcrread "sha256:0,1,4,7,14" > "$pcr_file" 2>/dev/null
        print_success "PCR values saved to: $pcr_file"
    fi
    
    # Check systemd-cryptenroll TPM2 enrollments
    local has_tpm2_enrollment=false
    for device in /dev/sd* /dev/nvme* /dev/vd*; do
        if [[ -b "$device" ]] && cryptsetup isLuks "$device" 2>/dev/null; then
            if cryptsetup luksDump "$device" 2>/dev/null | grep -q "tpm2"; then
                has_tpm2_enrollment=true
                print_success "TPM2 enrollment found on $device"
                
                # Try to show enrollment details if systemd-cryptenroll is available
                if command -v systemd-cryptenroll >/dev/null 2>&1; then
                    # Note: This may require root permissions
                    systemd-cryptenroll "$device" --tpm2-device=list 2>/dev/null || true
                fi
            fi
        fi
    done
    
    if ! $has_tpm2_enrollment; then
        print_warning "No systemd-cryptenroll TPM2 enrollments found!"
    fi
    
    # Remind about recovery key
    print_warning "Ensure you have access to your recovery key before proceeding!"
    print_info "Recovery key location: /root/.luks-recovery-key-*.txt (if not moved)"
}

# Check after system updates
check_post_update() {
    print_info "Post-update TPM health check (systemd-cryptenroll)"
    
    # Compare PCR values
    local latest_backup
    latest_backup=$(find "$HOME" -maxdepth 1 -name ".tpm-pcr-backup-*.txt" -type f -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)
    
    if [[ -f "$latest_backup" ]]; then
        print_info "Comparing PCR values with: $latest_backup"
        
        local current_pcr
        current_pcr=$(mktemp)
        if tpm2_pcrread "sha256:0,1,4,7,14" > "$current_pcr" 2>/dev/null; then
            if diff -q "$latest_backup" "$current_pcr" >/dev/null; then
                print_success "PCR values unchanged - auto-unlock should work"
            else
                print_warning "PCR values changed - auto-unlock may fail"
                print_info "Changed PCRs:"
                diff "$latest_backup" "$current_pcr" | grep "^[<>]" || true
            fi
        fi
        rm -f "$current_pcr"
    fi
    
    # Test systemd-cryptenroll status
    print_info "Checking systemd-cryptenroll TPM2 status..."
    local test_ok=false
    local has_tpm2_enrollment=false
    
    # Check systemd version first
    local systemd_version
    systemd_version=$(systemctl --version | head -1 | awk '{print $2}')
    if [[ "$systemd_version" -lt 248 ]]; then
        print_error "systemd version $systemd_version is too old for TPM2 support"
        return
    fi
    
    for device in /dev/sd* /dev/nvme* /dev/vd*; do
        if [[ -b "$device" ]] && cryptsetup isLuks "$device" 2>/dev/null; then
            # Check if device has TPM2 enrollment
            if cryptsetup luksDump "$device" 2>/dev/null | grep -q "tpm2"; then
                has_tpm2_enrollment=true
                
                # Check if device is already unlocked (typical for single-drive systems)
                local device_name
                device_name=$(basename "$device")
                if lsblk -ln -o NAME,TYPE | grep -q "^${device_name}.*crypt"; then
                    print_info "$device is already unlocked (this is your root device)"
                    
                    # For unlocked devices, check the enrollment metadata
                    if cryptsetup luksDump "$device" 2>&1 | grep -q "tpm2"; then
                        print_success "TPM2 enrollment appears valid"
                        test_ok=true
                        
                        # Show enrollment details if available
                        if command -v systemd-cryptenroll >/dev/null 2>&1 && [[ $EUID -eq 0 ]]; then
                            print_info "TPM2 enrollment details:"
                            systemd-cryptenroll "$device" --tpm2-device=list 2>/dev/null | sed 's/^/  /' || true
                        fi
                    else
                        print_warning "TPM2 enrollment metadata may be corrupted"
                    fi
                    continue
                fi
                
                # Note: systemd-cryptenroll doesn't provide a direct unlock test like clevis
                # The real test happens during boot
                print_info "TPM2 enrollment found on $device (unlock test happens at boot)"
                test_ok=true
            fi
        fi
    done
    
    if ! $has_tpm2_enrollment; then
        print_warning "No devices with systemd-cryptenroll TPM2 enrollment found"
        print_info "Run: sudo ./setup-tpm-luks-unlock_systemd.sh"
    elif ! $test_ok; then
        print_error "Could not verify TPM2 enrollment status"
        print_info "This might be normal if all devices are already unlocked"
        print_info "The real test will happen on next boot"
    else
        print_success "systemd-cryptenroll TPM2 enrollment is properly configured"
    fi
    
    # Check for additional requirements
    print_info "Checking boot configuration..."
    
    # Check if crypttab exists and has entries
    if [[ -f /etc/crypttab ]]; then
        if grep -v "^#" /etc/crypttab | grep -v "^$" >/dev/null 2>&1; then
            print_success "/etc/crypttab has entries"
        else
            print_warning "/etc/crypttab exists but has no entries"
        fi
    else
        print_warning "/etc/crypttab not found"
    fi
    
    # Check kernel command line for rd.luks parameters
    if grep -q "rd.luks" /proc/cmdline; then
        print_success "LUKS parameters found in kernel command line"
    else
        print_info "No rd.luks parameters in kernel command line (may be using crypttab)"
    fi
}

# Main
case "${1:-check}" in
    pre|before)
        check_pre_update
        ;;
    post|after)
        check_post_update
        ;;
    check|*)
        check_pre_update
        echo
        check_post_update
        ;;
esac