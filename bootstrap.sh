#!/usr/bin/env bash

set -euo pipefail

REPO_OWNER="${REPO_OWNER:-B3hnamR}"
REPO_NAME="${REPO_NAME:-BWLimiter}"
REPO_BRANCH="${REPO_BRANCH:-main}"

RAW_BASE="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}"
APP_BIN="/usr/local/bin/limit-tc-port"
SERVICE_NAME="limit-tc-port.service"

green="\033[1;32m"
yellow="\033[1;33m"
red="\033[1;31m"
reset="\033[0m"

ok() { echo -e "${green}[OK]${reset} $*"; }
warn() { echo -e "${yellow}[WARN]${reset} $*"; }
err() { echo -e "${red}[ERR]${reset} $*" >&2; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Run with root privileges."
    echo "Example:"
    echo "  curl -fsSL ${RAW_BASE}/bootstrap.sh | sudo bash"
    exit 1
  fi
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"; return; fi
  if command -v dnf >/dev/null 2>&1; then echo "dnf"; return; fi
  if command -v yum >/dev/null 2>&1; then echo "yum"; return; fi
  if command -v pacman >/dev/null 2>&1; then echo "pacman"; return; fi
  if command -v zypper >/dev/null 2>&1; then echo "zypper"; return; fi
  if command -v apk >/dev/null 2>&1; then echo "apk"; return; fi
  echo "unknown"
}

missing_runtime_commands() {
  local cmd
  for cmd in bash curl ip tc ss awk sort uniq paste modprobe; do
    command -v "$cmd" >/dev/null 2>&1 || echo "$cmd"
  done
}

install_deps() {
  local manager="$1"
  ok "Installing missing dependencies with package manager: $manager"

  case "$manager" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y iproute2 gawk coreutils grep sed procps kmod curl ca-certificates bash
      ;;
    dnf)
      dnf install -y iproute gawk coreutils grep sed procps-ng kmod curl ca-certificates bash
      ;;
    yum)
      yum install -y iproute gawk coreutils grep sed procps-ng kmod curl ca-certificates bash
      ;;
    pacman)
      pacman -Sy --noconfirm iproute2 gawk coreutils grep sed procps-ng kmod curl ca-certificates bash
      ;;
    zypper)
      zypper --non-interactive install iproute2 gawk coreutils grep sed procps kmod curl ca-certificates bash
      ;;
    apk)
      apk add --no-cache iproute2 gawk coreutils grep sed procps kmod curl ca-certificates bash
      ;;
    *)
      err "No supported package manager found. Install dependencies manually."
      return 1
      ;;
  esac
}

ensure_deps() {
  local missing manager
  missing="$(missing_runtime_commands | tr '\n' ' ' | xargs || true)"
  if [[ -z "$missing" ]]; then
    ok "Required runtime dependencies already installed."
    return
  fi

  warn "Missing commands: $missing"
  manager="$(detect_pkg_manager)"
  install_deps "$manager"

  missing="$(missing_runtime_commands | tr '\n' ' ' | xargs || true)"
  if [[ -n "$missing" ]]; then
    err "Dependencies are still missing after install: $missing"
    exit 1
  fi
  ok "Dependencies installed."
}

download_main_script() {
  local tmp_main
  tmp_main="$(mktemp)"

  curl -fsSL --retry 3 --connect-timeout 10 "${RAW_BASE}/limit-tc-port.sh" -o "$tmp_main"
  if [[ ! -s "$tmp_main" ]]; then
    rm -f "$tmp_main"
    err "Failed to download limit-tc-port.sh"
    exit 1
  fi

  if [[ -f "$APP_BIN" ]] && cmp -s "$tmp_main" "$APP_BIN"; then
    ok "Installed script is already up to date."
    rm -f "$tmp_main"
    return
  fi

  install -m 0755 "$tmp_main" "$APP_BIN"
  rm -f "$tmp_main"
  ok "Installed/updated ${APP_BIN}"
}

setup_service_if_available() {
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl not found; skipping service setup."
    return
  fi

  "$APP_BIN" --install-service >/dev/null
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  ok "Service is installed (enabled at boot): ${SERVICE_NAME}"
}

launch_menu() {
  ok "Launching interactive manager..."
  exec "$APP_BIN"
}

main() {
  require_root
  ensure_deps
  download_main_script
  setup_service_if_available
  launch_menu
}

main "$@"

