#!/bin/bash

# OpenVPN with DDNS and Reverse Proxy Setup Script for Debian
# Run with sudo: sudo bash openvpn_ddns_setup.sh

# Exit on error
set -e

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== OpenVPN with DDNS and Reverse Proxy Installer ===${NC}"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root (use sudo)${NC}"
  exit 1
fi

# Collect required information
echo -e "${BLUE}Please provide the following information:${NC}"
read -p "Enter your DDNS provider (duckdns, no-ip, dynu): " DDNS_PROVIDER
read -p "Enter your DDNS username/token: " DDNS_USERNAME
read -p "Enter your DDNS password (leave empty if using token): " DDNS_PASSWORD
read -p "Enter your DDNS domain (example: yourdomain.duckdns.org): " DDNS_DOMAIN

# Remove http:// or https:// prefix if present
DDNS_DOMAIN=$(echo "$DDNS_DOMAIN" | sed 's|^http://||' | sed 's|^https://||')
read -p "Enter your local network subnet (e.g., 192.168.1.0/24): " LOCAL_SUBNET
read -p "Enter the local IP and port for reverse proxy (e.g., 192.168.1.100:8080): " REVERSE_PROXY_TARGET

# Update package lists
echo -e "${GREEN}Updating package lists...${NC}"
apt update

# Install required packages
echo -e "${GREEN}Installing required packages...${NC}"
apt install -y openvpn easy-rsa nginx ddclient iptables-persistent

# Set up DDNS
echo -e "${GREEN}Setting up DDNS with $DDNS_PROVIDER...${NC}"

# Fix for DuckDNS domain format - strip any http:// or https:// prefix
DDNS_DOMAIN=$(echo "$DDNS_DOMAIN" | sed 's|^http://||' | sed 's|^https://||')

# Create ddclient configuration
cat > /etc/ddclient.conf << EOF
use=web, web=checkip.dyndns.org
protocol=$DDNS_PROVIDER
EOF

# Add specific configurations based on DDNS provider
if [ "$DDNS_PROVIDER" = "duckdns" ]; then
  cat >> /etc/ddclient.conf << EOF
server=www.duckdns.org
login=$DDNS_USERNAME
password=
$DDNS_DOMAIN
EOF
elif [ "$DDNS_PROVIDER" = "no-ip" ]; then
  cat >> /etc/ddclient.conf << EOF
server=dynupdate.no-ip.com
login=$DDNS_USERNAME
password=$DDNS_PASSWORD
$DDNS_DOMAIN
EOF
elif [ "$DDNS_PROVIDER" = "dynu" ]; then
  cat >> /etc/ddclient.conf << EOF
server=api.dynu.com
login=$DDNS_USERNAME
password=$DDNS_PASSWORD
$DDNS_DOMAIN
EOF
else
  echo -e "${RED}Unsupported DDNS provider. Please manually edit /etc/ddclient.conf${NC}"
fi

# Restart ddclient service
systemctl restart ddclient

# Set up OpenVPN using Easy-RSA
echo -e "${GREEN}Setting up OpenVPN with Easy-RSA...${NC}"

