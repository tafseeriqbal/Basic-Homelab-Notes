# Running 4 services on 4GB RAM

Pi-hole, a Minecraft server, WebDAV, and a git mirror running on a 2009
Toshiba laptop(dual-core Pentium, 3.8GB usable RAM, no VT-x), and an SSD
salvaged from a damaged laptop. 

```
   laptop ─┐
   phone ──┼── tailnet (WireGuard mesh) ── server ─┬─ Minecraft  :25565
  friend ──┘                                       ├─ WebDAV     :8443
                                                   └─ git mirror (outbound)

       LAN ─────────────────────────────────────── Pi-hole      :53

```

## What runs on it

| Service | Purpose | RSS | Reachable from |
|---|---|---|---|
| Minecraft (Paper) | Two-player world | 1.5 GB | Tailnet only |
| Tailscale | Mesh VPN, 4 nodes | 88 MB | — |
| Pi-hole | Whole-house DNS filtering | 65 MB | LAN, port 53 |
| fail2ban | SSH brute-force protection | 21 MB | — |
| Apache + WebDAV | Org files to phone over TLS | 10 MB | Tailnet only |
| git mirror | Syncs a private repo every 5 min | negligible | outbound only |

Measured with `systemd-cgtop -m`. Total used: 1.9GB of 3.8GB.
Swap: 768KB after 36 hours uptime.

## Hardware

- Toshiba Satellite L500, Pentium T4400 dual-core, 3.8GB usable (4GB hard cap)
- No VT-x, so no virtualisation 
- 256GB SSD, replacing a failing 2009 HDD
- Ubuntu Server 24.04 LTS, clean install
- 233GB filesystem, 7.8GB used

## The memory budget

3.8GB total, and the OS plus base
services take roughly 400MB before anything useful runs.

What that leaves, and where it goes:

```
total            3.8 GB
OS + base       ~0.4 GB
Minecraft        1.5 GB     
everything else ~0.2 GB
headroom         1.9 GB
```

## Network design

### No port forwarding

A WireGuard-based mesh VPN (Tailscale). Both players join the
tailnet; the server is reachable on its tailnet address.
Remote admin works from anywhere with no router config, using node sharing to
grant the second player access without giving them an account on the box.

Four nodes on the tailnet: this server, an Arch laptop, a Windows
machine, and my iphone.

### Pi-hole as household DNS

The router's DNS relay was disabled and its WAN DNS fields pointed at the
server, so every device on the network resolves through Pi-hole. No
per-device configuration.

### netplan

Ethernet (`enp14s0`) is primary with a DHCP reservation. WiFi
(`wlp20s0`) remains configured as fallback at metric 700, so the box
stays reachable if someone unplugs the cable. Pi-hole breaks if the
server's address changes, which is why the reservation is load-bearing
rather than cosmetic.

## Services

### Minecraft (Paper)

Paper 26.2 under a systemd unit with Aikar's GC flags,
`-Xms1G -Xmx1536M`, `Restart=on-failure`, `RestartSec=30`.
`ExecStop` sends SIGINT so the world flushes rather than being killed.

World state was migrated off of Aternos: stop server, export
the world directory and `server.properties`, import. Self-hosted since
I did not want to keep having to mute their advertisements, no wait time 
for the server to start, full control of the data, etc. also thought it would
be a pretty cool way to make use of my old laptop. 

Side effect worth knowing: the exported world carried duplicate entity
UUIDs, which the server logs as warnings and resolves by dropping the
duplicate. Artifact of the export, not of the migration method.

### Pi-hole

Whole-house DNS filtering, ~65MB resident. Holds ports 53, 80 and 443.

### WebDAV

Apache serving a directory of org-mode files over TLS, basic auth,
reachable only over the tailnet. An org-mode client on the phone reads
and writes them; the agenda and reminders work without a cloud provider
ever holding the files.

The certificate is issued by Tailscale 

Apache costs under 10MB for this.

### git mirror

