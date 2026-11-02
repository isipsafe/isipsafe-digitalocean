#!/usr/bin/env bash
set -euo pipefail

readonly PREFIX=/opt/isipsafe
readonly VENV="$PREFIX/venv"
readonly BASHRC_HOOK='[ -x /opt/isipsafe/setup.sh ] && /opt/isipsafe/setup.sh --first-login'
readonly SYSTEMD_DIR=/etc/systemd/system

python3 -m venv "$VENV"
"$VENV/bin/pip" install --quiet --disable-pip-version-check --no-cache-dir \
  --require-hashes --only-binary :all: -r "$PREFIX/requirements.txt"
"$VENV/bin/isipsafe" --version

chown -R root:root "$PREFIX" /etc/isipsafe
chmod 755 "$PREFIX" "$PREFIX/bin"
chmod 755 "$PREFIX/setup.sh" "$PREFIX"/bin/*
chmod 644 "$PREFIX/requirements.txt"
ln -sf "$PREFIX/bin/isipsafe" /usr/local/bin/isipsafe
ln -sf "$PREFIX/bin/isipsafe-blocklist" /usr/local/sbin/isipsafe-blocklist

chmod 700 /etc/isipsafe
chmod 600 /etc/isipsafe/env.example /etc/isipsafe/allowlist /etc/isipsafe/isipsafe.nft
rm -f /etc/isipsafe/env
install -d -m 700 -o root -g root /var/lib/isipsafe
find /var/lib/isipsafe -mindepth 1 -delete

chmod 644 /etc/fail2ban/action.d/isipsafe.conf /etc/fail2ban/jail.d/isipsafe.local
chmod 644 "$SYSTEMD_DIR"/isipsafe-firewall.service "$SYSTEMD_DIR"/isipsafe-blocklist.service "$SYSTEMD_DIR"/isipsafe-blocklist.timer
chmod 755 /etc/update-motd.d/99-isipsafe
chmod 755 /var/lib/cloud/scripts/per-instance/001_onboot

if ! grep -qxF "$BASHRC_HOOK" /root/.bashrc; then
  printf '\n%s\n' "$BASHRC_HOOK" >>/root/.bashrc
fi

if [ -d /run/systemd/system ]; then
  systemctl daemon-reload
  systemctl enable isipsafe-firewall.service fail2ban.service
  systemctl disable --now nftables.service 2>/dev/null || true
  systemctl restart fail2ban.service
fi
