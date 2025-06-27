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

# Generate certificates if not already present
CERT_DIR="/etc/ipsec.d/certs"
if [[ ! -f "$CERT_DIR/server-cert.pem" ]]; then
  echo "Generating certificates..."
  mkdir -p "$CERT_DIR"

  # Generate CA key and certificate
  certutil -N -d sql:/etc/ipsec.d --empty-password
  certutil -S -x -n "IKEv2 VPN CA" -s "CN=IKEv2 VPN CA" -k rsa -g 2048 -v 120 -d sql:/etc/ipsec.d -t "CT,," -2

  # Generate server key and certificate
  certutil -S -c "IKEv2 VPN CA" -n "Server-Cert" -s "CN=$PUBLIC_IP" -k rsa -g 2048 -v 120 -d sql:/etc/ipsec.d -t ",," -8 "$PUBLIC_IP"

  # Export server certificate
  pk12util -o "$CERT_DIR/server-cert.p12" -n "Server-Cert" -d sql:/etc/ipsec.d -W ""
  openssl pkcs12 -in "$CERT_DIR/server-cert.p12" -clcerts -nokeys -out "$CERT_DIR/server-cert.pem" -passin pass:
  openssl pkcs12 -in "$CERT_DIR/server-cert.p12" -nocerts -nodes -out "$CERT_DIR/server-key.pem" -passin pass:
else
  echo "Certificates already exist."
fi

# Restart libreswan to apply changes
echo "Restarting libreswan..."
systemctl enable ipsec
systemctl restart ipsec

echo "IKEv2 server setup completed."
