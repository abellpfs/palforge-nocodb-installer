#!/usr/bin/env bash
#
# NocoDB + Traefik + Postgres + Redis installer (for use INSIDE the VM)
# Run as:
#   sudo bash setup_nocodb.sh
# or:
#   bash <(curl -sSL https://raw.githubusercontent.com/abellpfs/palforge-nocodb-installer/main/setup_nocodb.sh)
#

set -euo pipefail

########################################
# Helpers
########################################
log() {
  echo "[INFO] $*"
}

warn() {
  echo "[WARN] $*" >&2
}

err() {
  echo "[ERROR] $*" >&2
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "This script must be run as root (or via sudo)."
    exit 1
  fi
}

gen_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32 | tr -d '=+/ ' | cut -c1-24
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
  fi
}

########################################
# Docker install / check
########################################
install_docker() {
  log "Docker not found. Installing Docker Engine + compose plugin..."

  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release jq

  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  local codename
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"

  echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  systemctl enable docker
  systemctl restart docker

  log "Docker installed successfully."
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    install_docker
  else
    log "Docker is already installed."
  fi

  if ! docker info >/dev/null 2>&1; then
    err "Docker daemon is not running or not accessible. Check 'systemctl status docker'."
    exit 1
  fi

  if ! docker compose version >/dev/null 2>&1; then
    err "docker compose plugin not available. Ensure 'docker-compose-plugin' is installed."
    exit 1
  fi
}

########################################
# Cloudflare (apt-based, systemd service)
########################################
ensure_cloudflared_installed() {
  if command -v cloudflared >/dev/null 2>&1; then
    log "cloudflared already installed."
    return
  fi

  log "Installing cloudflared via apt..."

  mkdir -p --mode=0755 /usr/share/keyrings
  if [[ ! -f /usr/share/keyrings/cloudflare-public-v2.gpg ]]; then
    curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg \
      | tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null
  fi

  echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' \
    > /etc/apt/sources.list.d/cloudflared.list

  apt-get update -y
  apt-get install -y cloudflared

  log "cloudflared installed."
}

configure_cloudflared_service() {
  local token="$1"

  ensure_cloudflared_installed

  # If config already exists, assume it's already set up
  if [[ -f /etc/cloudflared/config.yml ]]; then
    warn "cloudflared already appears to be configured (/etc/cloudflared/config.yml exists)."
    warn "Skipping 'cloudflared service install'. If you need to reconfigure, remove that file first."
  else
    log "Running 'cloudflared service install' with provided token..."
    cloudflared service install "${token}"
  fi

  systemctl daemon-reload || true
  systemctl enable --now cloudflared || true

  log "cloudflared systemd service is installed and (should be) running."
}

########################################
# Main
########################################
require_root

echo "======================================="
echo "  NocoDB + Traefik Installer (VM)      "
echo "======================================="

log "Updating apt and installing base dependencies..."
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release jq

ensure_docker

BASE_DIR="/opt/nocodb"
log "Ensuring base directory exists at ${BASE_DIR}..."
mkdir -p "${BASE_DIR}"

########################################
# Collect configuration
########################################
log "We will now collect configuration for NocoDB and its services."

# Domain for Host routing
read -rp "Enter the domain for NocoDB (e.g. sales.palforge.it) [leave blank for no host routing]: " DOMAIN
DOMAIN="${DOMAIN:-}"

# Postgres password
read -rp "Enter Postgres password for 'nocodb' user (leave blank to auto-generate): " -s PG_PASSWORD
echo
if [[ -z "${PG_PASSWORD}" ]]; then
  PG_PASSWORD="$(gen_password)"
  log "Generated random Postgres password: ${PG_PASSWORD}"
else
  log "Using provided Postgres password."
fi

# Traefik dashboard
read -rp "Expose Traefik dashboard on port 8080? (y/N): " EXPOSE_DASHBOARD
EXPOSE_DASHBOARD="${EXPOSE_DASHBOARD:-n}"
EXPOSE_DASHBOARD="$(echo "${EXPOSE_DASHBOARD}" | tr '[:upper:]' '[:lower:]')"

# Watchtower
read -rp "Install Watchtower for automatic image updates? (y/N): " USE_WATCHTOWER
USE_WATCHTOWER="${USE_WATCHTOWER:-n}"
USE_WATCHTOWER="$(echo "${USE_WATCHTOWER}" | tr '[:upper:]' '[:lower:]')"

# Cloudflare Tunnel (apt + systemd)
read -rp "Install & configure Cloudflare Tunnel via cloudflared service? (y/N): " USE_CLOUDFLARE
USE_CLOUDFLARE="${USE_CLOUDFLARE:-n}"
USE_CLOUDFLARE="$(echo "${USE_CLOUDFLARE}" | tr '[:upper:]' '[:lower:]')"

