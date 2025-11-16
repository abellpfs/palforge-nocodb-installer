#!/usr/bin/env bash
set -euo pipefail

########################################
# NocoDB + Traefik Setup (VM-friendly)
########################################

#----- Helpers -----#
require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "[ERROR] This script must be run as root (or via sudo)." >&2
    exit 1
  fi
}

ensure_base_dir() {
  BASE_DIR="/opt/nocodb"
  mkdir -p "${BASE_DIR}"
  cd "${BASE_DIR}"
  echo "[INFO] Working directory: ${BASE_DIR}"
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    echo "[INFO] Docker is already installed."
    return
  fi

  echo "[INFO] Docker not found. Installing Docker (docker.io + compose plugin)..."

  apt-get update -y
  apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    jq \
    docker.io \
    docker-compose-plugin

  systemctl enable docker
  systemctl restart docker

  if ! command -v docker >/dev/null 2>&1; then
    echo "[ERROR] Docker installation appears to have failed." >&2
    exit 1
  fi

  echo "[INFO] Docker installed successfully."
}

generate_password() {
  openssl rand -hex 16
}

########################################
# Main Script
########################################

require_root
ensure_base_dir
ensure_docker

echo "======================================="
echo "  NocoDB + Traefik Setup (VM version)  "
echo "======================================="

# Default values (can be overridden by existing compose)
NC_HOST_DEFAULT="sales.palforge.it"
TRAEFIK_HTTP_PORT_DEFAULT="80"
NC_DB_PASSWORD_DEFAULT=""

if [[ -f docker-compose.yml ]]; then
  echo "[INFO] Existing docker-compose.yml detected in $(pwd)."

  # Try to extract existing host
  EXISTING_HOST="$(grep -E 'traefik.http.routers.nocodb.rule=Host' docker-compose.yml 2>/dev/null \
    | sed -E 's/.*Host\(`([^`]+)`.*/\1/' || true)"
  if [[ -n "${EXISTING_HOST}" ]]; then
    NC_HOST_DEFAULT="${EXISTING_HOST}"
    echo "[INFO] Detected existing domain: ${NC_HOST_DEFAULT}"
  fi

  # Try to extract existing HTTP port
  EXISTING_PORT="$(grep -E '"[0-9]+:80"' docker-compose.yml 2>/dev/null \
    | head -n1 \
    | sed -E 's/.*"([0-9]+):80".*/\1/' || true)"
  if [[ -n "${EXISTING_PORT}" ]]; then
    TRAEFIK_HTTP_PORT_DEFAULT="${EXISTING_PORT}"
    echo "[INFO] Detected existing HTTP port: ${TRAEFIK_HTTP_PORT_DEFAULT}"
  fi

  # Try to extract existing DB password (do NOT echo it back)
  EXISTING_DB_PW="$(grep -E 'POSTGRES_PASSWORD=' docker-compose.yml 2>/dev/null \
    | sed -E 's/.*POSTGRES_PASSWORD=([^"]+).*/\1/' || true)"
  if [[ -n "${EXISTING_DB_PW}" ]]; then
    NC_DB_PASSWORD_DEFAULT="${EXISTING_DB_PW}"
    echo "[INFO] Detected existing Postgres password (will be reused if left blank)."
  fi

  echo
  read -rp "Existing configuration found. Do you want to CHANGE domain/port/password? [y/N]: " CHANGE_CFG
  CHANGE_CFG=${CHANGE_CFG:-n}
else
  CHANGE_CFG="y"
fi

NC_HOST=""
TRAEFIK_HTTP_PORT=""
NC_DB_PASSWORD=""

