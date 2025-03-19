#!/bin/bash

# Debian 12 Essential Tools Installation Script
# Run with sudo: sudo bash debian_essentials.sh

# Exit on error
set -e

# Print colorful messages
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Debian 12 Essential Tools Installer ===${NC}"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (use sudo)"
  exit 1
fi

echo -e "${GREEN}Updating package lists...${NC}"
apt update

echo -e "${GREEN}===== Installing System Maintenance Tools =====${NC}"
apt install -y htop neofetch inxi gparted

echo -e "${GREEN}===== Installing File Management Tools =====${NC}"
apt install -y mc rsync ncdu

echo -e "${GREEN}===== Installing Networking Tools =====${NC}"
apt install -y nmap iftop curl wget ssh

echo -e "${GREEN}===== Installing Text Processing Tools =====${NC}"
apt install -y vim nano grep sed gawk bat

# If 'bat' isn't found or is 'batcat' in Debian
if ! command -v bat &> /dev/null && command -v batcat &> /dev/null; then
    echo "Creating bat symlink for batcat..."
    ln -s /usr/bin/batcat /usr/local/bin/bat
fi

echo -e "${GREEN}===== Installing Security Tools =====${NC}"
apt install -y ufw fail2ban clamav clamav-daemon

echo -e "${GREEN}===== Installing Development Tools =====${NC}"
apt install -y git build-essential

# Install VS Code (requires additional repository)
echo -e "${GREEN}Installing Visual Studio Code...${NC}"
apt install -y wget gpg apt-transport-https

# Import Microsoft GPG key
wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > microsoft.gpg
install -o root -g root -m 644 microsoft.gpg /etc/apt/trusted.gpg.d/
rm microsoft.gpg

# Add VS Code repository
echo "deb [arch=amd64] https://packages.microsoft.com/repos/vscode stable main" > /etc/apt/sources.list.d/vscode.list

# Install VS Code
apt update
apt install -y code
echo -e "${GREEN}VS Code installed successfully!${NC}"

# Optional: Install Timeshift (the recommended snapshot tool)
echo -e "${BLUE}Do you want to install Timeshift for system snapshots? (y/n)${NC}"
read -r install_timeshift
if [[ $install_timeshift =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}Installing Timeshift...${NC}"
    apt install -y timeshift
    echo -e "${GREEN}Timeshift installed successfully!${NC}"
    echo "Run 'sudo timeshift-gtk' to configure and create snapshots"
fi

# Enable and configure UFW (firewall)
echo -e "${BLUE}Do you want to enable UFW firewall with basic configuration? (y/n)${NC}"
read -r enable_ufw
if [[ $enable_ufw =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}Configuring UFW...${NC}"
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh
    ufw enable
    echo -e "${GREEN}UFW enabled with basic configuration${NC}"
    echo "Run 'sudo ufw status' to check firewall status"
fi

# Enable and start Fail2ban
echo -e "${BLUE}Do you want to enable Fail2ban to protect SSH? (y/n)${NC}"
read -r enable_fail2ban
if [[ $enable_fail2ban =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}Configuring and starting Fail2ban...${NC}"
    systemctl enable fail2ban
    systemctl start fail2ban
    echo -e "${GREEN}Fail2ban enabled and started${NC}"
    echo "Run 'sudo fail2ban-client status' to check status"
fi

# Enable and start ClamAV
echo -e "${BLUE}Do you want to enable ClamAV antivirus? (y/n)${NC}"
read -r enable_clamav
if [[ $enable_clamav =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}Configuring and starting ClamAV...${NC}"
    systemctl enable clamav-daemon
    systemctl start clamav-daemon
    echo -e "${GREEN}ClamAV enabled and started${NC}"
    echo "Note: First-time database update may take some time"
    echo "Run 'sudo systemctl status clamav-daemon' to check status"
fi

echo -e "${BLUE}=== Installation Complete! ===${NC}"
echo -e "All selected essential tools have been installed on your Debian 12 system."
echo -e "Reboot is recommended for some changes to take effect."

# Display system summary using neofetch
echo -e "${GREEN}=== System Summary ===${NC}"
neofetch
