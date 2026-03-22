#!/usr/bin/env bash
# setup-dgx-spark.sh
# Configures the NVIDIA DGX Spark as a NIM inference server for NemoClaw.
# Runs Nemotron 3 Nano 30B (MoE) via NVIDIA NIM with GPU passthrough.
#
# Usage:
#   bash setup-dgx-spark.sh
#
# Prerequisites:
#   - NVIDIA Container Toolkit installed (pre-installed on DGX Spark)
#   - NGC API key (set as NGC_API_KEY or NVIDIA_API_KEY in environment)
#   - Logged in to nvcr.io: echo "$NGC_API_KEY" | docker login nvcr.io -u '$oauthtoken' --password-stdin
#
# What this script does:
#   1. Configures Docker to use the NVIDIA runtime by default
#   2. Creates a persistent model cache directory
#   3. Runs the NIM container (Nemotron 3 Nano 30B)
#   4. Installs a systemd service so NIM starts on boot

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────

NIM_IMAGE="nvcr.io/nim/nvidia/nemotron-3-nano:1.7.0-variant"
NIM_MODEL="nvidia/nemotron-3-nano"
NIM_PORT=8000
NIM_CONTAINER="nim-nemotron-nano"
NIM_CACHE_DIR="${HOME}/.nim/cache"
NGC_API_KEY="${NGC_API_KEY:-${NVIDIA_API_KEY:-}}"

# ── Helpers ───────────────────────────────────────────────────────────────────

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

info()    { echo -e "${BOLD}${GREEN}==>${RESET} $*"; }
warn()    { echo -e "${YELLOW}WARN:${RESET} $*"; }
die()     { echo -e "${RED}ERROR:${RESET} $*" >&2; exit 1; }
already() { echo -e "  ${GREEN}✓${RESET} $* (already done)"; }

# ── Preflight ─────────────────────────────────────────────────────────────────

[ -z "$NGC_API_KEY" ] && die "NGC_API_KEY / NVIDIA_API_KEY is not set. Export it before running this script."
command -v docker &>/dev/null || die "Docker not found."
command -v nvidia-smi &>/dev/null || die "nvidia-smi not found. Is the NVIDIA driver installed?"
nvidia-smi -L | grep -q "GPU 0" || die "No GPU detected by nvidia-smi."

# ── Step 1: Configure Docker NVIDIA runtime ───────────────────────────────────

