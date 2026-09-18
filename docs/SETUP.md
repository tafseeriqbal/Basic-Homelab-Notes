# Setup order

Order matters. Firewall before services, Tailscale before anything
that depends on tailnet-only access, DHCP reservation before Pi-hole.

## 1. Base OS

Ubuntu Server 24.04 LTS, minimal install, OpenSSH enabled.
Everything after this is over SSH.

## 2. Harden SSH

Copy your public key first, and keep a second session open while
testing — locking yourself out of a headless box means attaching a
keyboard.

    ssh-copy-id <user>@<host>
    sudo cp config/sshd-hardening.conf /etc/ssh/sshd_config.d/99-hardening.conf
    sudo systemctl restart ssh

Verify from a new terminal before closing the old one.

## 3. Firewall

    sudo apt install -y ufw
    sudo sh scripts/ufw-rules.sh

Note the rules are scoped to `tailscale0` where possible. See the
comments in that script for why.

## 4. Lid-close and patching

It's a laptop. Closing it suspends the server unless you stop it:

    sudo sed -i 's/^#HandleLidSwitch=.*/HandleLidSwitch=ignore/' /etc/systemd/logind.conf
    sudo systemctl restart systemd-logind

    sudo apt install -y unattended-upgrades fail2ban
    sudo systemctl enable --now fail2ban

## 5. Network

Ethernet primary, WiFi as fallback at a higher metric. Set a DHCP
reservation on the router for the ethernet MAC — Pi-hole breaks if
the address changes.

Edit `/etc/netplan/50-cloud-init.yaml`, then:

    sudo netplan apply

## 6. Tailscale

    curl -fsSL https://tailscale.com/install.sh | sh
    sudo tailscale up

Share the node with a second user from the admin console rather than
creating an account for them on the host.

## 7. Pi-hole

Requires the reservation from step 5.

    sh scripts/setup-pihole.sh

Then on the router: disable DNS relay, set WAN DNS to the server's
address as primary and a public resolver as secondary.

Warn the household before switching. Some sites break and they will
blame you.

## 8. Minecraft

    sudo apt install -y openjdk-25-jre-headless

Download Paper from the fill.papermc.io v3 API. Install the unit:

    sudo cp systemd/minecraft.service /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable --now minecraft

Heap is `-Xms1G -Xmx1536M`. Do not raise it — see README, Incidents.

## 9. Backups

    cp scripts/mc-backup.sh ~/
    crontab -e      # see crontab.example

Configure rclone for the offsite target. The rclone config holds live
OAuth tokens; keep it off this repo.

Test a restore before trusting it.

## 10. WebDAV

Apache, TLS, tailnet-only. Ports 80 and 443 are held by pihole-FTL,
so both are commented out of ports.conf.

    sudo apt install -y apache2 apache2-utils
    sudo a2enmod dav dav_fs auth_basic ssl
    sudo htpasswd -c /etc/apache2/webdav.htpasswd <user>

    sudo tailscale cert <host>.<tailnet>.ts.net

Copy `config/apache-webdav.conf.example` to
`/etc/apache2/sites-available/webdav.conf`, fill in the placeholders,
then:

    sudo a2ensite webdav
    sudo apache2ctl configtest
    sudo systemctl restart apache2

The certificate expires in ~90 days. Renewal is manual: re-run
`tailscale cert` and restart apache.

## 11. git mirror

    cp scripts/org-sync ~/
    cp systemd/org-sync.* ~/.config/systemd/user/
    systemctl --user daemon-reload
    systemctl --user enable --now org-sync.timer
    sudo loginctl enable-linger <user>

`enable-linger` is required or the timer stops when you log out.
