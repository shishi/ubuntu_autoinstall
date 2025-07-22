#!/usr/bin/env bash
set -euo pipefail

# TPM Status and Debug Information Script
# This script displays comprehensive TPM2 status and LUKS binding information

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to print colored output
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

print_section() {
    echo
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}▶ $1${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
}

# Check if running as root (some commands need root)
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_warning "Running as non-root user. Some information may be limited."
        return 1
    fi
    return 0
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check TPM2 device presence
check_tpm_device() {
    print_section "TPM Device Status"
    
    # Check for TPM device files
    if [[ -c /dev/tpm0 ]]; then
        print_success "TPM device found: /dev/tpm0"
        ls -la /dev/tpm0
    else
        print_error "TPM device /dev/tpm0 not found"
    fi
    
    if [[ -c /dev/tpmrm0 ]]; then
        print_success "TPM resource manager found: /dev/tpmrm0"
        ls -la /dev/tpmrm0
    else
        print_warning "TPM resource manager /dev/tpmrm0 not found"
    fi
    
    # Check kernel modules
    print_info "TPM kernel modules:"
    if lsmod | grep -E "^tpm" > /tmp/tpm_modules.txt; then
        while read -r line; do
            echo "  • $line"
        done < /tmp/tpm_modules.txt
        rm -f /tmp/tpm_modules.txt
    else
        print_warning "No TPM kernel modules loaded"
    fi
}

# Function to display TPM2 capabilities
show_tpm_capabilities() {
    print_section "TPM2 Capabilities"
    
    if ! command_exists tpm2_getcap; then
        print_error "tpm2-tools not installed. Cannot query TPM capabilities."
        return
    fi
    
    # TPM Properties
    print_info "TPM2 Properties:"
    if tpm2_getcap properties-fixed 2>/dev/null | grep -E "(TPM2_PT_FAMILY_INDICATOR|TPM2_PT_MANUFACTURER|TPM2_PT_VENDOR|TPM2_PT_FIRMWARE_VERSION)" | head -10; then
        :
    else
        print_error "Failed to query TPM2 properties"
    fi
    
    # PCR Banks
    print_info "Available PCR Banks:"
    if [[ $EUID -eq 0 ]] || groups 2>/dev/null | grep -qE "(tss|tpm)"; then
        if tpm2_getcap pcrs 2>/dev/null | grep -E "^  (sha1|sha256|sha384|sha512):" | sort -u; then
            :
        else
            print_warning "Failed to query PCR banks (may need root or tss group membership)"
        fi
    else
        print_info "Run with sudo to see PCR banks (requires elevated permissions)"
    fi
    
    # Algorithms
    print_info "Supported Algorithms:"
    if [[ $EUID -eq 0 ]] || groups 2>/dev/null | grep -qE "(tss|tpm)"; then
        if tpm2_getcap algorithms 2>/dev/null | grep -E "^  (rsa|ecc|aes|sha)" | head -10; then
            :
        else
            print_warning "Failed to query algorithms (may need root or tss group membership)"
        fi
    else
        print_info "Run with sudo to see algorithms (requires elevated permissions)"
    fi
}

# Function to show PCR values
show_pcr_values() {
    print_section "PCR Values"
    
    if ! command_exists tpm2_pcrread; then
        print_error "tpm2_pcrread not available"
        return
    fi
    
    print_info "Current PCR values (sha256 bank):"
    
    # Read common PCRs used for sealing
    local important_pcrs=(0 1 4 7 8 9 11 14)
    
    for pcr in "${important_pcrs[@]}"; do
        if output=$(tpm2_pcrread "sha256:$pcr" 2>/dev/null | grep -A1 "sha256:"); then
            case $pcr in
                0) desc="BIOS" ;;
                1) desc="BIOS Configuration" ;;
                4) desc="Boot Manager" ;;
                7) desc="Secure Boot State" ;;
                8) desc="Kernel Command Line" ;;
                9) desc="Initrd" ;;
                11) desc="Kernel and Boot Measurements" ;;
                14) desc="MOK State" ;;
                *) desc="Unknown" ;;
            esac
            echo -e "  PCR[$pcr] ($desc):"
            echo "$output" | tail -1 | sed 's/^/    /'
        fi
    done
}

