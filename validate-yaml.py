#!/usr/bin/env python3
"""
Validate YAML syntax and basic autoinstall structure
"""

import yaml
import sys
import json

def validate_yaml(file_path):
    """Validate YAML syntax and structure"""
    try:
        with open(file_path, 'r') as f:
            # Check cloud-config header
            first_line = f.readline().strip()
            if first_line != '#cloud-config':
                print("❌ Missing #cloud-config header")
                return False
            
            # Reset to beginning and load YAML
            f.seek(0)
            data = yaml.safe_load(f)
            
        print("✅ Valid YAML syntax")
        
        # Check basic structure
        if 'autoinstall' not in data:
            print("❌ Missing 'autoinstall' top-level key")
            return False
        
        autoinstall = data['autoinstall']
        
        # Check version
        if 'version' not in autoinstall:
            print("❌ Missing 'version' field")
            return False
        
        print("✅ Basic autoinstall structure is valid")
        
        # Print structure summary
        print("\n📋 Configuration summary:")
        print(f"  - Version: {autoinstall.get('version')}")
        print(f"  - Source: {autoinstall.get('source', {}).get('id', 'Not specified')}")
        print(f"  - Interactive sections: {autoinstall.get('interactive-sections', [])}")
        print(f"  - Storage type: {'LVM' if any(item.get('type') == 'lvm_volgroup' for item in autoinstall.get('storage', {}).get('config', [])) else 'Standard'}")
        print(f"  - Packages count: {len(autoinstall.get('packages', []))}")
        print(f"  - Late commands: {len(autoinstall.get('late-commands', []))}")
        
        return True
        
    except yaml.YAMLError as e:
        print(f"❌ YAML parsing error: {e}")
        return False
    except Exception as e:
        print(f"❌ Error: {e}")
        return False

if __name__ == '__main__':
    file_path = sys.argv[1] if len(sys.argv) > 1 else 'autoinstall.yml'
    
    print(f"Validating {file_path}...")
    print("=" * 50)
    
    if validate_yaml(file_path):
        print("\n✅ Validation successful!")
        sys.exit(0)
    else:
        print("\n❌ Validation failed!")
        sys.exit(1)