#!/usr/bin/env bash
set -euo pipefail

# TPM Slot Cleanup Script for systemd-cryptenroll (Version 2)
# Idempotent version with improved safety and validation

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
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
  echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

print_section() {
  echo
  echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}▶ $1${NC}"
  echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
}

# Global variables
AUDIT_LOG="/var/log/tpm-cleanup-audit.log"
DRY_RUN=false
VERBOSE=false

# Check if running as root
check_root() {
  if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root"
    exit 1
  fi
}

# Function to check if a command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Initialize environment
init_environment() {
  # Create audit log if needed
  if [[ ! -f "$AUDIT_LOG" ]]; then
    touch "$AUDIT_LOG"
    chmod 600 "$AUDIT_LOG"
  fi
}

# Function to log actions
log_action() {
  local action="$1"
  local details="$2"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] TPM_CLEANUP: $action - $details" >>"$AUDIT_LOG"
}

# Safety check function
confirm_action() {
  local prompt="$1"
  local response

  echo -e "${YELLOW}$prompt${NC}"
  read -r -p "Type 'yes' to continue, anything else to skip: " response

  if [[ "$response" == "yes" ]]; then
    return 0
  else
    return 1
  fi
}

# Function to find LUKS devices
find_luks_devices() {
  local luks_devices=()
  local patterns=("/dev/sd*" "/dev/nvme*" "/dev/vd*" "/dev/mapper/*")

  for pattern in "${patterns[@]}"; do
    shopt -s nullglob
    for device in $pattern; do
      if [[ -b "$device" ]] && cryptsetup isLuks "$device" 2>/dev/null; then
        luks_devices+=("$device")
      fi
    done
    shopt -u nullglob
  done

  printf '%s\n' "${luks_devices[@]}"
}

# Function to parse TPM2 enrollments with better error handling
parse_tpm2_enrollments() {
  local device="$1"
  local -A enrollment_info
  local -a tpm_slots=()

  # Get LUKS version
  local luks_version
  luks_version=$(cryptsetup luksDump "$device" 2>/dev/null | grep "^Version:" | awk '{print $2}')

  if [[ "$luks_version" != "2" ]]; then
    print_warning "Device $device is LUKS version $luks_version. TPM2 requires LUKS2."
    return 1
  fi

  # Parse tokens and keyslots
  local in_tokens=false
  local current_token=""
  local token_type=""
  local token_keyslot=""
  local token_pcrs=""

  while IFS= read -r line; do
    if [[ "$line" =~ ^Tokens: ]]; then
      in_tokens=true
    elif [[ "$line" =~ ^[A-Z] ]] && [[ "$in_tokens" == "true" ]]; then
      in_tokens=false
    elif [[ "$in_tokens" == "true" ]]; then
      # Parse token header
      if [[ "$line" =~ ^[[:space:]]+([0-9]+):[[:space:]]*(.+) ]]; then
        current_token="${BASH_REMATCH[1]}"
        token_type="${BASH_REMATCH[2]}"
        token_keyslot=""
        token_pcrs=""
      # Parse token properties
      elif [[ -n "$current_token" ]]; then
        if [[ "$line" =~ [[:space:]]+Keyslot:[[:space:]]+([0-9]+) ]]; then
          token_keyslot="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ [[:space:]]+tpm2-pcrs:[[:space:]]+(.+) ]]; then
          token_pcrs="${BASH_REMATCH[1]}"
        fi

        # Save TPM2 tokens
        if [[ "$token_type" == "systemd-tpm2" ]] && [[ -n "$token_keyslot" ]]; then
          tpm_slots+=("$token_keyslot")
          enrollment_info["slot_${token_keyslot}_token"]="$current_token"
          enrollment_info["slot_${token_keyslot}_pcrs"]="${token_pcrs:-7}"
          enrollment_info["slot_${token_keyslot}_type"]="systemd-tpm2"
        fi
      fi
    fi
  done < <(cryptsetup luksDump "$device" 2>/dev/null)

  # Return results
  enrollment_info["tpm_slots"]="${tpm_slots[*]}"
  enrollment_info["count"]="${#tpm_slots[@]}"

  # Output as key=value pairs
  for key in "${!enrollment_info[@]}"; do
    echo "$key=${enrollment_info[$key]}"
  done
}

