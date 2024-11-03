#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Color codes for output
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
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

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then
    print_error "Please run this script as root."
    exit 1
fi

print_info "==========================================="
print_info "  PostgreSQL 16 Installation Script"
print_info "==========================================="

# Prompt user for PostgreSQL port
read -p "$(echo -e "${YELLOW}Enter the PostgreSQL port you want to use (default is 5432): ${NC}")" PG_PORT
PG_PORT=${PG_PORT:-5432}

# Generate a secure password
PG_PASSWORD=$(openssl rand -base64 32)

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

# Install necessary dependencies
print_info "Installing necessary dependencies..."
apt install -y wget gnupg2 openssl rsync cron ca-certificates postgresql-common

# Add PostgreSQL APT repository
sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y

# Update package lists
print_info "Updating package lists..."
apt update -y

# Install PostgreSQL 16
print_info "Installing PostgreSQL 16..."
apt install -y postgresql-16 postgresql-client-16

# Ensure PostgreSQL service is running
systemctl enable postgresql
systemctl start postgresql

# Generate SSL certificates
print_info "Generating SSL certificates..."
SSL_DIR="/etc/postgresql/16/main/ssl"
mkdir -p "$SSL_DIR"
chown postgres:postgres "$SSL_DIR"
chmod 700 "$SSL_DIR"

# Variables for certificates
CA_KEY="$SSL_DIR/ca.key"
CA_CERT="$SSL_DIR/ca.crt"
SERVER_KEY="$SSL_DIR/server.key"
SERVER_CSR="$SSL_DIR/server.csr"
SERVER_CERT="$SSL_DIR/server.crt"
SSL_DAYS_VALID=365    # Validity of server certificate in days
CA_DAYS_VALID=36500   # Validity of CA certificate in days (100 years)
RENEWAL_DAYS_BEFORE_EXPIRY=30
CRON_JOB="/etc/cron.daily/renew_postgresql_server_cert"

# Generate CA key and certificate if they don't exist
if [ ! -f "$CA_KEY" ] || [ ! -f "$CA_CERT" ]; then
    print_info "Generating CA key and certificate..."
    sudo -u postgres openssl genrsa -out "$CA_KEY" 4096
    sudo -u postgres openssl req -x509 -new -nodes -key "$CA_KEY" -sha256 -days "$CA_DAYS_VALID" -out "$CA_CERT" -subj "/CN=$(hostname)"
    chmod 600 "$CA_KEY"
    chown postgres:postgres "$CA_KEY" "$CA_CERT"
else
    print_info "Using existing CA key and certificate."
fi

# Function to generate server certificate
generate_server_certificate() {
    print_info "Generating server key and certificate signing request (CSR)..."
    sudo -u postgres openssl genrsa -out "$SERVER_KEY" 2048
    sudo -u postgres openssl req -new -key "$SERVER_KEY" -out "$SERVER_CSR" -subj "/CN=$(hostname)"

    # Sign server certificate with CA
    print_info "Signing server certificate with private CA..."
    sudo -u postgres openssl x509 -req -in "$SERVER_CSR" -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial -out "$SERVER_CERT" -days "$SSL_DAYS_VALID" -sha256

    # Set permissions
    chmod 600 "$SERVER_KEY" "$SERVER_CERT"
    chown postgres:postgres "$SERVER_KEY" "$SERVER_CERT"
}

# Generate server certificate
generate_server_certificate

# Configure PostgreSQL to use SSL
print_info "Configuring PostgreSQL to use SSL..."

# Backup original postgresql.conf
PG_CONF="/etc/postgresql/16/main/postgresql.conf"
cp "$PG_CONF" "${PG_CONF}.bak"

# Update postgresql.conf
sed -i "s/^#port = 5432/port = $PG_PORT/" "$PG_CONF"
sed -i "s/^#ssl = off/ssl = on/" "$PG_CONF"
sed -i "s/^#listen_addresses = 'localhost'/listen_addresses = '*'/" "$PG_CONF"  # Allow connections from all IPs
echo "ssl_ca_file = '$CA_CERT'" >> "$PG_CONF"
echo "ssl_cert_file = '$SERVER_CERT'" >> "$PG_CONF"
echo "ssl_key_file = '$SERVER_KEY'" >> "$PG_CONF"

# Enforce SSL connections in pg_hba.conf
print_info "Configuring pg_hba.conf to enforce SSL connections..."