configure_nvidia_runtime() {
  local daemon_json=/etc/docker/daemon.json

  # Check if nvidia runtime is already registered and set as default
  local already_registered already_default
  already_registered=$(sudo python3 -c "
import json, os
d = json.load(open('$daemon_json')) if os.path.exists('$daemon_json') else {}
print('yes' if 'nvidia' in d.get('runtimes', {}) else 'no')
" 2>/dev/null)
  already_default=$(sudo python3 -c "
import json, os
d = json.load(open('$daemon_json')) if os.path.exists('$daemon_json') else {}
print(d.get('default-runtime', ''))
" 2>/dev/null)

  if [ "$already_registered" = "yes" ] && [ "$already_default" = "nvidia" ]; then
    already "Docker nvidia runtime registered and set as default"
    return
  fi

  # Register the nvidia runtime via nvidia-ctk (safe — it writes only the runtimes block)
  info "Registering nvidia runtime with Docker..."
  sudo nvidia-ctk runtime configure --runtime=docker

  # Set nvidia as the default runtime
  info "Setting nvidia as default Docker runtime..."
  sudo python3 -c "
import json, os
path = '$daemon_json'
d = json.load(open(path)) if os.path.exists(path) else {}
d['default-runtime'] = 'nvidia'
d['default-cgroupns-mode'] = 'host'
json.dump(d, open(path, 'w'), indent=2)
"
  sudo systemctl reset-failed docker 2>/dev/null || true
  sudo systemctl restart docker
  sleep 3
  docker info > /dev/null 2>&1 || die "Docker failed to restart. Check: journalctl -xeu docker.service"
  echo -e "  ${GREEN}✓${RESET} Docker running with nvidia default runtime"
}

# ── Step 2: Model cache directory ─────────────────────────────────────────────

create_cache_dir() {
  if [ -d "$NIM_CACHE_DIR" ]; then
    already "Model cache directory ($NIM_CACHE_DIR)"
    return
  fi

  info "Creating NIM model cache directory..."
  mkdir -p "$NIM_CACHE_DIR"
  echo -e "  ${GREEN}✓${RESET} $NIM_CACHE_DIR"
}

# ── Step 3: Run NIM container ─────────────────────────────────────────────────

run_nim() {
  if docker ps --format '{{.Names}}' | grep -q "^${NIM_CONTAINER}$"; then
    already "NIM container running ($NIM_CONTAINER)"
    return
  fi

  # Remove stopped container if it exists
  if docker ps -a --format '{{.Names}}' | grep -q "^${NIM_CONTAINER}$"; then
    info "Removing stopped NIM container..."
    docker rm "$NIM_CONTAINER"
  fi

  info "Pulling NIM image (this may take a while on first run)..."
  docker pull "$NIM_IMAGE"

  # NIM runs as UID 1000 (user: nvs) inside the container — ensure the cache
  # directory is owned by that UID so model weights can be written.
  sudo chown -R 1000:1000 "$NIM_CACHE_DIR"

  info "Starting NIM container..."
  docker run -d \
    --name "$NIM_CONTAINER" \
    --restart unless-stopped \
    --gpus all \
    -e NGC_API_KEY="$NGC_API_KEY" \
    -p "${NIM_PORT}:8000" \
    -v "${NIM_CACHE_DIR}:/opt/nim/.cache" \
    "$NIM_IMAGE"

  echo -e "  ${GREEN}✓${RESET} NIM container started"
  info "Waiting for NIM to be ready (model loading takes a few minutes)..."

  local attempts=0
  until curl -sf "http://localhost:${NIM_PORT}/v1/models" | grep -q "$NIM_MODEL" 2>/dev/null; do
    attempts=$((attempts + 1))
    [ "$attempts" -ge 60 ] && die "NIM did not become ready after 5 minutes. Check: docker logs $NIM_CONTAINER"
    printf '.'
    sleep 5
  done
  echo ""
  echo -e "  ${GREEN}✓${RESET} NIM is ready — model: $NIM_MODEL"
}

# ── Step 4: Systemd service ───────────────────────────────────────────────────

install_systemd_service() {
  local service_file=/etc/systemd/system/nim-nemotron.service

  if [ -f "$service_file" ]; then
    already "systemd service (nim-nemotron)"
    return
  fi

  info "Installing systemd service for NIM..."
  sudo tee "$service_file" > /dev/null <<EOF
[Unit]
Description=NVIDIA NIM - Nemotron 3 Nano 30B
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=${USER}
ExecStart=/usr/bin/docker start ${NIM_CONTAINER}
ExecStop=/usr/bin/docker stop ${NIM_CONTAINER}

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable nim-nemotron
  echo -e "  ${GREEN}✓${RESET} nim-nemotron.service enabled (starts on boot)"
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  echo ""
  echo -e "${BOLD}NIM Inference Server Setup — DGX Spark${RESET}"
  echo -e "Model:  $NIM_MODEL"
  echo -e "Host:   $(hostname) ($(hostname -I | awk '{print $1}'))"
  echo -e "GPU:    $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
  echo ""

  configure_nvidia_runtime
  create_cache_dir
  run_nim
  install_systemd_service

  echo ""
  echo -e "${BOLD}${GREEN}NIM is live.${RESET}"
  echo ""
  echo "  Endpoint: http://$(hostname -I | awk '{print $1}'):${NIM_PORT}/v1"
  echo "  Model:    $NIM_MODEL"
  echo "  Logs:     docker logs -f $NIM_CONTAINER"
  echo ""
  echo "Next: configure NemoClaw on the Mac Mini to use this endpoint."
  echo ""
}

main "$@"
