# Security policy

Please do not open a public issue for security problems.

Report vulnerabilities in this image definition, its scripts or the isIPsafe service privately through GitHub: open this repository's **Security** tab and choose **Report a vulnerability**. You can also use the form at https://isipsafe.com/contact. We will reply as soon as we can and keep you updated until the issue is fixed.

Only the latest published image receives fixes. Droplets created from an older image keep receiving Ubuntu security updates through `unattended-upgrades`. To pick up fixes to the isIPsafe scripts, recreate the Droplet from the latest image.

## How the image handles your API key

- It is stored only in `/etc/isipsafe/env`, mode 600, owned by root.
- It is sent to the API in an `Authorization: Bearer` header, never in a URL or on a command line.
- It is never written to logs, the MOTD or the setup output, and the interactive prompt hides it as you type.
- No key is baked into the image. The build removes `/etc/isipsafe/env`, and DigitalOcean's cleanup script removes SSH keys, shell history and logs.