The server keeps its own clone of a private notes repository and runs a
systemd timer every five minutes: pull, commit anything changed, push.

The sync chain is laptop → remote → server → phone. It's eventually
consistent, not instant — a change made on the laptop reaches the phone
in under ten minutes. For reading a schedule that's fine; for
collaborative editing it would not be.

Concurrent edits on two devices produce a rebase conflict, at which point
the timer silently stops syncing until it's resolved by hand.

## Incidents

### JVM heap OOM on a 4GB box

First config used `-Xms2G -Xmx2G`. The server died mid-session with two
players on: 2.9GB used of 3.8GB, 227MB free. JVM heap plus OS plus
off-heap overhead exceeded physical RAM.

Now `-Xms1G -Xmx1536M`. Stable since — 768KB of swap used after 36 hours
uptime, which is the measurement that says the fix held. The tradeoff is
more frequent GC pauses, which is strictly better than the OOM killer
terminating the process mid-save.

### Port conflicts with the DNS resolver

Apache refused to start:

```
(98)Address already in use: AH00072: make_sock: could not bind to address 0.0.0.0:80
no listening sockets available, shutting down
```

`ss -tlnp` showed `pihole-FTL` holding port 80 for its admin interface.
Commented `Listen 80` out of Apache's `ports.conf` and moved the vhost to
a high port.

### A client that refuses to make the request

The phone's org-mode client wouldn't sync. No error worth reading, and —
critically — **no entry in Apache's access log at all.** The request was
never being made.

iOS App Transport Security refuses plain HTTP from third-party apps.
Safari is exempt, which is why the same URL loaded fine in a browser and
proved nothing.

Adding a self-signed certificate didn't fix it either; the client
rejected that too, despite having an "allow untrusted certificate"
setting. What worked was a real certificate — Tailscale can provision a
Let's Encrypt cert for a `.ts.net` hostname, which iOS trusts without
manual installation.

## Backups

The SSD was from an unused laptop I had laying around.

- Nightly `tar.gz` of world data via cron at 04:00
- 14-day local retention via `find -mtime +14 -delete`
- Offsite copy to cloud storage via rclone, 30-day retention

**Known limitation:** the backup runs against a live server with no
`save-off` / `save-on` flush around it, so `tar` could read a chunk file
mid-write and produce an inconsistent snapshot. Fixing it properly needs RCON so the
script can pause saving.

The org repository is backed up differently: it's a git repo
with a remote, so every five-minute sync is an offsite commit with full
history.

## Security posture

**Authentication.** SSH is key-only — `PasswordAuthentication no` and
`PermitRootLogin no`. fail2ban on top of that. UFW defaults to deny
inbound.

**Least privilege for the second player.** They get access via tailnet
node sharing, not an account on the host. They can reach the game port.
They cannot SSH in.

**Patching.** `unattended-upgrades` applies security updates without me
remembering to.

**Availability and integrity.** systemd restarts services on failure;
`ExecStop` sends SIGINT so the world is flushed rather than killed.
Lid-close suspend is disabled in `logind.conf`.

**Credential handling.** The rclone config holds live OAuth tokens for
the backup target.

## Known gaps

- **No host logging or alerting.** Auth events and service restarts go
  nowhere but the local journal. Nothing watches, nothing notifies. This
  is the largest gap and the reason this is an ops build rather than a
  security one.
- **Pi-hole is a single point of failure** 
- **Backups are not crash-consistent** 
- **Single point of failure throughout:** 
- **No resource limits on any systemd unit.** 

## Repository contents

```
config/     apache webdav vhost + ports.conf, sshd hardening,
            pi-hole blocklists, setupVars and dnsmasq templates
systemd/    minecraft.service
scripts/    mc-backup.sh, setup-pihole.sh, ufw-rules.sh
crontab.example
```

All hostnames, addresses, usernames and credentials are replaced with
placeholders.

## Scope

This is ops configuration, not application code. For code, see
[doodoo](https://github.com/tafseeriqbal/doodoo) — a terminal TODO
manager in C++/ncurses.
