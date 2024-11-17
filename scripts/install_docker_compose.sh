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
print_info "  Starting Docker Installation Script"
print_info "======================================="

# Step 1: Install Docker Engine
print_info "Installing Docker Engine..."

# Add Docker's official GPG key:
sudo apt update
sudo apt install ca-certificates curl -y
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update

# Install Docker Engine
sudo apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y

# Enable and start Docker service
systemctl enable docker
systemctl start docker

print_info "Docker installed and started successfully."

# Step 2: Configure Docker log rotation and builder
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

systemctl restart docker
print_info "Docker logging configured."

# Step 3: Ask for project folder and alias
read -p "$(echo -e "${YELLOW}Enter project folder name: ${NC}")" project_folder
read -p "$(echo -e "${YELLOW}Enter project alias: ${NC}")" project_alias

# Create project directory structure
project_path="/${project_folder}/${project_alias}"
mkdir -p "${project_path}/containers"
mkdir -p "${project_path}/www"
mkdir -p "${project_path}/storage"

print_info "Project structure created at ${project_path}."

# Step 4: Generate .env file and Docker Compose templates
env_file="${project_path}/.env"
compose_file="${project_path}/docker-compose.yml"

print_info "Generating .env file..."
touch "$env_file"

# Step 5: Ask user for a list of node names
print_info "Please enter the list of Docker Compose node names."

node_names=()
while true; do
    read -p "$(echo -e "${YELLOW}Enter node name (or type 'done' to finish): ${NC}")" node_name
    if [[ "$node_name" == "done" ]]; then
        break
    elif [[ -z "$node_name" ]]; then
        print_warning "Node name cannot be empty."
    else
        node_names+=("$node_name")
    fi
done

if [ ${#node_names[@]} -eq 0 ]; then
    print_error "No node names provided. Exiting."
    exit 1
fi

print_info "Generating Docker Compose file..."
touch "$compose_file"
echo "services:" >> "$compose_file"

for node in "${node_names[@]}"; do
    # Create storage folder with same name as node
    storage_folder="${project_path}/storage/${node}"
    mkdir -p "${storage_folder}"

    # Add node to docker-compose.yml
    cat >> "$compose_file" <<EOL
  ${node}:
    container_name: ${node}
    image: your_image_here  # Replace with actual image
    volumes:
      - ./storage/${node}:/app/data  # Adjust volume path as needed
    restart: unless-stopped
EOL
    print_info "Added node '${node}' to docker-compose.yml and created storage folder."
done

print_info "Docker Compose setup completed successfully."
print_info "Your .env file is located at ${env_file}."
print_info "Your docker-compose.yml file is located at ${compose_file}."

print_info "======================================="
print_info "  Docker Installation Script Complete"
print_info "======================================="
