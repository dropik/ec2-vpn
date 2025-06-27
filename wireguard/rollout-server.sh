#!/bin/bash
set -e

$mainInterface=$(ip route | grep default | awk '{print $5}')
$vpnNetwork="10.0.0.1/24"
$vpnPort=51820

# Install packages
dnf install -y wireguard-tools iptables

# Registering the wg0 network
cat <<EOF > /run/systemd/network/wg0.network
[Match]
Name=wg0

[Network]
Address=$vpnNetwork
IPForward=ipv4
EOF

# Ensure main interface allows IP forwarding
for file in /etc/systemd/network/70-$mainInterface.network; do
  if grep -q "^\[Network\]" "$file"; then
    if ! grep -q "^IPForward=ipv4" "$file"; then
      sed -i '/^\[Network\]/a IPForward=ipv4' "$file"
    fi
  fi
done

# Install wg-nat.service to enable NAT masquerading
cat <<EOF > /etc/systemd/system/wg-nat.service
[Unit]
Description=Enable NAT masquerading for WireGuard
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables -t nat -A POSTROUTING -o $mainInterface -j MASQUERADE
ExecStop=/sbin/iptables -t nat -D POSTROUTING -o $mainInterface -j MASQUERADE
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and enable the service
systemctl daemon-reload
systemctl enable --now wg-nat.service
systemctl restart systemd-networkd
systemctl restart wg-nat.service

# Generate server key if not already present
cd /etc/wireguard
if [ ! -f server_private_key ] || [ ! -f server_public_key ]; then
  wg genkey | tee server_private_key | wg pubkey > server_public_key
fi
server_private_key=$(cat server_private_key)
server_public_key=$(cat server_public_key)

# Update [Interface] section of wg0.conf idempotently
wg_conf="/etc/wireguard/wg0.conf"
if ! grep -q "^\[Interface\]" "$wg_conf"; then
  echo "[Interface]" >> "$wg_conf"
fi
sed -i "/^\[Interface\]/,/^\[/ s|^PrivateKey =.*|PrivateKey = $server_private_key|" "$wg_conf"
sed -i "/^\[Interface\]/,/^\[/ s|^Address =.*|Address = $vpnNetwork|" "$wg_conf"
sed -i "/^\[Interface\]/,/^\[/ s|^ListenPort =.*|ListenPort = $vpnPort|" "$wg_conf"

# Start WireGuard interface
systemctl enable --now wg-quick@wg0
wg-quick down wg0 && wg-quick up wg0