# Function to display TPM enrollment analysis
display_tpm_analysis() {
  local device="$1"
  local -A info

  # Parse enrollment info
  while IFS='=' read -r key value; do
    info["$key"]="$value"
  done < <(parse_tpm2_enrollments "$device")

  local count="${info[count]:-0}"

  if [[ "$count" -eq 0 ]]; then
    print_info "No TPM2 enrollments found on $device"
    return 1
  fi

  print_section "TPM2 Enrollments on $device"
  print_info "Total TPM2 enrollments: $count"

  # Display details for each slot
  local -a tpm_slots
  IFS=' ' read -r -a tpm_slots <<<"${info[tpm_slots]}"

  echo
  printf "%-8s %-10s %-20s %-15s\n" "Slot" "Token" "PCRs" "Type"
  printf "%s\n" "────────────────────────────────────────────────────────"

  for slot in "${tpm_slots[@]}"; do
    local token="${info[slot_${slot}_token]:-unknown}"
    local pcrs="${info[slot_${slot}_pcrs]:-unknown}"
    local type="${info[slot_${slot}_type]:-unknown}"
    printf "%-8s %-10s %-20s %-15s\n" "$slot" "#$token" "$pcrs" "$type"
  done

  # Additional info from systemd-cryptenroll
  if command_exists systemd-cryptenroll; then
    echo
    print_info "systemd-cryptenroll view:"
    systemd-cryptenroll "$device" --tpm2-device=list 2>&1 | sed 's/^/  /' ||
      print_warning "  Unable to query systemd-cryptenroll"
  fi

  return 0
}

