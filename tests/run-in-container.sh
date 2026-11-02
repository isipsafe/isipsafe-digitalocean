#!/usr/bin/env bash
set -euo pipefail

readonly SRC="${SRC:-/src}"
readonly WHEELS="${WHEELS:-/wheels}"
readonly MOCK_DIR=/tmp/mock-api
readonly MOCK_PORT=18080
readonly BL="/opt/isipsafe/bin/isipsafe-blocklist"
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8

passed=0
step() { printf '\n== %s\n' "$*"; }
ok() {
  passed=$((passed + 1))
  printf 'ok   %s\n' "$*"
}
fail() {
  printf 'FAIL %s\n' "$*" >&2
  exit 1
}
expect() {
  local message="$1"
  shift
  if "$@"; then ok "$message"; else fail "$message"; fi
}
installed() {
  dpkg -s "$1" >/dev/null 2>&1
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
set_has() {
  nft list set inet isipsafe "$1" | grep -qF -- "$2"
}

step "route isipsafe.com to localhost so no test can reach the real API"
printf '127.0.0.1 isipsafe.com www.isipsafe.com\n::1 isipsafe.com www.isipsafe.com\n' >>/etc/hosts

step "install packages (same list as the Packer template)"
apt-get -qq update
mapfile -t packages < <(sed -n '/^variable "apt_packages"/,/^}/p' "$SRC/isipsafe.pkr.hcl" | grep -oE '"[a-z0-9.+-]+"' | tr -d '"')
printf 'packages: %s\n' "${packages[*]}"
apt-get -qqy install --no-install-recommends "${packages[@]}" openssh-server systemd iproute2 util-linux bsdutils procps >/dev/null
for pkg in fail2ban nftables ufw unattended-upgrades python3-venv python3-systemd; do
  expect "package $pkg installed" installed "$pkg"
done

step "copy files/ into the image root, like the Packer file provisioners"
cp -a "$SRC/files/etc/." /etc/
cp -a "$SRC/files/opt/." /opt/
cp -a "$SRC/files/var/." /var/
touch /root/.bashrc

step "run scripts/01-isipsafe.sh"
if compgen -G "$WHEELS/isipsafe-*.whl" >/dev/null; then
  export PIP_NO_INDEX=1 PIP_FIND_LINKS="$WHEELS"
  echo "installing isipsafe from local wheels in $WHEELS (hash-checked)"
fi
bash "$SRC/scripts/01-isipsafe.sh"
unset PIP_NO_INDEX PIP_FIND_LINKS
expect "isipsafe 0.1.0 in the venv" bash -c '/opt/isipsafe/venv/bin/isipsafe --version | grep -q "0.1.0"'
expect "isipsafe wrapper on PATH" bash -c 'command -v isipsafe | grep -q /usr/local/bin/isipsafe && isipsafe --version >/dev/null'
expect "isipsafe-blocklist on root's PATH" test -x /usr/local/sbin/isipsafe-blocklist
expect "first-login hook in /root/.bashrc" grep -qxF '[ -x /opt/isipsafe/setup.sh ] && /opt/isipsafe/setup.sh --first-login' /root/.bashrc
bash "$SRC/scripts/01-isipsafe.sh" >/dev/null
expect "hook added only once when re-run" test "$(grep -c 'setup.sh --first-login' /root/.bashrc)" -eq 1
expect "/etc/isipsafe is 700" test "$(stat -c %a /etc/isipsafe)" = 700
expect "/var/lib/isipsafe is 700" test "$(stat -c %a /var/lib/isipsafe)" = 700
expect "/var/lib/isipsafe ships empty" test -z "$(ls -A /var/lib/isipsafe)"
expect "no env file shipped in the image" test ! -e /etc/isipsafe/env
for f in /opt/isipsafe/setup.sh /opt/isipsafe/bin/isipsafe-blocklist /opt/isipsafe/bin/isipsafe-fail2ban-report \
  /opt/isipsafe/bin/isipsafe-nft-elements /etc/update-motd.d/99-isipsafe /var/lib/cloud/scripts/per-instance/001_onboot; do
  expect "$f is executable" test -x "$f"
done

step "run scripts/02-hardening.sh"
bash "$SRC/scripts/02-hardening.sh"
expect "unattended upgrades enabled" grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades
expect "ufw active" bash -c 'ufw status | grep -q "Status: active"'
expect "ufw allows OpenSSH" bash -c 'ufw status | grep -q "^OpenSSH .*ALLOW"'
expect "ufw default deny incoming" bash -c 'ufw status verbose | grep -q "deny (incoming)"'

step "fail2ban configuration"
fail2ban-client -t
ok "fail2ban-client -t"
expect "sshd jail uses the isipsafe action" bash -c 'fail2ban-client -d 2>/dev/null | grep -q "isipsafe-fail2ban-report"'
expect "sshd jail reports ssh,brute-force" bash -c 'fail2ban-client -d 2>/dev/null | grep "isipsafe" | grep -q "ssh,brute-force"'
expect "sshd jail bans with nftables" bash -c 'fail2ban-client -d 2>/dev/null | grep -q "nftables"'

step "systemd units"
systemd-analyze verify /etc/systemd/system/isipsafe-firewall.service /etc/systemd/system/isipsafe-blocklist.service \
  /etc/systemd/system/isipsafe-blocklist.timer >/tmp/verify.log 2>&1 || true
cat /tmp/verify.log
expect "systemd-analyze verify reports nothing about the isipsafe unit files" \
  bash -c '! grep -E "isipsafe-(firewall|blocklist)\.(service|timer):[0-9]+:" /tmp/verify.log'

step "nftables rules"
nft -c -f /etc/isipsafe/isipsafe.nft
ok "nft -c -f /etc/isipsafe/isipsafe.nft"
$BL start
expect "table inet isipsafe loaded" table_loaded
expect "chain accepts established traffic before the drop rules" bash -c \
  'nft list chain inet isipsafe input | grep -n -e "established,related accept" -e "@block4" | head -1 | grep -q established'
$BL start
ok "start is idempotent"

step "renderer"
r="$(printf '%s\n' '# comment' '' '198.51.100.7' '45.155.205.1' '45.155.205.2' '45.155.205.0/24' '10.0.0.1' '192.168.1.0/24' \
  '127.0.0.1' '0.0.0.0/0' '5.0.0.0/8' '2a03:2880:f12f:83:face:b00c:0:25de' 'fd00::1' 'not-an-ip' '<html>' |
  python3 -I /opt/isipsafe/bin/isipsafe-nft-elements --name block --input - 2>/tmp/render.err)"
