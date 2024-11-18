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

# Function to migrate a certificate
function migrate_certificate {
    local domain="$1"
    local renewal_conf="/etc/letsencrypt/renewal/${domain}.conf"

    if [ ! -f "$renewal_conf" ]; then
        print_error "Renewal configuration file for domain '$domain' not found."
        return 1
    fi

    print_info "Migrating certificate for domain '$domain'..."

    # Backup the renewal configuration file
    cp "$renewal_conf" "${renewal_conf}.backup"

    # Change authenticator from standalone to nginx
    sed -i 's/^authenticator = standalone/authenticator = nginx/' "$renewal_conf"

    # Comment out standalone_supported_challenges
    sed -i 's/^standalone_supported_challenges =/#&/' "$renewal_conf"

    print_info "Certificate for domain '$domain' migrated successfully."
    print_info "A backup of the original renewal configuration is at '${renewal_conf}.backup'."

    # Test renewal
    print_info "Testing renewal for domain '$domain'..."
    if certbot renew --dry-run --cert-name "$domain"; then
        print_info "Dry run successful for domain '$domain'."
    else
        print_warning "Dry run failed for domain '$domain'. Please check the configuration."
    fi
}

# Function to delete a certificate
function delete_certificate {
    local domain="$1"

    print_warning "You are about to delete the certificate for domain '$domain'."
    read -p "$(echo -e "${YELLOW}Are you sure you want to proceed? (Y/n): ${NC}")" confirm_delete
    confirm_delete=${confirm_delete:-Y}

    if [[ "$confirm_delete" =~ ^[Yy]$ ]]; then
        print_info "Deleting certificate for domain '$domain'..."
        certbot delete --cert-name "$domain"
        print_info "Certificate for domain '$domain' deleted."
    else
        print_info "Deletion of certificate for domain '$domain' canceled."
    fi
}

# Main script logic

print_info "======================================="
print_info "  Certbot Certificate Migration Script"
print_info "======================================="

# Check if Certbot is installed
if ! command -v certbot >/dev/null 2>&1; then
    print_error "Certbot is not installed. Please install Certbot before running this script."
    exit 1
fi

# Find all renewal configuration files
renewal_dir="/etc/letsencrypt/renewal"
if [ ! -d "$renewal_dir" ]; then
    print_error "Renewal directory '$renewal_dir' does not exist."
    exit 1
fi

shopt -s nullglob
renewal_files=("$renewal_dir"/*.conf)
shopt -u nullglob

if [ ${#renewal_files[@]} -eq 0 ]; then
    print_info "No certificates found to process."
    exit 0
fi

# Process each certificate
for renewal_conf in "${renewal_files[@]}"; do
    domain=$(basename "$renewal_conf" .conf)
    print_info "---------------------------------------"
    print_info "Processing certificate for domain: $domain"

    # Ask the user whether to migrate or delete
    while true; do
        read -p "$(echo -e "${YELLOW}Do you want to (M)igrate or (D)elete the certificate for '$domain'? (M/D): ${NC}")" action
        action=${action^^}  # Convert to uppercase
        if [[ "$action" == "M" ]]; then
            migrate_certificate "$domain"
            break
        elif [[ "$action" == "D" ]]; then
            delete_certificate "$domain"
            break
        else
            print_error "Invalid input. Please enter 'M' to migrate or 'D' to delete."
        fi
    done
done

print_info "======================================="
print_info "       Script Execution Complete       "
print_info "======================================="