if [[ "${CHANGE_CFG}" == "y" || "${CHANGE_CFG}" == "Y" ]]; then
  echo
  echo "[INFO] We will collect configuration for NocoDB and its services."

  # Domain
  read -rp "Domain for NocoDB [${NC_HOST_DEFAULT}]: " NC_HOST
  NC_HOST=${NC_HOST:-${NC_HOST_DEFAULT}}

  # HTTP Port
  read -rp "External HTTP port for Traefik [${TRAEFIK_HTTP_PORT_DEFAULT}]: " TRAEFIK_HTTP_PORT
  TRAEFIK_HTTP_PORT=${TRAEFIK_HTTP_PORT:-${TRAEFIK_HTTP_PORT_DEFAULT}}

  # DB Password
  echo
  if [[ -n "${NC_DB_PASSWORD_DEFAULT}" ]]; then
    echo "Postgres password for 'nocodb' user:"
    echo "  - Leave blank to REUSE existing password"
    echo "  - Or type a new password to change it"
    read -rsp "Postgres password [reuse existing]: " NC_DB_PASSWORD
    echo

    if [[ -z "${NC_DB_PASSWORD}" ]]; then
      NC_DB_PASSWORD="${NC_DB_PASSWORD_DEFAULT}"
      echo "[INFO] Reusing existing Postgres password."
    fi
  else
    read -rsp "Postgres password for 'nocodb' user [auto-generate]: " NC_DB_PASSWORD
    echo
    if [[ -z "${NC_DB_PASSWORD}" ]]; then
      NC_DB_PASSWORD="$(generate_password)"
      echo "[INFO] Generated DB password: ${NC_DB_PASSWORD}"
    fi
  fi
else
  # Reuse existing settings without prompting (except for missing values)
  NC_HOST="${NC_HOST_DEFAULT}"
  TRAEFIK_HTTP_PORT="${TRAEFIK_HTTP_PORT_DEFAULT}"

  if [[ -n "${NC_DB_PASSWORD_DEFAULT}" ]]; then
    NC_DB_PASSWORD="${NC_DB_PASSWORD_DEFAULT}"
  else
    NC_DB_PASSWORD="$(generate_password)"
    echo "[INFO] No existing DB password found; generated new one: ${NC_DB_PASSWORD}"
  fi
fi

NC_PUBLIC_URL="https://${NC_HOST}"

echo
echo "=========== Summary ==========="
echo "  Domain:           ${NC_HOST}"
echo "  Public URL:       ${NC_PUBLIC_URL}"
echo "  HTTP Port:        ${TRAEFIK_HTTP_PORT}"
echo "  DB Password:      ${NC_DB_PASSWORD}"
echo "==============================="
echo

read -rp "Proceed and write docker-compose.yml + start stack? [y/N]: " CONFIRM
CONFIRM=${CONFIRM:-n}
if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
  echo "[INFO] Aborting setup."
  exit 0
fi

########################################
# Write docker-compose.yml (minimal changes from your version)
########################################

cat > docker-compose.yml <<EOF
version: "3.9"

services:
  traefik:
    image: traefik:v3.1
    container_name: nocodb-traefik-1
    command:
      - --api.dashboard=true
      - --api.insecure=false
      - --providers.docker=true
      - --providers.docker.exposedByDefault=false
      - --providers.docker.endpoint=unix:///var/run/docker.sock
      - --entrypoints.web.address=:80
    ports:
      - "${TRAEFIK_HTTP_PORT}:80"
      - "8080:8080"   # Traefik dashboard (http://<host>:8080) - protect via firewall/Cloudflare
    environment:
      - DOCKER_API_VERSION=1.44
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

  app:
    image: nocodb/nocodb:latest
    container_name: nocodb-app
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

echo "[INFO] docker-compose.yml written to $(pwd)/docker-compose.yml"

# 3. Ensure data dirs exist
mkdir -p data/postgres data/redis

# 4. Bring stack up
echo "[INFO] Starting stack: docker compose up -d"
docker compose up -d

echo
echo "======================================="
echo "  NocoDB stack is starting up."
echo "  URL: ${NC_PUBLIC_URL}"
echo "======================================="
echo "If you're using Cloudflare, make sure ${NC_HOST} points to this VM."
echo "You can also test locally with:"
echo "  curl -v http://localhost -H \"Host: ${NC_HOST}\""
