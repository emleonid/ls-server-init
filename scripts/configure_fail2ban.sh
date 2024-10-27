





# Install Fail2Ban
echo -e "${GREEN}Installing Fail2Ban to protect SSH...${NC}"
apt install fail2ban -y

# Configure Fail2Ban
echo -e "${GREEN}Configuring Fail2Ban...${NC}"
if [ -f /etc/fail2ban/jail.conf ]; then
    cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
fi

# Set Fail2Ban parameters specifically for SSH
echo -e "${GREEN}Setting Fail2Ban parameters for SSH protection only...${NC}"
if [ -f /etc/fail2ban/jail.local ]; then
    # Set ban time and max retry for the SSH jail
    sed -i 's/^bantime  = .*/bantime  = 1h/' /etc/fail2ban/jail.local
    sed -i 's/^maxretry = .*/maxretry = 8/' /etc/fail2ban/jail.local
    sed -i 's/^destemail = .*/#destemail = root@localhost/' /etc/fail2ban/jail.local
    sed -i 's/^action = .*/action = %(action_)s/' /etc/fail2ban/jail.local

    # Enable only the SSH jail and set the custom port
    sed -i '/^\[sshd\]/,/^$/ { s/^enabled = .*/enabled = true/; s/^port\s*= .*/port = '"$SSH_PORT"'/ }' /etc/fail2ban/jail.local

    # Disable all other jails by setting 'enabled = false' except for sshd
    sed -i '/^\[.*\]/ { h; }; /^\[sshd\]/! { x; s/^enabled = .*/enabled = false/; x; }' /etc/fail2ban/jail.local
else
    echo -e "${RED}Fail2Ban configuration file not found. Skipping configuration.${NC}"
fi

# Restart Fail2Ban service
systemctl restart fail2ban