echo "$r"
cat /tmp/render.err
expect "private, reserved and huge networks are skipped" grep -q '1 IPv4 and 1 IPv6 entries, 9 skipped' /tmp/render.err
expect "overlapping entries are collapsed" bash -c "grep -q '45.155.205.0/24' <<<'$r' && ! grep -q '45.155.205.1[^/]' <<<'$r'"
if printf '' | python3 -I /opt/isipsafe/bin/isipsafe-nft-elements --name block --input - --min-entries 1 >/dev/null 2>&1; then
  fail "empty list accepted"
fi
ok "empty list rejected"

step "blocklist update against a local mock of the API"
mkdir -p "$MOCK_DIR/api/v1"
cp "$SRC/tests/fixtures/blocklist.txt" "$MOCK_DIR/api/v1/blocklist"
printf '{"data":[{"id":1,"slug":"ssh","name":"SSH","group":"Brute force","description":""}]}' >"$MOCK_DIR/api/v1/categories"
python3 -m http.server "$MOCK_PORT" --bind 127.0.0.1 --directory "$MOCK_DIR" >/tmp/mock.log 2>&1 &
mock_pid=$!
trap 'kill "$mock_pid" 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
  curl -fsS "http://127.0.0.1:$MOCK_PORT/api/v1/categories" >/dev/null 2>&1 && break
  sleep 0.1
done

$BL update
ok "update without a key is a no-op"
expect "nothing loaded without a key" test "$(set_count block4)" -eq 0

install -m 600 /dev/null /etc/isipsafe/env
cat >/etc/isipsafe/env <<EOF
ISIPSAFE_API_KEY=test_dummy_key_not_real
ISIPSAFE_BASE_URL=http://127.0.0.1:$MOCK_PORT/api/v1
EOF
$BL update
expect "IPv4 set filled from the mock list" test "$(set_count block4)" -eq 5
expect "IPv6 set filled from the mock list" test "$(set_count block6)" -eq 1
expect "private address from the list not loaded" bash -c '! nft list set inet isipsafe block4 | grep -q "10.1.2.3"'
expect "last good list cached" test -s /var/lib/isipsafe/blocklist.nft
expect "status ok" grep -q '^last_result=ok' /var/lib/isipsafe/status
expect "key sent as a Bearer header, not in the URL" bash -c '! grep -q test_dummy_key /tmp/mock.log'
expect "nft -c accepts the cached blocklist" nft -c -f /var/lib/isipsafe/blocklist.nft

