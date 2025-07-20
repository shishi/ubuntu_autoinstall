#!/usr/bin/env python3
"""
Strict validation for Ubuntu autoinstall.yml configuration
Detects common syntax errors and malformed sections
"""

import yaml
import sys
import re
import shlex

def validate_late_commands(commands):
    """Validate late-commands syntax"""
    errors = []
    
    for i, cmd in enumerate(commands):
        if not isinstance(cmd, str):
            errors.append(f"Late command {i+1}: Must be a string, got {type(cmd).__name__}")
            continue
            
        # Check for basic curtin command structure
        if not cmd.strip():
            errors.append(f"Late command {i+1}: Empty command")
            continue
            
        # Check for problematic quote combinations
        single_quotes = cmd.count("'")
        double_quotes = cmd.count('"')
        
        # Try to parse the command
        try:
            # If command starts with quotes, check if properly closed
            if cmd.strip().startswith("'") and not cmd.strip().endswith("'"):
                errors.append(f"Late command {i+1}: Unclosed single quote")
            elif cmd.strip().startswith('"') and not cmd.strip().endswith('"'):
                errors.append(f"Late command {i+1}: Unclosed double quote")
                
            # Try shell parsing for complex commands
            if 'bash -c' in cmd or 'sh -c' in cmd:
                # Extract the shell command
                match = re.search(r'(?:bash|sh)\s+-c\s+["\'](.+)["\']', cmd)
                if match:
                    shell_cmd = match.group(1)
                    # Check for common issues
                    if '||' in shell_cmd and 'echo' in shell_cmd:
                        # This is OK - error handling pattern
                        pass
                else:
                    # Try alternative parsing
                    try:
                        parts = shlex.split(cmd)
                    except ValueError as e:
                        errors.append(f"Late command {i+1}: Shell parsing error - {e}")
                        
        except Exception as e:
            errors.append(f"Late command {i+1}: Validation error - {e}")
            
    return errors

def validate_packages(packages):
    """Validate packages section"""
    errors = []
    
    if not isinstance(packages, list):
        errors.append("Packages must be a list")
        return errors
        
    for i, pkg in enumerate(packages):
        if not isinstance(pkg, str):
            errors.append(f"Package {i+1}: Must be a string, got {type(pkg).__name__}")
        elif not pkg.strip():
            errors.append(f"Package {i+1}: Empty package name")
            
    return errors

def validate_storage(storage):
    """Validate storage configuration"""
    errors = []
    
    if 'config' not in storage:
        errors.append("Storage: Missing 'config' section")
        return errors
        
    config = storage['config']
    if not isinstance(config, list):
        errors.append("Storage config must be a list")
        return errors
        
    # Track device IDs for reference validation
    defined_ids = set()
    
    for i, item in enumerate(config):
        if 'type' not in item:
            errors.append(f"Storage config {i+1}: Missing 'type' field")
            continue
            
        if 'id' in item:
            if item['id'] in defined_ids:
                errors.append(f"Storage config {i+1}: Duplicate ID '{item['id']}'")
            defined_ids.add(item['id'])
            
        # Validate references
        if 'device' in item and isinstance(item['device'], str):
            if item['device'] not in defined_ids:
                errors.append(f"Storage config {i+1}: References undefined device '{item['device']}'")
                
        if 'volume' in item and isinstance(item['volume'], str):
            if item['volume'] not in defined_ids:
                errors.append(f"Storage config {i+1}: References undefined volume '{item['volume']}'")
                
    return errors

def validate_autoinstall_strict(file_path):
    """Perform strict validation of autoinstall configuration"""
    
    try:
        # Check cloud-config header
        with open(file_path, 'r') as f:
            first_line = f.readline().strip()
            if first_line != '#cloud-config':
                print("❌ Missing #cloud-config header")
                return False
            f.seek(0)
            config = yaml.safe_load(f)
    except yaml.YAMLError as e:
        print(f"❌ YAML parsing error: {e}")
        return False
    except Exception as e:
        print(f"❌ File reading error: {e}")
        return False
        
    if not config:
        print("❌ Empty configuration")
        return False
        
    if 'autoinstall' not in config:
        print("❌ Missing 'autoinstall' top-level key")
        return False
        
    # Check for invalid top-level keys
    valid_top_keys = {'autoinstall'}
    invalid_keys = set(config.keys()) - valid_top_keys
    if invalid_keys:
        print(f"❌ Invalid top-level keys: {', '.join(invalid_keys)}")
        print("   Only 'autoinstall' is allowed at top level with #cloud-config")
        return False
        
    autoinstall = config['autoinstall']
    errors = []
    
    # Validate version
    if 'version' not in autoinstall:
        errors.append("Missing required 'version' field")
    elif autoinstall['version'] != 1:
        errors.append(f"Invalid version: {autoinstall['version']} (must be 1)")
        
    # Validate source
    if 'source' in autoinstall:
        source = autoinstall['source']
        if not isinstance(source, dict):
            errors.append("Source must be a dictionary")
        elif 'id' not in source:
            errors.append("Source missing required 'id' field")
            
    # Validate late-commands
    if 'late-commands' in autoinstall:
        late_errors = validate_late_commands(autoinstall['late-commands'])
        errors.extend(late_errors)
        
    # Validate packages
    if 'packages' in autoinstall:
        pkg_errors = validate_packages(autoinstall['packages'])
        errors.extend(pkg_errors)
        
    # Validate storage
    if 'storage' in autoinstall:
        storage_errors = validate_storage(autoinstall['storage'])
        errors.extend(storage_errors)
        
    # Validate identity
    if 'identity' in autoinstall:
        identity = autoinstall['identity']
        required_fields = ['hostname', 'username', 'password']
        for field in required_fields:
            if field not in identity:
                errors.append(f"Identity missing required field: {field}")
                
    # Print results
    if errors:
        print("❌ Validation errors found:")
        for error in errors:
            print(f"   • {error}")
        return False
    else:
        print("✅ All validations passed")
        return True

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: python3 validate-autoinstall-strict.py <autoinstall.yml>")
        sys.exit(1)
        
    file_path = sys.argv[1]
    print(f"Performing strict validation of {file_path}...")
    print("=" * 60)
    
    if validate_autoinstall_strict(file_path):
        print("\n✅ Configuration is valid")
        sys.exit(0)
    else:
        print("\n❌ Configuration has errors")
        sys.exit(1)