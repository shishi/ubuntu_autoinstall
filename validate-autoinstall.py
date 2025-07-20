#!/usr/bin/env python3
"""
Validate Ubuntu autoinstall.yml configuration
"""

import yaml
import sys

def validate_autoinstall(file_path):
    """Validate autoinstall.yml structure and requirements"""
    
    # Check for cloud-config header
    with open(file_path, 'r') as f:
        first_line = f.readline().strip()
        if first_line != '#cloud-config':
            print("✗ Missing #cloud-config header")
            return False
        f.seek(0)
        config = yaml.safe_load(f)
    
    all_ok = True
    validation_results = {}
    
    # Check for required top-level structure
    if 'autoinstall' not in config:
        print("✗ Missing 'autoinstall' top-level key")
        return False
    
    autoinstall = config['autoinstall']
    
    # Check version
    if 'version' not in autoinstall:
        print("✗ Missing 'version' field")
        all_ok = False
    elif autoinstall['version'] == 1:
        print("✓ Version 1 configured")
    
    # Check source configuration
    if 'source' in autoinstall:
        if autoinstall['source'].get('id') == 'ubuntu-server':
            print("✓ Ubuntu Server source configured")
        else:
            print("✗ Invalid source configuration")
            all_ok = False
    else:
        print("✗ No source configuration")
        all_ok = False
    
    # Check interactive sections
    if 'interactive-sections' in autoinstall:
        if 'identity' in autoinstall['interactive-sections']:
            print("✓ Interactive identity section configured")
            validation_results['interactive_identity'] = True
        else:
            print("✗ Identity not in interactive sections")
            all_ok = False
            validation_results['interactive_identity'] = False
    else:
        print("✗ No interactive sections configured")
        all_ok = False
        validation_results['interactive_identity'] = False
    
    # Check storage configuration
    if 'storage' in autoinstall:
        storage = autoinstall['storage']
        if 'config' in storage:
            # Check for LUKS encryption
            has_luks = any(item.get('type') == 'dm_crypt' for item in storage['config'])
            if has_luks:
                print("✓ LUKS encryption configured")
                validation_results['has_luks'] = True
                
                # Check for temporary password
                luks_config = next((item for item in storage['config'] if item.get('type') == 'dm_crypt'), None)
                if luks_config and luks_config.get('passphrase') == 'TemporaryUbuntu2024!TPM2WillReplace@InitialBoot#Secure':
                    print("✓ Complex temporary password configured")
                else:
                    print("✗ Temporary password missing or incorrect")
                    all_ok = False
            else:
                print("✗ No LUKS encryption found")
                all_ok = False
                validation_results['has_luks'] = False
            
            # Check for LVM
            has_lvm = any(item.get('type') == 'lvm_volgroup' for item in storage['config'])
            if has_lvm:
                print("✓ LVM configured")
            else:
                print("✗ No LVM configuration found")
                all_ok = False
                
            # Check partition sizes
            root_found = False
            swap_found = False
            for item in storage['config']:
                if item.get('type') == 'lvm_partition':
                    if item.get('name') == 'root' and item.get('size') == '90%':
                        print("✓ Root partition uses 90% of VG")
                        root_found = True
                    if item.get('name') == 'swap' and item.get('size') == '10%':
                        print("✓ Swap partition uses 10% of VG")
                        swap_found = True
            
            if not root_found:
                print("✗ Root partition not configured as 90%")
                all_ok = False
            if not swap_found:
                print("✗ Swap partition not configured as 10%")
                all_ok = False
            
            validation_results['root_90'] = root_found
            validation_results['swap_10'] = swap_found
    
    # Check identity configuration
    if 'identity' in autoinstall:
        # Empty identity is OK with interactive sections
        print("✓ Identity section present (interactive)")
    else:
        print("✗ No identity section")
        all_ok = False
    
    # Check for TPM2 packages
    if 'packages' in autoinstall:
        tpm_packages = ['tpm2-tools', 'systemd-cryptenroll']
        has_tpm = any(pkg in autoinstall['packages'] for pkg in tpm_packages)
        if has_tpm:
            print("✓ TPM2 packages included")
            validation_results['has_tpm'] = True
        else:
            print("✗ TPM2 packages missing")
            all_ok = False
            validation_results['has_tpm'] = False
    
    # Check for Nix installation
    if 'user-data' in autoinstall:
        user_data = autoinstall['user-data']
        if 'write_files' in user_data:
            has_nix_script = any(
                f.get('path') == '/usr/local/bin/setup-nix-multiuser' 
                for f in user_data['write_files']
            )
            if has_nix_script:
                print("✓ Nix installation script included")
                validation_results['has_nix'] = True
            else:
                print("✗ Nix installation script missing")
                all_ok = False
                validation_results['has_nix'] = False
    
    # Check for TPM2 enrollment script
    if 'user-data' in autoinstall:
        user_data = autoinstall['user-data']
        if 'write_files' in user_data:
            has_tpm_script = any(
                f.get('path') == '/usr/local/bin/enroll-tpm2-luks' 
                for f in user_data['write_files']
            )
            if has_tpm_script:
                print("✓ TPM2 enrollment script included")
            else:
                print("✗ TPM2 enrollment script missing")
                all_ok = False
    
    # Check late commands for recovery key
    if 'late-commands' in autoinstall:
        commands_str = ' '.join(autoinstall['late-commands'])
        if 'luks-recovery-key-' in commands_str and 'cryptsetup luksAddKey' in commands_str:
            print("✓ Recovery key generation configured")
            validation_results['recovery_key'] = True
        else:
            print("✗ No recovery key generation found")
            all_ok = False
            validation_results['recovery_key'] = False
            
        # Check for swap size recommendation logic
        if 'DISK_SIZE_GB' in commands_str and 'RECOMMENDED_SWAP' in commands_str:
            print("✓ Dynamic swap size recommendation configured")
            validation_results['swap_recommendation'] = True
        else:
            print("ℹ No swap size recommendation (optional)")
            validation_results['swap_recommendation'] = False
    
    # Check for improved features in scripts
    if 'user-data' in autoinstall:
        user_data = autoinstall['user-data']
        if 'write_files' in user_data:
            # Check TPM2 script for compatibility checks
            tpm_script = next((f for f in user_data['write_files'] 
                             if f.get('path') == '/usr/local/bin/enroll-tpm2-luks'), None)
            if tpm_script and 'tpm2_getcap' in tpm_script.get('content', ''):
                print("✓ TPM2 compatibility check included")
                validation_results['tpm2_compat'] = True
            else:
                print("ℹ TPM2 compatibility check not found")
                validation_results['tpm2_compat'] = False
                
            # Check Nix script for retry mechanism
            nix_script = next((f for f in user_data['write_files'] 
                             if f.get('path') == '/usr/local/bin/setup-nix-multiuser'), None)
            if nix_script and 'MAX_RETRIES' in nix_script.get('content', ''):
                print("✓ Network retry mechanism included")
                validation_results['network_retry'] = True
            else:
                print("ℹ Network retry mechanism not found")
                validation_results['network_retry'] = False
                
            # Check for first-boot service
            service_file = next((f for f in user_data['write_files'] 
                               if f.get('path') == '/etc/systemd/system/first-boot-setup.service'), None)
            if service_file:
                print("✓ First-boot setup service configured")
                validation_results['first_boot_service'] = True
            else:
                print("✗ First-boot setup service missing")
                all_ok = False
                validation_results['first_boot_service'] = False
    
    return all_ok, validation_results

