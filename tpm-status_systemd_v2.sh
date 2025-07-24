#!/usr/bin/env bash
set -euo pipefail

# TPM Status and Debug Information Script for systemd-cryptenroll (Version 2)
# Idempotent version with proper error handling and command validation

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

# Global variables
IS_ROOT=false
HAS_TPM_DEVICE=false
HAS_TPM_TOOLS=false
SYSTEMD_VERSION=0
HAS_SYSTEMD_CRYPTENROLL=false
LUKS_DEVICES=()
TPM2_ENROLLMENTS=()

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check root access
check_root() {
    if [[ $EUID -eq 0 ]]; then
        IS_ROOT=true
    else
        IS_ROOT=false
    fi
}

# Function to initialize environment
init_environment() {
    check_root
    
    # Check TPM device
    if [[ -c /dev/tpm0 ]] || [[ -c /dev/tpmrm0 ]]; then
        HAS_TPM_DEVICE=true
    fi
    
    # Check TPM tools
    if command_exists tpm2_getcap; then
        HAS_TPM_TOOLS=true
    fi
    
    # Check systemd version
    if command_exists systemctl; then
        SYSTEMD_VERSION=$(systemctl --version | head -1 | awk '{print $2}' || echo 0)
    fi
    
    # Check systemd-cryptenroll
    if command_exists systemd-cryptenroll; then
        HAS_SYSTEMD_CRYPTENROLL=true
    fi
    
    # Find LUKS devices (with proper handling)
    find_luks_devices
}

# Function to find LUKS devices safely
find_luks_devices() {
    LUKS_DEVICES=()
    
    # Only check if we have cryptsetup
    if ! command_exists cryptsetup; then
        return
    fi
    
    # Check common device patterns
    local patterns=("/dev/sd*" "/dev/nvme*" "/dev/vd*")
    
    for pattern in "${patterns[@]}"; do
        # Use null glob to handle no matches
        shopt -s nullglob
        for device in $pattern; do
            if [[ -b "$device" ]] && cryptsetup isLuks "$device" 2>/dev/null; then
                LUKS_DEVICES+=("$device")
                
                # Check for TPM2 enrollment if root
                if $IS_ROOT && cryptsetup luksDump "$device" 2>/dev/null | grep -q "tpm2"; then
                    TPM2_ENROLLMENTS+=("$device")
                fi
            fi
        done
        shopt -u nullglob
    done
}

# Function to check TPM device
check_tpm_device() {
    print_section "TPM Device Status"
    
    # Check device files
    if [[ -c /dev/tpm0 ]]; then
        print_success "TPM device found: /dev/tpm0"
        if $IS_ROOT; then
            ls -la /dev/tpm0
        fi
    else
        print_error "TPM device /dev/tpm0 not found"
    fi
    
    if [[ -c /dev/tpmrm0 ]]; then
        print_success "TPM resource manager found: /dev/tpmrm0"
        if $IS_ROOT; then
            ls -la /dev/tpmrm0
        fi
    else
        print_warning "TPM resource manager /dev/tpmrm0 not found"
    fi
    
    # Check kernel modules (idempotent)
    print_info "TPM kernel modules:"
    local tpm_modules
    tpm_modules=$(lsmod | grep -E "^tpm" || true)
    if [[ -n "$tpm_modules" ]]; then
        echo "$tpm_modules" | sed 's/^/  • /'
    else
        print_warning "No TPM kernel modules loaded"
    fi
}

# Function to show TPM capabilities
show_tpm_capabilities() {
    print_section "TPM2 Capabilities"
    
    if ! $HAS_TPM_TOOLS; then
        print_error "tpm2-tools not installed. Cannot query TPM capabilities."
        print_info "Install with: sudo apt-get install tpm2-tools"
        return
    fi
    
    if ! $HAS_TPM_DEVICE; then
        print_error "No TPM device available"
        return
    fi
    
    # TPM Properties (with proper error handling)
    print_info "TPM2 Properties:"
    local tpm_props
    tpm_props=$(tpm2_getcap properties-fixed 2>&1 || echo "")
    
    if [[ -n "$tpm_props" ]] && [[ ! "$tpm_props" =~ "ERROR" ]]; then
        echo "$tpm_props" | grep -E "(TPM2_PT_FAMILY_INDICATOR|TPM2_PT_MANUFACTURER|TPM2_PT_VENDOR|TPM2_PT_FIRMWARE_VERSION)" | head -10 | sed 's/^/  /'
    else
        print_error "Failed to query TPM2 properties"
        if ! $IS_ROOT; then
            print_info "Try running with sudo for full access"
        fi
    fi
}

