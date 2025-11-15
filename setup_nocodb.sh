#!/usr/bin/env bash
#
# Pal Forge IT – NocoDB stack installer (to be run INSIDE the VM)
# - Installs Docker & dependencies
# - Sets up NocoDB + Postgres + Redis + Traefik + Watchtower using docker compose
# - Optional Cloudflare Tunnel integration
#
# Usage (inside the VM, as root or with sudo):
#   curl -fsSL https://raw.githubusercontent.com/abellpfs/palforge-nocodb-installer/main/setup_nocodb.sh | sudo bash
#

set -euo pipefail

########################
#  Helper functions   #
########################

log() {
  echo -e "\033[1;32m[INFO]\033[0m $*"
}

warn() {
  echo -e "\033[1;33m[WARN]\033[0m $*"
}

err() {
  echo -e "\033[1;31m[ERROR]\033[0m $*" >&2
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    err "This script must be run as root (or via sudo)."
    exit 1
  fi
}

pause() {
  read -rp "Press Enter to continue..." _ || true
}

########################
#  Pre-flight checks   #
########################

require_root

if ! command -v apt >/dev/null 2>&1; then
  err "This script currently supports Debian/Ubuntu (apt-based) systems only."
  exit 1
fi

log "Updating package lists..."
apt-get update -y

########################
#  Install dependencies #
########################

log "Installing base dependencies (curl, ca-certificates, gnupg, jq)..."
apt-get install -y \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  jq

########################
#  Docker Installation #
########################

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker is already installed. Skipping Docker installation."
    return
  fi

  log "Installing Docker Engine and Docker Compose plugin from Docker's official repo..."

  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  UBUNTU_CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
$UBUNTU_CODENAME stable" > /etc/apt/sources.list.d/docker.list

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

install_docker

########################
#  NocoDB stack setup  #
########################

# Base directory for NocoDB stack
BASE_DIR="/opt/nocodb"
COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"

log "Ensuring base directory exists at ${BASE_DIR}..."
mkdir -p "${BASE_DIR}"

log "We will now collect configuration for NocoDB and its services."

# Domain name for Traefik routing (optional but recommended)
read -rp "Enter the domain for NocoDB (e.g. sales.palforge.it) [leave blank for no host routing]: " NOCODB_DOMAIN
NOCODB_DOMAIN="${NOCODB_DOMAIN:-}"

# NocoDB admin config
read -rp "Enter NocoDB admin email [admin@example.com]: " NOCODB_ADMIN_EMAIL
NOCODB_ADMIN_EMAIL="${NOCODB_ADMIN_EMAIL:-admin@example.com}"

# Admin password (required, but we can default to a random if blank)
read -rsp "Enter NocoDB admin password (leave blank to auto-generate): " NOCODB_ADMIN_PASSWORD || true
echo ""
if [[ -z "${NOCODB_ADMIN_PASSWORD}" ]]; then
  NOCODB_ADMIN_PASSWORD="$(openssl rand -base64 18 | tr -d '=+/')"
  log "Generated random admin password: ${NOCODB_ADMIN_PASSWORD}"
fi

# Postgres DB password
read -rsp "Enter Postgres password for 'nocodb' user (leave blank to auto-generate): " POSTGRES_PASSWORD || true
echo ""
if [[ -z "${POSTGRES_PASSWORD}" ]]; then
  POSTGRES_PASSWORD="$(openssl rand -base64 18 | tr -d '=+/')"
  log "Generated random Postgres password: ${POSTGRES_PASSWORD}"
fi

# NocoDB DB URL (Postgres)
NOCODB_DB_URL="postgres://nocodb:${POSTGRES_PASSWORD}@nocodb-postgres:5432/nocodb?sslmode=disable"

# Ask if they want Traefik dashboard exposed (8080 on host)
read -rp "Expose Traefik dashboard on port 8080? (y/N): " EXPOSE_DASH
EXPOSE_DASH="${EXPOSE_DASH:-n}"

########################
#  Optional Cloudflare #
########################

ENABLE_CF_TUNNEL="n"
CF_TOKEN=""
CF_TUNNEL_NAME=""
CF_TUNNEL_HOSTNAME=""

read -rp "Do you want to install and configure a Cloudflare Tunnel for this instance? (y/N): " ENABLE_CF_TUNNEL
ENABLE_CF_TUNNEL="${ENABLE_CF_TUNNEL,,}"  # to lowercase
if [[ "${ENABLE_CF_TUNNEL}" == "y" ]]; then
  log "Cloudflare Tunnel will be installed & configured."

  if [[ -z "${NOCODB_DOMAIN}" ]]; then
    read -rp "Enter hostname to expose via Cloudflare Tunnel (e.g. sales.palforge.it): " CF_TUNNEL_HOSTNAME
  else
    CF_TUNNEL_HOSTNAME="${NOCODB_DOMAIN}"
  fi

  read -rp "Enter your Cloudflare Tunnel token (from Cloudflare dashboard): " CF_TOKEN
  CF_TUNNEL_NAME="nocodb-tunnel"
fi

########################
#  Write docker-compose #
########################

log "Writing docker-compose stack to ${COMPOSE_FILE}..."

cat > "${COMPOSE_FILE}" <<EOF
version: "3.9"

services:
  nocodb:
    image: nocodb/nocodb:latest
    container_name: nocodb-app
    depends_on:
      - nocodb-postgres
      - nocodb-redis
    environment:
      NC_DB: "pg"
      DATABASE_URL: "${NOCODB_DB_URL}"
      NC_PUBLIC_URL: "http://${NOCODB_DOMAIN:-localhost}"
      NC_ADMIN_EMAIL: "${NOCODB_ADMIN_EMAIL}"
      NC_ADMIN_PASSWORD: "${NOCODB_ADMIN_PASSWORD}"
      NC_REDIS_URL: "redis://nocodb-redis:6379"
    restart: unless-stopped
    networks:
      - nocodb-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.services.nocodb.loadbalancer.server.port=8080"
