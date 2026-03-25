import sys
import yaml
from string import Template

def parse_shell_config(input_path):
    """Parses a shell-like config file and returns a dictionary."""
    config = {}
    
    with open(input_path, 'r') as f:
        for line in f:
            line = line.strip()
            # Skip comments and empty lines
            if not line or line.startswith('#'):
                continue
            
            if '=' in line:
                key, value = line.split('=', 1)
                key = key.strip()
                value = value.strip()
                
                # Check if value is wrapped in quotes and strip them
                if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
                    value = value[1:-1]
                
                # Perform variable expansion
                expanded_value = Template(value).safe_substitute(config)
                
                config[key] = expanded_value
    return config

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python shell2yaml.py <input.conf> <output.yaml>")
        sys.exit(1)
        
    config = parse_shell_config(sys.argv[1])
    
    with open(sys.argv[2], 'w') as f:
        yaml.dump(config, f, sort_keys=False, default_flow_style=False)