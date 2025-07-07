#!/bin/bash


# --- Configuration ---
# The wireless interface to use for the Access Point.
# You can change this if your wireless card is not wlan0.
AP_IFACE="wlan0"

# The static IP address for the Access Point.
AP_IP="192.168.50.1"
AP_NETMASK="24"
AP_NETWORK="192.168.50.0"

# DHCP range for connected clients.
DHCP_RANGE_START="192.168.50.50"
DHCP_RANGE_END="192.168.50.150"
DHCP_LEASE_TIME="12h"


# --- Script Body ---

# Exit immediately if a command exits with a non-zero status.
set -e

# Function to print colored messages
print_msg() {
    COLOR=$1
    MSG=$2
    case "$COLOR" in
        "green") echo -e "\e[32m[+] ${MSG}\e[0m" ;;
        "blue") echo -e "\e[34m[*] ${MSG}\e[0m" ;;
        "yellow") echo -e "\e[33m[!] ${MSG}\e[0m" ;;
        "red") echo -e "\e[31m[-] ${MSG}\e[0m" ;;
        *) echo "[ ] ${MSG}" ;;
    esac
}

# 1. Check for Root Privileges
print_msg "blue" "Checking for root privileges..."
if [[ $EUID -ne 0 ]]; then
   print_msg "red" "This script must be run as root. Please use sudo."
   exit 1
fi
print_msg "green" "Root privileges confirmed."

# 2. Get User Input for AP Configuration
print_msg "blue" "Please provide the details for your new Access Point."

read -p "Enter the desired SSID (network name): " SSID
while [[ -z "$SSID" ]]; do
    print_msg "yellow" "SSID cannot be empty."
    read -p "Enter the desired SSID (network name): " SSID
done

read -s -p "Enter the desired password (at least 8 characters): " PASSWORD
echo
while [[ ${#PASSWORD} -lt 8 ]]; do
    print_msg "yellow" "Password must be at least 8 characters long."
    read -s -p "Enter the desired password: " PASSWORD
    echo
done

# The connection name for NetworkManager
CON_NAME="$SSID-AP"

# 3. Check and Install dnsmasq
print_msg "blue" "Checking for dnsmasq..."
if ! command -v dnsmasq &> /dev/null; then
    print_msg "yellow" "dnsmasq not found. Installing..."
    apt-get update
    apt-get install -y dnsmasq
    print_msg "green" "dnsmasq installed successfully."
else
    print_msg "green" "dnsmasq is already installed."
fi

# 4. Configure dnsmasq
print_msg "blue" "Configuring dnsmasq..."
DNSMASQ_CONF="/etc/dnsmasq.conf"

# Backup existing configuration
if [ -f "$DNSMASQ_CONF" ]; then
    mv "$DNSMASQ_CONF" "${DNSMASQ_CONF}.bak_$(date +%F-%T)"
    print_msg "green" "Backed up existing dnsmasq configuration."
fi

# Write new configuration
cat > "$DNSMASQ_CONF" << EOF
# Listen only on the AP interface
interface=${AP_IFACE}

# Do not forward plain names (without a dot or domain part)
domain-needed

# Do not forward addresses in the non-routed address spaces.
bogus-priv

# Assign IP addresses and lease times to our DHCP clients.
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${DHCP_LEASE_TIME}

# Set the gateway for clients
dhcp-option=3,${AP_IP}

# Set the DNS server for clients
dhcp-option=6,${AP_IP}

# Use Google's public DNS servers for upstream queries
server=8.8.8.8
server=8.8.4.4
EOF
print_msg "green" "dnsmasq configured successfully."

# 5. Enable IP Forwarding
print_msg "blue" "Enabling IP forwarding..."
# Use sed to uncomment the line. -i flag edits in place.
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
# Apply the changes immediately
sysctl -p
print_msg "green" "IP forwarding enabled and made persistent."

# 6. Configure NAT (Network Address Translation)
print_msg "blue" "Configuring NAT..."
# Find the internet-facing interface automatically
INET_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
if [[ -z "$INET_IFACE" ]]; then
    print_msg "red" "Could not automatically determine the internet-facing interface. Exiting."
    exit 1
fi
print_msg "green" "Internet-facing interface detected as: ${INET_IFACE}"

# Set up the iptables rule for NAT
iptables -t nat -A POSTROUTING -o "$INET_IFACE" -j MASQUERADE

# Make the iptables rule persistent
print_msg "blue" "Making NAT rule persistent..."
if ! command -v netfilter-persistent &> /dev/null; then
    print_msg "yellow" "iptables-persistent not found. Installing..."
    apt-get install -y iptables-persistent
else
    print_msg "green" "iptables-persistent is already installed."
fi
netfilter-persistent save
print_msg "green" "NAT rule saved successfully."

# 7. Configure NetworkManager
print_msg "blue" "Configuring NetworkManager connection profile..."

# Check if a connection with the same name already exists and delete it
if nmcli connection show "$CON_NAME" &> /dev/null; then
    print_msg "yellow" "A connection named '$CON_NAME' already exists. Deleting it..."
    nmcli connection delete "$CON_NAME"
fi

# Create the new connection
nmcli connection add type wifi ifname "$AP_IFACE" con-name "$CON_NAME" autoconnect yes ssid "$SSID"

# Configure the connection as an Access Point
nmcli connection modify "$CON_NAME" 802-11-wireless.mode ap

# Set the static IP address for the AP
nmcli connection modify "$CON_NAME" ipv4.method manual ipv4.addresses "${AP_IP}/${AP_NETMASK}"

# Set the Wi-Fi security
nmcli connection modify "$CON_NAME" 802-11-wireless-security.key-mgmt wpa-psk
nmcli connection modify "$CON_NAME" 802-11-wireless-security.psk "$PASSWORD"

print_msg "green" "NetworkManager profile '$CON_NAME' created and configured."

# 8. Final Steps
print_msg "blue" "Applying all changes..."

# Restart dnsmasq to apply new configuration
systemctl restart dnsmasq

# Bring up the new AP connection
# It might disconnect your current Wi-Fi, which is expected.
print_msg "yellow" "Attempting to start the new Access Point. Your current Wi-Fi connection might be interrupted."
nmcli connection up "$CON_NAME"

print_msg "green" "\n=================================================="
print_msg "green" "      Access Point Setup Complete!"
print_msg "green" "=================================================="
echo -e "SSID:          \e[32m${SSID}\e[0m"
echo -e "Password:      \e[32m${PASSWORD}\e[0m"
echo -e "AP Interface:  \e[32m${AP_IFACE}\e[0m"
echo -e "AP IP Address: \e[32m${AP_IP}\e[0m"
echo -e "\nYour new Access Point should now be active."
echo -e "The configuration is persistent and will start automatically on reboot."
