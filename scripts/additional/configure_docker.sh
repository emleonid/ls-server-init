#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Color codes for console output
RED='\033[0;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Functions for colored output
function print_info {
    echo -e "${GREEN}$1${NC}"
}

function print_warning {
    echo -e "${YELLOW}$1${NC}"
}

function print_error {
    echo -e "${RED}$1${NC}"
}

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
    print_error "Please run this script as root."
    exit 1
fi

print_info "======================================="
print_info "  Starting Docker Configure Script"
print_info "======================================="


# Configure Docker log rotation and builder
print_info "Configuring Docker logging..."

mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<EOF
{
  "data-root": "/var/lib/docker",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  },
  "builder": {
    "gc": {
      "enabled": true,
      "defaultKeepStorage": "5GB"
    }
  }
}
EOF

print_info "Docker logging configured."

# Prompt the user to restart docker
echo -e "${YELLOW}Do you want to restart docker to apply all changes? (y/n): ${NC}"
read -p "Restart now? (y/n): " restart_choice

if [[ "$restart_choice" =~ ^[Yy]$ ]]; then
    systemctl restart docker
    echo -e "${GREEN}Restarting...${NC}"
else
    echo -e "${YELLOW}Restart skipped. Please remember restart to apply all changes.${NC}"
fi

print_info "======================================="
print_info "  Docker Installation Script Complete"
print_info "======================================="