PG_HBA="/etc/postgresql/16/main/pg_hba.conf"
cp "$PG_HBA" "${PG_HBA}.bak"

# Remove existing entries
cat /dev/null > "$PG_HBA"

# Restrict postgres user to localhost only
print_info "Restricting 'postgres' superuser to localhost connections only..."

# Add entries to pg_hba.conf
echo "# IPv4 remote connections with client certificate verification" >> "$PG_HBA"
echo "hostssl all all 0.0.0.0/0 md5" >> "$PG_HBA"

echo "# IPv6 remote connections with client certificate verification" >> "$PG_HBA"
echo "hostssl all all ::0/0 md5" >> "$PG_HBA"

echo "# Local connections for postgres user" >> "$PG_HBA"
echo "local   all postgres    peer" >> "$PG_HBA"

# Set a secure password for the default PostgreSQL 'postgres' user
print_info "Setting password for PostgreSQL 'postgres' user..."
sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD '$PG_PASSWORD';"

# Adjust PostgreSQL configurations for optimal performance
print_info "Adjusting PostgreSQL configurations for optimal performance..."

# Get total system memory in kB
TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))
TOTAL_MEM_GB=$(awk "BEGIN {print $TOTAL_MEM_MB/1024}")

# Calculate shared_buffers as 25% of total memory, with limits
SHARED_BUFFERS_MB=$((TOTAL_MEM_MB / 4))
# Minimum 128MB, Maximum 8192MB (8GB)
if [ $SHARED_BUFFERS_MB -lt 128 ]; then
    SHARED_BUFFERS_MB=128
elif [ $SHARED_BUFFERS_MB -gt 8192 ]; then
    SHARED_BUFFERS_MB=8192
fi

# Calculate effective_cache_size as 75% of total memory
EFFECTIVE_CACHE_SIZE_MB=$(( (TOTAL_MEM_MB * 3) / 4 ))
# Maximum 24576MB (24GB)
if [ $EFFECTIVE_CACHE_SIZE_MB -gt 24576 ]; then
    EFFECTIVE_CACHE_SIZE_MB=24576
fi

# Calculate maintenance_work_mem as 5% of total memory
MAINTENANCE_WORK_MEM_MB=$((TOTAL_MEM_MB / 20))
# Minimum 64MB, Maximum 2048MB (2GB)
if [ $MAINTENANCE_WORK_MEM_MB -lt 64 ]; then
    MAINTENANCE_WORK_MEM_MB=64
elif [ $MAINTENANCE_WORK_MEM_MB -gt 2048 ]; then
    MAINTENANCE_WORK_MEM_MB=2048
fi

# Calculate work_mem
# (Total Memory - shared_buffers) / (max_connections * 3)
# Estimate max_connections based on system memory
if [ $TOTAL_MEM_MB -le 1024 ]; then
    MAX_CONNECTIONS=50
elif [ $TOTAL_MEM_MB -le 4096 ]; then
    MAX_CONNECTIONS=100
else
    MAX_CONNECTIONS=200
fi

# Ensure max_connections is at least 20
if [ $MAX_CONNECTIONS -lt 20 ]; then
    MAX_CONNECTIONS=20
fi

# Minimum 64kB, Maximum 16MB
if [ "$TOTAL_MEM_MB" -le 1024 ]; then MAX_CONNECTIONS=50; elif [ "$TOTAL_MEM_MB" -le 4096 ]; then MAX_CONNECTIONS=100; else MAX_CONNECTIONS=200; fi
WORK_MEM_KB=$(( (TOTAL_MEM_MB - SHARED_BUFFERS_MB) * 1024 / (MAX_CONNECTIONS * 3) ))
if [ "$WORK_MEM_KB" -lt 64 ]; then WORK_MEM_KB=64; fi
if [ "$WORK_MEM_KB" -gt 16384 ]; then WORK_MEM_KB=16384; fi

# Calculate effective_io_concurrency
if [ -f /sys/block/$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]//g')/queue/rotational ]; then
    ROTATIONAL=$(cat /sys/block/$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]//g')/queue/rotational)
    if [ "$ROTATIONAL" -eq 1 ]; then
        # HDD
        EFFECTIVE_IO_CONCURRENCY=2
    else
        # SSD
        EFFECTIVE_IO_CONCURRENCY=200
    fi
