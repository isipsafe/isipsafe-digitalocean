# isIPsafe Protected Ubuntu for DigitalOcean

A DigitalOcean Marketplace 1-Click Droplet: Ubuntu 24.04 LTS that is hardened from the first boot and connected to [isIPsafe](https://isipsafe.com), the free IP reputation and abuse reporting service.

This repository holds the image definition (Packer template, provisioning scripts and the files copied into the image), the Marketplace listing copy and the tests.

## What the Droplet does

| Layer | What it does |
| --- | --- |
| **ufw** | Denies all incoming traffic except SSH (OpenSSH profile, IPv4 and IPv6). |
| **fail2ban** | `sshd` jail on the systemd journal. Bans repeat offenders with nftables (1 hour, doubling for repeat offenders up to a week) and reports each ban to isIPsafe as `ssh,brute-force`. |
| **isIPsafe blocklist** | An `inet isipsafe` nftables table drops traffic from the isIPsafe blocklist. A systemd timer refreshes it every 30 minutes. |
| **Automatic updates** | `unattended-upgrades` installs security updates every day. |
| **isipsafe CLI** | `isipsafe check <ip>`, `isipsafe report ...` and the rest of the [isipsafe](https://pypi.org/project/isipsafe/) tool (0.1.0, in a venv at `/opt/isipsafe/venv`). |

Everything that talks to isIPsafe needs a free API key from [isipsafe.com/login](https://isipsafe.com/login). Without a key, the Droplet still has ufw, fail2ban and automatic updates. The isIPsafe parts do nothing until you add a key.

### Safety rules for the blocklist

The blocklist must never lock you out of your Droplet or leave it unprotected:

- **Established connections are accepted first.** An SSH session that is already open keeps working, even if its address joins the list.
- **An allowlist comes before the drop rules.** `/etc/isipsafe/allowlist` is checked first. The setup script offers to add the address you are connected from.
- **Only public addresses are loaded.** Private, loopback, link-local, CGNAT, reserved and documentation ranges are never blocked. Networks wider than /16 (IPv4) or /32 (IPv6) are ignored.
- **The list is swapped in one step.** Each update replaces the sets in a single atomic nftables transaction.
- **A failed update changes nothing (fail open).** If the download fails, or returns an empty or unreadable list, the last good list stays loaded. The table is never flushed to empty because of an error.
- **The last good list survives a reboot.** It is cached in `/var/lib/isipsafe` and loaded at boot, before the network comes up.
- **No key, no blocking.** Updates are skipped until a key is configured.

The table runs at priority `filter - 10`, so it is checked before ufw. It only drops traffic; it never accepts traffic that ufw would refuse. The stock `nftables.service` stays disabled, because its `/etc/nftables.conf` flushes the whole ruleset.

The blocklist is downloaded as `format=txt` rather than `format=nftables`. That way every entry is validated, filtered and collapsed locally, and loaded into sets this image owns.

## Using the Droplet

### First login

The first time you SSH in as root, `/opt/isipsafe/setup.sh` asks for:

1. Your API key. It is entered hidden and checked against the API with a read-only request.
2. Whether to report fail2ban bans.
3. Whether to use the blocklist.
4. Whether to allowlist the address you are connected from.

It writes `/etc/isipsafe/env` (mode 600, root only) and enables the timer and jail. If you press Enter without a key, the prompt does not come back. Run `/opt/isipsafe/setup.sh` again at any time to change the settings.

### Without logging in (user data)

Paste one of these into **User data** when you create the Droplet. The key ends up in `/etc/isipsafe/env` and the first-boot script turns everything on.

```yaml
#cloud-config
write_files:
  - path: /etc/isipsafe/env
    permissions: "0600"
    owner: root:root
    content: |
      ISIPSAFE_API_KEY=sl_your_key_here
      ISIPSAFE_ALLOW_IPS=203.0.113.10
```

Or as a script:

```bash
#!/bin/bash
ISIPSAFE_API_KEY=sl_your_key_here ISIPSAFE_ALLOW_IPS=203.0.113.10 /opt/isipsafe/setup.sh --non-interactive
```

User data can be read from inside the Droplet through the metadata service at `169.254.169.254`. If other people have accounts on the Droplet, use the interactive setup instead, or rotate the key afterwards.

### Settings

`/etc/isipsafe/env` (see `/etc/isipsafe/env.example`):

| Variable | Default | Meaning |
| --- | --- | --- |
| `ISIPSAFE_API_KEY` | | Your key. Required for reporting and the blocklist. |
| `ISIPSAFE_REPORT` | `yes` | Report addresses banned by fail2ban. |
| `ISIPSAFE_BLOCKLIST` | `yes` | Drop traffic from the blocklist. |
| `ISIPSAFE_BLOCKLIST_CONFIDENCE` | `90` | Minimum abuse confidence score (1-100). The API default is 75; a firewall that drops traffic uses a stricter default. |
| `ISIPSAFE_BLOCKLIST_DAYS` | `30` | Only addresses reported in the last N days (1-90). |
| `ISIPSAFE_BLOCKLIST_LIMIT` | `10000` | Maximum number of entries (up to 500000). |
| `ISIPSAFE_BLOCKLIST_EXCEPT_COUNTRIES` | | ISO country codes never to block, for example `GB,IE`. |

### Useful commands

```bash
isipsafe check 203.0.113.7                 # reputation of an address (uses your key)
isipsafe-blocklist status                  # last update, drop counters
systemctl start isipsafe-blocklist         # update the blocklist now
systemctl list-timers isipsafe-blocklist.timer
fail2ban-client status sshd                # current SSH bans
journalctl -t isipsafe-fail2ban            # reports sent to isIPsafe
nano /etc/isipsafe/allowlist && systemctl reload isipsafe-firewall
```

### Turning parts off

```bash
systemctl disable --now isipsafe-blocklist.timer isipsafe-firewall   # remove the blocklist table
sed -i 's/^ISIPSAFE_REPORT=.*/ISIPSAFE_REPORT=no/' /etc/isipsafe/env    # stop reporting
```

If you are ever locked out, open the **Droplet Console** in the DigitalOcean control panel and run `systemctl stop isipsafe-firewall`.

## Files in the image

```
/opt/isipsafe/venv/                         isipsafe 0.1.0 (pip, hash-pinned)
/opt/isipsafe/setup.sh                      first-login and non-interactive setup
/opt/isipsafe/bin/isipsafe-blocklist        start | update | allowlist | stop | status
/opt/isipsafe/bin/isipsafe-nft-elements     validates a list and renders it as nft commands
/opt/isipsafe/bin/isipsafe-fail2ban-report  fail2ban action helper (always exits 0)
/usr/local/bin/isipsafe                     CLI wrapper that reads the key from /etc/isipsafe/env
/usr/local/sbin/isipsafe-blocklist          link to /opt/isipsafe/bin/isipsafe-blocklist
/etc/isipsafe/                              env (created by setup), allowlist, isipsafe.nft
/etc/fail2ban/action.d/isipsafe.conf        reporting action
/etc/fail2ban/jail.d/isipsafe.local         sshd jail, nftables ban actions
/etc/systemd/system/isipsafe-*              firewall service, blocklist service and timer
/etc/update-motd.d/99-isipsafe              login status
/var/lib/cloud/scripts/per-instance/001_onboot
```

## Repository layout

The layout follows [digitalocean/marketplace-partners](https://github.com/digitalocean/marketplace-partners).

```
isipsafe.pkr.hcl          Packer template (digitalocean builder)
scripts/01-isipsafe.sh    venv, permissions, units, first-login hook
scripts/02-hardening.sh   ufw and unattended-upgrades
scripts/90-cleanup.sh     DigitalOcean cleanup script, unmodified (Apache-2.0)
scripts/99-img-check.sh   DigitalOcean image validation, unmodified (Apache-2.0)
files/                    copied into / on the build Droplet
marketplace/listing.md    Marketplace listing copy
tests/                    container tests
third_party/              licence of the vendored DigitalOcean scripts
```

## Building the image

> Building creates a real Droplet and a snapshot in your DigitalOcean account, and they cost money while they exist. The tests below do not need DigitalOcean.

Requirements: [Packer](https://developer.hashicorp.com/packer/install) 1.10 or later, and a DigitalOcean personal access token with write scope. Version 0.1.0 of `isipsafe` must also be on PyPI; `files/opt/isipsafe/requirements.txt` pins it by SHA-256.

```bash
export DIGITALOCEAN_TOKEN=dop_v1_...          # never commit this
packer init isipsafe.pkr.hcl
packer validate isipsafe.pkr.hcl
packer build isipsafe.pkr.hcl
```

The build:

1. starts a `s-1vcpu-1gb` Droplet from `ubuntu-24-04-x64` in `nyc3`
2. waits for cloud-init and copies `files/`
3. fully upgrades the OS and installs the packages
4. runs the scripts, ending with DigitalOcean's cleanup and `99-img-check.sh`
5. powers off and saves a snapshot named `isipsafe-ubuntu-24-04-<timestamp>`

To override a setting, pass `-var region=fra1` (or `size`, `base_image`, `application_version`).

When releasing a new `isipsafe` version, update the pin and both hashes in `requirements.txt`:

```bash
pip download --no-deps isipsafe==X.Y.Z -d /tmp/isipsafe-dl && pip hash /tmp/isipsafe-dl/*
```

## Submitting to the DigitalOcean Marketplace

1. Ask for vendor access at [marketplace.digitalocean.com/vendors](https://marketplace.digitalocean.com/vendors). You get a login for the [Vendor Portal](https://cloud.digitalocean.com/vendorportal). If it does not arrive, email one-clicks-team@digitalocean.com.
2. Build the snapshot as described above, then boot a test Droplet from it and check it by hand: the first-login prompt, `isipsafe-blocklist status` and `fail2ban-client status sshd`.
3. In the Vendor Portal, create a Droplet 1-Click App and select the snapshot. Paste the copy from [`marketplace/listing.md`](marketplace/listing.md), and add the logo, screenshots and support details.
4. Submit for review. DigitalOcean runs its own image checks. For later versions, rebuild and submit the new snapshot as an update.

## Development and tests

All the tests run locally in Docker. None of them talk to DigitalOcean, and none can reach the real isIPsafe API: inside the test containers `isipsafe.com` points at localhost and a local mock serves the blocklist.

```bash
# template (validate runs with networking disabled and a dummy token)
docker run --rm -v "$PWD:/work" -w /work -e PACKER_PLUGIN_PATH=/work/.packer.d hashicorp/packer:1.11.2 init isipsafe.pkr.hcl
docker run --rm -v "$PWD:/work" -w /work hashicorp/packer:1.11.2 fmt -check -diff isipsafe.pkr.hcl
docker run --rm --network none -v "$PWD:/work" -w /work -e PACKER_PLUGIN_PATH=/work/.packer.d \
  -e DIGITALOCEAN_TOKEN=dummy hashicorp/packer:1.11.2 validate isipsafe.pkr.hcl

# shell scripts
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:v0.10.0 -x -P SCRIPTDIR \
  scripts/01-isipsafe.sh scripts/02-hardening.sh files/opt/isipsafe/setup.sh files/opt/isipsafe/lib/common.sh \
  files/opt/isipsafe/bin/isipsafe files/opt/isipsafe/bin/isipsafe-blocklist \
  files/opt/isipsafe/bin/isipsafe-fail2ban-report files/etc/update-motd.d/99-isipsafe \
  files/var/lib/cloud/scripts/per-instance/001_onboot tests/*.sh

# provisioning in ubuntu:24.04: packages, file layout, fail2ban -t, nft rules, fail-open updates, setup.sh
./tests/container-test.sh

# the same with systemd as PID 1: units, sandbox, timer, a real fail2ban ban (needs --privileged)
./tests/systemd-test.sh
```

Before `isipsafe` 0.1.0 is on PyPI, point both container tests at a local wheel, for example `ISIPSAFE_WHEELS=../isipsafe-python/dist ./tests/container-test.sh`. The wheel is still checked against the pinned hash.

The two vendored DigitalOcean scripts are kept byte-for-byte as published. They are linted separately, at warning level.

## Links

- isIPsafe: [isipsafe.com](https://isipsafe.com) · API: [isipsafe.com/api](https://isipsafe.com/api) · Python client: [isipsafe-python](https://github.com/isipsafe/isipsafe-python)
- Security issues: see [SECURITY.md](SECURITY.md)

## Licence

MIT, see [LICENSE](LICENSE). `scripts/90-cleanup.sh` and `scripts/99-img-check.sh` are © DigitalOcean LLC under the Apache License 2.0 ([third_party/digitalocean-marketplace-partners/LICENSE.md](third_party/digitalocean-marketplace-partners/LICENSE.md)). Data returned by the isIPsafe API is covered by the [isIPsafe EULA](https://isipsafe.com/eula).
