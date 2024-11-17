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
print_info "  Starting Nginx Installation Script"
print_info "======================================="

# Step 1: Install Nginx
print_info "Installing Nginx..."

# Install prerequisites
apt update
sudo apt install nginx -y

# Enable Nginx to start on boot
systemctl enable nginx

print_info "Nginx installed successfully."

# Step 2: Configure nginx.conf according to best practices
print_info "Configuring Nginx..."

# Backup existing nginx.conf
if [ -f /etc/nginx/nginx.conf ]; then
    mv /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup
    print_info "Existing nginx.conf backed up to nginx.conf.backup"
fi

# Create /etc/nginx/proxy.conf
print_info "Creating /etc/nginx/proxy.conf with recommended settings..."
cat <<'EOF' > /etc/nginx/proxy.conf
proxy_redirect          off;
proxy_set_header        Host $host;
proxy_set_header        X-Real-IP $remote_addr;
proxy_set_header        X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header        X-Forwarded-Proto $scheme;
client_max_body_size    100m;
client_body_buffer_size 128k;
proxy_connect_timeout   90;
proxy_send_timeout      90;
proxy_read_timeout      90;
proxy_buffers           32 4k;
EOF

# Create a new nginx.conf with best practices and include proxy.conf
print_info "Creating new nginx.conf with best practices..."
cat <<'EOF' > /etc/nginx/nginx.conf
user  www-data;
worker_processes  auto;
worker_rlimit_nofile 65535;
pid /run/nginx.pid;

events {
    worker_connections  8192;
    multi_accept on;
    use epoll;
}

http {

    ##
    # Basic Settings
    ##

    include       /etc/nginx/mime.types;
    include        /etc/nginx/proxy.conf;
    default_type  application/octet-stream;

    sendfile on;
    keepalive_timeout   29;
    client_body_timeout 10;
    client_header_timeout 10;
    send_timeout 10;
    server_tokens  off;

    ##
    # Logging Settings
    ##

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;
    error_log   /var/log/nginx/error.log warn;

    ##
    # Gzip Settings
    ##

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;

    # Include server blocks
    include /etc/nginx/conf.d/*.conf;
}
EOF

print_info "Nginx configuration file created."

# Remove the default Nginx welcome page
print_info "Removing default Nginx welcome page..."
if [ -f /usr/share/nginx/html/index.html ]; then
    rm /usr/share/nginx/html/index.html
    print_info "Default index.html removed."
fi

# Remove default server block if exists
if [ -f /etc/nginx/conf.d/default.conf ]; then
    rm /etc/nginx/conf.d/default.conf
    print_info "Default server block configuration removed."
fi

# Step 3: Instructions for adding server block manually
print_info "Nginx is configured with the recommended settings."

print_info "You can add your server block configurations in /etc/nginx/conf.d/ or directly within nginx.conf under the http context."

print_info "======================================="
print_info "  Nginx Installation Script Complete"
print_info "======================================="
