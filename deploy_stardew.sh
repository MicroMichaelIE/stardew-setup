#!/usr/bin/env bash

# Deploy JunimoServer (Stardew Valley dedicated server) on Raspberry Pi
# - Installs Docker and Compose plugin if missing
# - Sets up amd64 emulation (binfmt/qemu) on ARM hosts
# - Clones/pulls the upstream repo
# - Creates .env from provided secrets/ports
# - Adds compose override to force linux/amd64 platform and restart policy
# - Starts the stack with `docker compose up -d`
#
# Usage (fish-friendly):
#   env STEAM_USER=you STEAM_PASS=secret VNC_PASSWORD=changeme bash ./deploy_stardew.sh
#   bash ./deploy_stardew.sh \
#     --steam-user you --steam-pass secret --vnc-password changeme \
#     --steam-guard-code 12345 --game-port 24643 --vnc-port 8090 --dir ~/junimoserver
#
# Notes:
# - Steam Guard code is optional, but may be needed on first run.
# - On Raspberry Pi (ARM), the image is amd64-only; we enable emulation.
# - Ports to forward on your router: UDP <GAME_PORT> (default 24643), TCP <VNC_PORT> (default 8090).

set -euo pipefail

log() { echo "[stardew-deploy] $*"; }
err() { echo "[stardew-deploy][error] $*" >&2; }

usage() {
  cat <<EOF
Deploy Stardew Valley dedicated server (JunimoServer) via Docker.

Options (or use env vars with same names):
  -u, --steam-user USER        Steam username           (env: STEAM_USER)
  -p, --steam-pass PASS        Steam password           (env: STEAM_PASS)
      --steam-guard-code CODE  Steam guard code (opt)   (env: STEAM_GUARD_CODE)
  -v, --vnc-password PASS      VNC password             (env: VNC_PASSWORD)
  -g, --game-port PORT         Game UDP port (host)     (env: GAME_PORT, default 24643)
  -w, --vnc-port PORT          VNC web port (host)      (env: VNC_PORT, default 8090)
  -d, --dir PATH               Install dir               (default: ~/junimoserver)
      --no-binfmt              Skip amd64 emulation setup on ARM
      --force                  Overwrite existing .env
  -h, --help                   Show this help

Examples:
  env STEAM_USER=you STEAM_PASS=secret VNC_PASSWORD=changeme bash ./deploy_stardew.sh
  bash ./deploy_stardew.sh --steam-user you --steam-pass secret --vnc-password changeme
EOF
}

# Defaults from env or sane values
STEAM_USER=${STEAM_USER:-}
STEAM_PASS=${STEAM_PASS:-}
STEAM_GUARD_CODE=${STEAM_GUARD_CODE:-}
VNC_PASSWORD=${VNC_PASSWORD:-}
GAME_PORT=${GAME_PORT:-24643}
VNC_PORT=${VNC_PORT:-8090}
INSTALL_DIR_DEFAULT="$HOME/junimoserver"
INSTALL_DIR=${INSTALL_DIR:-$INSTALL_DIR_DEFAULT}
REPO_URL="https://github.com/stardew-valley-dedicated-server/server.git"
SETUP_BINFMT=1
FORCE_ENV=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--steam-user) STEAM_USER=${2:-}; shift 2;;
    -p|--steam-pass) STEAM_PASS=${2:-}; shift 2;;
    --steam-guard-code) STEAM_GUARD_CODE=${2:-}; shift 2;;
    -v|--vnc-password) VNC_PASSWORD=${2:-}; shift 2;;
    -g|--game-port) GAME_PORT=${2:-24643}; shift 2;;
    -w|--vnc-port) VNC_PORT=${2:-8090}; shift 2;;
    -d|--dir) INSTALL_DIR=${2:-$INSTALL_DIR_DEFAULT}; shift 2;;
    --no-binfmt) SETUP_BINFMT=0; shift;;
    --force) FORCE_ENV=1; shift;;
    -h|--help) usage; exit 0;;
    *) err "Unknown argument: $1"; usage; exit 1;;
  esac
done

