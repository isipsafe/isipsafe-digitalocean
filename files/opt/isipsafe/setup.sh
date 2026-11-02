#!/usr/bin/env bash
set -euo pipefail
umask 077

readonly CONF_DIR="${ISIPSAFE_CONF_DIR:-/etc/isipsafe}"
readonly ENV_FILE="$CONF_DIR/env"
readonly ALLOWLIST="$CONF_DIR/allowlist"
readonly PYTHON="${ISIPSAFE_PYTHON:-/opt/isipsafe/venv/bin/python3}"
readonly LIB="${ISIPSAFE_LIB:-/opt/isipsafe/lib/common.sh}"
readonly BASHRC="${ISIPSAFE_BASHRC:-/root/.bashrc}"
readonly SIGNUP_URL="https://isipsafe.com/login"

# shellcheck source=lib/common.sh
. "$LIB"

mode=interactive

usage() {
  cat <<EOF
Usage: setup.sh [--non-interactive | --first-login]

Configures isIPsafe on this Droplet: saves your API key to $ENV_FILE,
turns on blocklist updates and fail2ban reporting.

  --non-interactive  read ISIPSAFE_API_KEY (and optionally ISIPSAFE_REPORT,
                     ISIPSAFE_BLOCKLIST, ISIPSAFE_ALLOW_IPS) from the environment
                     or from $ENV_FILE; never prompt
  --first-login      what /root/.bashrc runs on the first SSH login

Free API key: $SIGNUP_URL
EOF
}

say() {
  printf '%s\n' "$*"
}

have_systemd() {
  [ -d /run/systemd/system ]
}

remove_login_hook() {
  if [ -f "$BASHRC" ]; then
    sed -i '\#/opt/isipsafe/setup.sh --first-login#d' "$BASHRC"
  fi
}

valid_key() {
  [[ "$1" =~ ^[A-Za-z0-9_.-]{8,256}$ ]]
}

verify_key() {
  ISIPSAFE_API_KEY="$1" timeout 30 "$PYTHON" -I -c '
import os, sys
from isipsafe.client import DEFAULT_BASE_URL, Client
from isipsafe.errors import AuthenticationError, IsIPsafeError
try:
    Client(base_url=os.environ.get("ISIPSAFE_BASE_URL") or DEFAULT_BASE_URL, timeout=10).categories()
except AuthenticationError:
    sys.exit(3)
except IsIPsafeError:
    sys.exit(4)
' >/dev/null 2>&1
}

normalize_ip() {
  "$PYTHON" -I -c '
import ipaddress, sys
try:
    print(ipaddress.ip_network(sys.argv[1], strict=False))
except ValueError:
    sys.exit(1)
' "$1" 2>/dev/null
}

allow_ip() {
  local net
  net="$(normalize_ip "$1")" || {
    say "Skipping invalid allowlist entry: $1"
    return 0
  }
  touch "$ALLOWLIST"
  if ! awk -v net="$net" '$1 == net { found = 1 } END { exit !found }' "$ALLOWLIST"; then
    printf '%s  # added by setup.sh %s\n' "$net" "$(date -u +%Y-%m-%d)" >>"$ALLOWLIST"
    say "Added $net to $ALLOWLIST"
  fi
}

ask_yes() {
  local prompt="$1" answer
  read -r -p "$prompt [Y/n] " answer || answer=n
  case "$answer" in
    n | N | no | NO) return 1 ;;
    *) return 0 ;;
  esac
}

write_env() {
  local key="$1" report="$2" blocklist="$3" tmp
  install -d -m 700 "$CONF_DIR"
  tmp="$(mktemp "$CONF_DIR/.env.XXXXXX")"
  cat >"$tmp" <<EOF
ISIPSAFE_API_KEY=$key
ISIPSAFE_REPORT=$report
ISIPSAFE_BLOCKLIST=$blocklist
ISIPSAFE_BLOCKLIST_CONFIDENCE=${ISIPSAFE_BLOCKLIST_CONFIDENCE:-90}
ISIPSAFE_BLOCKLIST_DAYS=${ISIPSAFE_BLOCKLIST_DAYS:-30}
ISIPSAFE_BLOCKLIST_LIMIT=${ISIPSAFE_BLOCKLIST_LIMIT:-10000}
ISIPSAFE_BLOCKLIST_EXCEPT_COUNTRIES=${ISIPSAFE_BLOCKLIST_EXCEPT_COUNTRIES:-}
EOF
  chmod 600 "$tmp"
  chown root:root "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$ENV_FILE"
  say "Saved settings to $ENV_FILE (readable by root only)."
}

