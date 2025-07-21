# LUKS Parsing and Shellcheck Fixes Summary

## Overview
Fixed shellcheck warnings and updated LUKS parsing to support LUKS2 format across all shell scripts.

## Key Changes

### 1. LUKS2 Format Support

#### Problem
- Scripts were using LUKS1 pattern `"Key Slot X: ENABLED"` which doesn't exist in LUKS2
- This caused incorrect slot counting (always showing 0 enabled slots)

#### Solution
- Updated parsing to detect LUKS version
- For LUKS2: Parse the `Keyslots:` section looking for `"  N: luks2"` pattern
- For LUKS1: Keep the original `"Key Slot N: ENABLED"` pattern
- Implemented in: `tpm-status.sh`, `cleanup-tpm-slots.sh`

### 2. Shellcheck Fixes

#### Fixed Issues by Script:

**tpm-status.sh**
- ✓ Removed useless cat (SC2002)
- ✓ Replaced sed with shell constructs (SC2001)
- ✓ Fixed variable declaration and assignment (SC2155)
- ✓ Used `grep -c` instead of `grep | wc -l` (SC2126)

**setup-tpm-luks-unlock.sh**
- ✓ Added `-r` flag to all read commands (SC2162)
- ✓ Fixed variable declaration and assignment (SC2155)
- ✓ Replaced `ls | grep` with find (SC2010)
- ✓ Replaced `ls` with find for file counting (SC2012)
- Note: SC2178 warning is a false positive (different function scopes)

**cleanup-tpm-slots.sh**
- ✓ Added `-r` flag to read command (SC2162)
- ✓ Used mapfile instead of array assignment (SC2207)
- ✓ Fixed variable declaration and assignment (SC2155)
- ✓ Fixed word splitting issues (SC2206)
- ✓ Commented unused variable (SC2034)

**check-tpm-health.sh**
- ✓ Fixed variable declaration and assignment (SC2155)
- ✓ Replaced `ls -t` with find for sorting files (SC2012)

**test-idempotency.sh**
- ✓ Replaced `ls` with find for file counting (SC2012)

**pre-install-check.sh**
- ✓ No issues found

### 3. Best Practices Applied

1. **Variable Declaration**: Separated declaration from assignment to avoid masking return values
2. **Array Handling**: Used `mapfile` or `read -a` for safer array population
3. **File Operations**: Replaced `ls` with `find` for more robust file handling
4. **Input Reading**: Added `-r` flag to prevent backslash mangling
5. **Command Substitution**: Avoided useless `cat` and unnecessary `sed`

## Testing

Run the test script to verify LUKS parsing:
```bash
./test-luks-parsing.sh
```

Run shellcheck to verify fixes:
```bash
for script in *.sh; do
    echo "Checking $script..."
    shellcheck "$script"
done
```

## LUKS Format Examples

### LUKS2 Format
```
Version:        2
Keyslots:
  0: luks2
     Key:        512 bits
     Priority:   normal
  1: luks2
     Key:        512 bits
```

### LUKS1 Format
```
Version:        1
Key Slot 0: ENABLED
Key Slot 1: ENABLED
Key Slot 2: DISABLED
```

## Remaining Notes

- The SC2178 warning in `setup-tpm-luks-unlock.sh` is a false positive due to variables with the same name in different function scopes
- All scripts now properly handle both LUKS1 and LUKS2 formats
- File operations are more robust and handle filenames with spaces