EOF

# Add host routing labels only if domain provided
if [[ -n "${NOCODB_DOMAIN}" ]]; then
  cat >> "${COMPOSE_FILE}" <<EOF
      - "traefik.http.routers.nocodb.rule=Host(\`${NOCODB_DOMAIN}\`)"
      - "traefik.http.routers.nocodb.entrypoints=web"
EOF
else
  cat >> "${COMPOSE_FILE}" <<EOF
      - "traefik.http.routers.nocodb.rule=PathPrefix(\`/\`)"
      - "traefik.http.routers.nocodb.entrypoints=web"
EOF
fi

cat >> "${COMPOSE_FILE}" <<'EOF'

  nocodb-postgres:
    image: postgres:16
    container_name: nocodb-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: nocodb
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: nocodb
    volumes:
      - pgdata:/var/lib/postgresql/data
    networks:
      - nocodb-net

  nocodb-redis:
    image: redis:7-alpine
    container_name: nocodb-redis
    restart: unless-stopped
    networks:
      - nocodb-net

  traefik:
    image: traefik:v3.1
    container_name: nocodb-traefik
    restart: unless-stopped
    command:
      - "--api.dashboard=true"
      - "--api.insecure=true"
      - "--providers.docker=true"
      - "--providers.docker.exposedByDefault=false"
      - "--entrypoints.web.address=:80"
    ports:
      - "80:80"
EOF

# Optionally expose Traefik dashboard
if [[ "${EXPOSE_DASH}" == "y" || "${EXPOSE_DASH}" == "Y" ]]; then
  cat >> "${COMPOSE_FILE}" <<'EOF'
      - "8080:8080"
EOF
fi

cat >> "${COMPOSE_FILE}" <<'EOF'
    networks:
      - nocodb-net
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro

  watchtower:
    image: containrrr/watchtower
    container_name: nocodb-watchtower
    restart: unless-stopped
    command:
      - "--cleanup"
      - "--schedule=0 0 3 * * *"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - nocodb-net

networks:
  nocodb-net:
    driver: bridge

volumes:
  pgdata:
EOF

# Now we must substitute the POSTGRES_PASSWORD in the heredoc above
# because ${POSTGRES_PASSWORD} in a quoted heredoc wouldn't expand.
sed -i "s/POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}/POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}/" "${COMPOSE_FILE}"

log "docker-compose.yml created."

########################
#  Cloudflare Tunnel   #
########################

if [[ "${ENABLE_CF_TUNNEL}" == "y" ]]; then
  log "Installing Cloudflare Tunnel (cloudflared)..."
  # Official Cloudflare repo for Debian/Ubuntu
  if ! command -v cloudflared >/dev/null 2>&1; then
    curl -fsSL https://pkg.cloudflare.com/gpg | gpg --dearmor -o /usr/share/keyrings/cloudflare-main.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/ $(lsb_release -cs) main" \
      > /etc/apt/sources.list.d/cloudflare-main.list
    apt-get update -y
    apt-get install -y cloudflared
  else
    log "cloudflared already installed."
  fi

  # Configure tunnel using token
  log "Configuring Cloudflare Tunnel..."
  mkdir -p /etc/cloudflared
  # Use the token-based service mode
  cloudflared service install "${CF_TOKEN}"

  # Create a config.yml for http://localhost:80
  cat > /etc/cloudflared/config.yml <<EOF
tunnel: ${CF_TUNNEL_NAME}
credentials-file: /etc/cloudflared/${CF_TUNNEL_NAME}.json

ingress:
  - hostname: ${CF_TUNNEL_HOSTNAME}
    service: http://localhost:80
  - service: http_status:404
EOF

  systemctl enable cloudflared
  systemctl restart cloudflared
  log "Cloudflare Tunnel configured for hostname: ${CF_TUNNEL_HOSTNAME}"
fi

########################
#  Bring up stack      #
########################

log "Bringing up NocoDB stack with Docker Compose..."

cd "${BASE_DIR}"

docker compose pull
docker compose up -d

log "NocoDB stack is now running."

########################
#  Summary             #
########################

echo ""
echo "================= NocoDB SETUP COMPLETE ================="
echo "NocoDB URL:"
if [[ -n "${NOCODB_DOMAIN}" ]]; then
  echo "  http://${NOCODB_DOMAIN}"
else
  echo "  http://<this-VM-IP>/"
fi
echo ""
echo "Admin credentials:"
echo "  Email:    ${NOCODB_ADMIN_EMAIL}"
echo "  Password: ${NOCODB_ADMIN_PASSWORD}"
echo ""
echo "Postgres connection (internal):"
echo "  Host:     nocodb-postgres"
echo "  DB:       nocodb"
echo "  User:     nocodb"
echo "  Password: ${POSTGRES_PASSWORD}"
echo ""
if [[ "${EXPOSE_DASH}" == "y" || "${EXPOSE_DASH}" == "Y" ]]; then
  echo "Traefik dashboard (local-only, unless exposed via firewall/Cloudflare):"
  echo "  http://<this-VM-IP>:8080"
fi
if [[ "${ENABLE_CF_TUNNEL}" == "y" ]]; then
  echo ""
  echo "Cloudflare Tunnel:"
  echo "  Hostname: ${CF_TUNNEL_HOSTNAME}"
  echo "  Config:   /etc/cloudflared/config.yml"
fi
echo "=========================================================="
echo ""

log "Done."