else
    # Default
    EFFECTIVE_IO_CONCURRENCY=2
fi

# Calculate max_worker_processes and max_parallel_workers
CPU_CORES=$(nproc)
MAX_WORKER_PROCESSES=$CPU_CORES
MAX_PARALLEL_WORKERS=$CPU_CORES
MAX_PARALLEL_WORKERS_PER_GATHER=$((CPU_CORES / 2))
if [ $MAX_PARALLEL_WORKERS_PER_GATHER -lt 1 ]; then
    MAX_PARALLEL_WORKERS_PER_GATHER=1
fi

# Set wal_buffers to a fraction of shared_buffers, max 16MB
if [ $SHARED_BUFFERS_MB -lt 4096 ]; then
    WAL_BUFFERS_MB=$((SHARED_BUFFERS_MB / 8))
else
    WAL_BUFFERS_MB=16
fi

# Set checkpoint_completion_target
CHECKPOINT_COMPLETION_TARGET=0.9

# Update postgresql.conf with performance settings
cat >> "$PG_CONF" <<EOL

# Performance tuning parameters
max_connections = $MAX_CONNECTIONS
shared_buffers = ${SHARED_BUFFERS_MB}MB
effective_cache_size = ${EFFECTIVE_CACHE_SIZE_MB}MB
maintenance_work_mem = ${MAINTENANCE_WORK_MEM_MB}MB
work_mem = ${WORK_MEM_KB}kB
wal_buffers = ${WAL_BUFFERS_MB}MB
checkpoint_completion_target = $CHECKPOINT_COMPLETION_TARGET
effective_io_concurrency = $EFFECTIVE_IO_CONCURRENCY
max_worker_processes = $MAX_WORKER_PROCESSES
max_parallel_workers = $MAX_PARALLEL_WORKERS
max_parallel_workers_per_gather = $MAX_PARALLEL_WORKERS_PER_GATHER
default_statistics_target = 100
random_page_cost = 1.1
min_wal_size = 1GB
max_wal_size = 4GB

EOL

# Restart PostgreSQL to apply changes
print_info "Restarting PostgreSQL to apply changes..."
systemctl restart postgresql

# Set up automatic backups
print_info "Setting up automatic backups..."

BACKUP_DIR="/var/backups/postgresql"

# Ensure backup directory exists
if [ ! -d "$BACKUP_DIR" ]; then
    mkdir -p "$BACKUP_DIR"
    chown postgres:postgres "$BACKUP_DIR"
fi

# Create backup script
BACKUP_SCRIPT="/usr/local/bin/pg_backup.sh"
cat <<EOF > "$BACKUP_SCRIPT"
#!/bin/bash
DATE=\$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/postgres_\$DATE.sql.gz"
sudo -u postgres pg_dumpall | gzip > "\$BACKUP_FILE"

# Transfer backup via SFTP
SFTP_USER="your_sftp_username"
SFTP_HOST="your_sftp_server"
SFTP_REMOTE_DIR="remote_backup_directory"
SFTP_IDENTITY_FILE="/path/to/private/key"

scp -i \$SFTP_IDENTITY_FILE "\$BACKUP_FILE" \$SFTP_USER@\$SFTP_HOST:\$SFTP_REMOTE_DIR/

# Delete backups older than 14 days
find "$BACKUP_DIR" -type f -name "*.gz" -mtime +14 -exec rm {} \;
EOF

chmod +x "$BACKUP_SCRIPT"

# Set up cron job for backups
print_info "Configuring cron job for backups..."
(crontab -l 2>/dev/null; echo "0 5 * * * $BACKUP_SCRIPT") | crontab -

# Set up automatic server certificate renewal
print_info "Setting up automatic server certificate renewal..."

# Create renewal script
cat <<EOF > "$CRON_JOB"
#!/bin/bash
SSL_DIR="$SSL_DIR"
CA_KEY="$CA_KEY"
CA_CERT="$CA_CERT"
SERVER_KEY="$SERVER_KEY"
SERVER_CSR="$SERVER_CSR"
SERVER_CERT="$SERVER_CERT"
SSL_DAYS_VALID=$SSL_DAYS_VALID
RENEWAL_DAYS_BEFORE_EXPIRY=$RENEWAL_DAYS_BEFORE_EXPIRY
LOG_FILE="/var/log/postgresql_cert_renewal.log"

