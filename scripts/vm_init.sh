#!/bin/bash


# Color codes for console output
RED='\033[0;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color

set -e  # Exit immediately if a command exits with a non-zero status

package_installed() {
    dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null | grep -q '^ii'
}

uses_persistent_iptables() {
    package_installed iptables-persistent || package_installed netfilter-persistent
}

backup_persistent_firewall_rules() {
    if [ -f /etc/iptables/rules.v4 ] && [ ! -f /etc/iptables/rules.v4.ls-server-init.bak ]; then
        cp --preserve=all /etc/iptables/rules.v4 /etc/iptables/rules.v4.ls-server-init.bak
    fi

    if [ -f /etc/iptables/rules.v6 ] && [ ! -f /etc/iptables/rules.v6.ls-server-init.bak ]; then
        cp --preserve=all /etc/iptables/rules.v6 /etc/iptables/rules.v6.ls-server-init.bak
    fi
}

allow_persistent_tcp_port() {
    local port="$1"

    if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; then
        iptables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT
    fi

    if command -v ip6tables >/dev/null 2>&1 && [ -f /proc/net/if_inet6 ]; then
        if ! ip6tables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; then
            ip6tables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT
        fi
    fi
}

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run this script as root (use sudo).${NC}"
    exit 1
fi

# Detect this before package cleanup so provider-managed persistent firewall
# packages are retained throughout the upgrade.
FIREWALL_BACKEND="ufw"
if uses_persistent_iptables; then
    FIREWALL_BACKEND="iptables-persistent"
    for firewall_package in iptables-persistent netfilter-persistent; do
        if package_installed "$firewall_package"; then
            apt-mark manual "$firewall_package" >/dev/null
        fi
    done
fi

echo -e "${BLUE}=======================================${NC}"
echo -e "${GREEN}     Starting Basic Server Setup...     ${NC}"
echo -e "${BLUE}=======================================${NC}"

# Ask for desired SSH port
read -p "$(echo -e "${YELLOW}Enter the desired SSH port (default is 22): ${NC}")" SSH_PORT
if [ -z "$SSH_PORT" ]; then
    SSH_PORT=22
fi

# Ask whether to disable root login via SSH
read -p "$(echo -e "${YELLOW}Do you want to disable root login via SSH? (y/n): ${NC}")" disable_root_ssh
if [[ "$disable_root_ssh" =~ ^[Yy]$ ]]; then
    DISABLE_ROOT_SSH=true
else
    DISABLE_ROOT_SSH=false
fi

# Ask if unattended-upgrades should be enabled
echo -e "${YELLOW}Would you like to enable unattended-upgrades for automatic security updates? ${NC}"
echo -e "${GREEN}If enabled, security updates will be installed automatically, which can improve security.${NC}"
echo -e "${GREEN}However, reboots may be needed after some updates, which could affect stability if not carefully scheduled.${NC}"
read -p "$(echo -e "${YELLOW}Enable unattended-upgrades? (y/n): ${NC}")" enable_unattended
ENABLE_UNATTENDED_UPGRADES=false
if [[ "$enable_unattended" =~ ^[Yy]$ ]]; then
    ENABLE_UNATTENDED_UPGRADES=true
fi

# Check if swap exists
echo -e "${GREEN}Checking for existing swap space...${NC}"
if swapon --show | grep -q '/'; then
    echo -e "${YELLOW}Swap space is already enabled on this system:${NC}"
    swapon --show
else
    echo -e "${YELLOW}No swap space detected.${NC}"
    
    # Ask the user if they want to add swap
    read -p "$(echo -e "${YELLOW}Would you like to add swap space? (y/n): ${NC}")" add_swap
    if [[ "$add_swap" =~ ^[Yy]$ ]]; then
        # Ask the user how much swap space they want to add
        read -p "$(echo -e "${YELLOW}Enter the swap size in GB (e.g., 2 for 2GB): ${NC}")" swap_size
        if [[ "$swap_size" =~ ^[0-9]+$ ]]; then
            # Convert GB to MB
            swap_size_mb=$((swap_size * 1024))

            # Create swap file
            echo -e "${GREEN}Creating ${swap_size}GB swap file...${NC}"
            fallocate -l "${swap_size_mb}M" /swapfile
            chmod 600 /swapfile
            mkswap /swapfile
            swapon /swapfile

            # Make swap file permanent
            echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab > /dev/null

            echo -e "${GREEN}${swap_size}GB swap space has been added and enabled.${NC}"
        else
            echo -e "${RED}Invalid input for swap size. Please enter a number in GB.${NC}"
        fi
    else
        echo -e "${YELLOW}Swap space not added.${NC}"
    fi
fi

# Update and upgrade packages
echo -e "${GREEN}Updating package list and upgrading existing packages...${NC}"

