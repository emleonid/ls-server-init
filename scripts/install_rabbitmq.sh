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
SSL_CERT="${CERT_DIR}/cert.pem"
SSL_KEY="${CERT_DIR}/key.pem"
SSL_DAYS_VALID=365
RENEWAL_DAYS_BEFORE_EXPIRY=30
CRON_JOB="/etc/cron.daily/renew_rabbitmq_cert"

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

# Function to generate self-signed certificate
generate_certificates() {
    print_info "Generating new self-signed certificates..."
    openssl req -newkey rsa:2048 -nodes -keyout "$SSL_KEY" -x509 -days "$SSL_DAYS_VALID" -out "$SSL_CERT" -subj "/CN=$(hostname)"
    chown -R rabbitmq:rabbitmq "$CERT_DIR"
    chmod 600 "$SSL_KEY"
    chmod 644 "$SSL_CERT"
}

# Generate certificates
generate_certificates

print_info "Configuring RabbitMQ for SSL/TLS..."

# Backup existing config if exists
if [ -f /etc/rabbitmq/rabbitmq.conf ]; then
    mv /etc/rabbitmq/rabbitmq.conf /etc/rabbitmq/rabbitmq.conf.bak
fi

# Create RabbitMQ configuration
cat > /etc/rabbitmq/rabbitmq.conf <<EOF
listeners.tcp = none

listeners.ssl.default = 5671
ssl_options.cacertfile = $SSL_CERT
ssl_options.certfile = $SSL_CERT
ssl_options.keyfile = $SSL_KEY
ssl_options.verify = verify_peer
ssl_options.fail_if_no_peer_cert = false
ssl_options.versions.1 = tlsv1.2
ssl_options.versions.2 = tlsv1.3

management.ssl.port       = 15671
management.ssl.cacertfile = $SSL_CERT
management.ssl.certfile   = $SSL_CERT
management.ssl.keyfile    = $SSL_KEY
management.ssl.versions.1 = tlsv1.2
management.ssl.versions.2 = tlsv1.3
EOF

print_info "Restarting RabbitMQ server..."
systemctl restart rabbitmq-server

print_info "Setting up cron job for certificate renewal..."

# Create renewal script
cat > "$CRON_JOB" <<EOF
#!/bin/bash
CERT_FILE="$SSL_CERT"
KEY_FILE="$SSL_KEY"
DAYS_BEFORE_EXPIRY=$RENEWAL_DAYS_BEFORE_EXPIRY

if openssl x509 -checkend \$(( 86400 * DAYS_BEFORE_EXPIRY )) -noout -in "\$CERT_FILE"; then
    # Certificate is valid for more than DAYS_BEFORE_EXPIRY days
    exit 0
else
    # Certificate expires in less than DAYS_BEFORE_EXPIRY days, renew it
    openssl req -newkey rsa:2048 -nodes -keyout "\$KEY_FILE" -x509 -days $SSL_DAYS_VALID -out "\$CERT_FILE" -subj "/CN=$(hostname)"
    chown rabbitmq:rabbitmq "\$KEY_FILE" "\$CERT_FILE"
    chmod 600 "\$KEY_FILE"
    chmod 644 "\$CERT_FILE"
    systemctl restart rabbitmq-server
fi
EOF

chmod +x "$CRON_JOB"

print_info "Configuring UFW firewall..."

# Allow port 5671 (AMQP over SSL/TLS)
ufw allow 5671/tcp

# Allow port 15671 (RabbitMQ Management UI over SSL/TLS)
ufw allow 15671/tcp

# Optional: Limit access to management UI by IP
# ufw allow from x.x.x.x to any port 15671 proto tcp
# ufw deny 15671/tcp

# Enable the firewall (if not already enabled)
ufw --force enable

print_info "RabbitMQ installation and configuration completed."

print_info "======================================="
print_info "RabbitMQ User: $RABBITMQ_USER"
print_info "RabbitMQ Password: $RABBITMQ_PASSWORD"
print_info "---------------------------------------"
print_info "Access RabbitMQ Management UI at: https://$(hostname -I | awk '{print $1}'):15671"
print_info "======================================="

print_warning "Note: Since we're using self-signed certificates, your browser will show a warning. You can proceed by accepting the self-signed certificate."
