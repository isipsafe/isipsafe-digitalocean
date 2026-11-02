#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly IMAGE="${UBUNTU_IMAGE:-ubuntu:24.04}"
readonly NAME="isipsafe-do-systemd-test-$$"

wheel_args=()
if [ -n "${ISIPSAFE_WHEELS:-}" ]; then
  wheel_args=(-v "$(cd "$ISIPSAFE_WHEELS" && pwd):/wheels:ro")
fi

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run -d --name "$NAME" \
  --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /run --tmpfs /run/lock \
  -v "$ROOT:/src:ro" \
  ${wheel_args[@]+"${wheel_args[@]}"} \
  "$IMAGE" bash -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get -qq update >/dev/null &&
    apt-get -qqy install --no-install-recommends systemd systemd-sysv dbus >/dev/null &&
    touch /tmp/.systemd-installed &&
    exec /lib/systemd/systemd' >/dev/null

for _ in $(seq 1 180); do
  if docker exec "$NAME" systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded'; then
    break
  fi
  sleep 1
done
docker exec "$NAME" systemctl is-system-running || true

docker exec "$NAME" bash /src/tests/run-systemd-checks.sh
