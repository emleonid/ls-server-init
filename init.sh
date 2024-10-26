#!/bin/bash

# Color codes for console output
RED='\033[0;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run this script as root (use sudo).${NC}"
    exit 1
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

# Update and upgrade packages
echo -e "${GREEN}Updating package list and upgrading existing packages...${NC}"
apt update && apt upgrade -y

# Check if a reboot is required
if [ -f /var/run/reboot-required ]; then
    echo -e "${YELLOW}A system reboot is required to complete the updates.${NC}"
    read -p "$(echo -e "${YELLOW}Do you want to reboot now? (y/n): ${NC}")" reboot_choice
    if [[ "$reboot_choice" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}Rebooting the system...${NC}"
        reboot
        exit 0
    else
        echo -e "${YELLOW}Please remember to reboot the system later to apply all updates.${NC}"
    fi
fi

# Install UFW firewall
echo -e "${GREEN}Installing UFW firewall...${NC}"
apt install ufw -y

# Configure SSH to use the specified port
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
echo -e "${GREEN}Configuring SSH to use port ${SSH_PORT}...${NC}"
if ! grep -q "^Port $SSH_PORT" /etc/ssh/sshd_config; then
    echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
fi
systemctl reload sshd

# Allow both the old and new SSH ports through the firewall
echo -e "${GREEN}Allowing SSH through the firewall on port ${SSH_PORT}...${NC}"
ufw allow "${SSH_PORT}/tcp"
echo -e "${GREEN}Also allowing SSH on the default port 22 temporarily...${NC}"
ufw allow 22/tcp

# Enable the firewall
echo -e "${GREEN}Enabling the firewall...${NC}"
ufw --force enable

# Install Fail2Ban
echo -e "${GREEN}Installing Fail2Ban to protect SSH...${NC}"
apt install fail2ban -y

# Copy default Fail2Ban configuration
echo -e "${GREEN}Configuring Fail2Ban...${NC}"
cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local

# Configure Fail2Ban settings
echo -e "${GREEN}Setting Fail2Ban parameters...${NC}"
sed -i 's/^bantime  = .*/bantime  = 1h/' /etc/fail2ban/jail.local
sed -i 's/^maxretry = .*/maxretry = 8/' /etc/fail2ban/jail.local
sed -i 's/^destemail = .*/#destemail = root@localhost/' /etc/fail2ban/jail.local
sed -i 's/^action = .*/action = %(action_)s/' /etc/fail2ban/jail.local

# Enable only the sshd jail
sed -i 's/^\[sshd\]/[sshd]/' /etc/fail2ban/jail.local
sed -i '/\[sshd\]/,/^$/ { s/^enabled = .*/enabled = true/; s/^port\s*= .*/port = '"$SSH_PORT"'/ }'

# Disable all other jails
sed -i '/^\[.*\]/ { h; }; /^\[sshd\]/! { x; s/^enabled = .*/enabled = false/; x; }' /etc/fail2ban/jail.local

# Restart Fail2Ban service
systemctl restart fail2ban

# Install unattended-upgrades
echo -e "${GREEN}Installing unattended-upgrades for automatic security updates...${NC}"
apt install unattended-upgrades -y
echo -e "${GREEN}Configuring unattended-upgrades...${NC}"
dpkg-reconfigure -plow unattended-upgrades

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

# Prompt to test new SSH port before closing old port
echo -e "${YELLOW}Please open a new SSH session using the new port ${SSH_PORT} to verify the connection before proceeding.${NC}"
read -p "$(echo -e "${YELLOW}Have you successfully connected using the new SSH port? (y/n): ${NC}")" ssh_test_choice
if [[ "$ssh_test_choice" =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}Removing SSH access on the default port 22...${NC}"
    sed -i '/^Port 22/d' /etc/ssh/sshd_config
    systemctl reload sshd
    ufw delete allow 22/tcp
    echo -e "${GREEN}SSH access on port 22 has been removed.${NC}"
else
    echo -e "${RED}Please ensure you can connect via the new SSH port before disabling the default port.${NC}"
    echo -e "${YELLOW}You can manually disable port 22 later once you've confirmed access.${NC}"
fi

echo -e "${BLUE}=======================================${NC}"
echo -e "${GREEN}     Basic Server Setup Completed      ${NC}"
echo -e "${BLUE}=======================================${NC}"
