#!/usr/bin/env bash
set -euo pipefail

############################################
# NocoDB + Traefik Installer (VM)
# - Installs deps + Docker (with compose)
# - Ensures Docker min-api-version=1.24
# - Writes docker-compose.yml (Traefik+NocoDB+PG+Redis)
# - Optional Cloudflare Tunnel integration
############################################

if [[ "$EUID" -ne 0 ]]; then
  echo "[ERROR] This script must be run as root (or via sudo)." >&2
  exit 1
fi

WORKDIR="/opt/nocodb"
echo "[INFO] Working directory: ${WORKDIR}"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

############################################
# 1. Install base dependencies
############################################
echo "[INFO] Installing base dependencies (curl, openssl, jq, etc.)..."
apt-get update -y
apt-get install -y \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  jq \
  openssl

############################################
# 2. Install Docker (if missing)
############################################
if ! command -v docker >/dev/null 2>&1; then
  echo "[INFO] Docker not found. Installing Docker CE & compose plugin..."

  # Remove any old Docker bits
  apt-get remove -y docker docker-engine docker.io containerd runc || true

  # Set up Docker's official repo
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  . /etc/os-release
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    ${UBUNTU_CODENAME} stable" > /etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  systemctl enable --now docker
  echo "[INFO] Docker installed successfully."
else
  echo "[INFO] Docker already installed."
fi

############################################
# 3. Ensure Docker daemon.json has min-api-version
############################################
DAEMON_JSON="/etc/docker/daemon.json"

