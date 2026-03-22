#!/usr/bin/env bash
# setup-mac-mini.sh
# Prepares an Ubuntu 24.04 host to run NemoClaw, with inference routed to
# a remote NVIDIA DGX Spark. Run as a non-root user with sudo access.
#
# Usage:
#   bash setup-mac-mini.sh
#
# What this script does:
#   1. Installs Docker (official Docker repo)
#   2. Adds the current user to the docker group
#   3. Fixes cgroup v2 incompatibility (required for OpenShell/k3s)
#   4. Installs Node.js 22
#   5. Installs the OpenShell CLI
#   6. Installs NemoClaw

set -euo pipefail

# ── Helpers ──────────────────────────────────────────────────────────────────

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

info()    { echo -e "${BOLD}${GREEN}==>${RESET} $*"; }
warn()    { echo -e "${YELLOW}WARN:${RESET} $*"; }
die()     { echo -e "${RED}ERROR:${RESET} $*" >&2; exit 1; }
already() { echo -e "  ${GREEN}✓${RESET} $* (already installed)"; }

require_ubuntu_24() {
  local id version
  id=$(. /etc/os-release && echo "$ID")
  version=$(. /etc/os-release && echo "$VERSION_ID")
  [[ "$id" == "ubuntu" && "$version" == "24.04" ]] \
    || die "This script targets Ubuntu 24.04. Found: $id $version"
}

# ── Step 1: Docker ────────────────────────────────────────────────────────────

install_docker() {
  if command -v docker &>/dev/null; then
    already "Docker $(docker --version | awk '{print $3}' | tr -d ',')"
    return
  fi

  info "Installing Docker..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq ca-certificates curl gnupg lsb-release

  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  sudo apt-get update -qq
  sudo apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

  echo -e "  ${GREEN}✓${RESET} $(docker --version)"
}

# ── Step 2: Docker group ──────────────────────────────────────────────────────

add_docker_group() {
  if id -nG "$USER" | grep -qw docker; then
    already "$USER is in the docker group"
    return
  fi

  info "Adding $USER to the docker group..."
  sudo usermod -aG docker "$USER"
  warn "Group change takes effect on next login. Run 'newgrp docker' to apply now."
}

# ── Step 3: cgroup v2 fix ────────────────────────────────────────────────────
# OpenShell embeds k3s inside Docker. On Ubuntu 24.04 (cgroup v2), k3s fails
# unless Docker containers use the host cgroup namespace.

fix_cgroup_v2() {
  local daemon_json=/etc/docker/daemon.json

  if sudo python3 -c "
import json, sys
d = json.load(open('$daemon_json')) if __import__('os').path.exists('$daemon_json') else {}
sys.exit(0 if d.get('default-cgroupns-mode') == 'host' else 1)
" 2>/dev/null; then
    already "cgroup v2 fix (default-cgroupns-mode=host)"
    return
  fi

  info "Applying cgroup v2 fix for OpenShell/k3s compatibility..."
  sudo python3 -c "
import json, os
path = '$daemon_json'
d = json.load(open(path)) if os.path.exists(path) else {}
d['default-cgroupns-mode'] = 'host'
json.dump(d, open(path, 'w'), indent=2)
print('  Written:', path)
"
  sudo systemctl restart docker
  echo -e "  ${GREEN}✓${RESET} Docker restarted with cgroupns=host"
}

# ── Step 4: Node.js 22 ───────────────────────────────────────────────────────

install_nodejs() {
  local required=22
  local current
  current=$(node --version 2>/dev/null | sed 's/v//' | cut -d. -f1 || echo 0)

  if [[ "$current" -ge "$required" ]]; then
    already "Node.js $(node --version)"
    return
  fi

  info "Installing Node.js $required..."
  curl -fsSL https://deb.nodesource.com/setup_${required}.x | sudo -E bash -
  sudo apt-get install -y -qq nodejs
  echo -e "  ${GREEN}✓${RESET} $(node --version) / npm $(npm --version)"
}

# ── Step 5: OpenShell CLI ────────────────────────────────────────────────────

