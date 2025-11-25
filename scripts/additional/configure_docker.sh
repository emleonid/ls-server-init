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

# ---------------------------------------------
# 1. Configure Docker Daemon (Logging & GC)
# ---------------------------------------------
print_info "Configuring Docker Daemon settings..."

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

print_info "Docker Daemon configured."

# ---------------------------------------------
# 2. Install Secure Credential Helper
# ---------------------------------------------
print_info "Installing Secure Credential dependencies..."

# Install standard tools and jq (for safe JSON editing)
apt-get update -qq && apt-get install -y gnupg2 pass wget jq

# Define version and new URL pattern (Raw binary, NOT tar.gz)
CRED_HELPER_VERSION="v0.9.4"
# URL for raw binary
CRED_HELPER_URL="https://github.com/docker/docker-credential-helpers/releases/download/${CRED_HELPER_VERSION}/docker-credential-pass-${CRED_HELPER_VERSION}.linux-amd64"
BIN_PATH="/usr/local/bin/docker-credential-pass"

# Check if binary already exists
if [ -f "$BIN_PATH" ]; then
    print_info "Credential helper binary already exists at $BIN_PATH"
else
    print_info "Downloading docker-credential-pass ($CRED_HELPER_VERSION)..."
    wget -qO /tmp/docker-cred.tar.gz "$CRED_HELPER_URL"
    
    print_info "Extracting and installing..."
    tar -xf /tmp/docker-cred.tar.gz -C /tmp/
    mv /tmp/docker-credential-pass /usr/local/bin/
    chmod +x /usr/local/bin/docker-credential-pass
    rm /tmp/docker-cred.tar.gz
    print_info "Credential helper installed."
fi

# ---------------------------------------------
# 3. Update Root's Docker Config
# ---------------------------------------------
print_info "Updating Docker client config for Root..."

DOCKER_CONFIG_DIR="/root/.docker"
DOCKER_CONFIG_FILE="$DOCKER_CONFIG_DIR/config.json"

mkdir -p "$DOCKER_CONFIG_DIR"

if [ ! -f "$DOCKER_CONFIG_FILE" ]; then
    # Create new file if it doesn't exist
    echo '{ "credsStore": "pass" }' > "$DOCKER_CONFIG_FILE"
else
    # Use jq to insert/update the key without deleting existing data
    tmp=$(mktemp)
    jq '. + {"credsStore": "pass"}' "$DOCKER_CONFIG_FILE" > "$tmp" && mv "$tmp" "$DOCKER_CONFIG_FILE"
fi

print_info "Docker client configured to use 'pass' store."

# ---------------------------------------------
# 4. Restart Prompt
# ---------------------------------------------
echo -e "${YELLOW}Do you want to restart docker to apply daemon changes? (y/n): ${NC}"
read -p "Restart now? (y/n): " restart_choice

if [[ "$restart_choice" =~ ^[Yy]$ ]]; then
    systemctl restart docker
    echo -e "${GREEN}Restarting...${NC}"
else
    echo -e "${YELLOW}Restart skipped. Please remember restart to apply all changes.${NC}"
fi

print_info "======================================="
print_info "  Configuration Complete"
print_info "======================================="
print_warning "IMPORTANT FINAL STEP:"
print_warning "Since this is a fresh install, you must manually initialize the pass store."
print_warning "Run the following commands manually:"
print_warning "  1. gpg --generate-key"
print_warning "  2. pass init <your_new_key_id>"
print_warning "Then log in: docker login"