# Function to validate TPM slot removal safety
validate_removal_safety() {
  local device="$1"
  local keep_slot="$2"
  shift 2
  local -a remove_slots=("$@")

  # Count total active slots
  local total_slots
  total_slots=$(cryptsetup luksDump "$device" 2>/dev/null | grep -cE "^  [0-9]+: luks2" || echo 0)

  # Count password slots (non-token slots)
  local password_slots=0
  for i in {0..31}; do
    if cryptsetup luksDump "$device" 2>/dev/null | grep -qE "^  $i: luks2"; then
      # Check if this slot has a token
      local has_token=false
      if cryptsetup luksDump "$device" 2>/dev/null | awk '/^Tokens:/,/^[A-Z]/' | grep -q "Keyslot:[[:space:]]*$i"; then
        has_token=true
      fi

      if [[ "$has_token" == "false" ]]; then
        ((password_slots++))
      fi
    fi
  done

  # Safety checks
  local remaining_slots=$((total_slots - ${#remove_slots[@]}))

  print_info "Safety validation:"
  print_info "  Total slots: $total_slots"
  print_info "  Password slots: $password_slots"
  print_info "  Slots to remove: ${#remove_slots[@]}"
  print_info "  Slots remaining after removal: $remaining_slots"

  if [[ $remaining_slots -lt 2 ]]; then
    print_error "Removal would leave less than 2 authentication methods!"
    print_error "This is unsafe. Keep at least one password and one TPM slot."
    return 1
  fi

  if [[ $password_slots -eq 0 ]]; then
    print_error "No password slots found! This is dangerous."
    print_error "Always maintain at least one password slot."
    return 1
  fi

  print_success "Safety check passed"
  return 0
}

# Function to cleanup TPM slots
cleanup_tpm_slots() {
  local device="$1"
  local -A info

  # Parse enrollment info
  while IFS='=' read -r key value; do
    info["$key"]="$value"
  done < <(parse_tpm2_enrollments "$device")

  local count="${info[count]:-0}"

  if [[ "$count" -eq 0 ]]; then
    print_info "No TPM2 enrollments found on $device"
    return 0
  elif [[ "$count" -eq 1 ]]; then
    print_success "Only one TPM2 enrollment found - no duplicates"
    return 0
  fi

  # Show current state
  display_tpm_analysis "$device" || return 1

  # Get TPM slots
  local -a tpm_slots
  IFS=' ' read -r -a tpm_slots <<<"${info[tpm_slots]}"

  # Explain the situation
  echo
  print_warning "Multiple TPM2 enrollments detected!"
  print_info "Common causes:"
  print_info "  • System updates that changed PCR values"
  print_info "  • Multiple enrollment attempts"
  print_info "  • Testing different PCR policies"
  echo

  # Choose slot to keep
  print_warning "Select which TPM2 slot to KEEP:"
  print_info "Available slots: ${tpm_slots[*]}"
  print_info "Tip: Usually keep the newest (highest number) or currently working slot"

  local keep_slot
  while true; do
    read -r -p "Keep slot: " keep_slot
    if [[ " ${tpm_slots[*]} " =~ " ${keep_slot} " ]]; then
      break
    else
      print_error "Invalid. Choose from: ${tpm_slots[*]}"
    fi
  done

  # Calculate removal list
  local -a remove_slots=()
  for slot in "${tpm_slots[@]}"; do
    if [[ "$slot" != "$keep_slot" ]]; then
      remove_slots+=("$slot")
    fi
  done

  # Validate safety
  if ! validate_removal_safety "$device" "$keep_slot" "${remove_slots[@]}"; then
    print_error "Safety validation failed. Aborting."
    return 1
  fi

  # Show plan
  echo
  print_section "Removal Plan"
  print_success "KEEP: Slot $keep_slot"
  print_warning "REMOVE: ${remove_slots[*]}"

  if [[ "$DRY_RUN" == "true" ]]; then
    print_info "DRY RUN: No changes will be made"
    return 0
  fi

  # Final confirmation
  echo
  print_warning "Pre-removal checklist:"
  print_info "  ✓ Have a working password for emergency access"
  print_info "  ✓ Recovery key is accessible"
  print_info "  ✓ Can test TPM unlock after changes"
  echo

  if ! confirm_action "Proceed with TPM slot removal?"; then
    print_info "Cancelled by user"
    return 0
  fi

  # Get authentication
  print_info "Enter a valid password for $device:"
  local password
  read -r -s -p "Password: " password
  echo
  echo

  # Verify password first
  if ! printf '%s' "$password" | cryptsetup open --test-passphrase "$device" 2>/dev/null; then
    print_error "Invalid password"
    return 1
  fi

  # Remove slots
  print_section "Removing TPM Slots"

  log_action "START_REMOVAL" "Device: $device, Keep: $keep_slot, Remove: ${remove_slots[*]}"

  local success_count=0
  local fail_count=0

  for slot in "${remove_slots[@]}"; do
    print_info "Removing slot $slot..."

    if printf '%s' "$password" | cryptsetup luksKillSlot "$device" "$slot" 2>/dev/null; then
      print_success "Removed slot $slot"
      log_action "REMOVE_SUCCESS" "Device: $device, Slot: $slot"
      ((success_count++))
    else
      print_error "Failed to remove slot $slot"
      log_action "REMOVE_FAILED" "Device: $device, Slot: $slot"
      ((fail_count++))
    fi
  done

  # Summary
  echo
  if [[ $fail_count -eq 0 ]]; then
    print_success "Successfully removed $success_count TPM slot(s)"
  else
    print_warning "Removed $success_count slot(s), failed to remove $fail_count slot(s)"
  fi

  # Verify final state
  echo
  print_section "Final State"
  display_tpm_analysis "$device" || print_warning "Unable to display final state"

  # Reminder
  echo
  print_warning "IMPORTANT: Test TPM unlock on next boot!"
  print_info "If it fails, use your password or recovery key"
}

# Function to show usage
show_usage() {
  cat <<EOF
Usage: $0 [OPTIONS] [DEVICE]

Clean up duplicate TPM2 enrollments from LUKS devices (systemd-cryptenroll).

OPTIONS:
    -d, --dry-run     Show what would be done without making changes
    -v, --verbose     Show detailed information
    -h, --help        Show this help message

DEVICE:
    Specific LUKS device to clean (e.g., /dev/sda3)
    If not specified, all LUKS devices will be processed

SAFETY FEATURES:
    - Validates removal won't leave system inaccessible
    - Requires password authentication
    - Creates audit log at: $AUDIT_LOG
    - Supports dry-run mode
    - Shows detailed slot information

This script is idempotent and can be run multiple times safely.
EOF
}

# Main function
main() {
  local device=""

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -d | --dry-run)
      DRY_RUN=true
      shift
      ;;
    -v | --verbose)
      VERBOSE=true
      shift
      ;;
    -h | --help)
      show_usage
      exit 0
      ;;
    -*)
      print_error "Unknown option: $1"
      show_usage
      exit 1
      ;;
    *)
      device="$1"
      shift
      ;;
    esac
  done

  # Initialize
  check_root
  init_environment

  # Check prerequisites
  if ! command_exists cryptsetup; then
    print_error "cryptsetup not installed"
    exit 1
  fi

  # Check systemd version
  local systemd_version
  systemd_version=$(systemctl --version | head -1 | awk '{print $2}' || echo 0)
  if [[ $systemd_version -lt 248 ]]; then
    print_error "systemd $systemd_version too old (need 248+)"
    exit 1
  fi

  print_section "TPM2 Slot Cleanup (systemd-cryptenroll)"

  if [[ "$DRY_RUN" == "true" ]]; then
    print_warning "DRY RUN MODE - No changes will be made"
  fi

  # Process devices
  if [[ -n "$device" ]]; then
    # Specific device
    if [[ ! -b "$device" ]] || ! cryptsetup isLuks "$device" 2>/dev/null; then
      print_error "$device is not a valid LUKS device"
      exit 1
    fi

    cleanup_tpm_slots "$device"
  else
    # All devices
    local -a devices
    mapfile -t devices < <(find_luks_devices)

    if [[ ${#devices[@]} -eq 0 ]]; then
      print_warning "No LUKS devices found"
      exit 0
    fi

    print_info "Found ${#devices[@]} LUKS device(s)"

    for dev in "${devices[@]}"; do
      echo
      cleanup_tpm_slots "$dev"

      if [[ ${#devices[@]} -gt 1 ]]; then
        echo
        read -r -p "Press Enter to continue..."
      fi
    done
  fi

  echo
  print_success "Operation completed"

  if [[ "$DRY_RUN" == "false" ]]; then
    print_info "Audit log: $AUDIT_LOG"
  fi
}

# Run main
main "$@"