# Function to check systemd-cryptenroll status
check_systemd_cryptenroll() {
    print_section "systemd-cryptenroll Status"
    
    if command_exists systemd-cryptenroll; then
        print_success "systemd-cryptenroll is available"
        systemd-cryptenroll --version | head -1
    else
        print_error "systemd-cryptenroll not found"
    fi
    
    # Check for LUKS devices with systemd-cryptenroll
    if check_root; then
        print_info "Checking for systemd-cryptenroll bindings:"
        local found=0
        
        for device in /dev/sd* /dev/nvme* /dev/vd* /dev/mapper/*; do
            if [[ -b "$device" ]] && cryptsetup isLuks "$device" 2>/dev/null; then
                if systemd-cryptenroll "$device" --tpm2-device=list 2>/dev/null | grep -q "TPM2"; then
                    print_success "Found TPM2 enrollment on $device"
                    systemd-cryptenroll "$device" --tpm2-device=list 2>/dev/null
                    found=1
                fi
            fi
        done
        
        if [[ $found -eq 0 ]]; then
            print_info "No systemd-cryptenroll TPM2 bindings found"
        fi
    fi
}

# Function to check Clevis status
check_clevis_status() {
    print_section "Clevis Status"
    
    if ! command_exists clevis; then
        print_error "Clevis not installed"
        return
    fi
    
    print_success "Clevis is installed"
    
    # Check Clevis services
    print_info "Clevis services status:"
    for service in clevis-luks-askpass.path clevis-luks-askpass.service; do
        if systemctl is-enabled "$service" >/dev/null 2>&1; then
            status=$(systemctl is-active "$service" 2>/dev/null || echo "unknown")
            print_success "$service: enabled (status: $status)"
        else
            print_warning "$service: not enabled"
        fi
    done
    
    # Check for LUKS devices with Clevis bindings
    if check_root; then
        print_info "Checking for Clevis LUKS bindings:"
        local found=0
        
        for device in /dev/sd* /dev/nvme* /dev/vd* /dev/mapper/*; do
            if [[ -b "$device" ]] && cryptsetup isLuks "$device" 2>/dev/null; then
                if bindings=$(clevis luks list -d "$device" 2>/dev/null); then
                    if [[ -n "$bindings" ]]; then
                        print_success "Found Clevis bindings on $device:"
                        echo "$bindings" | while IFS= read -r line; do echo "    $line"; done
                        found=1
                    fi
                fi
            fi
        done
        
        if [[ $found -eq 0 ]]; then
            print_info "No Clevis bindings found on any LUKS device"
        fi
    fi
}

# Function to show LUKS device information
show_luks_info() {
    print_section "LUKS Device Information"
    
    if ! check_root; then
        print_warning "Root access required for detailed LUKS information"
        return
    fi
    
    local found=0
    
    for device in /dev/sd* /dev/nvme* /dev/vd* /dev/mapper/*; do
        if [[ -b "$device" ]] && cryptsetup isLuks "$device" 2>/dev/null; then
            found=1
            print_info "LUKS device: $device"
            
            # Show header info
            echo "  Header Information:"
            cryptsetup luksDump "$device" 2>/dev/null | grep -E "^(Version|Cipher|UUID|Key Slot)" | sed 's/^/    /'
            
            # Count enabled slots - LUKS2 format
            local total_slots
            total_slots=$(cryptsetup luksDump "$device" 2>/dev/null | grep -E "^Keyslots:" -A 100 | grep -cE "^  [0-9]+: luks2" || echo 0)
            if [[ $total_slots -eq 0 ]]; then
                # Fallback for LUKS1 format
                total_slots=$(cryptsetup luksDump "$device" 2>/dev/null | grep -c "Key Slot.*ENABLED" || echo 0)
            fi
            echo "  Total enabled key slots: $total_slots"
            
            # Check for Clevis slots
            if command_exists clevis; then
                local clevis_slots
                clevis_slots=$(clevis luks list -d "$device" 2>/dev/null | wc -l || echo 0)
                if [[ $clevis_slots -gt 0 ]]; then
                    echo "  Clevis-bound slots: $clevis_slots"
                fi
            fi
            echo
        fi
    done
    
    if [[ $found -eq 0 ]]; then
        print_warning "No LUKS encrypted devices found"
    fi
}

# Function to check TPM2 resource usage
check_tpm_resources() {
    print_section "TPM2 Resource Usage"
    
    if ! command_exists tpm2_getcap; then
        print_error "Cannot check TPM resources without tpm2-tools"
        return
    fi
    
    # Check handles
    print_info "Persistent handles in use:"
    if handles=$(tpm2_getcap handles-persistent 2>/dev/null); then
        if [[ -n "$handles" ]]; then
            echo "$handles" | while IFS= read -r line; do echo "  $line"; done
        else
            print_info "  No persistent handles in use"
        fi
    fi
    
    # Check NV indices
    print_info "NV indices in use:"
    if nvindices=$(tpm2_getcap handles-nv-index 2>/dev/null); then
        if [[ -n "$nvindices" ]]; then
            echo "$nvindices" | while IFS= read -r line; do echo "  $line"; done
        else
            print_info "  No NV indices in use"
        fi
    fi
}

# Function to show boot configuration
show_boot_config() {
    print_section "Boot Configuration"
    
    # Kernel command line
    print_info "Current kernel command line:"
    fold -w 70 < /proc/cmdline | while IFS= read -r line; do echo "  $line"; done
    
    # Check for rd.luks parameters
    if grep -q "rd.luks" /proc/cmdline; then
        print_success "LUKS boot parameters found in kernel command line"
    else
        print_warning "No rd.luks parameters in kernel command line"
    fi
    
    # Check crypttab
    if [[ -f /etc/crypttab ]]; then
        print_info "Crypttab entries:"
        grep -v "^#" /etc/crypttab | grep -v "^$" | sed 's/^/  /' || print_info "  No entries"
    fi
    
    # Initramfs tools
    print_info "Initramfs configuration:"
    if [[ -f /etc/cryptsetup-initramfs/conf-hook ]]; then
        grep -E "^(CRYPTSETUP|ASKPASS)" /etc/cryptsetup-initramfs/conf-hook 2>/dev/null | sed 's/^/  /' || true
    fi
}

# Function to run diagnostics
run_diagnostics() {
    print_section "Quick Diagnostics"
    
    local issues=0
    
    # Check TPM
    if tpm2_getcap properties-fixed >/dev/null 2>&1; then
        print_success "TPM2 communication: OK"
    else
        print_error "TPM2 communication: FAILED"
        ((issues++))
    fi
    
    # Check Clevis services
    if systemctl is-enabled clevis-luks-askpass.path >/dev/null 2>&1; then
        print_success "Clevis askpass service: ENABLED"
    else
        print_warning "Clevis askpass service: NOT ENABLED"
        ((issues++))
    fi
    
    # Check for LUKS devices
    local luks_found=0
    for device in /dev/sd* /dev/nvme* /dev/vd*; do
        if [[ -b "$device" ]] && cryptsetup isLuks "$device" 2>/dev/null; then
            luks_found=1
            break
        fi
    done
    
    if [[ $luks_found -eq 1 ]]; then
        print_success "LUKS devices: FOUND"
    else
        print_error "LUKS devices: NONE FOUND"
        ((issues++))
    fi
    
    # Summary
    echo
    if [[ $issues -eq 0 ]]; then
        print_success "All checks passed!"
    else
        print_warning "Found $issues potential issues"
    fi
}

# Main function
main() {
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           TPM2 and LUKS Status Report                 ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}"
    echo -e "Generated on: $(date)"
    
    # Run all checks
    check_tpm_device
    show_tpm_capabilities
    show_pcr_values
    check_systemd_cryptenroll
    check_clevis_status
    show_luks_info
    check_tpm_resources
    show_boot_config
    run_diagnostics
    
    print_section "End of Report"
    print_info "For more detailed information, run individual tpm2_* commands"
}

# Check for specific command
if [[ $# -gt 0 ]]; then
    case "$1" in
        tpm)
            check_tpm_device
            show_tpm_capabilities
            ;;
        pcr)
            show_pcr_values
            ;;
        luks)
            show_luks_info
            ;;
        clevis)
            check_clevis_status
            ;;
        boot)
            show_boot_config
            ;;
        diag|diagnose)
            run_diagnostics
            ;;
        *)
            echo "Usage: $0 [tpm|pcr|luks|clevis|boot|diag]"
            echo "  tpm    - Show TPM device and capabilities"
            echo "  pcr    - Show PCR values"
            echo "  luks   - Show LUKS device information"
            echo "  clevis - Show Clevis status"
            echo "  boot   - Show boot configuration"
            echo "  diag   - Run quick diagnostics"
            echo "  (none) - Show full report"
            exit 1
            ;;
    esac
else
    main
fi