if [[ ! -f "${DAEMON_JSON}" ]]; then
  echo "[INFO] Creating ${DAEMON_JSON} with min-api-version and log settings..."
  cat > "${DAEMON_JSON}" <<'EOF'
{
  "min-api-version": "1.24",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
else
  echo "[INFO] ${DAEMON_JSON} already exists. Ensuring min-api-version is present..."
  if ! grep -q '"min-api-version"' "${DAEMON_JSON}"; then
    tmpfile=$(mktemp)
    if jq '. + {"min-api-version": "1.24"}' "${DAEMON_JSON}" > "${tmpfile}" 2>/dev/null; then
      mv "${tmpfile}" "${DAEMON_JSON}"
      echo "[INFO] Added \"min-api-version\": \"1.24\" to existing daemon.json."
    else
      echo "[WARN] Failed to parse ${DAEMON_JSON} as JSON. Overwriting with safe default."
      cat > "${DAEMON_JSON}" <<'EOF'
{
  "min-api-version": "1.24",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
    fi
  else
    echo "[INFO] min-api-version already present in daemon.json."
  fi
fi

echo "[INFO] Restarting Docker to apply daemon.json changes (min-api-version=1.24)..."
systemctl restart docker || true

############################################
# 4. Detect existing stack / warn about overwrite
############################################
if [[ -f "docker-compose.yml" ]]; then
  echo "============================================================"
  echo "[WARN] Existing docker-compose.yml detected in ${WORKDIR}."
  echo "      Re-running this script will overwrite it."
  echo "      This is how you change domain/ports/DB password."
  echo "============================================================"
  read -rp "Do you want to overwrite docker-compose.yml with new settings? (y/N): " OVERWRITE
  OVERWRITE=${OVERWRITE:-n}
  if [[ ! "${OVERWRITE}" =~ ^[Yy]$ ]]; then
    echo "[INFO] Aborting to avoid overwriting existing compose file."
    exit 0
  fi
fi

############################################
# 5. Collect configuration
############################################
echo "[INFO] We will now collect configuration for NocoDB and Traefik."

read -rp "Domain for NocoDB [sales.palforge.it]: " NC_HOST
NC_HOST=${NC_HOST:-sales.palforge.it}

read -rp "External HTTP port for Traefik [80]: " TRAEFIK_HTTP_PORT
TRAEFIK_HTTP_PORT=${TRAEFIK_HTTP_PORT:-80}

read -rsp "Postgres password for 'nocodb' user (leave blank to auto-generate): " NC_DB_PASSWORD
echo
if [[ -z "${NC_DB_PASSWORD}" ]]; then
  NC_DB_PASSWORD=$(openssl rand -hex 16)
  echo "[INFO] Generated random Postgres password: ${NC_DB_PASSWORD}"
fi

NC_PUBLIC_URL="https://${NC_HOST}"

echo
read -rp "Do you want to install and configure a Cloudflare Tunnel for this instance? (y/N): " CF_USE_TUNNEL
CF_USE_TUNNEL=${CF_USE_TUNNEL:-n}
CF_TUNNEL_TOKEN=""
if [[ "${CF_USE_TUNNEL}" =~ ^[Yy]$ ]]; then
  read -rp "Enter your Cloudflare Tunnel token: " CF_TUNNEL_TOKEN
fi

echo
echo "========== Summary =========="
echo "  Domain:            ${NC_HOST}"
echo "  Public URL:        ${NC_PUBLIC_URL}"
echo "  HTTP Port:         ${TRAEFIK_HTTP_PORT}"
echo "  DB Password:       ${NC_DB_PASSWORD}"
echo "  Cloudflare Tunnel: ${CF_USE_TUNNEL}"
echo "============================="
echo

read -rp "Proceed to write docker-compose.yml and start stack? (y/N): " CONFIRM
CONFIRM=${CONFIRM:-n}
if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
  echo "[INFO] Aborting by user choice."
  exit 0
fi

############################################
# 6. Write docker-compose.yml
############################################
echo "[INFO] Writing docker-compose.yml..."

cat > docker-compose.yml <<EOF
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
      - NC_REDIS_URL=redis://nocodb-redis:6379
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

echo "[INFO] docker-compose.yml written."

############################################
# 7. Create data directories
############################################
mkdir -p data/postgres data/redis

############################################
# 8. Bring stack up
############################################
echo "[INFO] Pulling latest images..."
docker compose pull

echo "[INFO] Starting NocoDB stack with: docker compose up -d"
docker compose up -d

echo "[INFO] Current containers:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

############################################
# 9. Install & configure Cloudflare Tunnel (optional)
############################################
if [[ "${CF_USE_TUNNEL}" =~ ^[Yy]$ && -n "${CF_TUNNEL_TOKEN}" ]]; then
  echo "[INFO] Installing Cloudflare Tunnel (cloudflared)..."

  mkdir -p --mode=0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg \
    | tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null

  echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' \
    > /etc/apt/sources.list.d/cloudflared.list

  apt-get update -y
  apt-get install -y cloudflared

  echo "[INFO] Configuring cloudflared service with your tunnel token..."
  cloudflared service install "${CF_TUNNEL_TOKEN}"
  systemctl enable --now cloudflared || true

  echo "[INFO] Cloudflare Tunnel configured. Ensure your DNS in Cloudflare points to this tunnel."
fi

############################################
# 10. Health check via Traefik
############################################
echo "[INFO] Waiting a few seconds for services to settle..."
sleep 8

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost -H "Host: ${NC_HOST}" || echo "000")

if [[ "${HTTP_CODE}" == "200" || "${HTTP_CODE}" == "302" ]]; then
  echo "===================================================="
  echo "[OK] Traefik is routing correctly for Host: ${NC_HOST}"
  echo "     HTTP status: ${HTTP_CODE}"
  echo "     NocoDB should be available at: ${NC_PUBLIC_URL}"
  echo "===================================================="
else
  echo "===================================================="
  echo "[WARN] Traefik returned HTTP ${HTTP_CODE} for Host: ${NC_HOST}"
  echo "      - Check Traefik logs:"
  echo "          docker logs nocodb-traefik --tail=100"
  echo "      - Check NocoDB logs:"
  echo "          docker logs nocodb-nocodb --tail=100"
  echo "      - Manually test from this VM:"
  echo "          curl -v http://localhost -H \"Host: ${NC_HOST}\""
  echo "===================================================="
fi
