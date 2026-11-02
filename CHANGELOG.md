# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-11-02

### Added

- Packer template (`isipsafe.pkr.hcl`) for the "isIPsafe Protected Ubuntu" 1-Click Droplet, based on Ubuntu 24.04 LTS, using the DigitalOcean builder.
- ufw allowing only SSH, and `unattended-upgrades` enabled.
- fail2ban `sshd` jail on the systemd journal with nftables bans and an `isipsafe` action that reports bans as `ssh,brute-force`.
- `inet isipsafe` nftables table, refreshed every 30 minutes by a systemd timer. The blocklist fails open: established connections are accepted first, the allowlist comes before the drop rules, private and reserved ranges are filtered out, updates are atomic, the last good list is kept on any error and restored at boot.
- `/opt/isipsafe/setup.sh`, run on first login, plus non-interactive setup from Droplet user data.
- `isipsafe` 0.1.0 CLI in a hash-pinned venv, with a wrapper that reads the key from `/etc/isipsafe/env`.
- DigitalOcean's `90-cleanup.sh` and `99-img-check.sh`, unmodified.
- Docker-based tests: provisioning in `ubuntu:24.04`, and the same with systemd as PID 1.
- Marketplace listing copy.
