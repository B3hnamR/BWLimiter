#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="/usr/local/bin/limit-tc-port"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Run as root."
  exit 1
fi

install -m 0755 "$SCRIPT_DIR/limit-tc-port.sh" "$TARGET"
"$TARGET" --install-service
systemctl enable --now limit-tc-port.service
systemctl enable --now limit-tc-port-scheduler.timer

echo "Installed: $TARGET"
echo "Service:   limit-tc-port.service (enabled)"
echo "Timer:     limit-tc-port-scheduler.timer (enabled)"
echo
echo "Run: limit-tc-port"