apply() {
  local blocklist="$1"
  if ! have_systemd; then
    say "systemd is not running; start isipsafe-firewall.service and isipsafe-blocklist.timer after boot."
    return 0
  fi
  systemctl daemon-reload
  systemctl enable --now isipsafe-firewall.service
  systemctl reload isipsafe-firewall.service || true
  if isipsafe_enabled "$blocklist"; then
    systemctl enable --now isipsafe-blocklist.timer
    systemctl start --no-block isipsafe-blocklist.service
    say "Blocklist updates are on (every 30 minutes)."
  else
    systemctl disable --now isipsafe-blocklist.timer 2>/dev/null || true
    say "Blocklist updates are off."
  fi
  systemctl enable --now fail2ban.service
  systemctl reload fail2ban.service || systemctl restart fail2ban.service || true
}

run_non_interactive() {
  isipsafe_load_env "$ENV_FILE"
  local key="${ISIPSAFE_API_KEY:-}"
  if [ -z "$key" ]; then
    say "isipsafe setup: no ISIPSAFE_API_KEY given; nothing to do. Get a key at $SIGNUP_URL"
    return 0
  fi
  if ! valid_key "$key"; then
    say "isipsafe setup: ISIPSAFE_API_KEY has an unexpected format; not saved." >&2
    return 1
  fi
  local entry entries=()
  IFS=', ' read -r -a entries <<<"${ISIPSAFE_ALLOW_IPS:-}"
  for entry in "${entries[@]}"; do
    if [ -n "$entry" ]; then
      allow_ip "$entry"
    fi
  done
  write_env "$key" "${ISIPSAFE_REPORT:-yes}" "${ISIPSAFE_BLOCKLIST:-yes}"
  apply "${ISIPSAFE_BLOCKLIST:-yes}"
  remove_login_hook
}

run_interactive() {
  local key="" status report=yes blocklist=yes client_ip
  isipsafe_load_env "$ENV_FILE"
  cat <<EOF

================================================================================
 isIPsafe Protected Ubuntu - setup
================================================================================
 This Droplet already has a firewall (ufw, SSH only), fail2ban and automatic
 security updates. Add a free isIPsafe API key to also:

   * drop traffic from known attackers (the isIPsafe blocklist, every 30 min)
   * report the addresses fail2ban bans, so other servers are warned

 Get a free key: $SIGNUP_URL
 Press Enter without a key to skip. Run /opt/isipsafe/setup.sh again any time.
================================================================================

EOF
  for _ in 1 2 3; do
    read -r -s -p "isIPsafe API key: " key || key=""
    printf '\n'
    if [ -z "$key" ]; then
      say "Skipped. Run /opt/isipsafe/setup.sh when you have a key."
      if [ "$mode" = first-login ]; then
        remove_login_hook
      fi
      return 0
    fi
    if ! valid_key "$key"; then
      say "That does not look like an isIPsafe API key. Try again."
      key=""
      continue
    fi
    status=0
    verify_key "$key" || status=$?
    case "$status" in
      0)
        say "Key accepted."
        break
        ;;
      3)
        say "isIPsafe rejected that key. Check it at $SIGNUP_URL and try again."
        key=""
        ;;
      *)
        say "Could not reach isIPsafe to check the key; saving it anyway."
        break
        ;;
    esac
  done
  if [ -z "$key" ]; then
    say "No key saved. Run /opt/isipsafe/setup.sh to try again."
    return 1
  fi

  ask_yes "Report addresses banned by fail2ban to isIPsafe?" || report=no
  ask_yes "Drop traffic from the isIPsafe blocklist?" || blocklist=no

  client_ip="${SSH_CLIENT%% *}"
  if [ -n "$client_ip" ] && ask_yes "Never block your current address ($client_ip)?"; then
    allow_ip "$client_ip"
  fi

  write_env "$key" "$report" "$blocklist"
  apply "$blocklist"
  remove_login_hook
  cat <<EOF

Done. Useful commands:
  isipsafe check 203.0.113.7              look up an address
  isipsafe-blocklist status               blocklist status and drop counters
  fail2ban-client status sshd             current SSH bans
  nano $ALLOWLIST    then: systemctl reload isipsafe-firewall

EOF
}

main() {
  case "${1:-}" in
    --non-interactive) mode=non-interactive ;;
    --first-login) mode=first-login ;;
    "") mode=interactive ;;
    -h | --help)
      usage
      return 0
      ;;
    *)
      usage >&2
      return 2
      ;;
  esac

  if [ "$(id -u)" -ne 0 ]; then
    say "Run this as root." >&2
    return 1
  fi

  if [ "$mode" = non-interactive ]; then
    run_non_interactive
    return
  fi

  if [ "$mode" = first-login ]; then
    if [ -r "$ENV_FILE" ] && grep -qE '^ISIPSAFE_API_KEY=.+' "$ENV_FILE"; then
      remove_login_hook
      return 0
    fi
    [ -t 0 ] && [ -t 1 ] || return 0
  fi
  run_interactive
}

main "$@"
