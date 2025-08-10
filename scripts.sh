#!/usr/bin/env bash

# Purpose: Automate DuckDNS setup on Raspberry Pi (Debian-based)
# - Installs curl (if apt is available)
# - Creates ~/duckdns and installs duck.sh there
# - Ensures duck.sh is executable
# - Adds an idempotent crontab entry to run every 5 minutes with provided domain/token
#
# Usage examples (fish shell friendly):
#   env DUCKDNS_DOMAIN=myfarm DUCKDNS_TOKEN=xxxxxxxx bash ./scripts.sh
#   bash ./scripts.sh --domain myfarm --token xxxxxxxx
# Optional flags:
#   --interval "*/5 * * * *"  Cron schedule (default every 5 minutes)
#   --user pi                  Install crontab for this user (defaults to SUDO_USER if set, else current user)
#   --no-apt                   Skip apt install of curl

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

CRON_INTERVAL="*/5 * * * *"
NO_APT=0

log() { echo "[duckdns-setup] $*"; }
err() { echo "[duckdns-setup][error] $*" >&2; }

usage() {
	cat <<EOF
Usage: $0 [--domain DOMAIN] [--token TOKEN] [--interval CRON] [--user USER] [--no-apt]

Provide domain/token via flags or environment variables DUCKDNS_DOMAIN and DUCKDNS_TOKEN.

Examples (fish shell):
	env DUCKDNS_DOMAIN=myfarm DUCKDNS_TOKEN=xxxxxxxx bash ./scripts.sh
	bash ./scripts.sh --domain myfarm --token xxxxxxxx
EOF
}

DUCKDNS_DOMAIN=${DUCKDNS_DOMAIN:-}
DUCKDNS_TOKEN=${DUCKDNS_TOKEN:-}
TARGET_USER=${SUDO_USER:-${USER}}

while [[ $# -gt 0 ]]; do
	case "$1" in
		-d|--domain)
			DUCKDNS_DOMAIN=${2:-}; shift 2 ;;
		-t|--token)
			DUCKDNS_TOKEN=${2:-}; shift 2 ;;
		-i|--interval)
			CRON_INTERVAL=${2:-}; shift 2 ;;
		-u|--user)
			TARGET_USER=${2:-}; shift 2 ;;
		--no-apt)
			NO_APT=1; shift ;;
		-h|--help)
			usage; exit 0 ;;
		*)
			err "Unknown argument: $1"; usage; exit 1 ;;
	esac
done

if [[ -z "${DUCKDNS_DOMAIN}" || -z "${DUCKDNS_TOKEN}" ]]; then
	err "DUCKDNS_DOMAIN and DUCKDNS_TOKEN are required."
	usage
	exit 1
fi

# Normalize domain: accept either 'subdomain' or 'subdomain.duckdns.org'
RAW_DOMAIN="${DUCKDNS_DOMAIN}"
DUCKDNS_DOMAIN="${RAW_DOMAIN%.duckdns.org}"
if [[ "${DUCKDNS_DOMAIN}" != "${RAW_DOMAIN}" ]]; then
	log "Normalized domain '${RAW_DOMAIN}' -> '${DUCKDNS_DOMAIN}'"
fi

# Resolve target home directory (supports when running with sudo)
TARGET_HOME=$(eval echo "~${TARGET_USER}")
if [[ ! -d "${TARGET_HOME}" ]]; then
	err "Could not resolve home for user '${TARGET_USER}' (got '${TARGET_HOME}')."
	exit 1
fi

log "Using user='${TARGET_USER}', home='${TARGET_HOME}'"

# Install curl if apt available and not skipped
if [[ "${NO_APT}" -eq 0 ]] && command -v apt >/dev/null 2>&1; then
	log "Installing curl via apt (if missing)"
	if [[ $EUID -ne 0 ]]; then
		if command -v sudo >/dev/null 2>&1; then
			sudo apt update -y
			sudo apt install -y curl
		else
			err "apt installation requires root or sudo; skipping curl install."
		fi
	else
		apt update -y
		apt install -y curl
	fi
else
	log "Skipping apt install (either --no-apt or apt not found)."
fi

# Prepare directory
DUCK_DIR="${TARGET_HOME}/duckdns"
mkdir -p "${DUCK_DIR}"

# Copy duck.sh into place and ensure executable
SOURCE_DUCK_SH="${SCRIPT_DIR}/duck.sh"
TARGET_DUCK_SH="${DUCK_DIR}/duck.sh"
if [[ ! -f "${SOURCE_DUCK_SH}" ]]; then
	err "Source duck.sh not found at ${SOURCE_DUCK_SH}. Ensure this repo contains duck.sh."
	exit 1
fi
cp -f "${SOURCE_DUCK_SH}" "${TARGET_DUCK_SH}"
chmod +x "${TARGET_DUCK_SH}"

# Ensure ownership matches target user if running with sudo/root
if command -v chown >/dev/null 2>&1; then
	if [[ "${USER}" != "${TARGET_USER}" || $EUID -eq 0 ]]; then
		if command -v sudo >/dev/null 2>&1; then
			sudo chown -R "${TARGET_USER}:${TARGET_USER}" "${DUCK_DIR}"
		elif [[ $EUID -eq 0 ]]; then
			chown -R "${TARGET_USER}:${TARGET_USER}" "${DUCK_DIR}"
		fi
	fi
fi

# Build cron line (inline env vars so duck.sh gets them)
CRON_CMD="DUCKDNS_DOMAIN='${DUCKDNS_DOMAIN}' DUCKDNS_TOKEN='${DUCKDNS_TOKEN}' ${TARGET_DUCK_SH} >/dev/null 2>&1"
CRON_LINE="${CRON_INTERVAL} ${CRON_CMD}"

# Fetch existing crontab for target user
get_crontab() {
	if [[ "${TARGET_USER}" == "${USER}" ]]; then
		crontab -l 2>/dev/null || true
	else
		if command -v sudo >/dev/null 2>&1; then
			sudo crontab -u "${TARGET_USER}" -l 2>/dev/null || true
		else
			err "Cannot manage crontab for ${TARGET_USER} without sudo. Run with sudo or specify --user ${USER}."
			exit 1
		fi
	fi
}

set_crontab() {
	local file="$1"
	if [[ "${TARGET_USER}" == "${USER}" ]]; then
		crontab "$file"
	else
		sudo crontab -u "${TARGET_USER}" "$file"
	fi
}

CURRENT_CRON=$(get_crontab)

# Remove any existing duck.sh lines to avoid duplicates
FILTERED_CRON=$(echo "$CURRENT_CRON" | awk 'BEGIN{found=0} !/duckdns\/duck.sh/ {print} /duckdns\/duck.sh/ {found=1} END{}')

# Compose new cron content
TMP_CRON=$(mktemp)
{
	echo "$FILTERED_CRON"
	# ensure a newline before adding, if not empty
	if [[ -n "$FILTERED_CRON" ]]; then echo ""; fi
	echo "$CRON_LINE"
} > "$TMP_CRON"

set_crontab "$TMP_CRON"
rm -f "$TMP_CRON"

log "Installed/updated cron entry: ${CRON_LINE}"
log "Setup complete. Log file: ${DUCK_DIR}/duck.log"