step "failed download keeps the previous list"
kill "$mock_pid"
wait "$mock_pid" 2>/dev/null || true
if $BL update; then fail "update reported success with the API down"; fi
expect "IPv4 entries kept after a failed download" test "$(set_count block4)" -eq 5
expect "IPv6 entries kept after a failed download" test "$(set_count block6)" -eq 1
expect "status records the error" grep -q '^last_result=error' /var/lib/isipsafe/status
expect "status keeps the last success time" grep -q '^last_success=' /var/lib/isipsafe/status

step "empty or garbage list keeps the previous list"
python3 -m http.server "$MOCK_PORT" --bind 127.0.0.1 --directory "$MOCK_DIR" >/tmp/mock.log 2>&1 &
mock_pid=$!
sleep 1
: >"$MOCK_DIR/api/v1/blocklist"
if $BL update; then fail "empty list accepted"; fi
expect "entries kept after an empty list" test "$(set_count block4)" -eq 5
printf '<html><body>maintenance</body></html>\n' >"$MOCK_DIR/api/v1/blocklist"
if $BL update; then fail "garbage list accepted"; fi
expect "entries kept after a garbage list" test "$(set_count block4)" -eq 5

step "updated list replaces the old one atomically"
printf '%s\n' 203.0.113.250 45.95.147.236 >"$MOCK_DIR/api/v1/blocklist"
$BL update
expect "only global entries of the new list remain" test "$(set_count block4)" -eq 1
expect "old entries are gone" bash -c '! nft list set inet isipsafe block4 | grep -q "185.220.101.1"'
expect "IPv6 set flushed when the list has no IPv6" test "$(set_count block6)" -eq 0

step "reboot path: table rebuilt from the cache"
cp "$SRC/tests/fixtures/blocklist.txt" "$MOCK_DIR/api/v1/blocklist"
$BL update
$BL stop
expect "stop removes the table" bash -c '! nft list table inet isipsafe >/dev/null 2>&1'
$BL start
expect "start reloads the cached list" test "$(set_count block4)" -eq 5

step "allowlist"
printf '198.51.100.0/24\n2001:db8::/32\n' >>/etc/isipsafe/allowlist
$BL allowlist
expect "allow4 loaded" set_has allow4 198.51.100.0/24
expect "allow6 loaded" set_has allow6 2001:db8::/32
expect "allowlist rule sits before the drop rule" bash -c \
  'nft list chain inet isipsafe input | grep -n -e "@allow4 accept" -e "@block4" | head -1 | grep -q allow4'

step "status and MOTD"
$BL status
/etc/update-motd.d/99-isipsafe | tee /tmp/motd.txt
expect "MOTD shows the blocklist" grep -q 'blocklist   5 IPv4 and 1 IPv6 entries (updated' /tmp/motd.txt
expect "MOTD never prints the key" bash -c '! grep -q test_dummy_key /tmp/motd.txt'

step "fail2ban reporting action"
cat >/tmp/fake-isipsafe <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >/tmp/fake-isipsafe.args
printf '%s\n' "${ISIPSAFE_API_KEY:-}" >/tmp/fake-isipsafe.key
echo "reported $3"
EOF
chmod 755 /tmp/fake-isipsafe
ISIPSAFE_CLI=/tmp/fake-isipsafe /opt/isipsafe/bin/isipsafe-fail2ban-report 45.155.205.233 ssh,brute-force sshd 6
expect "report sent with ssh,brute-force" grep -q -- 'report 45.155.205.233 -c ssh,brute-force -m Banned by fail2ban, jail sshd, 6 failed attempts' /tmp/fake-isipsafe.args
expect "key passed through the environment, not argv" bash -c '! grep -q test_dummy_key /tmp/fake-isipsafe.args && grep -q test_dummy_key /tmp/fake-isipsafe.key'
rm -f /tmp/fake-isipsafe.args
ISIPSAFE_CLI=/tmp/fake-isipsafe /opt/isipsafe/bin/isipsafe-fail2ban-report 45.155.205.233 ssh,brute-force 'sshd;rm -rf /' 'x'
expect "unsafe jail name and failures are not passed through" bash -c "grep -q 'jail fail2ban\$' /tmp/fake-isipsafe.args"
expect "real CLI failure (mock rejects the POST) never breaks fail2ban" /opt/isipsafe/bin/isipsafe-fail2ban-report 45.155.205.233 ssh,brute-force sshd 6
expect "the failed report reached the mock, not isipsafe.com" grep -q '"POST /api/v1/report' /tmp/mock.log
sed -i 's/^ISIPSAFE_API_KEY=.*/ISIPSAFE_API_KEY=/' /etc/isipsafe/env
rm -f /tmp/fake-isipsafe.args
ISIPSAFE_CLI=/tmp/fake-isipsafe /opt/isipsafe/bin/isipsafe-fail2ban-report 45.155.205.233 ssh,brute-force sshd 6
expect "no report without a key" test ! -e /tmp/fake-isipsafe.args

