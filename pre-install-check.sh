#!/bin/bash
# Pre-installation validation script
# Runs all available validations to catch errors before installation

set -euo pipefail

CONFIG_FILE="${1:-autoinstall.yml}"

echo "🔍 Running comprehensive pre-installation checks for: $CONFIG_FILE"
echo "================================================================"

# Check if file exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "❌ ERROR: File $CONFIG_FILE not found"
    exit 1
fi

# 1. YAML syntax check
echo -e "\n1️⃣  Checking YAML syntax..."
if python3 -c "import yaml; yaml.safe_load(open('$CONFIG_FILE'))" 2>/dev/null; then
    echo "   ✅ Valid YAML syntax"
else
    echo "   ❌ Invalid YAML syntax"
    python3 -c "import yaml; yaml.safe_load(open('$CONFIG_FILE'))" 2>&1 | sed 's/^/   /'
    exit 1
fi

# 2. Cloud-init schema validation
echo -e "\n2️⃣  Checking cloud-init schema..."
if cloud-init schema --config-file "$CONFIG_FILE" 2>&1 | grep -q "Valid schema"; then
    echo "   ✅ Valid cloud-init schema"
else
    echo "   ❌ Invalid cloud-init schema"
    cloud-init schema --config-file "$CONFIG_FILE" 2>&1 | sed 's/^/   /'
    exit 1
fi

# 3. Strict autoinstall validation
echo -e "\n3️⃣  Running strict autoinstall validation..."
if python3 validate-autoinstall-strict.py "$CONFIG_FILE" >/dev/null 2>&1; then
    echo "   ✅ Passed strict validation"
else
    echo "   ❌ Failed strict validation"
    python3 validate-autoinstall-strict.py "$CONFIG_FILE" 2>&1 | grep -E "❌|•" | sed 's/^/   /'
    exit 1
fi

# 4. Command syntax validation
echo -e "\n4️⃣  Validating command syntax..."
if python3 validate-commands.py "$CONFIG_FILE" >/dev/null 2>&1; then
    echo "   ✅ All commands validated"
else
    echo "   ❌ Command syntax errors found"
    python3 validate-commands.py "$CONFIG_FILE" 2>&1 | grep -E "❌|•" | sed 's/^/   /'
    exit 1
fi

# 5. Check for common issues
echo -e "\n5️⃣  Checking for common issues..."
ISSUES=0

# Check late-commands for common syntax errors
if grep -q "late-commands:" "$CONFIG_FILE"; then
    # Check for unescaped quotes in late-commands
    if grep -A 50 "late-commands:" "$CONFIG_FILE" | grep -E "^\s*-\s+[^'\"].*['\"].*['\"]" | grep -v -E "^\s*-\s+['\"]"; then
        echo "   ⚠️  WARNING: Possible unescaped quotes in late-commands"
        ((ISSUES++))
    fi
    
    # Check for multiline commands without proper quotes
    if grep -A 50 "late-commands:" "$CONFIG_FILE" | grep -E "^\s*-\s+.*\|\|.*echo" | grep -v -E "^\s*-\s+['\"]"; then
        echo "   ⚠️  WARNING: Complex commands should be quoted"
        ((ISSUES++))
    fi
fi

# Check for systemd-cryptenroll in packages (known issue)
if grep -A 50 "packages:" "$CONFIG_FILE" | grep -E "^\s*-\s*systemd-cryptenroll" >/dev/null 2>&1; then
    echo "   ⚠️  WARNING: systemd-cryptenroll in packages section may fail on some ISOs"
    echo "      Consider moving to late-commands for better compatibility"
    ((ISSUES++))
fi

if [[ $ISSUES -eq 0 ]]; then
    echo "   ✅ No common issues detected"
fi

# Summary
echo -e "\n================================================================"
echo "📊 Validation Summary:"
echo "   • YAML Syntax: ✅"
echo "   • Cloud-init Schema: ✅"
echo "   • Autoinstall Structure: ✅"
echo "   • Command Syntax: ✅"
echo "   • Common Issues: $([ $ISSUES -eq 0 ] && echo '✅' || echo "⚠️  $ISSUES warning(s)")"
echo -e "\n✅ Configuration appears valid and ready for installation"
echo "================================================================"