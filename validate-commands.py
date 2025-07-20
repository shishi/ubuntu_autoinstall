#!/usr/bin/env python3
"""
Validate shell commands in autoinstall configuration
Detects syntax errors before installation
"""

import yaml
import sys
import re
import subprocess
import shlex

class CommandValidator:
    def __init__(self):
        self.errors = []
        self.warnings = []
        
        # Known command signatures
        self.command_signatures = {
            'systemd-cryptenroll': {
                'valid_options': ['--tpm2-device', '--tpm2-pcrs', '--recovery-key', '--wipe-slot'],
                'invalid_options': ['--key-file'],
                'stdin_password': True,
                'usage': 'echo "password" | systemd-cryptenroll --tpm2-device=auto /dev/device'
            },
            'cryptsetup': {
                'subcommands': {
                    'luksAddKey': {
                        'valid_options': ['--key-file', '--key-slot', '--force-password', '--iter-time'],
                        'usage': 'echo "password" | cryptsetup luksAddKey /dev/device /path/to/newkey'
                    },
                    'luksDump': {
                        'valid_options': [],
                        'usage': 'cryptsetup luksDump /dev/device'
                    }
                }
            },
            'apt-get': {
                'subcommands': {
                    'install': {
                        'valid_options': ['-y', '--yes', '-q', '--quiet'],
                        'requires_package': True
                    },
                    'update': {
                        'valid_options': ['-y', '--yes', '-q', '--quiet']
                    }
                }
            }
        }
    
    def validate_systemd_cryptenroll(self, cmd_parts):
        """Validate systemd-cryptenroll commands"""
        sig = self.command_signatures['systemd-cryptenroll']
        
        # Check for invalid options
        for part in cmd_parts:
            if part.startswith('--key-file'):
                self.errors.append(f"systemd-cryptenroll does not support --key-file option. Use stdin: {sig['usage']}")
                
        # Special case: --tpm2-device=list doesn't need a device path
        if any('--tpm2-device=list' in part for part in cmd_parts):
            return
            
        # Check if device is specified for enrollment commands
        has_device = any(part.startswith('/dev/') or part.startswith('$') for part in cmd_parts)
        if not has_device:
            self.errors.append("systemd-cryptenroll requires a device path (/dev/...) for enrollment")
            
        # Check for TPM2 options
        has_tpm = any('--tpm2-device' in part for part in cmd_parts)
        if not has_tpm and has_device:
            self.warnings.append("systemd-cryptenroll used without --tpm2-device option")
    
    def validate_cryptsetup(self, cmd_parts):
        """Validate cryptsetup commands"""
        if len(cmd_parts) < 2:
            self.errors.append("cryptsetup requires a subcommand")
            return
            
        subcommand = cmd_parts[1]
        
        if subcommand == 'luksAddKey':
            # Check argument order: device, then new keyfile
            device_idx = None
            keyfile_idx = None
            
            for i, part in enumerate(cmd_parts[2:], 2):
                if part.startswith('/dev/'):
                    device_idx = i
                elif part.startswith('/') and not part.startswith('--'):
                    keyfile_idx = i
                    
            if device_idx and keyfile_idx and device_idx > keyfile_idx:
                self.errors.append("cryptsetup luksAddKey: device must come before keyfile")
                
            # Check for --key-file=- which is invalid
            if any('--key-file=-' in part for part in cmd_parts):
                self.errors.append("cryptsetup luksAddKey: use stdin directly, not --key-file=-")
    
    def validate_shell_syntax(self, command):
        """Basic shell syntax validation"""
        # Skip multiline YAML blocks
        if command.strip() == '|':
            return True
            
        try:
            # Try to parse with shlex
            shlex.split(command)
        except ValueError as e:
            self.errors.append(f"Shell syntax error in command: {e}")
            return False
            
        # Check for common shell mistakes
        if '&&' in command and not command.strip().endswith('\\'):
            # Check if && is at the end without continuation
            parts = command.split('&&')
            if parts[-1].strip() == '':
                self.errors.append("Command ends with && but no following command")
                
        return len(self.errors) == 0
    
    def extract_commands_from_yaml(self, yaml_content):
        """Extract commands from autoinstall YAML"""
        commands = []
        
        try:
            data = yaml.safe_load(yaml_content)
            if not data or 'autoinstall' not in data:
                return commands
                
            autoinstall = data['autoinstall']
            
            # Extract from late-commands
            if 'late-commands' in autoinstall:
                for cmd in autoinstall['late-commands']:
                    if isinstance(cmd, str):
                        # Handle multiline commands
                        if cmd.strip().startswith('|'):
                            # YAML multiline
                            commands.append(('late-command', cmd))
                        else:
                            commands.append(('late-command', cmd))
                            
            # Extract from user-data runcmd
            if 'user-data' in autoinstall and 'runcmd' in autoinstall['user-data']:
                for cmd in autoinstall['user-data']['runcmd']:
                    if isinstance(cmd, str):
                        commands.append(('runcmd', cmd))
                        
        except Exception as e:
            self.errors.append(f"Failed to parse YAML: {e}")
            
        return commands
    
    def validate_command(self, cmd_type, command):
        """Validate a single command"""
        # Skip comments
        if command.strip().startswith('#'):
            return
            
        # Debug mode
        if '--debug' in sys.argv:
            print(f"[DEBUG] Validating {cmd_type}: {command[:80]}...")
            
        # Extract the actual command from curtin wrapper
        actual_cmd = command
        if 'curtin in-target --' in command:
            parts = command.split('curtin in-target --', 1)
            if len(parts) > 1:
                actual_cmd = parts[1].strip()
                
        # Handle bash -c commands
        if 'bash -c' in actual_cmd:
            # Extract the command inside bash -c
            match = re.search(r'bash -c [\'"](.+)[\'"]', actual_cmd, re.DOTALL)
            if match:
                bash_cmd = match.group(1)
                # Validate the inner command
                self.validate_shell_syntax(bash_cmd)
                # Parse inner commands
                for line in bash_cmd.split('\n'):
                    line = line.strip()
                    if line and not line.startswith('#'):
                        self.validate_specific_command(line)
            return
            
        self.validate_specific_command(actual_cmd)
    
    def validate_specific_command(self, command):
        """Validate specific command types"""
        try:
            parts = shlex.split(command)
            if not parts:
                return
                
            cmd = parts[0]
            
            # Check known commands
            if cmd == 'systemd-cryptenroll':
                self.validate_systemd_cryptenroll(parts)
            elif cmd == 'cryptsetup':
                self.validate_cryptsetup(parts)
            elif cmd == 'apt-get' and len(parts) > 2 and parts[1] == 'install':
                # Skip validation of package names in apt-get install
                return
            elif cmd == 'echo' and '|' in command:
                # Check pipe commands
                pipe_parts = command.split('|')
                if len(pipe_parts) > 1:
                    next_cmd = pipe_parts[1].strip()
                    self.validate_specific_command(next_cmd)
                    
        except Exception as e:
            # Ignore parsing errors here, they're caught in shell_syntax
            pass

