# Running 4 services on 4GB RAM

Pi-hole, a Minecraft server, WebDAV, and a git mirror running on a 2009
Toshiba laptop — dual-core Pentium, 3.8GB usable RAM, no VT-x, and an SSD
salvaged from a machine that had already died. Nothing is exposed to the
internet.

The interesting constraint isn't the CPU. It's that one service takes 79%
of the memory and the other three cost less than 210MB combined.

```
   laptop ─┐
   phone ──┼── tailnet (WireGuard mesh) ── server ─┬─ Minecraft  :25565
  friend ──┘                                       ├─ WebDAV     :8443
                                                   └─ git mirror (outbound)

       LAN ─────────────────────────────────────── Pi-hole      :53

  internet ──✕── no inbound. nothing forwarded.
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
- No VT-x, so no virtualisation — everything runs on the host
- 256GB SSD salvaged from a dead laptop, replacing a failing 2009 HDD
- Ubuntu Server 24.04 LTS, clean install
- 233GB filesystem, 7.8GB used

## The memory budget

This is the whole design problem. 3.8GB total, and the OS plus base
services take roughly 400MB before anything useful runs.

What that leaves, and where it goes:

```
total            3.8 GB
OS + base       ~0.4 GB
Minecraft        1.5 GB     ← 79% of everything in use
everything else ~0.2 GB
headroom         1.9 GB
```

Two things follow from this.

**One service dominates.** Minecraft is the budget. Pi-hole, WebDAV and
the git mirror together cost less than a sixth of what the game server
takes. Adding them was close to free — which is why "this box runs a
Minecraft server" undersells what it actually does.

**Heap size is bounded by the OS, not by installed RAM.** See Incidents
below. The rule I'd take from it: on a memory-capped host, you size a JVM
by what's left after everything else, not by what `free -h` reports as
total.

Docker is installed but disabled. It idles at roughly 100MB, which is
half the entire non-Minecraft footprint. On this box that's not a
reasonable trade for container convenience, so it stays stopped.

## Network design

### No port forwarding

The default advice is to forward 25565. That puts a Java process on a
public IP and makes you responsible for patching it forever.

Instead: a WireGuard-based mesh VPN (Tailscale). Both players join the
tailnet; the server is reachable on its tailnet address and nowhere else.
Public attack surface: zero. Remote admin works from anywhere with no
router config, using node sharing to grant the second player access
without giving them an account on the box.

Four nodes on the tailnet: this server, an Arch laptop, a Windows
machine, and a phone.

### Pi-hole as household DNS

The router's DNS relay was disabled and its WAN DNS fields pointed at the
server, so every device on the network resolves through Pi-hole. No
per-device configuration.

The tradeoff is explicit: **this box is now a single point of failure for
household DNS.** If it goes down, the house loses name resolution until
someone changes the router back. A secondary resolver is configured on
the router as fallback, but resolution quality degrades to unfiltered.

### The router got in the way

The ISP-supplied D-Link runs vendor firmware with several standard
features stripped out — including the DHCP reservation UI and the DNS
relay override. The reservation had to be set through the connected-
clients diagram on the Home tab rather than a normal DHCP page.

Worth knowing if you're on the same ISP: the features exist, they're just
not where the documentation says they are.

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

World state was migrated off a free third-party host: stop server, export
the world directory and `server.properties`, import. Self-hosted since —
no uptime limits, no queues, full control of the data.

Side effect worth knowing: the exported world carried duplicate entity
UUIDs, which the server logs as warnings and resolves by dropping the
duplicate. Artifact of the export, not of the migration method.

### Pi-hole

Whole-house DNS filtering, ~65MB resident. Holds ports 53, 80 and 443 —
which matters more than it sounds. See Incidents.

### WebDAV

Apache serving a directory of org-mode files over TLS, basic auth,
reachable only over the tailnet. An org-mode client on the phone reads
and writes them; the agenda and reminders work without a cloud provider
ever holding the files.

The certificate is issued by Tailscale (real Let's Encrypt, for the
`.ts.net` hostname), not self-signed. That was not a preference — see
Incidents.

Apache costs under 10MB for this. The cheapest service on the box.

### git mirror

The server keeps its own clone of a private notes repository and runs a
systemd timer every five minutes: pull, commit anything changed, push.

The sync chain is laptop → remote → server → phone. It's eventually
consistent, not instant — a change made on the laptop reaches the phone
in under ten minutes. For reading a schedule that's fine; for
collaborative editing it would not be.

Concurrent edits on two devices produce a rebase conflict, at which point
the timer silently stops syncing until it's resolved by hand. Known
sharp edge.

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

Then enabling `mod_ssl` caused the identical failure on 443 — the SSL
module activates a second `Listen` directive, and Pi-hole holds that port
too. Same fix.

The lesson isn't about Apache. On a single-host multi-service box, port
ownership is a shared resource with no central registry, and the failure
mode is a service that won't start with an error that names the port but
not the owner. `ss -tlnp` is the tool that closes that gap.

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

Two things worth taking from this:

1. `tail -f` on the access log during a failed attempt is what proved the
   request wasn't arriving. Without that, every fix would have been a
   guess about the server.
2. Tailscale's HTTPS feature publishes the machine's hostname to the
   Certificate Transparency log, permanently. The hostname includes a
   randomised tailnet ID and resolves only inside the tailnet, so the
   exposure is a name and nothing else — but it's a real tradeoff and
   it's irreversible.

## Backups

The SSD came out of a machine that already failed.

- Nightly `tar.gz` of world data via cron at 04:00
- 14-day local retention via `find -mtime +14 -delete`
- Offsite copy to cloud storage via rclone, 30-day retention
- Restore tested, not assumed

**Known limitation:** the backup runs against a live server with no
`save-off` / `save-on` flush around it, so `tar` could read a chunk file
mid-write and produce an inconsistent snapshot. The live world is never
at risk — the backup is read-only. Fixing it properly needs RCON so the
script can pause saving. Acceptable at 4am with two players; wrong for
anything that matters.

The org repository is backed up differently and better: it's a git repo
with a remote, so every five-minute sync is an offsite commit with full
history.

## Security posture

The threat model here is small but the decisions are real ones.

**No inbound attack surface.** Nothing is port-forwarded. Game and WebDAV
are reachable only over the WireGuard mesh; an internet-wide scan sees
nothing.

**Authentication.** SSH is key-only — `PasswordAuthentication no` and
`PermitRootLogin no`. fail2ban on top of that. UFW defaults to deny
inbound.

**Firewall scoped to the interface, not the port.** The rules that matter
are `allow in on tailscale0` rather than `allow <port>` — services meant
for the tailnet are not reachable from the LAN, even though the LAN is
nominally trusted. Getting this wrong once left WebDAV open to every
device in the house; it was a one-line fix and worth checking for.

**Least privilege for the second player.** They get access via tailnet
node sharing, not an account on the host. They can reach the game port.
They cannot SSH in.

**Patching.** `unattended-upgrades` applies security updates without me
remembering to.

**Availability and integrity.** systemd restarts services on failure;
`ExecStop` sends SIGINT so the world is flushed rather than killed.
Lid-close suspend is disabled in `logind.conf` — it's a laptop, and
closing it would otherwise put the server to sleep.

**Credential handling.** The rclone config holds live OAuth tokens for
the backup target. It is stored off-box and is not in this repo. Nothing
in this repository contains a hostname, an IP, a username or a
credential.

## Known gaps

Stated deliberately, because a writeup that lists no weaknesses isn't one.

- **No host logging or alerting.** Auth events and service restarts go
  nowhere but the local journal. Nothing watches, nothing notifies. This
  is the largest gap and the reason this is an ops build rather than a
  security one.
- **Pi-hole is a single point of failure** for household DNS.
- **Backups are not crash-consistent** (see above).
- **Single point of failure throughout:** one disk, one box, no
  redundancy of any kind.
- **The TLS certificate needs manual renewal** every ~90 days, plus an
  Apache restart to pick it up. Not automated, and it will fail silently
  when it lapses.
- **WebDAV uses basic auth.** Fine inside an encrypted mesh; wrong
  anywhere else.
- **No resource limits on any systemd unit.** One service can starve the
  others, which on a 3.8GB box is a realistic failure rather than a
  theoretical one.
- **The world runs in offline mode**, so in-game identity is unverified.
  Mitigated only by the fact that reaching the server requires tailnet
  membership.

## Repository contents

```
config/     pi-hole blocklists, setupVars and dnsmasq templates
systemd/    minecraft.service
scripts/    mc-backup.sh, setup-pihole.sh
crontab.example
```

All hostnames, addresses, usernames and credentials are replaced with
placeholders.

## Scope

This is ops configuration, not application code. For code, see
[doodoo](https://github.com/tafseeriqbal/doodoo) — a terminal TODO
manager in C++/ncurses.
