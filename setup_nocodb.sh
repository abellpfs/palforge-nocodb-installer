#!/usr/bin/env bash
set -euo pipefail

#############################################
#  Pal Forge IT - NocoDB + Traefik Installer
#  Target: Ubuntu 24.04 VM (Proxmox cloud-init)
#############################################

#----- Helper: require root -----#
if [[ "${EUID}" -ne 0 ]]; then
  echo "[ERROR] This script must be run as root (or via sudo)." >&2
  exit 1
fi

#----- Helper: log -----#
log()  { echo "[INFO] $*"; }
warn() { echo "===================================================="; echo "[WARN] $*"; echo "===================================================="; }

#----- 1. Ensure working dir -----#
BASE_DIR="/opt/nocodb"
log "Working directory: ${BASE_DIR}"
mkdir -p "${BASE_DIR}"
cd "${BASE_DIR}"

#----- 2. Install base deps -----#
log "Ensuring base dependencies (curl, ca-certificates, gnupg, lsb-release, jq)..."
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release jq

#----- 3. Install Docker (engine + compose plugin) if missing -----#
if ! command -v docker >/dev/null 2>&1; then
  log "Docker not found. Installing Docker via get.docker.com..."
  curl -fsSL https://get.docker.com | sh
  log "Docker installed successfully."

  # Enable & start Docker
  systemctl enable docker
  systemctl restart docker
else
  log "Docker is already installed."
fi

#----- 4. Force Docker daemon API compatibility (min-api-version) -----#
DAEMON_JSON="/etc/docker/daemon.json"
log "Configuring Docker daemon JSON for min-api-version compatibility..."
if [[ -f "${DAEMON_JSON}" ]]; then
  cp "${DAEMON_JSON}" "${DAEMON_JSON}.bak.$(date +%s)" || true
fi

