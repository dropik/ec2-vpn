#!/bin/bash
set -e

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <client-name>"
    exit 1
fi

CLIENT_NAME=$1
CLIENT_DIR="/etc/wireguard/clients"
CLIENT_CONF="$CLIENT_DIR/client.$CLIENT_NAME.conf"
SERVER_CONF="/etc/wireguard/wg0.conf"

# Ensure client directory exists
mkdir -p "$CLIENT_DIR"

# Generate key pair if not already present
if [ ! -f "$CLIENT_DIR/$CLIENT_NAME.key" ]; then
    wg genkey | tee "$CLIENT_DIR/$CLIENT_NAME.key" | wg pubkey > "$CLIENT_DIR/$CLIENT_NAME.pub"
fi

PRIVATE_KEY=$(cat "$CLIENT_DIR/$CLIENT_NAME.key")
PUBLIC_KEY=$(cat "$CLIENT_DIR/$CLIENT_NAME.pub")

# Check if the client already exists in the server configuration
EXISTING_IP=$(grep -A 1 "$PUBLIC_KEY" "$SERVER_CONF" | grep -oP 'AllowedIPs = 10\.0\.0\.\K[0-9]+')

if [ -n "$EXISTING_IP" ]; then
    CLIENT_IP=$EXISTING_IP
else
    # Find the next available IP address
    ALLOCATED_IPS=$(grep -oP 'AllowedIPs = 10\.0\.0\.\K[0-9]+' "$SERVER_CONF" || true)
    if [ -z "$ALLOCATED_IPS" ]; then
        CLIENT_IP=2
    else
        CLIENT_IP=$(( $(echo "$ALLOCATED_IPS" | sort -n | tail -n 1) + 1 ))
    fi
fi

# Generate client configuration
cat > "$CLIENT_CONF" <<EOF
[Interface]
PrivateKey = $PRIVATE_KEY
Address = 10.0.0.$CLIENT_IP/24
DNS = 8.8.8.8

[Peer]
PublicKey = $(wg show wg0 public-key)
Endpoint = $(hostname -I | awk '{print $1}'):51820
AllowedIPs = 0.0.0.0/0, ::/0
EOF

# Add peer to server configuration if not already present
if ! grep -q "$PUBLIC_KEY" "$SERVER_CONF"; then
    cat >> "$SERVER_CONF" <<EOF

[Peer]
PublicKey = $PUBLIC_KEY
AllowedIPs = 10.0.0.$CLIENT_IP/32
EOF
    wg syncconf wg0 <(wg-quick strip wg0)
fi

echo "Client configuration created/updated: $CLIENT_CONF"
