#!/usr/bin/env bash
set -euo pipefail

########################################
# NocoDB + Traefik Setup / Installer
# - Installs Docker if missing
# - Ensures daemon.json min-api-version
# - Writes docker-compose.yml
# - Reuses existing config if desired
########################################

BASE_DIR="/opt/nocodb"
DEFAULT_DOMAIN="sales.palforge.it"
DEFAULT_HTTP_PORT="80"

echo "======================================="
echo "  NocoDB + Traefik Setup (Pal Forge)   "
echo "======================================="

# Must be root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[ERROR] This script must be run as root (or via sudo)." >&2
  exit 1
fi

# Ensure base dir
mkdir -p "${BASE_DIR}"
cd "${BASE_DIR}"

########################################
# Docker install / check
########################################
if ! command -v docker >/dev/null 2>&1; then
  echo "[INFO] Docker not found. Installing via get.docker.com..."
  curl -fsSL https://get.docker.com | sh

  echo "[INFO] Enabling and starting Docker service..."
  systemctl enable docker >/dev/null 2>&1 || true
  systemctl restart docker || systemctl start docker
else
  echo "[INFO] Docker is already installed."
fi

# Ensure docker is actually working
if ! docker version >/dev/null 2>&1; then
  echo "[ERROR] Docker appears installed but 'docker version' failed."
  exit 1
fi

########################################
# Ensure /etc/docker/daemon.json (min-api-version)
########################################
if [[ ! -d /etc/docker ]]; then
  mkdir -p /etc/docker
fi

