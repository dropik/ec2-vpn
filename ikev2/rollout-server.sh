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

# Install strongSwan if not already installed
if ! command -v ipsec &> /dev/null; then
  echo "Installing strongSwan..."
  yum install -y strongswan
else
  echo "strongSwan is already installed."
fi

# Detect the current instance's public IP
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
if [[ -z "$PUBLIC_IP" ]]; then
  echo "Failed to retrieve the public IP address." >&2
  exit 1
fi
echo "Detected public IP: $PUBLIC_IP"

# Configure strongSwan
CONFIG_FILE="/etc/strongswan/ipsec.conf"
if ! grep -q "IKEv2 VPN configuration" "$CONFIG_FILE"; then
  echo "Configuring strongSwan..."
  cat > "$CONFIG_FILE" <<EOF
# IKEv2 VPN configuration
config setup
  uniqueids=never

conn ikev2-vpn
  keyexchange=ikev2
  auto=add
  dpdaction=clear
  dpddelay=300s
  eap_identity=%any
  left=%any
  leftid=@$PUBLIC_IP
  leftcert=/etc/strongswan/ipsec.d/certs/server-cert.pem
  leftsendcert=always
  leftsubnet=0.0.0.0/0
  right=%any
  rightid=%any
  rightauth=eap-mschapv2
  rightsourceip=10.10.10.0/24
EOF
else
  echo "strongSwan is already configured."
fi

# Generate certificates if not already present
CERT_DIR="/etc/strongswan/ipsec.d/certs"
if [[ ! -f "$CERT_DIR/server-cert.pem" ]]; then
  echo "Generating certificates..."
  mkdir -p "$CERT_DIR"
  ipsec pki --gen --outform pem > "$CERT_DIR/ca-key.pem"
  ipsec pki --self --ca --lifetime 3650 --in "$CERT_DIR/ca-key.pem" --type rsa --dn "CN=IKEv2 VPN CA" --outform pem > "$CERT_DIR/ca-cert.pem"
  ipsec pki --gen --outform pem > "$CERT_DIR/server-key.pem"
  ipsec pki --pub --in "$CERT_DIR/server-key.pem" --type rsa | ipsec pki --issue --lifetime 1825 --cacert "$CERT_DIR/ca-cert.pem" --cakey "$CERT_DIR/ca-key.pem" --dn "CN=$PUBLIC_IP" --san "$PUBLIC_IP" --flag serverAuth --flag ikeIntermediate --outform pem > "$CERT_DIR/server-cert.pem"
else
  echo "Certificates already exist."
fi

# Restart strongSwan to apply changes
echo "Restarting strongSwan..."
systemctl enable strongswan
systemctl restart strongswan

echo "IKEv2 server setup completed."
