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

# Detect the current instance's public IP
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
if [[ -z "$PUBLIC_IP" ]]; then
  echo "Failed to retrieve the public IP address." >&2
  exit 1
fi
echo "Detected public IP: $PUBLIC_IP"

# Configure libreswan
CONFIG_FILE="/etc/ipsec.conf"
if ! grep -q "IKEv2 VPN configuration" "$CONFIG_FILE"; then
  echo "Configuring libreswan..."
  cat > "$CONFIG_FILE" <<EOF
# IKEv2 VPN configuration
config setup
  uniqueids=never

conn ikev2-vpn
  ikev2=insist
  auto=add
  dpdaction=clear
  dpddelay=300s
  authby=secret
  left=%defaultroute
  leftid=@$PUBLIC_IP
  leftcert=/etc/ipsec.d/certs/server-cert.pem
  leftsendcert=always
  leftsubnet=0.0.0.0/0
  right=%any
  rightid=%any
  rightauth=eap-mschapv2
  rightsourceip=10.10.10.0/24
EOF
else
  echo "libreswan is already configured."
fi

# Generate certificates if not already present
CERT_DIR="/etc/ipsec.d/certs"
if [[ ! -f "$CERT_DIR/server-cert.pem" ]]; then
  echo "Generating certificates..."
  mkdir -p "$CERT_DIR"
  ipsec newhostkey --output "$CERT_DIR/ca-key.pem"
  ipsec newca --output "$CERT_DIR/ca-cert.pem" --key "$CERT_DIR/ca-key.pem" --dn "CN=IKEv2 VPN CA"
  ipsec newhostkey --output "$CERT_DIR/server-key.pem"
  ipsec newcert --output "$CERT_DIR/server-cert.pem" --key "$CERT_DIR/server-key.pem" --cacert "$CERT_DIR/ca-cert.pem" --dn "CN=$PUBLIC_IP" --san "$PUBLIC_IP"
else
  echo "Certificates already exist."
fi

# Restart libreswan to apply changes
echo "Restarting libreswan..."
systemctl enable ipsec
systemctl restart ipsec

echo "IKEv2 server setup completed."
