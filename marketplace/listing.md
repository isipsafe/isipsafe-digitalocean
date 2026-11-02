# Marketplace listing: isIPsafe Protected Ubuntu

Copy for the DigitalOcean Vendor Portal. Items marked **TO CONFIRM** need a decision before you submit.

## Basics

| Field | Value |
| --- | --- |
| App name | isIPsafe Protected Ubuntu |
| Version | 0.1.0 |
| Category | Security |
| Operating system | Ubuntu 24.04 LTS (x64) |
| Vendor | WaveCentric |
| Website | https://isipsafe.com |
| Documentation | https://github.com/isipsafe/isipsafe-digitalocean |
| Terms of service | https://isipsafe.com/terms |
| Privacy policy | https://isipsafe.com/privacy |
| Minimum Droplet | Basic, 1 vCPU / 1 GB (built on `s-1vcpu-1gb`, so it runs on every plan) |
| Pricing | Free. The isIPsafe API key is free. |
| Managed database offer | None |

## Summary (one line)

Ubuntu 24.04 that blocks known attackers and reports the ones that hit it: ufw, fail2ban, automatic security updates and the isIPsafe blocklist, ready on first boot.

## Description

isIPsafe Protected Ubuntu is a plain Ubuntu 24.04 LTS server that is protected from the moment it boots, so you can install your own software on top.

- **Firewall on by default.** ufw blocks every incoming port except SSH.
- **Brute-force protection.** fail2ban watches SSH logins and bans addresses after repeated failures.
- **Community blocklist.** Every 30 minutes the Droplet downloads the [isIPsafe](https://isipsafe.com) list of high-confidence attackers and drops their traffic in the kernel with nftables, before it reaches SSH or any service you add.
- **Report attackers back.** Each address fail2ban bans is reported to isIPsafe, so every other server using the list is warned too.
- **Safe by design.** Open SSH sessions are never cut and your own address can be allowlisted. Private and reserved ranges are never blocked. If the list cannot be downloaded, the last good list stays in place.
- **Patched automatically.** unattended-upgrades installs Ubuntu security updates every day.
- **isipsafe command line.** Look up any address with `isipsafe check 203.0.113.7`.

isIPsafe is a free IP reputation and abuse reporting service. Reporting and the blocklist need a free API key from https://isipsafe.com/login. Without a key, the Droplet still runs with ufw, fail2ban and automatic updates.

## Software included

| Software | Version | Licence |
| --- | --- | --- |
| Ubuntu Server | 24.04 LTS | Various open-source licences |
| isipsafe (CLI and Python client) | 0.1.0 | MIT |
| isIPsafe image scripts | 0.1.0 | MIT |
| fail2ban | 1.0.2 | GPL-2.0 |
| nftables | 1.0.9 | GPL-2.0 |
| ufw | 0.36.2 | GPL-3.0 |
| unattended-upgrades | 2.9.1 | GPL-2.0 |
| Python | 3.12 | PSF-2.0 |
| OpenSSH | 9.6p1 | BSD |

Versions are the Ubuntu 24.04 packages at build time. `unattended-upgrades` keeps them patched afterwards.

## Getting started (shown after the Droplet is created)

1. **Get a free isIPsafe API key** at https://isipsafe.com/login.
2. **Log in** to your Droplet as root:
   `ssh root@your_droplet_public_ipv4`
3. **Answer the setup questions.** On the first login, the setup script asks for your API key and whether to report bans, use the blocklist and allowlist your current address. To skip it, press Enter. To run it again later: `/opt/isipsafe/setup.sh`
4. **Check that it works:**
   - `isipsafe-blocklist status` shows the last update and how many packets were dropped
   - `fail2ban-client status sshd` lists the current SSH bans
   - `ufw status` lists the open ports
5. **Open ports for your apps:** for example `ufw allow 80/tcp` and `ufw allow 443/tcp`.

**Skip the prompt with User data.** Paste this into User data when you create the Droplet:

```yaml
#cloud-config
write_files:
  - path: /etc/isipsafe/env
    permissions: "0600"
    content: |
      ISIPSAFE_API_KEY=your_key_here
```

**Settings** are in `/etc/isipsafe/env`. Addresses that must never be blocked go in `/etc/isipsafe/allowlist`; apply changes with `systemctl reload isipsafe-firewall`. If you are ever locked out, open the Droplet Console in the control panel and run `systemctl stop isipsafe-firewall`.

## Support

| Field | Value |
| --- | --- |
| Support | https://isipsafe.com/contact (**TO CONFIRM**: DigitalOcean asks for a support email; decide which one to use) |
| Support URL | https://github.com/isipsafe/isipsafe-digitalocean/issues (**TO CONFIRM**: the repository is not public yet) |
| Security reports | https://isipsafe.com/contact |
| Documentation | https://github.com/isipsafe/isipsafe-digitalocean#readme |

## Assets still needed for the Vendor Portal

- Logo: square PNG or SVG (**TO CONFIRM**: check the current size requirements in the Vendor Portal).
- Two or three screenshots, for example the first-login setup, the MOTD and `isipsafe-blocklist status`.
- The snapshot ID from `packer build`. It must be shared with or transferred to the Marketplace team, as the Vendor Portal explains.