if [[ ! -f /etc/docker/daemon.json ]]; then
  echo "[INFO] Creating /etc/docker/daemon.json with min-api-version..."
  cat >/etc/docker/daemon.json <<'EOF'
{
  "min-api-version": "1.24",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
  systemctl restart docker || true
else
  echo "[INFO] /etc/docker/daemon.json already exists; not modifying it."
  echo "       (Ensure it has 'min-api-version' set the way you like.)"
fi

########################################
# Determine docker compose command
########################################
DOCKER_COMPOSE_CMD="docker compose"
if ! ${DOCKER_COMPOSE_CMD} version >/dev/null 2>&1; then
  if command -v docker-compose >/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD="docker-compose"
  else
    echo "[ERROR] Neither 'docker compose' nor 'docker-compose' is available." >&2
    echo "        Docker install might have failed. Check Docker and rerun." >&2
    exit 1
  fi
fi
echo "[INFO] Using compose command: ${DOCKER_COMPOSE_CMD}"

########################################
# Existing config detection
########################################
EXISTING_COMPOSE=false
CURRENT_DOMAIN="${DEFAULT_DOMAIN}"

if [[ -f "${BASE_DIR}/docker-compose.yml" ]]; then
  EXISTING_COMPOSE=true
  echo "[INFO] Existing docker-compose.yml detected at ${BASE_DIR}/docker-compose.yml"

  # Try to extract current hostname from existing compose
  existing_rule="$(grep -E 'traefik.http.routers.nocodb.rule=Host' docker-compose.yml || true)"
  if [[ -n "${existing_rule}" ]]; then
    # Expect something like: traefik.http.routers.nocodb.rule=Host(`sales.palforge.it`)
    CURRENT_DOMAIN="$(echo "${existing_rule}" | sed -E 's/.*Host\(`([^`]+)`\).*/\1/')"
  fi

  echo "  Detected current domain: ${CURRENT_DOMAIN}"
  echo
  read -rp "Do you want to KEEP the current config and just (re)start the stack? [Y/n]: " REUSE
  REUSE=${REUSE:-Y}
  if [[ "${REUSE}" =~ ^[Yy]$ ]]; then
    echo "[INFO] Reusing existing configuration. Bringing stack up..."
    ${DOCKER_COMPOSE_CMD} up -d
    echo
    echo "======================================="
    echo "  Stack restarted with existing config "
    echo "  NocoDB should be at: https://${CURRENT_DOMAIN}"
    echo "======================================="
    exit 0
  else
    echo "[INFO] Will rebuild docker-compose.yml (domain, ports, DB password, etc.)."
    echo "       If you already have data in Postgres, changing DB password may break it."
  fi
fi

########################################
# New / updated configuration prompts
########################################
echo
echo "[INFO] We will now collect configuration for NocoDB and Traefik."

read -rp "Domain for NocoDB [${CURRENT_DOMAIN}]: " NC_HOST
NC_HOST=${NC_HOST:-${CURRENT_DOMAIN}}

read -rp "External HTTP port for Traefik [${DEFAULT_HTTP_PORT}]: " TRAEFIK_HTTP_PORT
TRAEFIK_HTTP_PORT=${TRAEFIK_HTTP_PORT:-${DEFAULT_HTTP_PORT}}

# DB password
read -rsp "Postgres password for 'nocodb' user [leave blank to auto-generate]: " NC_DB_PASSWORD
echo
if [[ -z "${NC_DB_PASSWORD}" ]]; then
  NC_DB_PASSWORD="$(openssl rand -hex 16)"
  echo "[INFO] Generated random DB password: ${NC_DB_PASSWORD}"
fi

NC_PUBLIC_URL="https://${NC_HOST}"

echo
echo "=== Summary ==="
echo "  Domain:           ${NC_HOST}"
echo "  Public URL:       ${NC_PUBLIC_URL}"
echo "  HTTP Port:        ${TRAEFIK_HTTP_PORT}"
echo "  DB Password:      ${NC_DB_PASSWORD}"
echo

read -rp "Proceed, write docker-compose.yml and start stack? [y/N]: " CONFIRM
CONFIRM=${CONFIRM:-n}
if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
  echo "Aborting."
  exit 1
fi

########################################
# Write docker-compose.yml
########################################
cat > "${BASE_DIR}/docker-compose.yml" <<EOF
version: "3.9"

services:
  traefik:
    image: traefik:v3.1
    container_name: nocodb-traefik
    command:
      - --api.dashboard=true
      - --api.insecure=false
      - --providers.docker=true
      - --providers.docker.exposedByDefault=false
      - --entrypoints.web.address=:80
    ports:
      - "${TRAEFIK_HTTP_PORT}:80"
      - "8080:8080"   # Traefik dashboard (http://<host>:8080) - protect via firewall / Cloudflare
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - nocodb-net
    restart: unless-stopped

  postgres:
    image: postgres:16-alpine
    container_name: nocodb-postgres
    environment:
      - POSTGRES_DB=nocodb
      - POSTGRES_USER=nocodb
      - POSTGRES_PASSWORD=${NC_DB_PASSWORD}
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    networks:
      - nocodb-net
    restart: unless-stopped

  redis:
    image: redis:7-alpine
    container_name: nocodb-redis
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - ./data/redis:/data
    networks:
      - nocodb-net
    restart: unless-stopped

  nocodb:
    image: nocodb/nocodb:latest
    container_name: nocodb-nocodb
    depends_on:
      - postgres
      - redis
    environment:
      - NC_DB=pg
      - NC_DB_HOST=postgres
      - NC_DB_PORT=5432
      - NC_DB_USER=nocodb
      - NC_DB_PASSWORD=${NC_DB_PASSWORD}
      - NC_DB_NAME=nocodb
      - NC_REDIS_URL=redis://redis:6379
      - NC_PUBLIC_URL=${NC_PUBLIC_URL}
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.nocodb.rule=Host(\`${NC_HOST}\`)"
      - "traefik.http.routers.nocodb.entrypoints=web"
      - "traefik.http.services.nocodb.loadbalancer.server.port=8080"
    networks:
      - nocodb-net
    restart: unless-stopped

networks:
  nocodb-net:
    driver: bridge
EOF

echo "[INFO] docker-compose.yml written to ${BASE_DIR}/docker-compose.yml"

########################################
# Ensure data dirs exist
########################################
mkdir -p "${BASE_DIR}/data/postgres" "${BASE_DIR}/data/redis"

########################################
# Bring stack up
########################################
echo "[INFO] Starting stack with: ${DOCKER_COMPOSE_CMD} up -d"
${DOCKER_COMPOSE_CMD} up -d

echo
echo "======================================="
echo "  NocoDB + Traefik stack is up        "
echo "  URL: ${NC_PUBLIC_URL}"
echo "======================================="
echo "If you're using Cloudflare, ensure a DNS record for ${NC_HOST}"
echo "points to this VM (or Cloudflare Tunnel) correctly."
