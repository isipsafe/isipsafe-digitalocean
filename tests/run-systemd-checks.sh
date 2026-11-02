#!/usr/bin/env bash
set -euo pipefail

readonly SRC="${SRC:-/src}"
readonly WHEELS="${WHEELS:-/wheels}"
readonly MOCK_DIR=/srv/mock-api
readonly MOCK_PORT=18080
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8

passed=0
step() { printf '\n== %s\n' "$*"; }
ok() {
  passed=$((passed + 1))
  printf 'ok   %s\n' "$*"
}
fail() {
  printf 'FAIL %s\n' "$*" >&2
  journalctl --no-pager -n 60 >&2 || true
  exit 1
}
expect() {
  local message="$1"
  shift
  if "$@"; then ok "$message"; else fail "$message"; fi
}
table_loaded() {
  nft list table inet isipsafe >/dev/null 2>&1
}
set_count() {
  nft -j list set inet isipsafe "$1" | python3 -c '
import json, sys
items = [i["set"] for i in json.load(sys.stdin)["nftables"] if "set" in i]
print(len(items[0].get("elem", [])))'
}
unit_prop() {
  systemctl show -p "$1" --value isipsafe-blocklist.service
}
not_activating() {
  [ "$(unit_prop ActiveState)" != activating ]
}
last_run_succeeded() {
  [ "$(unit_prop Result)" = success ]
}
last_run_failed() {
  [ "$(unit_prop Result)" != success ]
}
wait_for() {
  local tries="$1"
  shift
  for _ in $(seq 1 "$tries"); do
    if "$@"; then return 0; fi
    sleep 1
  done
  return 1
}

step "systemd is PID 1"
expect "systemd running" test -d /run/systemd/system

step "route isipsafe.com to localhost so nothing can reach the real API"
printf '127.0.0.1 isipsafe.com www.isipsafe.com\n::1 isipsafe.com www.isipsafe.com\n' >>/etc/hosts

step "provision like Packer: packages, files/, scripts"
apt-get -qq update
mapfile -t packages < <(sed -n '/^variable "apt_packages"/,/^}/p' "$SRC/isipsafe.pkr.hcl" | grep -oE '"[a-z0-9.+-]+"' | tr -d '"')
apt-get -qqy install --no-install-recommends "${packages[@]}" openssh-server rsyslog >/dev/null
cp -a "$SRC/files/etc/." /etc/
cp -a "$SRC/files/opt/." /opt/
cp -a "$SRC/files/var/." /var/
touch /root/.bashrc
if compgen -G "$WHEELS/isipsafe-*.whl" >/dev/null; then
  export PIP_NO_INDEX=1 PIP_FIND_LINKS="$WHEELS"
fi
bash "$SRC/scripts/01-isipsafe.sh"
unset PIP_NO_INDEX PIP_FIND_LINKS
bash "$SRC/scripts/02-hardening.sh" >/dev/null
expect "isipsafe-firewall.service enabled" systemctl is-enabled --quiet isipsafe-firewall.service
expect "fail2ban enabled" systemctl is-enabled --quiet fail2ban.service
expect "nftables.service (flushes the ruleset) stays disabled" bash -c '! systemctl is-enabled --quiet nftables.service'
expect "timer not enabled before a key exists" bash -c '! systemctl is-enabled --quiet isipsafe-blocklist.timer'

step "fail2ban runs with the systemd backend"
expect "fail2ban active" wait_for 30 systemctl is-active --quiet fail2ban.service
expect "sshd jail loaded" wait_for 30 bash -c 'fail2ban-client status sshd >/dev/null 2>&1'

step "firewall unit"
systemctl start isipsafe-firewall.service
expect "isipsafe-firewall.service active" systemctl is-active --quiet isipsafe-firewall.service
expect "table loaded by the unit" table_loaded

