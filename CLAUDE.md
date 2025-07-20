# Ubuntu Autoinstall Configuration Rules and Guidelines

## Overview
This document contains the rules and best practices for Ubuntu autoinstall configurations that I've learned through our work together.

## System Information
- **Ubuntu Version**: 22.04 LTS
- **Installation Type**: ubuntu-desktop (NOT ubuntu-server)
- **Target System**: Desktop installation with LVM

## Critical Rules

### 1. File Format Requirements
- **MUST** start with `#cloud-config` header (first line)
- **MUST** have only `autoinstall:` as top-level key when using cloud-config
- **MUST** use `version: 1` for autoinstall version
- **MUST** maintain proper YAML indentation (2 spaces)

### 2. Source Configuration
```yaml
source:
  id: ubuntu-desktop  # NOT ubuntu-server for this system
  search_drivers: true
```

### 3. Package Installation Issues

#### systemd-cryptenroll Problem
- **Issue**: `systemd-cryptenroll` package fails during installation with error code 100
- **Root Cause**: Ubuntu 22.04 installation ISO contains systemd without TPM2 support compiled in
- **Solution**: Install via late-commands after system update

```yaml
# DON'T do this:
packages:
  - systemd-cryptenroll  # Will fail!

# DO this instead:
late-commands:
  - curtin in-target -- apt-get update
  - curtin in-target -- apt-get upgrade -y
  - 'curtin in-target -- bash -c "apt-get install -y systemd-cryptenroll || echo Warning: systemd-cryptenroll installation failed, continuing without TPM2 enrollment support"'
```

### 4. Late-Commands Syntax Rules
- **MUST** be a list of strings
- **MUST** properly escape quotes when using complex commands
- **MUST** use proper YAML quoting for commands with special characters

```yaml
# Correct examples:
late-commands:
  - curtin in-target -- apt-get update
  - 'curtin in-target -- bash -c "command || echo fallback"'
  - "curtin in-target -- bash -c 'command with $variable'"
```

### 5. Storage Configuration
- LVM configuration is working correctly
- Partition sizes use percentages for LVM volumes:
  - Root: 90%
  - Swap: 10%

### 6. Interactive Sections
```yaml
interactive-sections:
  - identity  # Allows manual input during installation
```

## Validation Requirements

### Always validate before installation:
1. **YAML Syntax**: `python3 -c "import yaml; yaml.safe_load(open('config.yml'))"`
2. **Cloud-init Schema**: `cloud-init schema --config-file config.yml`
3. **Autoinstall Structure**: Use custom validation scripts
4. **Pre-install Check**: `./pre-install-check.sh config.yml`

### Common Validation Errors
- "Malformed autoinstall in late-commands section" - Usually quote escaping issues
- "Exit code 100" - Package installation failure
- Missing `#cloud-config` header
- Invalid top-level keys alongside `autoinstall:`

## Known Working Configuration Template
```yaml
#cloud-config
autoinstall:
  version: 1
  interactive-sections:
    - identity
  locale: en_US.UTF-8
  keyboard:
    layout: us
  source:
    id: ubuntu-desktop
    search_drivers: true
  network:
    version: 2
    ethernets:
      any:
        match:
          name: "en*"
        dhcp4: true
        dhcp6: true
  storage:
    # ... storage config ...
  packages:
    - git
    - build-essential
    - curl
    - tpm2-tools
    - cryptsetup-initramfs
    - cryptsetup-bin
    - pkg-config
    - libssl-dev
    - xz-utils
    # NOT systemd-cryptenroll here!
  late-commands:
    - curtin in-target -- apt-get update
    - curtin in-target -- apt-get upgrade -y
    - 'curtin in-target -- bash -c "apt-get install -y systemd-cryptenroll || echo Warning: continuing without TPM2 support"'
  identity:
    hostname: ubuntu-server
    username: ubuntu
    password: "$6$exDY1mhS4KUYCE/2$zmn9ToZwTKLhCw.b4/b.ZRTIZM30JZ4QrOQ2aOXJ8yk96xpcCof0kxKwuX1kqLG/ygbJ1f8wxED22bTL4F46P0"
  ssh:
    install-server: true
    allow-pw: true
```

## Debugging Tips
1. Check `/var/log/installer/` logs during installation
2. Use `curtin` logs for storage configuration issues
3. Check `subiquity` logs for autoinstall parsing errors
4. Screenshots of error messages help identify the exact failure point

## Time-Saving Practices
1. **ALWAYS** run validation before attempting installation
2. **NEVER** trust that valid YAML means valid autoinstall config
3. **ALWAYS** check for known problematic packages (systemd-cryptenroll)
4. **USE** the pre-install-check.sh script to catch issues early

## References
- [Ubuntu Autoinstall Reference](https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html)
- [Subiquity GitHub](https://github.com/canonical/subiquity)
- Bug #1969375 - systemd-cryptenroll TPM2 support issue