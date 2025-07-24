#!/usr/bin/env bash
set -euo pipefail

# TPM Health Check Script
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
    print_info "Pre-update TPM health check"
    
    # Save current PCR values
    local pcr_file
    pcr_file="$HOME/.tpm-pcr-backup-$(date +%Y%m%d-%H%M%S).txt"
    
    if command -v tpm2_pcrread >/dev/null 2>&1; then
        tpm2_pcrread "sha256:0,1,4,7,14" > "$pcr_file" 2>/dev/null
        print_success "PCR values saved to: $pcr_file"
    fi
    
    # Check Clevis bindings
    local has_clevis=false
    for device in /dev/sd* /dev/nvme* /dev/vd*; do
        if [[ -b "$device" ]] && cryptsetup isLuks "$device" 2>/dev/null; then
            if clevis luks list -d "$device" 2>/dev/null | grep -q "tpm2"; then
                has_clevis=true
                print_success "Clevis TPM2 binding found on $device"
            fi
        fi
    done
    
    if ! $has_clevis; then
        print_warning "No Clevis TPM2 bindings found!"
    fi
    
    # Remind about recovery key
    print_warning "Ensure you have access to your recovery key before proceeding!"
    print_info "Recovery key location: /root/.luks-recovery-key-*.txt (if not moved)"
}

# Check after system updates
check_post_update() {
    print_info "Post-update TPM health check"
    
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
    
    # Test Clevis unlock
    print_info "Testing Clevis unlock capability..."
    local test_ok=false
    local has_clevis_binding=false
    
    for device in /dev/sd* /dev/nvme* /dev/vd*; do
        if [[ -b "$device" ]] && cryptsetup isLuks "$device" 2>/dev/null; then
            # Check if device has Clevis binding
            if clevis luks list -d "$device" 2>/dev/null | grep -q "tpm2"; then
                has_clevis_binding=true
                
                # Check if device is already unlocked (typical for single-drive systems)
                local device_name
                device_name=$(basename "$device")
                if lsblk -ln -o NAME,TYPE | grep -q "^${device_name}.*crypt"; then
                    print_info "$device is already unlocked (this is your root device)"
                    
                    # For unlocked devices, verify the binding is valid
                    if clevis luks list -d "$device" -s 1 2>&1 | grep -qE "(tpm2|^1:)"; then
                        print_success "TPM2 binding appears valid"
                        test_ok=true
                    else
                        print_warning "TPM2 binding metadata may be corrupted"
                    fi
                    continue
                fi
                
                # Only try unlock test for additional drives (not common in desktop systems)
                if clevis luks unlock -d "$device" -n "test_unlock_$$" 2>/dev/null; then
                    cryptsetup close "test_unlock_$$" 2>/dev/null || true
                    print_success "Clevis unlock test passed for additional drive $device"
                    test_ok=true
                else
                    print_info "Could not test unlock for $device (normal for single-drive systems)"
                fi
            fi
        fi
    done
    
    if ! $has_clevis_binding; then
        print_warning "No devices with Clevis TPM2 binding found"
        print_info "Run: sudo ./setup-tpm-luks-unlock.sh"
    elif ! $test_ok; then
        print_error "Clevis unlock test could not be completed"
        print_info "This might be normal if all devices are already unlocked"
        print_info "The real test will happen on next boot"
    else
        print_success "Clevis TPM2 binding is properly configured"
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