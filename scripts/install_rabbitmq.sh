#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Color codes for console output
RED='\033[0;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color

# Variables
RABBITMQ_USER="rabbit"
RABBITMQ_PASSWORD=$(openssl rand -base64 32)
CERT_DIR="/etc/rabbitmq/ssl"
CA_KEY="$CERT_DIR/ca.key.pem"
CA_CERT="$CERT_DIR/ca.cert.pem"
SERVER_KEY="$CERT_DIR/server.key.pem"
SERVER_CSR="$CERT_DIR/server.csr.pem"
SERVER_CERT="$CERT_DIR/server.cert.pem"
SERVER_EXT="$CERT_DIR/server_cert_ext.cnf"
SSL_DAYS_VALID=365    # Validity of server certificate (in days)
CA_DAYS_VALID=36500   # Validity of CA certificate (in days)
RENEWAL_DAYS_BEFORE_EXPIRY=30
CRON_JOB="/etc/cron.daily/renew_rabbitmq_server_cert"
FIREWALL_ENABLED=false

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

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
    print_error "Please run this script as root."
    exit 1
fi

print_info "======================================="
print_info "  Starting RabbitMQ Installation Script"
print_info "======================================="

print_info "Updating system packages..."
sudo apt update

if sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"; then
    echo "Upgrade completed successfully."
else
    echo "Upgrade failed." >&2
    exit 1
fi

print_info "Installing required dependencies..."
apt-get install -y curl gnupg apt-transport-https lsb-release

print_info "Adding RabbitMQ and Erlang repository signing keys..."

# Team RabbitMQ's main signing key
curl -1sLf "https://keys.openpgp.org/vks/v1/by-fingerprint/0A9AF2115F4687BD29803A206B73A36E6026DFCA" | gpg --dearmor | sudo tee /usr/share/keyrings/com.rabbitmq.team.gpg > /dev/null

# Community mirror of Cloudsmith: modern Erlang repository
curl -1sLf "https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-erlang.E495BB49CC4BBE5B.key" | gpg --dearmor | sudo tee /usr/share/keyrings/rabbitmq.E495BB49CC4BBE5B.gpg > /dev/null

# Community mirror of Cloudsmith: RabbitMQ repository
curl -1sLf "https://github.com/rabbitmq/signing-keys/releases/download/3.0/cloudsmith.rabbitmq-server.9F4587F226208342.key" | gpg --dearmor | sudo tee /usr/share/keyrings/rabbitmq.9F4587F226208342.gpg > /dev/null

print_info "Adding RabbitMQ and Erlang repositories..."

# Use the correct Ubuntu codename
UBUNTU_CODENAME=$(lsb_release -cs)

sudo tee /etc/apt/sources.list.d/rabbitmq.list > /dev/null <<EOF
## Provides modern Erlang/OTP releases
##
deb [arch=amd64 signed-by=/usr/share/keyrings/rabbitmq.E495BB49CC4BBE5B.gpg] https://ppa1.rabbitmq.com/rabbitmq/rabbitmq-erlang/deb/ubuntu ${UBUNTU_CODENAME} main
deb-src [signed-by=/usr/share/keyrings/rabbitmq.E495BB49CC4BBE5B.gpg] https://ppa1.rabbitmq.com/rabbitmq/rabbitmq-erlang/deb/ubuntu ${UBUNTU_CODENAME} main

# Another mirror for redundancy
deb [arch=amd64 signed-by=/usr/share/keyrings/rabbitmq.E495BB49CC4BBE5B.gpg] https://ppa2.rabbitmq.com/rabbitmq/rabbitmq-erlang/deb/ubuntu ${UBUNTU_CODENAME} main
deb-src [signed-by=/usr/share/keyrings/rabbitmq.E495BB49CC4BBE5B.gpg] https://ppa2.rabbitmq.com/rabbitmq/rabbitmq-erlang/deb/ubuntu ${UBUNTU_CODENAME} main

