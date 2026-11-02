#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly IMAGE="${UBUNTU_IMAGE:-ubuntu:24.04}"
readonly NAME="isipsafe-do-test-$$"

wheel_args=()
if [ -n "${ISIPSAFE_WHEELS:-}" ]; then
  wheel_args=(-v "$(cd "$ISIPSAFE_WHEELS" && pwd):/wheels:ro")
fi

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run --rm --name "$NAME" \
  --cap-add NET_ADMIN \
  -v "$ROOT:/src:ro" \
  ${wheel_args[@]+"${wheel_args[@]}"} \
  "$IMAGE" bash /src/tests/run-in-container.sh