if __name__ == '__main__':
    file_path = sys.argv[1] if len(sys.argv) > 1 else 'autoinstall.yml'
    
    print(f"Validating {file_path}...")
    print("=" * 50)
    
    try:
        all_ok, validation_results = validate_autoinstall(file_path)
        
        if all_ok:
            print("\n✅ All requirements met!")
        else:
            print("\n❌ Validation failed - check issues above")
        
        print("\n" + "=" * 50)
        print("Requirements summary:")
        print(f"- LVM disk encryption: {'✓' if validation_results.get('has_luks', False) else '✗'}")
        print(f"- Nix installation: {'✓' if validation_results.get('has_nix', False) else '✗'}")
        print(f"- 90% main partition: {'✓' if validation_results.get('root_90', False) else '✗'}")
        print(f"- 10% swap partition: {'✓' if validation_results.get('swap_10', False) else '✗'}")
        print(f"- TPM support: {'✓' if validation_results.get('has_tpm', False) else '✗'}")
        print(f"- Recovery key generation: {'✓' if validation_results.get('recovery_key', False) else '✗'}")
        print("\nEnhanced features:")
        print(f"- TPM2 compatibility check: {'✓' if validation_results.get('tpm2_compat', False) else 'ℹ (optional)'}")
        print(f"- Network retry mechanism: {'✓' if validation_results.get('network_retry', False) else 'ℹ (optional)'}")
        print(f"- Swap size recommendation: {'✓' if validation_results.get('swap_recommendation', False) else 'ℹ (optional)'}")
        print(f"- First-boot service: {'✓' if validation_results.get('first_boot_service', False) else '✗'}")
        
        sys.exit(0 if all_ok else 1)
        
    except Exception as e:
        print(f"\n❌ Validation failed: {e}")
        sys.exit(1)