## Provides RabbitMQ
##
deb [arch=amd64 signed-by=/usr/share/keyrings/rabbitmq.9F4587F226208342.gpg] https://ppa1.rabbitmq.com/rabbitmq/rabbitmq-server/deb/ubuntu ${UBUNTU_CODENAME} main
deb-src [signed-by=/usr/share/keyrings/rabbitmq.9F4587F226208342.gpg] https://ppa1.rabbitmq.com/rabbitmq/rabbitmq-server/deb/ubuntu ${UBUNTU_CODENAME} main

# Another mirror for redundancy
deb [arch=amd64 signed-by=/usr/share/keyrings/rabbitmq.9F4587F226208342.gpg] https://ppa2.rabbitmq.com/rabbitmq/rabbitmq-server/deb/ubuntu ${UBUNTU_CODENAME} main
deb-src [signed-by=/usr/share/keyrings/rabbitmq.9F4587F226208342.gpg] https://ppa2.rabbitmq.com/rabbitmq/rabbitmq-server/deb/ubuntu ${UBUNTU_CODENAME} main
EOF

print_info "Updating package lists..."
apt-get update -y

print_info "Installing Erlang packages..."
apt-get install -y erlang-base \
                        erlang-asn1 erlang-crypto erlang-eldap erlang-ftp erlang-inets \
                        erlang-mnesia erlang-os-mon erlang-parsetools erlang-public-key \
                        erlang-runtime-tools erlang-snmp erlang-ssl \
                        erlang-syntax-tools erlang-tftp erlang-tools erlang-xmerl

print_info "Installing RabbitMQ server..."
apt-get install rabbitmq-server -y --fix-missing

print_info "Adjusting system limits for RabbitMQ..."

# Increase fs.file-max if necessary
FS_FILE_MAX=$(sysctl -n fs.file-max)
if [ "$FS_FILE_MAX" -lt 100000 ]; then
    print_info "Increasing fs.file-max to 100000..."
    echo "fs.file-max = 100000" >> /etc/sysctl.conf
    sysctl -p
else
    print_info "fs.file-max is sufficient ($FS_FILE_MAX)"
fi

# Set per-user limits for rabbitmq user
print_info "Configuring per-user limits for rabbitmq user..."

LIMITS_CONF_FILE="/etc/security/limits.d/rabbitmq.conf"
echo "rabbitmq soft nofile 65536" > $LIMITS_CONF_FILE
echo "rabbitmq hard nofile 65536" >> $LIMITS_CONF_FILE

# Configure systemd service override for LimitNOFILE
print_info "Configuring systemd service limits for RabbitMQ..."

SYSTEMD_SERVICE_DIR="/etc/systemd/system/rabbitmq-server.service.d"
mkdir -p $SYSTEMD_SERVICE_DIR

cat > $SYSTEMD_SERVICE_DIR/limits.conf <<EOF
[Service]
LimitNOFILE=65536
EOF

# Reload systemd daemon
systemctl daemon-reload

print_info "Enabling RabbitMQ management plugin..."
rabbitmq-plugins enable rabbitmq_management

print_info "Generating secure password for RabbitMQ user..."

print_info "Creating RabbitMQ user and setting permissions..."
rabbitmqctl add_user $RABBITMQ_USER "$RABBITMQ_PASSWORD"
rabbitmqctl set_user_tags $RABBITMQ_USER administrator
rabbitmqctl set_permissions -p / $RABBITMQ_USER ".*" ".*" ".*"

print_info "Deleting default guest user if it exists..."
rabbitmqctl delete_user guest || print_warning "Guest user does not exist or has already been deleted."

print_info "Setting up SSL/TLS certificates..."

if [ ! -d "$CERT_DIR" ]; then
    mkdir -p "$CERT_DIR"
fi