# Ensure the log file exists
touch "\$LOG_FILE"
chmod 644 "\$LOG_FILE"

# Check if the server certificate expires within RENEWAL_DAYS_BEFORE_EXPIRY days
if ! openssl x509 -checkend \$(( 86400 * \$RENEWAL_DAYS_BEFORE_EXPIRY )) -noout -in "\$SERVER_CERT"; then
    # Certificate expires soon, renew it
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - Certificate expires in less than \$RENEWAL_DAYS_BEFORE_EXPIRY days. Renewing..." >> "\$LOG_FILE"

    # Generate new server key and CSR
    sudo -u postgres openssl genrsa -out "\$SERVER_KEY" 2048
    sudo -u postgres openssl req -new -key "\$SERVER_KEY" -out "\$SERVER_CSR" -subj "/CN=\$(hostname)"

    # Sign server certificate with CA
    sudo -u postgres openssl x509 -req -in "\$SERVER_CSR" -CA "\$CA_CERT" -CAkey "\$CA_KEY" -CAcreateserial -out "\$SERVER_CERT" -days "\$SSL_DAYS_VALID" -sha256

    # Set permissions
    chmod 600 "\$SERVER_KEY" "\$SERVER_CERT"
    chown postgres:postgres "\$SERVER_KEY" "\$SERVER_CERT"

    # Restart PostgreSQL to apply new certificate
    systemctl restart postgresql
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - PostgreSQL restarted to apply new certificate." >> "\$LOG_FILE"
else
    echo "\$(date '+%Y-%m-%d %H:%M:%S') - Certificate is valid for more than \$RENEWAL_DAYS_BEFORE_EXPIRY days. No action needed." >> "\$LOG_FILE"
fi
EOF

chmod +x "$CRON_JOB"

print_info "Automatic renewal script created at $CRON_JOB"

# Ask user if they want to restrict access to specific IPs
print_info "Would you like to restrict access to PostgreSQL to specific IPs?"
read -p "$(echo -e "${YELLOW}Enter 'y' to specify IP addresses or 'n' to allow access from any IP: ${NC}")" IP_LIMIT_CHOICE

if [[ "$IP_LIMIT_CHOICE" =~ ^[Yy]$ ]]; then
    # Prompt for IP addresses, comma-separated
    read -p "$(echo -e "${YELLOW}Enter the IP addresses allowed to access PostgreSQL (comma-separated): ${NC}")" ALLOWED_IPS

    # Process and apply each IP to UFW rule
    IFS=',' read -ra IP_ARRAY <<< "$ALLOWED_IPS"
    for IP in "${IP_ARRAY[@]}"; do
        ufw allow from "$IP" to any port "$PG_PORT" proto tcp
        print_info "UFW has been configured to allow connections on port $PG_PORT from IP: $IP."
    done
else
    # Allow access from any IP if no restriction is specified
    ufw allow "$PG_PORT"/tcp
    print_info "UFW has been configured to allow connections on port $PG_PORT from any IP."
fi

# Enable UFW if not already enabled
ufw_status=$(ufw status | grep "Status: active" || true)
if [ -z "$ufw_status" ]; then
    print_info "UFW is not active. Enabling UFW..."
    ufw --force enable
fi

# Output final message with connection details
print_info "==========================================="
print_info "PostgreSQL installation and configuration complete!"
print_info "==========================================="
echo -e "${GREEN}PostgreSQL User:${NC} $PG_USER"
echo -e "${GREEN}PostgreSQL Password:${NC} $PG_PASSWORD"
echo -e "${GREEN}PostgreSQL Port:${NC} $PG_PORT"
echo -e "${GREEN}SSL CA Certificate:${NC} $CA_CERT"
echo -e "${GREEN}Connection String for .NET:${NC}"
echo "Host=$(hostname -I | awk '{print $1}'); Port=$PG_PORT; Username=$PG_USER; Password=$PG_PASSWORD; SslMode=Require; Trust Server Certificate=true; Root Certificate=$CA_CERT"
print_info "==========================================="
print_info "To connect from a client or .NET application:"
print_info "1. Use the CA certificate located at $CA_CERT."
print_info "2. Ensure SSL mode is set to 'Require' or 'Verify-CA'."
print_info "3. Provide the username and password above."
print_info "4. Use client certificates if required."
print_info "==========================================="

