#!/usr/bin/env bash
set -euo pipefail

# TPM Health Check Script for systemd-cryptenroll (Version 3)
# Fixed version - only uses documented commands

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Functions for colored output
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[FAIL]${NC} $1"; }

# Global variables
PCR_BACKUP_DIR="${HOME}/.tpm-pcr-backups"
FOUND_DEVICES=()
HAS_TPM2_ENROLLMENT=false

# Function to check if command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Function to ensure backup directory exists
ensure_backup_dir() {
  if [[ ! -d "$PCR_BACKUP_DIR" ]]; then
    mkdir -p "$PCR_BACKUP_DIR"
    print_info "Created PCR backup directory: $PCR_BACKUP_DIR"
  fi
}

# Function to find all LUKS devices
find_luks_devices() {
  FOUND_DEVICES=()
  local device_patterns=("/dev/sd*" "/dev/nvme*" "/dev/vd*")

  for pattern in "${device_patterns[@]}"; do
    # Use nullglob to handle no matches gracefully
    shopt -s nullglob
    for device in $pattern; do
      if [[ -b "$device" ]] && cryptsetup isLuks "$device" 2>/dev/null; then
        FOUND_DEVICES+=("$device")
      fi
    done
    shopt -u nullglob
  done

  if [[ ${#FOUND_DEVICES[@]} -eq 0 ]]; then
    print_warning "No LUKS devices found"
    return 1
  fi

  print_info "Found ${#FOUND_DEVICES[@]} LUKS device(s)"
  return 0
}

# Function to check systemd version
check_systemd_version() {
  local systemd_version
  systemd_version=$(systemctl --version | head -1 | awk '{print $2}')

  if [[ -z "$systemd_version" ]]; then
    print_error "Could not determine systemd version"
    return 1
  fi

  if [[ "$systemd_version" -lt 248 ]]; then
    print_error "systemd version $systemd_version is too old for TPM2 support (need 248+)"
    return 1
  fi

  print_success "systemd version $systemd_version supports TPM2"
  return 0
}

# Function to check for TPM2 enrollments
check_tpm2_enrollments() {
  HAS_TPM2_ENROLLMENT=false
  local enrolled_devices=0

  for device in "${FOUND_DEVICES[@]}"; do
    if cryptsetup luksDump "$device" 2>/dev/null | grep -q "tpm2"; then
      HAS_TPM2_ENROLLMENT=true
      ((enrolled_devices++))
      print_success "TPM2 enrollment found on $device"

      # Show basic enrollment info from luksDump
      if [[ $EUID -eq 0 ]]; then
        print_info "  TPM2 tokens in LUKS header:"
        cryptsetup luksDump "$device" 2>/dev/null | grep -A2 "tpm2" | sed 's/^/    /' || true
      fi
    else
      print_info "No TPM2 enrollment on $device"
    fi
  done

  if [[ $enrolled_devices -eq 0 ]]; then
    print_warning "No devices have TPM2 enrollment"
    return 1
  fi

  return 0
}

# Function to save PCR values
save_pcr_values() {
  if ! command_exists tpm2_pcrread; then
    print_warning "tpm2-tools not installed, cannot save PCR values"
    return 1
  fi

  ensure_backup_dir

  local pcr_file
  pcr_file="${PCR_BACKUP_DIR}/pcr-backup-$(date +%Y%m%d-%H%M%S).txt"

  # Save PCR values with metadata
  {
    echo "# TPM2 PCR Backup - $(date)"
    echo "# PCRs used by systemd-cryptenroll: 7 (Secure Boot)"
    echo ""
    tpm2_pcrread "sha256:0,1,4,7,14" 2>/dev/null
  } >"$pcr_file"

  if [[ -s "$pcr_file" ]]; then
    print_success "PCR values saved to: $pcr_file"

    # Keep only last 10 backups (idempotent cleanup)
    local backup_count
    backup_count=$(find "$PCR_BACKUP_DIR" -name "pcr-backup-*.txt" -type f | wc -l)
    if [[ $backup_count -gt 10 ]]; then
      print_info "Cleaning up old PCR backups (keeping last 10)..."
      find "$PCR_BACKUP_DIR" -name "pcr-backup-*.txt" -type f -printf '%T@ %p\n' |
        sort -n | head -n -10 | cut -d' ' -f2- | xargs -r rm -f
    fi

    return 0
  else
    rm -f "$pcr_file"
    print_error "Failed to save PCR values"
    return 1
  fi
}

# Function to compare PCR values
compare_pcr_values() {
  if ! command_exists tpm2_pcrread; then
    print_warning "tpm2-tools not installed, cannot compare PCR values"
    return 1
  fi

  # Find latest backup
  local latest_backup
  latest_backup=$(find "$PCR_BACKUP_DIR" -name "pcr-backup-*.txt" -type f -printf '%T@ %p\n' 2>/dev/null |
    sort -nr | head -1 | cut -d' ' -f2-)

  if [[ -z "$latest_backup" ]] || [[ ! -f "$latest_backup" ]]; then
    print_warning "No previous PCR backup found for comparison"
    return 1
  fi

  print_info "Comparing with: $(basename "$latest_backup")"

  # Get current PCR values
  local current_pcr
  current_pcr=$(mktemp)
  tpm2_pcrread "sha256:0,1,4,7,14" >"$current_pcr" 2>/dev/null

  # Extract PCR 7 values for comparison
  local old_pcr7 new_pcr7
  old_pcr7=$(grep -A1 "^  7 :" "$latest_backup" | tail -1 | awk '{print $2}' || echo "")
  new_pcr7=$(grep -A1 "^  7 :" "$current_pcr" | tail -1 | awk '{print $2}' || echo "")

  if [[ "$old_pcr7" == "$new_pcr7" ]]; then
    print_success "PCR 7 (Secure Boot) unchanged - auto-unlock should work"
  else
    print_warning "PCR 7 (Secure Boot) changed - auto-unlock may fail"
    print_info "Old PCR 7: ${old_pcr7:0:16}..."
    print_info "New PCR 7: ${new_pcr7:0:16}..."
    print_info "This can happen after kernel/bootloader updates"
  fi

  rm -f "$current_pcr"
  return 0
}

# Function to check recovery key
check_recovery_key() {
  local recovery_key_found=false

  # Check common locations
  if [[ -d /root ]] && [[ $EUID -eq 0 ]]; then
    local key_count
    key_count=$(find /root -maxdepth 1 -name ".luks-recovery-key-*.txt" -type f 2>/dev/null | wc -l)
    if [[ $key_count -gt 0 ]]; then
      print_success "Found $key_count recovery key file(s) in /root"
      recovery_key_found=true
    fi
  fi

  if ! $recovery_key_found; then
    print_warning "No recovery key files found in standard location"
    print_info "Make sure you have access to your recovery key!"
  fi
}

# Function to check boot configuration
check_boot_config() {
  print_info "Checking boot configuration..."

  # Check crypttab
  if [[ -f /etc/crypttab ]]; then
    local crypttab_entries
    crypttab_entries=$(grep -v "^#" /etc/crypttab 2>/dev/null | grep -v "^$" | wc -l || echo 0)
    if [[ $crypttab_entries -gt 0 ]]; then
      print_success "/etc/crypttab has $crypttab_entries entry/entries"
    else
      print_warning "/etc/crypttab exists but has no active entries"
    fi
  else
    print_warning "/etc/crypttab not found"
  fi

  # Check kernel parameters
  if [[ -f /proc/cmdline ]]; then
    if grep -q "rd.luks" /proc/cmdline; then
      print_success "LUKS parameters found in kernel command line"
    else
      print_info "No rd.luks parameters in kernel command line (using crypttab)"
    fi
  fi

  # Check if running in initramfs
  if [[ -d /run/initramfs ]]; then
    print_info "Running from initramfs environment"
  fi
}

# Pre-update check
check_pre_update() {
  print_info "=== Pre-update TPM health check (systemd-cryptenroll) ==="

  # System checks
  check_systemd_version || return 1

  # Find devices
  find_luks_devices || return 1

  # Check enrollments
  check_tpm2_enrollments || true # Continue even if no enrollments

  # Save PCR values
  save_pcr_values || true # Continue even if fails

  # Check recovery key
  check_recovery_key

  print_info ""
  print_warning "Before proceeding with system updates:"
  print_warning "1. Ensure you have your recovery key accessible"
  print_warning "2. Be prepared to enter recovery key if TPM unlock fails after update"
  print_warning "3. Consider running this script again after updates to verify"
}

# Post-update check
check_post_update() {
  print_info "=== Post-update TPM health check (systemd-cryptenroll) ==="

  # System checks
  check_systemd_version || return 1

  # Find devices
  find_luks_devices || return 1

  # Check enrollments
  check_tpm2_enrollments || true # Continue even if no enrollments

  # Compare PCR values
  compare_pcr_values || true # Continue even if fails

  # Check boot configuration
  check_boot_config

  # Final recommendations
  print_info ""
  if $HAS_TPM2_ENROLLMENT; then
    print_info "TPM2 auto-unlock status will be verified on next boot"
    print_info "If auto-unlock fails, use your recovery key"
  else
    print_warning "No TPM2 enrollments found"
    print_info "Run setup script to enable TPM2 auto-unlock"
  fi
}

# Full check
check_full() {
  check_pre_update
  echo
  check_post_update
}

# Main execution
main() {
  case "${1:-check}" in
  pre | before)
    check_pre_update
    ;;
  post | after)
    check_post_update
    ;;
  check | full | *)
    check_full
    ;;
  esac
}

# Run main function
main "$@"