# Generate CA key and certificate if they don't exist
if [ ! -f "$CA_KEY" ] || [ ! -f "$CA_CERT" ]; then
    print_info "Generating private CA key and certificate..."
    openssl genrsa -out "$CA_KEY" 4096
    openssl req -x509 -new -nodes -key "$CA_KEY" -sha256 -days "$CA_DAYS_VALID" -out "$CA_CERT" -subj "/CN=$(hostname)"
    chmod 600 "$CA_KEY"
    chown rabbitmq:rabbitmq "$CA_KEY" "$CA_CERT"
else
    print_info "Using existing CA key and certificate."
fi

# Function to generate server certificate
generate_server_certificate() {
    print_info "Generating server key and certificate signing request (CSR)..."
    openssl genrsa -out "$SERVER_KEY" 2048
    openssl req -new -key "$SERVER_KEY" -out "$SERVER_CSR" -subj "/CN=$(hostname)"

    # Create extensions config file for server certificate
    cat > "$SERVER_EXT" <<EOF
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = $(hostname)
EOF

    # Sign server certificate with CA
    print_info "Signing server certificate with private CA..."
    openssl x509 -req -in "$SERVER_CSR" \
      -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
      -out "$SERVER_CERT" -days "$SSL_DAYS_VALID" -sha256 -extfile "$SERVER_EXT"

    # Secure server key and certificate
    chmod 600 "$SERVER_KEY"
    chmod 644 "$SERVER_CERT"
    chown rabbitmq:rabbitmq "$SERVER_KEY" "$SERVER_CERT"
}

# Generate server certificate
generate_server_certificate

print_info "Configuring RabbitMQ for SSL/TLS..."

# Backup existing config if exists
if [ -f /etc/rabbitmq/rabbitmq.conf ]; then
    mv /etc/rabbitmq/rabbitmq.conf /etc/rabbitmq/rabbitmq.conf.bak
fi

# Create RabbitMQ configuration
cat > /etc/rabbitmq/rabbitmq.conf <<EOF
listeners.tcp = none

listeners.ssl.default = 5671
ssl_options.cacertfile = $CA_CERT
ssl_options.certfile = $SERVER_CERT
ssl_options.keyfile = $SERVER_KEY
ssl_options.verify = verify_peer
ssl_options.fail_if_no_peer_cert = false
ssl_options.versions.1 = tlsv1.2
ssl_options.versions.2 = tlsv1.3

management.ssl.port       = 15671
management.ssl.cacertfile = $CA_CERT
management.ssl.certfile   = $SERVER_CERT
management.ssl.keyfile    = $SERVER_KEY
management.ssl.versions.1 = tlsv1.2
management.ssl.versions.2 = tlsv1.3
EOF

print_info "Restarting RabbitMQ server..."
systemctl restart rabbitmq-server

print_info "Setting up cron job for certificate renewal..."

# Create renewal script
cat > "$CRON_JOB" <<EOF
#!/bin/bash
CERT_DIR="$CERT_DIR"
CA_KEY="$CA_KEY"
CA_CERT="$CA_CERT"
SERVER_KEY="$SERVER_KEY"
SERVER_CSR="$SERVER_CSR"
SERVER_CERT="$SERVER_CERT"
SERVER_EXT="$SERVER_EXT"
SSL_DAYS_VALID=$SSL_DAYS_VALID
RENEWAL_DAYS_BEFORE_EXPIRY=$RENEWAL_DAYS_BEFORE_EXPIRY
LOG_FILE="/var/log/rabbitmq_cert_renewal.log"

# Ensure the log file exists
touch "\$LOG_FILE"
chmod 644 "\$LOG_FILE"