# Function to show PCR values
show_pcr_values() {
    print_section "PCR Values (Secure Boot Related)"
    
    if ! $HAS_TPM_TOOLS; then
        print_error "tpm2_pcrread not available"
        return
    fi
    
    if ! $HAS_TPM_DEVICE; then
        print_error "No TPM device available"
        return
    fi
    
    print_info "PCR 7 (Secure Boot State) - Used by systemd-cryptenroll:"
    
    # Try to read PCR 7
    local pcr7_output
    pcr7_output=$(tpm2_pcrread "sha256:7" 2>&1 || echo "")
    
    if [[ -n "$pcr7_output" ]] && [[ ! "$pcr7_output" =~ "ERROR" ]]; then
        echo "$pcr7_output" | grep -A2 "sha256" | sed 's/^/  /'
    else
        print_error "Failed to read PCR values"
        if ! $IS_ROOT; then
            print_info "Try running with sudo for full access"
        fi
    fi
}

# Function to check systemd-cryptenroll status
check_systemd_cryptenroll() {
    print_section "systemd-cryptenroll Status"
    
    # Check systemd version
    print_info "systemd version: $SYSTEMD_VERSION"
    
    if [[ "$SYSTEMD_VERSION" -lt 248 ]]; then
        print_error "systemd version $SYSTEMD_VERSION is too old for TPM2 support (requires 248+)"
        return
    else
        print_success "systemd version supports TPM2 enrollment"
    fi
    
    if $HAS_SYSTEMD_CRYPTENROLL; then
        print_success "systemd-cryptenroll is available"
        local version_info
        version_info=$(systemd-cryptenroll --version 2>&1 | head -1 || echo "")
        if [[ -n "$version_info" ]]; then
            echo "  $version_info"
        fi
    else
        print_error "systemd-cryptenroll not found"
        print_info "This tool is included in systemd 248+"
        return
    fi
    
    # Show enrollments if found
    if [[ ${#TPM2_ENROLLMENTS[@]} -gt 0 ]]; then
        print_success "Found TPM2 enrollments on ${#TPM2_ENROLLMENTS[@]} device(s):"
        for device in "${TPM2_ENROLLMENTS[@]}"; do
            echo "  • $device"
            
            # Try to show details if root
            if $IS_ROOT && $HAS_SYSTEMD_CRYPTENROLL; then
                local enroll_details
                enroll_details=$(systemd-cryptenroll "$device" --tpm2-device=list 2>&1 || echo "")
                if [[ -n "$enroll_details" ]] && [[ ! "$enroll_details" =~ "Failed" ]]; then
                    echo "$enroll_details" | sed 's/^/    /'
                fi
            fi
        done
    else
        if [[ ${#LUKS_DEVICES[@]} -gt 0 ]]; then
            print_info "No TPM2 enrollments found on ${#LUKS_DEVICES[@]} LUKS device(s)"
        else
            print_info "No LUKS devices found to check"
        fi
    fi
}

# Function to show LUKS info
show_luks_info() {
    print_section "LUKS Device Information"
    
    if [[ ${#LUKS_DEVICES[@]} -eq 0 ]]; then
        print_warning "No LUKS encrypted devices found"
        return
    fi
    
    print_info "Found ${#LUKS_DEVICES[@]} LUKS device(s):"
    
    for device in "${LUKS_DEVICES[@]}"; do
        echo
        print_info "Device: $device"
        
        # Basic info (always available)
        if $IS_ROOT; then
            # Get LUKS version
            local luks_version
            luks_version=$(cryptsetup luksDump "$device" 2>/dev/null | grep "^Version:" | awk '{print $2}' || echo "unknown")
            echo "  LUKS Version: $luks_version"
            
            # Count key slots
            local slot_count=0
            if [[ "$luks_version" == "2" ]]; then
                slot_count=$(cryptsetup luksDump "$device" 2>/dev/null | grep -cE "^  [0-9]+: luks2" || echo 0)
            else
                slot_count=$(cryptsetup luksDump "$device" 2>/dev/null | grep -c "Key Slot.*ENABLED" || echo 0)
            fi
            echo "  Active key slots: $slot_count"
            
            # Check for TPM2
            if [[ " ${TPM2_ENROLLMENTS[@]} " =~ " ${device} " ]]; then
                print_success "  TPM2 enrollment: YES"
            else
                print_info "  TPM2 enrollment: NO"
            fi
        else
            print_info "  Run with sudo for detailed information"
        fi
    done
}

# Function to check boot configuration
show_boot_config() {
    print_section "Boot Configuration"
    
    # Kernel command line
    if [[ -f /proc/cmdline ]]; then
        print_info "Kernel command line:"
        fold -w 70 < /proc/cmdline | sed 's/^/  /'
        
        # Check for LUKS parameters
        if grep -q "rd.luks" /proc/cmdline; then
            print_success "LUKS boot parameters found"
        else
            print_info "No rd.luks parameters (may use crypttab)"
        fi
    fi
    
    # Crypttab
    if [[ -f /etc/crypttab ]]; then
        local crypttab_entries
        crypttab_entries=$(grep -v "^#" /etc/crypttab 2>/dev/null | grep -cv "^$" || echo 0)
        if [[ $crypttab_entries -gt 0 ]]; then
            print_success "Crypttab has $crypttab_entries entry/entries"
            if $IS_ROOT; then
                print_info "Crypttab entries:"
                grep -v "^#" /etc/crypttab | grep -v "^$" | sed 's/^/  /'
            fi
        else
            print_info "Crypttab exists but has no entries"
        fi
    else
        print_warning "No /etc/crypttab found"
    fi
}

# Function for diagnostics
run_diagnostics() {
    print_section "Quick Diagnostics"
    
    local issues=0
    
    # TPM Device
    if $HAS_TPM_DEVICE; then
        print_success "TPM2 device: PRESENT"
    else
        print_error "TPM2 device: NOT FOUND"
        ((issues++))
    fi
    
    # TPM Tools
    if $HAS_TPM_TOOLS; then
        print_success "TPM2 tools: INSTALLED"
    else
        print_warning "TPM2 tools: NOT INSTALLED"
    fi
    
    # Systemd version
    if [[ $SYSTEMD_VERSION -ge 248 ]]; then
        print_success "systemd version: OK ($SYSTEMD_VERSION >= 248)"
    else
        print_error "systemd version: TOO OLD ($SYSTEMD_VERSION < 248)"
        ((issues++))
    fi
    
    # systemd-cryptenroll
    if $HAS_SYSTEMD_CRYPTENROLL; then
        print_success "systemd-cryptenroll: AVAILABLE"
    else
        print_error "systemd-cryptenroll: NOT FOUND"
        ((issues++))
    fi
    
    # LUKS devices
    if [[ ${#LUKS_DEVICES[@]} -gt 0 ]]; then
        print_success "LUKS devices: ${#LUKS_DEVICES[@]} FOUND"
    else
        print_warning "LUKS devices: NONE FOUND"
    fi
    
    # TPM2 enrollments
    if [[ ${#TPM2_ENROLLMENTS[@]} -gt 0 ]]; then
        print_success "TPM2 enrollments: ${#TPM2_ENROLLMENTS[@]} FOUND"
    else
        if [[ ${#LUKS_DEVICES[@]} -gt 0 ]]; then
            print_warning "TPM2 enrollments: NONE FOUND"
        fi
    fi
    
    # Summary
    echo
    if [[ $issues -eq 0 ]]; then
        print_success "System is ready for TPM2 auto-unlock"
    else
        print_warning "Found $issues issue(s) that need attention"
    fi
    
    # Recommendations
    if ! $HAS_TPM_DEVICE; then
        print_info "Enable TPM in BIOS/UEFI settings"
    fi
    if ! $HAS_TPM_TOOLS; then
        print_info "Install tpm2-tools: sudo apt-get install tpm2-tools"
    fi
    if [[ ${#TPM2_ENROLLMENTS[@]} -eq 0 ]] && [[ ${#LUKS_DEVICES[@]} -gt 0 ]]; then
        print_info "Run setup script to enable TPM2 auto-unlock"
    fi
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTION]"
    echo "Display TPM2 and LUKS status for systemd-cryptenroll"
    echo
    echo "Options:"
    echo "  tpm       Show TPM device status"
    echo "  pcr       Show PCR values"
    echo "  luks      Show LUKS device information"
    echo "  systemd   Show systemd-cryptenroll status"
    echo "  boot      Show boot configuration"
    echo "  diag      Run quick diagnostics"
    echo "  help      Show this help message"
    echo "  (none)    Show full report"
    echo
    echo "This script is idempotent and can be run multiple times safely."
}

# Main function
main() {
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     TPM2 and LUKS Status Report (systemd-cryptenroll) ║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}"
    echo -e "Generated on: $(date)"
    
    if ! $IS_ROOT; then
        print_warning "Running as non-root. Some information may be limited."
        print_info "For full details, run with: sudo $0"
    fi
    
    # Initialize environment
    init_environment
    
    # Process command line argument
    case "${1:-full}" in
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
        systemd|enroll)
            check_systemd_cryptenroll
            ;;
        boot)
            show_boot_config
            ;;
        diag|diagnose)
            run_diagnostics
            ;;
        help|-h|--help)
            show_usage
            exit 0
            ;;
        full|*)
            check_tpm_device
            show_tpm_capabilities
            show_pcr_values
            check_systemd_cryptenroll
            show_luks_info
            show_boot_config
            run_diagnostics
            print_section "End of Report"
            ;;
    esac
}

# Run main with all arguments
main "$@"