require() {
  local name="$1" value="$2"
  if [[ -z "$value" ]]; then
    err "Missing required: $name"
    MISSING=1
  fi
}

MISSING=0
require STEAM_USER "$STEAM_USER"
require STEAM_PASS "$STEAM_PASS"
require VNC_PASSWORD "$VNC_PASSWORD"
if [[ "$MISSING" -eq 1 ]]; then
  usage
  exit 1
fi

# Detect architecture
ARCH=$(uname -m)
log "Detected arch: $ARCH"
NEEDS_EMU=0
if [[ "$ARCH" != "x86_64" && "$ARCH" != "amd64" ]]; then
  NEEDS_EMU=1
fi

# Install Docker if missing
if ! command -v docker >/dev/null 2>&1; then
  log "Docker not found. Installing via get.docker.com (requires sudo)."
  if ! command -v sudo >/dev/null 2>&1; then
    err "sudo is required to install Docker. Please install sudo or run as root."
    exit 1
  fi
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sudo sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
  # Add current user to docker group (effective after re-login)
  if getent group docker >/dev/null 2>&1; then
    sudo usermod -aG docker "$USER" || true
  fi
fi

# Ensure Compose v2 is available
if ! docker compose version >/dev/null 2>&1; then
  log "Docker Compose plugin not found; attempting to install via apt (requires sudo)."
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y
    sudo apt-get install -y docker-compose-plugin || sudo apt-get install -y docker-compose || true
  else
    err "Could not install docker compose plugin automatically. Install it and re-run."
  fi
fi

# Setup amd64 emulation if on ARM and not skipped
if [[ "$NEEDS_EMU" -eq 1 && "$SETUP_BINFMT" -eq 1 ]]; then
  log "Setting up amd64 emulation (binfmt + qemu-user-static)."
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y
    sudo apt-get install -y qemu-user-static
  fi
  sudo docker run --privileged --rm tonistiigi/binfmt --install amd64 || true
fi

# Clone or update repo
INSTALL_DIR_EXPANDED=$(eval echo "$INSTALL_DIR")
mkdir -p "$INSTALL_DIR_EXPANDED"
if [[ -d "$INSTALL_DIR_EXPANDED/.git" ]]; then
  log "Repo exists at $INSTALL_DIR_EXPANDED; pulling latest."
  git -C "$INSTALL_DIR_EXPANDED" pull --ff-only
else
  log "Cloning repo into $INSTALL_DIR_EXPANDED"
  git clone "$REPO_URL" "$INSTALL_DIR_EXPANDED"
fi

pushd "$INSTALL_DIR_EXPANDED" >/dev/null

# Create compose override to force amd64 on ARM and set restart policy
cat > docker-compose.override.yml <<YAML
services:
  stardew:
    platform: linux/amd64
    restart: unless-stopped
YAML

# Generate .env if not present or --force
if [[ -f .env && "$FORCE_ENV" -ne 1 ]]; then
  log ".env exists; leaving it unchanged (use --force to overwrite)."
else
  log "Writing .env"
  umask 077
  {
    echo "# Generated by deploy_stardew.sh"
    echo "GAME_PORT=\"$GAME_PORT\""
    echo "DISABLE_RENDERING=true"
    echo "STEAM_USER=\"$STEAM_USER\""
    echo "STEAM_PASS=\"$STEAM_PASS\""
    echo "STEAM_GUARD_CODE=\"$STEAM_GUARD_CODE\""
    echo "VNC_PORT=\"$VNC_PORT\""
    echo "VNC_PASSWORD=\"$VNC_PASSWORD\""
  } > .env
fi

# Start the stack
log "Starting containers with docker compose up -d"
docker compose up -d

log "Done. Useful commands:"
echo "  docker compose logs -f"
echo "  docker compose ps"
echo "  docker compose down   # to stop"

popd >/dev/null

log "Ports to expose on your router (Fritz!Box):"
echo "  UDP $GAME_PORT  -> Raspberry Pi (Stardew game)"
echo "  TCP $VNC_PORT   -> Raspberry Pi (Web VNC admin)"
