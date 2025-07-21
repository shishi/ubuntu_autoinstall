# Ubuntu Autoinstall Configuration Rules and Guidelines

## Overview
This document contains the rules and best practices for Ubuntu autoinstall configurations that I've learned through our work together.

## System Information
- **Ubuntu Version**: 24.04 LTS
- **Installation Type**: ubuntu-desktop (NOT ubuntu-server)
- **Target System**: Desktop installation with LVM

## Critical Development Rules

### NEVER make changes without evidence:
1. **ALWAYS research and provide evidence before making any configuration changes**
2. **NEVER change settings multiple times without clear justification**
3. **ALWAYS show the source of your information (documentation, official guides, etc.)**
4. **If uncertain, ASK instead of guessing**
5. **Time is valuable - avoid trial and error approaches**

Examples of required evidence:
- Official Ubuntu/Curtin documentation links
- Error message analysis with clear cause-effect relationship
- Tested configurations with proven results
- Community consensus from reliable sources

### Changes must include:
```
## Change Justification
- **What**: Specific change being made
- **Why**: Evidence-based reason for the change
- **Source**: Documentation or error analysis supporting this change
- **Expected Result**: What this change will fix/improve
```
## Validation Requirements

### Always validate before installation:

### Common Validation Errors

## Time-Saving Practices
1. **ALWAYS** run validation before attempting installation
2. **NEVER** trust that valid YAML means valid autoinstall config
3. **ALWAYS** check for known problematic packages (systemd-cryptenroll)
4. **USE** the pre-install-check.sh script to catch issues early

## References
- [Ubuntu Autoinstall Reference](https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html)
- [Subiquity GitHub](https://github.com/canonical/subiquity)
- Bug #1969375 - systemd-cryptenroll TPM2 support issue
