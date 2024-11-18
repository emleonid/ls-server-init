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

# Function to check if a command exists
function command_exists {
    command -v "$1" >/dev/null 2>&1
}

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
    print_error "Please run this script as root."
    exit 1
fi

print_info "======================================="
print_info "  Starting Certbot Installation Script"
print_info "======================================="

# Remove any existing Certbot packages installed via apt
if apt list --installed 2>/dev/null | grep -q certbot; then
    print_info "Removing existing Certbot packages..."
    apt remove -y certbot
fi

# Step 1: Install Certbot using Snap if not already installed
if ! command_exists certbot; then
    print_info "Certbot is not installed. Installing Certbot via Snap..."

    # Ensure Snap is installed
    if ! command_exists snap; then
        print_info "Snap is not installed. Installing Snap..."
        apt update
        apt install -y snapd
    fi

    # Ensure Snap core is up to date
    print_info "Ensuring Snap core is up to date..."
    snap install core
    snap refresh core

    # Install Certbot
    snap install --classic certbot

    # Create a symbolic link for certbot command
    ln -sf /snap/bin/certbot /usr/bin/certbot

    print_info "Certbot installed successfully."
else
    print_info "Certbot is already installed. Skipping installation."
fi

# Step 2: Configure Certbot with TOS, email, and share email settings if not already configured

# Check if Certbot is already registered
if [ ! -f /etc/letsencrypt/accounts/acme-v02.api.letsencrypt.org/directory/*/meta.json ]; then
    print_info "Configuring Certbot..."

    # Ask the user for email address
    read -p "$(echo -e "${YELLOW}Enter your email address for important account notifications: ${NC}")" email_address

    # Validate email address (simple regex)
    if ! [[ "$email_address" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-z]{2,}$ ]]; then
        print_error "Invalid email address format."
        exit 1
    fi

    # Ask the user if they agree to the terms of service
    read -p "$(echo -e "${YELLOW}Do you agree to the Let's Encrypt Terms of Service? (Y/n): ${NC}")" agree_tos
    agree_tos=${agree_tos:-Y}

    if [[ "$agree_tos" =~ ^[Yy]$ ]]; then
        tos_arg="--agree-tos"
    else
        print_error "You must agree to the Terms of Service to use Certbot."
        exit 1
    fi

    # Ask the user if they want to share their email with EFF
    read -p "$(echo -e "${YELLOW}Would you like to share your email with the Electronic Frontier Foundation (EFF) to receive news and updates? (Y/n): ${NC}")" eff_subscribe
    eff_subscribe=${eff_subscribe:-Y}

    if [[ "$eff_subscribe" =~ ^[Yy]$ ]]; then
        eff_arg="--email $email_address"
    else
        eff_arg="--register-unsafely-without-email"
    fi

    # Register with Certbot
    print_info "Registering with Certbot..."
    certbot register $tos_arg $eff_arg

    print_info "Certbot configured successfully."
else
    print_info "Certbot is already configured. Skipping configuration."
fi

# Step 3: Configure Automatic Renewal with Nginx Reload

print_info "Configuring automatic renewal..."

# Create a renewal hook to reload Nginx after certificate renewal
renewal_hook_script="/etc/letsencrypt/renewal-hooks/post/nginx_reload.sh"

if [ ! -f "$renewal_hook_script" ]; then
    mkdir -p "$(dirname "$renewal_hook_script")"

    cat <<'EOF' > "$renewal_hook_script"
#!/bin/bash

# Script to reload Nginx after Certbot renews certificates

systemctl reload nginx
EOF

    chmod +x "$renewal_hook_script"

    print_info "Renewal hook created at $renewal_hook_script."
    actions_performed+="\n- Renewal hook added to reload Nginx after certificate renewal"
else
    print_info "Renewal hook already exists at $renewal_hook_script. Skipping creation."
fi


# Step 4: Ask the user if they want to generate certificate
read -p "$(echo -e "${YELLOW}Do you want to generate SSL certificate for your domain now? (Y/n): ${NC}")" generate_cert
generate_cert=${generate_cert:-Y}

if [[ "$generate_cert" =~ ^[Yy]$ ]]; then
    # Ask the user for domain names
    read -p "$(echo -e "${YELLOW}Enter the domain name for which you want to obtain SSL certificates (e.g., example.com www.example.com): ${NC}")" domain

    # Validate that domain are not empty
    if [[ -z "$domain" ]]; then
        print_error "No domain name provided."
        exit 1
    fi

    # Obtain SSL certificates
    print_info "Obtaining SSL certificate for the domain: $domain"

    certbot_output=$(certbot --nginx -d $domain --non-interactive 2>&1) || {
        print_error "Certbot failed to obtain certificates. Details:"
        echo "$certbot_output"
        exit 1
    }
else
    print_info "SSL certificate generation skipped. You can generate certificates later using Certbot."
fi

print_info "SSL certificates obtained and Nginx configuration updated."
actions_performed+="\n- SSL certificates obtained for domain(s): $domain"

print_info "Testing automatic renewal process..."

# Perform a dry run to test renewal
if certbot renew --dry-run >/dev/null 2>&1; then
    print_info "Automatic renewal test successful."
    actions_performed+="\n- Automatic renewal tested successfully"
else
    print_warning "Dry run for certificate renewal failed. Please check Certbot logs for details."
fi

print_info "======================================="
print_info "  Certbot Installation Script Complete"
print_info "======================================="

# Step 5: Show summary of actions performed

print_info "Summary of actions performed:"
if [ -z "$actions_performed" ]; then
    print_info "- Certbot installation and configuration checked; no new actions performed."
else
    echo -e "$actions_performed"
fi