install_openshell() {
  if command -v openshell &>/dev/null; then
    already "OpenShell $(openshell --version 2>/dev/null || echo '(version unknown)')"
    return
  fi

  info "Installing OpenShell CLI..."
  local arch asset tmpdir
  arch=$(uname -m)   # x86_64 on Mac Mini, aarch64 on DGX Spark

  case "$arch" in
    x86_64)  asset="openshell-x86_64-unknown-linux-musl.tar.gz" ;;
    aarch64) asset="openshell-aarch64-unknown-linux-musl.tar.gz" ;;
    *) die "Unsupported architecture: $arch" ;;
  esac

  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT

  curl -fsSL \
    "https://github.com/NVIDIA/OpenShell/releases/latest/download/${asset}" \
    -o "$tmpdir/$asset"
  tar xzf "$tmpdir/$asset" -C "$tmpdir"
  sudo install -m 755 "$tmpdir/openshell" /usr/local/bin/openshell

  echo -e "  ${GREEN}✓${RESET} OpenShell installed (${arch})"
}

# ── Step 6: NemoClaw ─────────────────────────────────────────────────────────

install_nemoclaw() {
  if command -v nemoclaw &>/dev/null; then
    already "NemoClaw (installed)"
    return
  fi

  info "Installing NemoClaw..."

  local src="${HOME}/.nemoclaw/source"
  rm -rf "$src"
  mkdir -p "$(dirname "$src")"
  git clone --depth 1 https://github.com/NVIDIA/NemoClaw.git "$src"

  # GH-503 workaround: openclaw's npm tarball is missing directory entries that
  # npm's tar extractor hard-fails on. Pre-extract with system tar first so npm
  # sees the dependency as already satisfied and skips its own extraction.
  local openclaw_version
  openclaw_version=$(node -e "console.log(require('${src}/package.json').dependencies.openclaw)" 2>/dev/null) || openclaw_version=""

  if [ -n "$openclaw_version" ]; then
    info "Pre-extracting openclaw@${openclaw_version} with system tar (GH-503 workaround)..."
    local tmpdir
    tmpdir=$(mktemp -d)
    if npm pack "openclaw@${openclaw_version}" --pack-destination "$tmpdir" > /dev/null 2>&1; then
      local tgz
      tgz=$(find "$tmpdir" -maxdepth 1 -name 'openclaw-*.tgz' -print -quit)
      if [ -n "$tgz" ]; then
        mkdir -p "${src}/node_modules/openclaw"
        tar xzf "$tgz" -C "${src}/node_modules/openclaw" --strip-components=1 \
          && echo -e "  ${GREEN}✓${RESET} openclaw pre-extracted" \
          || warn "openclaw extraction failed — continuing anyway"
      fi
    else
      warn "Failed to pack openclaw — continuing without pre-extraction"
    fi
    rm -rf "$tmpdir"
  else
    warn "Could not determine openclaw version — skipping pre-extraction"
  fi

  # Build the TypeScript plugin and link globally.
  # --ignore-scripts skips prepublishOnly (which would re-run tsc redundantly).
  (cd "$src" \
    && npm install --ignore-scripts \
    && cd nemoclaw \
    && npm install --ignore-scripts \
    && npm run build \
    && cd .. \
    && sudo npm link)

  echo -e "  ${GREEN}✓${RESET} NemoClaw installed"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  echo ""
  echo -e "${BOLD}NemoClaw Host Setup — Ubuntu 24.04${RESET}"
  echo -e "Target: $(hostname) ($(hostname -I | awk '{print $1}'))"
  echo ""

  require_ubuntu_24
  install_docker
  add_docker_group
  fix_cgroup_v2
  install_nodejs
  install_openshell
  install_nemoclaw

  echo ""
  echo -e "${BOLD}${GREEN}Setup complete.${RESET}"
  echo ""
  echo "Next steps:"
  echo "  1. Run 'newgrp docker' (or log out/in) if this is a fresh docker group membership"
  echo "  2. Run 'nemoclaw onboard' to configure inference and the sandbox"
  echo ""
}

main "$@"
