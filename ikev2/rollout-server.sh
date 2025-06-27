#!/bin/bash
set -e

# Check if the script is run as root
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root" >&2
  exit 1
fi

# Update system packages
echo "Updating system packages..."
yum update -y

# Install libreswan if not already installed
if ! command -v ipsec &> /dev/null; then
  echo "Installing libreswan..."
  yum install -y libreswan
else
  echo "libreswan is already installed."
fi

# Retrieve the public IP using IMDSv2
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
if [[ -z "$TOKEN" ]]; then
  echo "Failed to retrieve IMDSv2 token." >&2
  exit 1
fi

PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/public-ipv4")
if [[ -z "$PUBLIC_IP" ]]; then
  echo "Failed to retrieve the public IP address using IMDSv2." >&2
  exit 1
fi
echo "Detected public IP: $PUBLIC_IP"

# Configure libreswan
CONFIG_FILE="/etc/ipsec.conf"
echo "Configuring libreswan with PSK..."
cat > "$CONFIG_FILE" <<EOF
# IKEv2 VPN configuration
config setup
  uniqueids=no

conn ikev2-vpn
  ikev2=insist
  auto=add
  dpdaction=clear
  dpddelay=300s
  authby=secret
  left=%defaultroute
  leftid=@$PUBLIC_IP
  leftsubnet=0.0.0.0/0
  right=%any
  rightid=%any
  rightauth=secret
  rightsourceip=10.10.10.0/24
EOF

# Configure the pre-shared key
SECRETS_FILE="/etc/ipsec.secrets"
if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "Configuring pre-shared key..."
  cat > "$SECRETS_FILE" <<EOF
# Pre-shared key for IKEv2 VPN
: PSK "your-strong-pre-shared-key"
EOF
else
  echo "Pre-shared key file already exists. Skipping configuration."
fi

# Restart libreswan to apply changes
echo "Restarting libreswan..."
systemctl enable ipsec
systemctl restart ipsec

echo "IKEv2 server setup with PSK completed."
