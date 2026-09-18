#!/bin/sh
# Firewall ruleset for the server. Run once after installing ufw.
#
# The principle: services meant for the tailnet are scoped to the
# tailscale0 interface, not just to a port. A rule like
#   ufw allow 8443/tcp
# opens that port to every device on the LAN. This instead:
#   ufw allow in on tailscale0 to any port 8443 proto tcp
# means the service is unreachable from the local network even though
# the local network is nominally trusted. Getting this wrong once left
# WebDAV open to the whole house.

set -e

ufw default deny incoming
ufw default allow outgoing

# SSH — LAN-wide, so the box stays reachable if Tailscale is down.
# Key-only auth is what makes this acceptable. See config/sshd-hardening.conf
ufw allow 22/tcp

# Anything else on the tailnet
ufw allow in on tailscale0

# Minecraft — tailnet only, never forwarded
ufw allow in on tailscale0 to any port 25565

# WebDAV — tailnet only
ufw allow in on tailscale0 to any port 8443 proto tcp

# Pi-hole serves DNS to the LAN, so these are deliberately not scoped
ufw allow 53
ufw allow 80/tcp

ufw --force enable
ufw status numbered