sudo apt update

if sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"; then
    echo "Upgrade completed successfully."
else
    echo "Upgrade failed." >&2
    exit 1
fi

# Check if a reboot is required
if [ -f /var/run/reboot-required ]; then
    echo -e "${YELLOW}A system reboot is required to complete the updates.${NC}"
    read -p "$(echo -e "${YELLOW}Do you want to reboot now? You should run this script again after restart. (y/n): ${NC}")" reboot_choice
    if [[ "$reboot_choice" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}Rebooting the system...${NC}"
        reboot
        exit 0
    else
        echo -e "${YELLOW}Please remember to reboot the system later to apply all updates.${NC}"
    fi
fi

# Clean up unnecessary packages
echo -e "${GREEN}Clean up unnecessary packages...${NC}"
sudo apt autoremove -y
sudo apt autoclean -y

# Keep the firewall manager already selected by the image. Oracle Cloud Ubuntu
# images use persistent iptables rules that must not be replaced by UFW.
if [ "$FIREWALL_BACKEND" = "iptables-persistent" ]; then
    echo -e "${YELLOW}Persistent iptables rules detected. Keeping them and skipping UFW installation.${NC}"
    echo -e "${YELLOW}This preserves provider rules used by platforms such as Oracle Cloud.${NC}"
    backup_persistent_firewall_rules
else
    echo -e "${GREEN}Installing UFW firewall...${NC}"
    apt install ufw -y
fi

# Configure SSH to use the specified port
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
echo -e "${GREEN}Configuring SSH to use port ${SSH_PORT}...${NC}"
if ! grep -q "^Port $SSH_PORT" /etc/ssh/sshd_config; then
    echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
fi

# Allow both the old and new SSH ports through the host firewall
echo -e "${GREEN}Allowing SSH through the firewall on port ${SSH_PORT}...${NC}"
if [ "$FIREWALL_BACKEND" = "iptables-persistent" ]; then
    allow_persistent_tcp_port 22
    allow_persistent_tcp_port "$SSH_PORT"
    netfilter-persistent save
    echo -e "${GREEN}SSH rules saved with netfilter-persistent.${NC}"
    echo -e "${YELLOW}Also allow TCP port ${SSH_PORT} in your cloud security list or network security group.${NC}"
else
    ufw allow "${SSH_PORT}/tcp"

    echo -e "${GREEN}Enabling the firewall...${NC}"
    ufw --force enable
fi

# Conditionally install and configure unattended-upgrades
if [ "$ENABLE_UNATTENDED_UPGRADES" = true ]; then
    echo -e "${GREEN}Installing and configuring unattended-upgrades...${NC}"

    # Pre-answer the configuration prompt
    echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' | sudo debconf-set-selections

    # Install unattended-upgrades without prompts
    sudo DEBIAN_FRONTEND=noninteractive apt install -y unattended-upgrades
    dpkg-reconfigure -plow unattended-upgrades
else
    echo -e "${YELLOW}Unattended-upgrades not enabled. Remember to apply updates manually to keep your system secure.${NC}"
fi

# Install common tools
echo -e "${GREEN}Installing essential tools (curl, wget, git)...${NC}"
apt install curl wget git tree rsync htop -y

# Ask to add new user
read -p "$(echo -e "${YELLOW}Do you want to add a new sudo user? (y/n): ${NC}")" adduser_choice
if [[ "$adduser_choice" =~ ^[Yy]$ ]]; then
    read -p "$(echo -e "${YELLOW}Enter the new username: ${NC}")" new_username
    adduser "$new_username"
    usermod -aG sudo "$new_username"
    echo -e "${GREEN}User $new_username added and granted sudo privileges.${NC}"
fi

# Disable root login via SSH if chosen
if [ "$DISABLE_ROOT_SSH" = true ]; then
    echo -e "${GREEN}Disabling root login via SSH...${NC}"
    sed -i 's/^#*PermitRootLogin\s.*/PermitRootLogin no/' /etc/ssh/sshd_config
    systemctl reload sshd
else
    echo -e "${YELLOW}Root login via SSH remains enabled.${NC}"
fi

# Prompt the user to reboot
echo -e "${YELLOW}Do you want to reboot the system now to apply all changes? (y/n): ${NC}"
read -p "Reboot now? (y/n): " reboot_choice

if [[ "$reboot_choice" =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}Rebooting the system...${NC}"
    reboot
else
    echo -e "${YELLOW}Reboot skipped. Please remember to reboot the system later to apply all changes.${NC}"
fi

echo -e "${BLUE}=======================================${NC}"
echo -e "${GREEN}     Basic Server Setup Completed      ${NC}"
echo -e "${BLUE}=======================================${NC}"