def validate_autoinstall_commands(file_path):
    """Main validation function"""
    validator = CommandValidator()
    
    print(f"Validating commands in {file_path}...")
    print("=" * 60)
    
    try:
        with open(file_path, 'r') as f:
            content = f.read()
            
        # Check for #cloud-config header
        if not content.startswith('#cloud-config'):
            validator.errors.append("Missing #cloud-config header")
            
        commands = validator.extract_commands_from_yaml(content)
        
        print(f"Found {len(commands)} commands to validate\n")
        
        for cmd_type, command in commands:
            validator.validate_command(cmd_type, command)
            
    except Exception as e:
        validator.errors.append(f"Failed to read file: {e}")
    
    # Report results
    if validator.errors:
        print("❌ ERRORS FOUND:")
        for error in validator.errors:
            print(f"   • {error}")
            
    if validator.warnings:
        print("\n⚠️  WARNINGS:")
        for warning in validator.warnings:
            print(f"   • {warning}")
            
    if not validator.errors and not validator.warnings:
        print("✅ All commands validated successfully")
        
    return len(validator.errors) == 0

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: python3 validate-commands.py <autoinstall.yml>")
        sys.exit(1)
        
    file_path = sys.argv[1]
    
    if validate_autoinstall_commands(file_path):
        sys.exit(0)
    else:
        sys.exit(1)