step "setup.sh"
rm -f /etc/isipsafe/env
/opt/isipsafe/setup.sh --non-interactive
expect "non-interactive without a key does nothing" test ! -e /etc/isipsafe/env
expect "hook kept until a key is configured" grep -q 'setup.sh --first-login' /root/.bashrc
ISIPSAFE_API_KEY=sl_test_dummy_key_123 ISIPSAFE_ALLOW_IPS="203.0.113.9, 2001:db8:1::1" /opt/isipsafe/setup.sh --non-interactive
expect "env file written" grep -qx 'ISIPSAFE_API_KEY=sl_test_dummy_key_123' /etc/isipsafe/env
expect "env file is 600 root" test "$(stat -c '%a %U' /etc/isipsafe/env)" = "600 root"
expect "allowlist entries added" bash -c 'grep -q "^203.0.113.9/32 " /etc/isipsafe/allowlist && grep -q "^2001:db8:1::1/128 " /etc/isipsafe/allowlist'
expect "hook removed after setup" bash -c '! grep -q "setup.sh --first-login" /root/.bashrc'
ISIPSAFE_API_KEY=sl_test_dummy_key_123 ISIPSAFE_ALLOW_IPS=203.0.113.9 /opt/isipsafe/setup.sh --non-interactive >/dev/null
expect "allowlist entries not duplicated" test "$(grep -c '^203.0.113.9/32 ' /etc/isipsafe/allowlist)" -eq 1
if ISIPSAFE_API_KEY='bad key; rm -rf /' /opt/isipsafe/setup.sh --non-interactive 2>/dev/null; then fail "malformed key accepted"; fi
ok "malformed key rejected"

step "setup.sh interactive (pseudo-terminal, key checked against the mock)"
rm -f /etc/isipsafe/env
printf '\n%s\n' '[ -x /opt/isipsafe/setup.sh ] && /opt/isipsafe/setup.sh --first-login' >>/root/.bashrc
export ISIPSAFE_BASE_URL="http://127.0.0.1:$MOCK_PORT/api/v1"
{
  sleep 2
  printf 'sl_interactive_dummy_key\n'
  sleep 2
  printf 'y\n'
  sleep 1
  printf 'n\n'
  sleep 1
  printf 'y\n'
  sleep 2
} | SSH_CLIENT="198.51.100.77 52000 22" script -qec "/opt/isipsafe/setup.sh --first-login" /dev/null >/tmp/setup.out
cat /tmp/setup.out
unset ISIPSAFE_BASE_URL
expect "interactive run accepted the key" grep -q 'Key accepted' /tmp/setup.out
expect "key not echoed to the terminal" bash -c '! grep -q sl_interactive_dummy_key /tmp/setup.out'
expect "interactive env file written" grep -qx 'ISIPSAFE_API_KEY=sl_interactive_dummy_key' /etc/isipsafe/env
expect "blocklist answer saved" grep -qx 'ISIPSAFE_BLOCKLIST=no' /etc/isipsafe/env
expect "admin SSH address allowlisted" grep -q '^198.51.100.77/32 ' /etc/isipsafe/allowlist
expect "first-login hook removed" bash -c '! grep -q "setup.sh --first-login" /root/.bashrc'

printf '\n%s\n' '[ -x /opt/isipsafe/setup.sh ] && /opt/isipsafe/setup.sh --first-login' >>/root/.bashrc
printf '\n' | script -qec "/opt/isipsafe/setup.sh --first-login" /dev/null >/tmp/setup-skip.out
expect "first login is skipped when a key already exists" bash -c '! grep -q "isIPsafe API key" /tmp/setup-skip.out && ! grep -q "setup.sh --first-login" /root/.bashrc'

step "per-instance first boot with a key from user-data"
printf 'ISIPSAFE_API_KEY=sl_userdata_dummy_key\n' >/etc/isipsafe/env
chmod 644 /etc/isipsafe/env
printf '\n%s\n' '[ -x /opt/isipsafe/setup.sh ] && /opt/isipsafe/setup.sh --first-login' >>/root/.bashrc
/var/lib/cloud/scripts/per-instance/001_onboot || true
expect "001_onboot tightens env permissions" test "$(stat -c %a /etc/isipsafe/env)" = 600
expect "001_onboot configures from user-data" grep -qx 'ISIPSAFE_API_KEY=sl_userdata_dummy_key' /etc/isipsafe/env
expect "001_onboot removes the first-login prompt" bash -c '! grep -q "setup.sh --first-login" /root/.bashrc'

printf '\nall %d checks passed\n' "$passed"