CLOUDFLARE_TOKEN=""
if [[ "${USE_CLOUDFLARE}" == "y" ]]; then
  read -rp "Enter your Cloudflare Tunnel token (from Cloudflare dashboard): " CLOUDFLARE_TOKEN
  if [[ -z "${CLOUDFLARE_TOKEN}" ]]; then
    err "Cloudflare Tunnel token cannot be empty if you enabled Cloudflare Tunnel."
    exit 1
  fi
fi

########################################
# Generate docker-compose.yml
########################################
log "Writing docker-compose stack to ${BASE_DIR}/docker-compose.yml..."

# Build ports block for traefik
TRAEFIK_PORTS="
    ports:
      - \"80:80\""
if [[ "${EXPOSE_DASHBOARD}" == "y" ]]; then
  TRAEFIK_PORTS="${TRAEFIK_PORTS}
      - \"8080:8080\""
fi

# Optional Watchtower service
WATCHTOWER_BLOCK=""
if [[ "${USE_WATCHTOWER}" == "y" ]]; then
  WATCHTOWER_BLOCK=$(cat <<'EOF_WT'

  watchtower:
    image: containrrr/watchtower:latest
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    command: --cleanup --interval 86400
EOF_WT
)
fi

cat > "${BASE_DIR}/docker-compose.yml" <<EOF
services:
  traefik:
    image: traefik:v3.1
    restart: unless-stopped
    command:
      - "--api.dashboard=true"
      - "--api.insecure=true"
      - "--providers.docker=true"
      - "--providers.docker.exposedByDefault=false"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.traefik.address=:8080"
    environment:
      - DOCKER_API_VERSION=1.44
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
${TRAEFIK_PORTS}

  nocodb:
    image: nocodb/nocodb:latest
    restart: unless-stopped
    depends_on:
      - nocodb-postgres
      - nocodb-redis
    environment:
      - NC_DB=pg://nocodb-postgres:5432?u=nocodb&p=${PG_PASSWORD}&d=nocodb
      - NC_REDIS_ENABLED=true
      - NC_REDIS_URL=redis://nocodb-redis:6379
    labels:
      - "traefik.enable=true"
EOF

# Add routing rule
if [[ -n "${DOMAIN}" ]]; then
  cat >> "${BASE_DIR}/docker-compose.yml" <<EOF
      - "traefik.http.routers.nocodb.rule=Host(\`${DOMAIN}\`)"
EOF
else
  cat >> "${BASE_DIR}/docker-compose.yml" <<EOF
      - "traefik.http.routers.nocodb.rule=PathPrefix(\`/\`)"
EOF
fi

cat >> "${BASE_DIR}/docker-compose.yml" <<'EOF'
      - "traefik.http.routers.nocodb.entrypoints=web"

  nocodb-postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      - POSTGRES_USER=nocodb
      - POSTGRES_PASSWORD=__PG_PASSWORD__
      - POSTGRES_DB=nocodb
    volumes:
      - nocodb-postgres-data:/var/lib/postgresql/data

  nocodb-redis:
    image: redis:7-alpine
    restart: unless-stopped
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - nocodb-redis-data:/data
EOF

# Substitute Postgres password
sed -i "s/__PG_PASSWORD__/${PG_PASSWORD}/g" "${BASE_DIR}/docker-compose.yml"

# Append Watchtower if enabled
if [[ -n "${WATCHTOWER_BLOCK}" ]]; then
  echo "${WATCHTOWER_BLOCK}" >> "${BASE_DIR}/docker-compose.yml"
fi

# Volumes block
cat >> "${BASE_DIR}/docker-compose.yml" <<'EOF'

volumes:
  nocodb-postgres-data:
  nocodb-redis-data:
EOF

log "docker-compose.yml created."

########################################
# Start NocoDB stack
########################################
cd "${BASE_DIR}"

log "Pulling images..."
docker compose pull

log "Starting NocoDB stack..."
docker compose up -d

log "Current container status:"
docker compose ps

########################################
# Cloudflare configuration (if requested)
########################################
if [[ "${USE_CLOUDFLARE}" == "y" ]]; then
  configure_cloudflared_service "${CLOUDFLARE_TOKEN}"
fi

########################################
# Final info
########################################
HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<your-vm-ip>")

echo
echo "======================================="
echo "        NocoDB Deployment Info         "
echo "======================================="
echo "Postgres user:     nocodb"
echo "Postgres password: ${PG_PASSWORD}"
echo "Postgres database: nocodb"
echo
if [[ -n "${DOMAIN}" ]]; then
  echo "NocoDB (via Traefik):        http://${DOMAIN}"
fi
echo "Local NocoDB (via Traefik):  http://${HOST_IP}"
if [[ "${EXPOSE_DASHBOARD}" == "y" ]]; then
  echo "Traefik dashboard:           http://${HOST_IP}:8080"
fi
if [[ "${USE_CLOUDFLARE}" == "y" ]]; then
  echo
  echo "Cloudflare Tunnel:"
  echo "- cloudflared installed via apt and running as a systemd service."
  echo "- DNS & hostname for the tunnel are managed in your Cloudflare dashboard."
fi
echo
echo "On first visit, NocoDB will prompt you to create the initial admin account."
echo "All done."
