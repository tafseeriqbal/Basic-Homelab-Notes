# Self-Hosted Server on Salvaged Hardware

A Minecraft (Paper) server for two players, running on a recovered 2009
laptop with zero ports exposed to the internet.

## Hardware
- Recovered laptop: dual-core, 4GB RAM (hard cap), no VT-x
- SSD salvaged from a dead machine, replacing a failing 2009 HDD
- Ubuntu Server 24.04 LTS, clean install

## Design decisions

### No port forwarding. Ever.
The default advice is to forward 25565. That puts a Java process on a
public IP and makes you responsible for patching it forever.

Instead: a WireGuard-based mesh VPN (Tailscale). Both players join the
tailnet; the server is reachable on its tailnet address and nowhere
else. Public attack surface: zero. Remote admin works from anywhere
with no router config, using node sharing to grant the second player
access without giving them an account on the box.

### SSH is key-only
Password auth disabled in `sshd_config`. UFW default-deny inbound.
`unattended-upgrades` enabled for security patches. Lid-close suspend
disabled in `logind.conf` — it's a laptop, and closing it would
otherwise put the server to sleep.

### Heap sizing on a 4GB box (learned the hard way)
First config used `-Xms2G -Xmx2G`. The server died mid-session with two
players on: 2.9GB used of 3.8GB, 227MB free. JVM heap plus OS plus
off-heap overhead exceeded physical RAM.

Now `-Xms1G -Xmx1536M`. Stable since. The tradeoff is more frequent GC
pauses, which is strictly better than the OOM killer terminating the
process mid-save. On a memory-capped host, heap size is bounded by what
the OS needs, not by what's installed.

### Backups assume the disk will die
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

### systemd, not tmux
`Restart=on-failure`, `RestartSec=30`, starts on boot. `ExecStop` sends
SIGINT so Paper shuts down cleanly and flushes the world rather than
being killed. The box can lose power and come back without me.

## Migration
World state was migrated off a free third-party host: stop server,
export the world directory and `server.properties`, import. Self-hosted
since — no uptime limits, no queues, full control of the data.

Side effect worth knowing: the exported world carried duplicate entity
UUIDs, which the server logs as warnings and resolves by dropping the
duplicate. Artifact of the export, not of the migration method.

## Security posture

The threat model here is small but the decisions are real ones.

**No inbound attack surface.** Nothing is port-forwarded. The service is
reachable only over a WireGuard mesh (Tailscale); an internet-wide scan
sees nothing. This is the single biggest difference between this build
and the standard "forward 25565" guide.

**Authentication.** SSH is key-only — password auth is disabled in
`sshd_config`, so credential stuffing and brute force are off the table
entirely. UFW defaults to deny inbound.

**Least privilege for the second user.** The other player gets access
via tailnet node sharing, not an account on the host. They can reach the
game port. They cannot SSH in.

**Patching.** `unattended-upgrades` applies security updates without me
remembering to.

**Availability and integrity.** systemd restarts the service on failure;
`ExecStop` sends SIGINT so the world is flushed rather than killed.
Backups are nightly, retained 14 days locally and 30 days offsite, and
the restore path has been tested — an untested backup is a guess.

**Credential handling.** The rclone config holds live OAuth tokens for
the backup target. It is stored off-box and is not in this repo. Nothing
in this repository contains a hostname, an IP, a username or a
credential.

### Known gaps

Stated deliberately, because a security writeup that lists no weaknesses
isn't one.

- No host logging or alerting. Auth events and service restarts go
  nowhere but the local journal.
- Backups are not crash-consistent (see above).
- Single point of failure: one disk, one box, no redundancy.
- The world runs in offline mode, so in-game identity is unverified.
  Mitigated only by the fact that reaching the server requires tailnet
  membership.

## Scope
This is ops configuration, not application code. For code, see
[doodoo](https://github.com/tafseeriqbal/doodoo) — a terminal TODO
manager in C++/ncurses.