cat > "${DAEMON_JSON}" <<EOF
{
  "min-api-version": "1.24",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

log "Restarting Docker to apply daemon.json..."
systemctl restart docker

#----- 5. Check for existing stack -----#
DEFAULT_DOMAIN="sales.palforge.it"
if [[ -f "${BASE_DIR}/docker-compose.yml" ]]; then
  # try to grab domain from existing compose
  EXISTING_DOMAIN=$(grep -oP 'traefik.http.routers.nocodb.rule=Host\(`\K[^`]+' docker-compose.yml || true)
  if [[ -n "${EXISTING_DOMAIN:-}" ]]; then
    DEFAULT_DOMAIN="${EXISTING_DOMAIN}"
  fi

  warn "Existing docker-compose.yml detected in ${BASE_DIR}."
  echo "Current configured domain (if detected): ${EXISTING_DOMAIN:-<none>}"
  read -rp "Do you want to overwrite and recreate the stack? [y/N]: " OVERWRITE
  OVERWRITE=${OVERWRITE:-n}
  if [[ "${OVERWRITE}" != "y" && "${OVERWRITE}" != "Y" ]]; then
    echo "[INFO] Aborting: existing stack left untouched."
    exit 0
  fi
fi

#----- 6. Collect configuration -----#
log "We will now collect configuration for NocoDB and Traefik."

read -rp "Enter the domain for NocoDB (e.g. sales.palforge.it) [${DEFAULT_DOMAIN}]: " NC_HOST
NC_HOST=${NC_HOST:-${DEFAULT_DOMAIN}}

read -rp "External HTTP port for Traefik [80]: " TRAEFIK_HTTP_PORT
TRAEFIK_HTTP_PORT=${TRAEFIK_HTTP_PORT:-80}

read -rp "Enter NocoDB admin email [admin@example.com]: " NC_ADMIN_EMAIL
NC_ADMIN_EMAIL=${NC_ADMIN_EMAIL:-admin@example.com}

read -rsp "Enter NocoDB admin password (leave blank to auto-generate): " NC_ADMIN_PASSWORD
echo
if [[ -z "${NC_ADMIN_PASSWORD}" ]]; then
  NC_ADMIN_PASSWORD=$(openssl rand -base64 16)
  log "Generated random NocoDB admin password: ${NC_ADMIN_PASSWORD}"
fi

read -rsp "Enter Postgres password for 'nocodb' user (leave blank to auto-generate): " NC_DB_PASSWORD
echo
if [[ -z "${NC_DB_PASSWORD}" ]]; then
  NC_DB_PASSWORD=$(openssl rand -base64 24)
  log "Generated random Postgres password: ${NC_DB_PASSWORD}"
fi

# PUBLIC URL for NocoDB
NC_PUBLIC_URL="https://${NC_HOST}"

# Ask about Traefik dashboard (always mapped to 8080, but we may warn)
read -rp "Expose Traefik dashboard on port 8080? (y/N): " EXPOSE_DASH
EXPOSE_DASH=${EXPOSE_DASH:-n}

# Ask for Cloudflare Tunnel
read -rp "Do you want to install and configure a Cloudflare Tunnel for this instance? (y/N): " USE_CF
USE_CF=${USE_CF:-n}
CF_TOKEN=""
if [[ "${USE_CF}" == "y" || "${USE_CF}" == "Y" ]]; then
  read -rp "Enter your Cloudflare Tunnel token (from Cloudflare dashboard): " CF_TOKEN
fi

echo
echo "============ Summary ============"
echo "  Domain:             ${NC_HOST}"
echo "  Public URL:         ${NC_PUBLIC_URL}"
echo "  HTTP Port:          ${TRAEFIK_HTTP_PORT}"
echo "  NocoDB Admin Email: ${NC_ADMIN_EMAIL}"
echo "  NocoDB Admin Pass:  ${NC_ADMIN_PASSWORD}"
echo "  DB Password:        ${NC_DB_PASSWORD}"
echo "  Cloudflare Tunnel:  ${USE_CF}"
echo "================================="
echo

read -rp "Proceed with writing docker-compose.yml and starting stack? [y/N]: " CONFIRM
CONFIRM=${CONFIRM:-n}
if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
  echo "[INFO] Aborting by user choice."
  exit 0
fi

#----- 7. Write docker-compose.yml -----#
log "Writing docker-compose stack to ${BASE_DIR}/docker-compose.yml..."

cat > docker-compose.yml <<EOF
version: "3.9"

services:
  traefik:
    image: traefik:v3.1
    container_name: nocodb-traefik
    command:
      - --api.dashboard=true
      - --api.insecure=true
      - --providers.docker=true
      - --providers.docker.exposedByDefault=false
      - --entrypoints.web.address=:80
    ports:
      - "${TRAEFIK_HTTP_PORT}:80"
      - "8080:8080"
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
      - NC_ADMIN_EMAIL=${NC_ADMIN_EMAIL}
      - NC_ADMIN_PASSWORD=${NC_ADMIN_PASSWORD}
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.nocodb.rule=Host(\`${NC_HOST}\`)"
      - "traefik.http.routers.nocodb.entrypoints=web"
      - "traefik.http.routers.nocodb.service=nocodb-svc"
      - "traefik.http.services.nocodb-svc.loadbalancer.server.port=8080"
    networks:
      - nocodb-net
    restart: unless-stopped

networks:
  nocodb-net:
    driver: bridge
EOF

log "docker-compose.yml created."

#----- 8. Create data directories -----#
log "Ensuring data directories exist..."
mkdir -p data/postgres data/redis

#----- 9. Cloudflare Tunnel (systemd) optional -----#
if [[ "${USE_CF}" == "y" || "${USE_CF}" == "Y" ]]; then
  if ! command -v cloudflared >/dev/null 2>&1; then
    log "Installing Cloudflare Tunnel (cloudflared)..."

    mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg \
      | tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null

    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' \
      > /etc/apt/sources.list.d/cloudflared.list

    apt-get update -y
    apt-get install -y cloudflared
  else
    log "cloudflared already installed, skipping install."
  fi

  if [[ -n "${CF_TOKEN}" ]]; then
    log "Installing Cloudflare Tunnel service with provided token..."
    cloudflared service install "${CF_TOKEN}"
    systemctl enable cloudflared || true
    systemctl restart cloudflared || true
  else
    warn "Cloudflare selected but no token provided. Skipping tunnel configuration."
  fi
else
  log "Cloudflare Tunnel installation skipped."
fi

#----- 10. Start or restart Docker stack -----#
log "Bringing NocoDB stack up with Docker Compose..."
docker compose down || true
docker compose up -d

log "Current stack status:"
docker compose ps

#----- 11. Health checks -----#
log "Testing direct NocoDB container HTTP (internal)..."
if docker inspect nocodb-nocodb >/dev/null 2>&1; then
  NOCODB_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' nocodb-nocodb || echo "")
  echo "NocoDB IP: ${NOCODB_IP}"
  if [[ -n "${NOCODB_IP}" ]]; then
    curl -fsS "http://${NOCODB_IP}:8080" >/dev/null 2>&1 || warn "Direct NocoDB HTTP check failed (container might still be starting)."
  fi
fi

log "Testing Traefik routing locally for Host: ${NC_HOST}..."
if ! curl -fsS -H "Host: ${NC_HOST}" http://localhost >/dev/null 2>&1; then
  warn "Traefik returned a non-2xx for Host: ${NC_HOST}
      - Check Traefik logs:
          docker logs nocodb-traefik --tail=100
      - Check NocoDB logs:
          docker logs nocodb-nocodb --tail=100
      - Manually test from this VM:
          curl -v http://localhost -H \"Host: ${NC_HOST}\""
else
  log "Traefik routing appears OK for Host: ${NC_HOST}."
fi

echo
echo "========================================="
echo "  NocoDB should be available at:"
echo "    ${NC_PUBLIC_URL}"
echo
echo "  Traefik dashboard (from trusted IP):"
echo "    http://<VM-IP>:8080/dashboard/"
echo
echo "  If using Cloudflare:"
echo "    - Ensure DNS for ${NC_HOST} points to the tunnel or VM"
echo "========================================="
