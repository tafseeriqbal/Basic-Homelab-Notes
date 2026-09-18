#!/bin/bash
# Pi-hole setup. Run ONLY on a wired connection with physical access.
set -euo pipefail

echo "=== Pi-hole setup ==="
echo

# --- 1. Check we're wired ---
echo "Interfaces:"
ip -br addr
echo
read -rp "Ethernet interface name (e.g. enp14s0): " IFACE

if ! ip link show "$IFACE" | grep -q "state UP"; then
  echo "ERROR: $IFACE is not UP. Plug in ethernet first."
  exit 1
fi

CURRENT_IP=$(ip -4 -br addr show "$IFACE" | awk '{print $3}' | cut -d/ -f1)
echo "Current address on $IFACE: ${CURRENT_IP:-none}"
echo

# --- 2. Confirm a fixed address exists ---
cat <<'EOF'
Pi-hole needs a fixed address. Two ways:

  A) DHCP reservation on your router (recommended - nothing to break
     on the host, survives a reinstall)
  B) Static config on this machine via netplan

If you have not done either yet, stop, do A on your router, reboot
this box, and re-run this script.
EOF
echo
read -rp "Is this machine's address fixed? (yes/no): " FIXED
[[ "$FIXED" == "yes" ]] || { echo "Set it up first. Exiting."; exit 1; }

read -rp "This server's fixed IP: " SERVER_IP
read -rp "LAN subnet in CIDR (e.g. 192.168.0.0/24): " LAN_CIDR
echo

# --- 3. Pre-flight ---
if ss -lnu | grep -q ':53 '; then
  echo "WARNING: something is already listening on UDP 53."
  ss -lnup | grep ':53 ' || true
  read -rp "Continue anyway? (yes/no): " C
  [[ "$C" == "yes" ]] || exit 1
fi

echo "Backing up current UFW rules to ~/ufw-rules-before-pihole.txt"
sudo ufw status numbered > ~/ufw-rules-before-pihole.txt

# --- 4. Install ---
read -rp "Run the Pi-hole installer now? (yes/no): " GO
[[ "$GO" == "yes" ]] || exit 0
curl -sSL https://install.pi-hole.net | sudo bash

# --- 5. Firewall: LAN only, never the internet ---
echo
echo "Opening DNS + admin UI to $LAN_CIDR only."
sudo ufw allow from "$LAN_CIDR" to any port 53 proto udp
sudo ufw allow from "$LAN_CIDR" to any port 53 proto tcp
sudo ufw allow from "$LAN_CIDR" to any port 80 proto tcp
sudo ufw reload
sudo ufw status numbered

# --- 6. Verify locally ---
echo
echo "Local resolution test:"
dig +short doubleclick.net @"$SERVER_IP" || true
echo "(0.0.0.0 = blocking works. A real IP = not filtering.)"

# --- 7. What's left ---
cat <<EOF

Done on the host. Two manual steps left:

1. Router -> DHCP settings -> primary DNS = $SERVER_IP
   A public resolver as secondary lets clients silently bypass
   filtering. 

2. Renew the lease on another device, then from that device:
       nslookup doubleclick.net
   Should return 0.0.0.0.

ROLLBACK: set the router's DNS back to 1.1.1.1. Everything recovers
on the next lease renewal.
EOF