# Check if the server certificate expires within RENEWAL_DAYS_BEFORE_EXPIRY days
if ! openssl x509 -checkend \$(( 86400 * \$RENEWAL_DAYS_BEFORE_EXPIRY )) -noout -in "\$SERVER_CERT"; then
    # Certificate expires soon, renew it
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - Certificate expires in less than \$RENEWAL_DAYS_BEFORE_EXPIRY days. Renewing..." >> "\$LOG_FILE"

    # Generate new server key and CSR
    openssl genrsa -out "\$SERVER_KEY" 2048
    openssl req -new -key "\$SERVER_KEY" -out "\$SERVER_CSR" -subj "/CN=\$(hostname)"

    # Create extensions config file
    cat > "\$SERVER_EXT" <<EOC
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = \$(hostname)
EOC

    # Sign server certificate with CA
    openssl x509 -req -in "\$SERVER_CSR" \
      -CA "\$CA_CERT" -CAkey "\$CA_KEY" -CAcreateserial \
      -out "\$SERVER_CERT" -days "\$SSL_DAYS_VALID" -sha256 -extfile "\$SERVER_EXT"

    # Secure server key and certificate
    chmod 600 "\$SERVER_KEY"
    chmod 644 "\$SERVER_CERT"
    chown rabbitmq:rabbitmq "\$SERVER_KEY" "\$SERVER_CERT"

    # Reload RabbitMQ TLS certificates using ssl:clear_pem_cache()
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - Reloading RabbitMQ TLS certificates..." >> "\$LOG_FILE"
    if rabbitmqctl eval 'ssl:clear_pem_cache().' > /dev/null 2>&1; then
        echo "\$(date '+%Y-%m-%d %H:%M:%S') - RabbitMQ TLS certificates reloaded successfully." >> "\$LOG_FILE"
    else
        echo "\$(date '+%Y-%m-%d %H:%M:%S') - Failed to reload RabbitMQ TLS certificates." >> "\$LOG_FILE"
    fi
else
    # Certificate is still valid
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - Certificate is valid for more than \$RENEWAL_DAYS_BEFORE_EXPIRY days. No action needed." >> "\$LOG_FILE"
fi
EOF

chmod +x "$CRON_JOB"

# Firewall configuration
print_info "Configuring firewall rules..."

# Check if UFW is active
if ufw status | grep -q "Status: inactive"; then
    print_info "UFW (Uncomplicated Firewall) is inactive. Enabling UFW..."
    ufw --force enable
    FIREWALL_ENABLED=true
else
    FIREWALL_ENABLED=true
fi

print_info "Allowing ports 5671 and 15671 through the firewall..."

# Ask the user if they want to limit access to specific IPs
read -p "$(echo -e "${YELLOW}Do you want to limit access to RabbitMQ ports to specific IP addresses? (y/n): ${NC}")" limit_access_choice
if [[ "$limit_access_choice" =~ ^[Yy]$ ]]; then
    read -p "$(echo -e "${YELLOW}Enter the IP addresses separated by commas (e.g., 192.168.1.10,203.0.113.5): ${NC}")" ip_addresses
    IFS=',' read -ra ADDR <<< "$ip_addresses"
    for ip in "${ADDR[@]}"; do
        ip=$(echo "$ip" | xargs) # Trim whitespace
        print_info "Allowing access from $ip..."
        ufw allow from "$ip" to any port 5671 proto tcp
        ufw allow from "$ip" to any port 15671 proto tcp
    done
else
    print_info "Allowing access from any IP address..."
    ufw allow 5671/tcp
    ufw allow 15671/tcp
fi

print_info "Firewall configuration completed."

print_info "RabbitMQ installation and configuration completed."

print_info "======================================="
print_info "RabbitMQ User: $RABBITMQ_USER"
print_info "RabbitMQ Password: $RABBITMQ_PASSWORD"
print_info "---------------------------------------"
print_info "Access RabbitMQ Management UI at: https://$(hostname -I | awk '{print $1}'):15671"
print_info "---------------------------------------"
print_info "CA Certificate is located at: $CA_CERT"
print_info "Please distribute the CA certificate to clients to establish trust."
print_info "======================================="
print_warning "Note: Since we're using self-signed certificates, your browser will show a warning. You can proceed by accepting the self-signed certificate."