# Create directory for Easy-RSA
mkdir -p /etc/openvpn/easy-rsa
cp -r /usr/share/easy-rsa/* /etc/openvpn/easy-rsa/
cd /etc/openvpn/easy-rsa

# Create vars file
cat > vars << EOF
set_var EASYRSA_REQ_COUNTRY "US"
set_var EASYRSA_REQ_PROVINCE "State"
set_var EASYRSA_REQ_CITY "City"
set_var EASYRSA_REQ_ORG "Organization"
set_var EASYRSA_REQ_EMAIL "admin@example.com"
set_var EASYRSA_REQ_OU "IT"
set_var EASYRSA_KEY_SIZE 2048
set_var EASYRSA_CA_EXPIRE 3650
set_var EASYRSA_CERT_EXPIRE 825
EOF

# Initialize the PKI
./easyrsa init-pki

# Generate the CA (Certificate Authority)
echo -e "${GREEN}Generating CA certificate (automated/non-interactive)...${NC}"
./easyrsa --batch build-ca nopass

# Generate server certificate and key
echo -e "${GREEN}Generating server certificate and key...${NC}"
./easyrsa --batch gen-req server nopass
./easyrsa --batch sign-req server server

# Generate Diffie-Hellman parameters
echo -e "${GREEN}Generating Diffie-Hellman parameters (this may take a while)...${NC}"
./easyrsa gen-dh

# Generate client certificate and key
echo -e "${GREEN}Generating client certificate and key...${NC}"
./easyrsa --batch gen-req client1 nopass
./easyrsa --batch sign-req client client1

# Create server configuration
echo -e "${GREEN}Creating OpenVPN server configuration...${NC}"
cat > /etc/openvpn/server.conf << EOF
port 1194
proto udp
dev tun
ca /etc/openvpn/easy-rsa/pki/ca.crt
cert /etc/openvpn/easy-rsa/pki/issued/server.crt
key /etc/openvpn/easy-rsa/pki/private/server.key
dh /etc/openvpn/easy-rsa/pki/dh.pem
server 10.8.0.0 255.255.255.0
# Don't redirect all gateway traffic - this prevents breaking server internet
# push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 8.8.4.4"
push "route ${LOCAL_SUBNET}"
keepalive 10 120
cipher AES-256-GCM
auth SHA256
user nobody
group nogroup
persist-key
persist-tun
status /var/log/openvpn/openvpn-status.log
log-append /var/log/openvpn/openvpn.log
verb 3
EOF

# Create necessary directories
mkdir -p /var/log/openvpn/

# Enable IP forwarding
echo -e "${GREEN}Enabling IP forwarding...${NC}"
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
sysctl -p

# Configure iptables for NAT
echo -e "${GREEN}Configuring iptables for NAT...${NC}"
DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}')
echo -e "${BLUE}Detected default interface: ${DEFAULT_IFACE}${NC}"

# More targeted NAT rule - only for traffic to the local subnet
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -d ${LOCAL_SUBNET} -o ${DEFAULT_IFACE} -j MASQUERADE

# Save iptables rules
if command -v netfilter-persistent &> /dev/null; then
    netfilter-persistent save
else
    echo -e "${BLUE}netfilter-persistent not found. Installing...${NC}"
    apt install -y iptables-persistent
    netfilter-persistent save
fi

# Start OpenVPN
echo -e "${GREEN}Starting OpenVPN server...${NC}"
systemctl enable openvpn@server
systemctl start openvpn@server

# Set up Nginx reverse proxy
echo -e "${GREEN}Setting up Nginx reverse proxy...${NC}"
cat > /etc/nginx/sites-available/reverse-proxy << EOF
server {
    listen 80;
    server_name $DDNS_DOMAIN;

    location / {
        proxy_pass http://$REVERSE_PROXY_TARGET;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# Enable the site
ln -sf /etc/nginx/sites-available/reverse-proxy /etc/nginx/sites-enabled/
nginx -t
systemctl restart nginx

# Create client configuration directory
echo -e "${GREEN}Creating client configuration...${NC}"
mkdir -p /etc/openvpn/client-configs

# Extract key information for the client config
cat > /etc/openvpn/client-configs/client1.ovpn << EOF
client
dev tun
proto udp
remote $DDNS_DOMAIN 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
auth SHA256
verb 3

# Only route traffic for the private network through VPN
# This prevents breaking internet access on clients
route-nopull
route ${LOCAL_SUBNET} 255.255.255.0
dhcp-option DNS 8.8.8.8
dhcp-option DNS 8.8.4.4

<ca>
$(cat /etc/openvpn/easy-rsa/pki/ca.crt)
</ca>
<cert>
$(cat /etc/openvpn/easy-rsa/pki/issued/client1.crt)
</cert>
<key>
$(cat /etc/openvpn/easy-rsa/pki/private/client1.key)
</key>
EOF

# Set proper permissions
chmod 600 /etc/openvpn/client-configs/client1.ovpn

# Open firewall ports
echo -e "${GREEN}Configuring firewall...${NC}"

# Check if we should use UFW or iptables directly
if command -v ufw &> /dev/null; then
    echo -e "${BLUE}Using UFW for firewall configuration${NC}"
    ufw allow 1194/udp
    ufw allow 80/tcp
    ufw allow 443/tcp
    echo -e "${GREEN}UFW firewall configured.${NC}"
elif command -v iptables &> /dev/null; then
    echo -e "${BLUE}Using iptables directly for firewall configuration${NC}"
    iptables -A INPUT -p udp --dport 1194 -j ACCEPT
    iptables -A INPUT -p tcp --dport 80 -j ACCEPT
    iptables -A INPUT -p tcp --dport 443 -j ACCEPT
    echo -e "${GREEN}Iptables firewall configured.${NC}"
else
    echo -e "${RED}No firewall utility found. Please manually configure your firewall.${NC}"
fi

# Copy client config to script execution directory
SCRIPT_DIR=$(pwd)
cp /etc/openvpn/client-configs/client1.ovpn "$SCRIPT_DIR/"
chmod 644 "$SCRIPT_DIR/client1.ovpn"
echo -e "${GREEN}Client configuration copied to:${NC} $SCRIPT_DIR/client1.ovpn"

# Test connectivity before finishing
echo -e "${GREEN}Testing internet connectivity...${NC}"
if ping -c 3 8.8.8.8 &> /dev/null; then
    echo -e "${GREEN}✓ Internet connectivity works!${NC}"
else
    echo -e "${RED}✗ Internet connectivity test failed.${NC}"
    echo -e "${BLUE}Stopping OpenVPN to restore connectivity...${NC}"
    systemctl stop openvpn@server
    echo -e "${GREEN}OpenVPN service stopped. Your internet should be restored.${NC}"
    echo -e "${BLUE}You can start OpenVPN again with:${NC} sudo systemctl start openvpn@server"
    echo -e "${RED}Please check the OpenVPN configuration for issues.${NC}"
fi

# Final steps and instructions
echo -e "${GREEN}=== Installation Complete! ===${NC}"
echo -e "${BLUE}Your OpenVPN server with DDNS and reverse proxy has been set up.${NC}"
echo -e "${BLUE}Client configuration file is available at:${NC}"
echo -e "  1. ${BLUE}Original location:${NC} /etc/openvpn/client-configs/client1.ovpn"
echo -e "  2. ${BLUE}Copied to:${NC} $SCRIPT_DIR/client1.ovpn"
echo -e "${BLUE}Your reverse proxy is configured to forward requests from${NC} http://$DDNS_DOMAIN ${BLUE}to${NC} http://$REVERSE_PROXY_TARGET"
echo -e "${BLUE}DDNS will automatically update your IP address with the provider.${NC}"

# Important note about configuration
echo -e "${GREEN}=== IMPORTANT NOTE ===${NC}"
echo -e "${BLUE}This setup is configured for accessing only your local network (${LOCAL_SUBNET})${NC}"
echo -e "${BLUE}through the VPN, not for routing all internet traffic through it.${NC}"
echo -e "${BLUE}This prevents internet connectivity issues on both server and clients.${NC}"

# Try to display public IP if internet works
if ping -c 1 ifconfig.me &> /dev/null; then
    echo -e "${GREEN}Current public IP address:${NC} $(curl -s ifconfig.me)"
else
    echo -e "${BLUE}Cannot determine public IP address. Please check internet connectivity.${NC}"
fi