step "mock API"
mkdir -p "$MOCK_DIR/api/v1"
cp "$SRC/tests/fixtures/blocklist.txt" "$MOCK_DIR/api/v1/blocklist"
printf '{"data":[]}' >"$MOCK_DIR/api/v1/categories"
systemd-run --unit isipsafe-mock-api --property=StandardOutput=file:/var/log/mock-api.log \
  --property=StandardError=file:/var/log/mock-api.log \
  python3 -m http.server "$MOCK_PORT" --bind 127.0.0.1 --directory "$MOCK_DIR" >/dev/null
expect "mock API up" wait_for 20 curl -fsS -o /dev/null "http://127.0.0.1:$MOCK_PORT/api/v1/categories"

step "setup.sh --non-interactive enables everything"
ISIPSAFE_API_KEY=sl_systemd_dummy_key ISIPSAFE_ALLOW_IPS=198.51.100.5 /opt/isipsafe/setup.sh --non-interactive
printf 'ISIPSAFE_BASE_URL=http://127.0.0.1:%s/api/v1\n' "$MOCK_PORT" >>/etc/isipsafe/env
expect "timer enabled" systemctl is-enabled --quiet isipsafe-blocklist.timer
expect "timer active" systemctl is-active --quiet isipsafe-blocklist.timer
systemctl list-timers isipsafe-blocklist.timer --no-pager

step "blocklist service runs inside its sandbox"
wait_for 60 not_activating
systemctl reset-failed isipsafe-blocklist.service 2>/dev/null || true
systemctl start isipsafe-blocklist.service || true
expect "service succeeded" last_run_succeeded
expect "IPv4 set filled by the service" test "$(set_count block4)" -eq 5
expect "IPv6 set filled by the service" test "$(set_count block6)" -eq 1
expect "cache written under ProtectSystem=strict" test -s /var/lib/isipsafe/blocklist.nft
expect "allowlist loaded" bash -c 'nft list set inet isipsafe allow4 | grep -q 198.51.100.5'

step "failed download under systemd keeps the list"
systemctl stop isipsafe-mock-api
systemctl start isipsafe-blocklist.service || true
expect "service reports the failure" last_run_failed
expect "entries kept" test "$(set_count block4)" -eq 5
journalctl -u isipsafe-blocklist.service --no-pager -n 5 | tail -3

step "restart of the firewall unit (reboot path) restores the cached list"
systemctl restart isipsafe-firewall.service
expect "entries restored from the cache" test "$(set_count block4)" -eq 5
systemctl reload isipsafe-firewall.service
ok "reload works"

step "a real fail2ban ban runs the isipsafe action"
systemd-run --unit isipsafe-mock-api2 --property=StandardOutput=file:/var/log/mock-api.log \
  --property=StandardError=file:/var/log/mock-api.log \
  python3 -m http.server "$MOCK_PORT" --bind 127.0.0.1 --directory "$MOCK_DIR" >/dev/null
wait_for 20 curl -fsS -o /dev/null "http://127.0.0.1:$MOCK_PORT/api/v1/categories"
fail2ban-client set sshd banip 45.155.205.233 >/dev/null
expect "banned address is in the fail2ban nftables set" wait_for 15 bash -c 'nft list table inet f2b-table 2>/dev/null | grep -q 45.155.205.233'
expect "isipsafe action posted the report (to the mock)" wait_for 30 grep -q '"POST /api/v1/report' /var/log/mock-api.log
expect "action failure was logged, not fatal" wait_for 15 bash -c 'journalctl -t isipsafe-fail2ban --no-pager | grep -q "could not report 45.155.205.233"'
expect "fail2ban still running" systemctl is-active --quiet fail2ban.service

step "ufw and the isipsafe table coexist"
expect "ufw active" bash -c 'ufw status | grep -q "Status: active"'
expect "isipsafe table still present" table_loaded

step "MOTD"
/etc/update-motd.d/99-isipsafe

printf '\nall %d systemd checks passed\n' "$passed"
