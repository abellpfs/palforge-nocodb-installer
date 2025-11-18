#!/usr/bin/env bash
set -euo pipefail

echo "============================================================"
echo " Pal Forge NocoDB + Traefik + (optional) Cloudflare Setup"
echo "============================================================"
echo

#--------------------------------------------------------------
# 0. Root check
#--------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
  echo "[ERROR] This script must be run as root (or via sudo)." >&2
  exit 1
fi

#--------------------------------------------------------------
# 1. Base paths & helpers
#--------------------------------------------------------------
NC_DIR="/opt/nocodb"
DAEMON_JSON="/etc/docker/daemon.json"

mkdir -p "${NC_DIR}"
cd "${NC_DIR}"

log() { echo -e "[INFO] $*"; }
warn() { echo -e "[WARN] $*" >&2; }
err() { echo -e "[ERROR] $*" >&2; }

#--------------------------------------------------------------
# 2. Ensure Docker + basic tools
#--------------------------------------------------------------
log "Ensuring curl, jq, and Docker are installed..."

apt-get update -y
apt-get install -y curl jq ca-certificates docker.io

if ! command -v docker >/dev/null 2>&1; then
  err "Docker binary not found even after installation. Aborting."
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  warn "docker compose plugin not found via 'docker compose'."
  warn "Check Docker CLI plugins if this fails later."
fi

#--------------------------------------------------------------
# 3. Ensure Docker daemon.json has min API + log options
#--------------------------------------------------------------
log "Ensuring /etc/docker/daemon.json has min-api-version and log options..."

if [[ -f "${DAEMON_JSON}" ]]; then
  # Merge/override using jq to avoid clobbering other keys
  tmp="$(mktemp)"
  jq '. + {
    "min-api-version": "1.24",
    "log-driver": "json-file",
    "log-opts": {"max-size": "10m", "max-file": "3"}
  }' "${DAEMON_JSON}" > "${tmp}" || {
    err "Failed to update ${DAEMON_JSON} with jq."
    rm -f "${tmp}"
    exit 1
  }
  mv "${tmp}" "${DAEMON_JSON}"
else
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
fi

systemctl restart docker
log "Docker restarted to apply daemon.json changes."

#--------------------------------------------------------------
# 4. Ask for config
#--------------------------------------------------------------
read -rp "Domain for NocoDB [sales.palforge.it]: " NC_HOST
NC_HOST="${NC_HOST:-sales.palforge.it}"

read -rp "External HTTP port for Traefik [80]: " TRAEFIK_HTTP_PORT
TRAEFIK_HTTP_PORT="${TRAEFIK_HTTP_PORT:-80}"

read -rsp "Postgres password for 'nocodb' user [auto-generate]: " NC_DB_PASSWORD || true
echo
if [[ -z "${NC_DB_PASSWORD}" ]]; then
  NC_DB_PASSWORD="$(openssl rand -hex 16)"
  log "Generated DB password: ${NC_DB_PASSWORD}"
fi

NC_PUBLIC_URL="https://${NC_HOST}"

echo
echo "=== Summary ==="
echo "  Domain:           ${NC_HOST}"
echo "  Public URL:       ${NC_PUBLIC_URL}"
echo "  HTTP Port:        ${TRAEFIK_HTTP_PORT}"
echo "  DB Password:      ${NC_DB_PASSWORD}"
echo

read -rp "Use Cloudflare Tunnel for this domain? [y/N]: " USE_CF
USE_CF="${USE_CF:-n}"

CF_TOKEN=""
if [[ "${USE_CF}" =~ ^[Yy]$ ]]; then
  read -rsp "Enter Cloudflare tunnel token: " CF_TOKEN
  echo
fi

read -rp "Proceed with this configuration and (re)deploy stack? [y/N]: " CONFIRM
CONFIRM="${CONFIRM:-n}"
if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
  echo "Aborting."
  exit 0
fi

#--------------------------------------------------------------
# 5. Write docker-compose.yml (fixed networking)
#   - IMPORTANT: removed 'traefik.docker.network=...' label
#     so Traefik auto-selects the correct network.
#--------------------------------------------------------------
log "Writing docker-compose.yml to ${NC_DIR}..."

cat > docker-compose.yml <<EOF
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
      - "8080:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - nocodb-net
    restart: unless-stopped

  postgres:
    image: postgres:16
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
    image: redis:7
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

mkdir -p data/postgres data/redis

#--------------------------------------------------------------
# 6. (Optional) Install / update Cloudflare Tunnel
#--------------------------------------------------------------
if [[ "${USE_CF}" =~ ^[Yy]$ ]]; then
  log "Ensuring cloudflared is installed..."

  if ! command -v cloudflared >/dev/null 2>&1; then
    mkdir -p /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg \
      | tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null

    echo "deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main" \
      > /etc/apt/sources.list.d/cloudflared.list

    apt-get update -y
    apt-get install -y cloudflared
  fi

  if [[ -n "${CF_TOKEN}" ]]; then
    log "Installing/Updating Cloudflare tunnel service..."
    tmp_err="$(mktemp)"
    set +e
    cloudflared service install "${CF_TOKEN}" 2>"${tmp_err}"
    rc=$?
    set -e

    if [[ ${rc} -ne 0 ]]; then
      if grep -q "cloudflared service is already installed" "${tmp_err}"; then
        warn "Cloudflare service already installed. Skipping install step."
      else
        err "cloudflared service install failed:"
        cat "${tmp_err}" >&2
        rm -f "${tmp_err}"
        exit 1
      fi
    else
      log "Cloudflare tunnel service installed/updated."
    fi
    rm -f "${tmp_err}"

    systemctl enable cloudflared
    systemctl restart cloudflared
  else
    warn "Cloudflare token was empty, skipping tunnel install."
  fi
else
  log "Skipping Cloudflare Tunnel configuration."
fi

#--------------------------------------------------------------
# 7. Bring the stack up
#--------------------------------------------------------------
log "Starting NocoDB stack with docker compose..."

docker compose pull
docker compose up -d

echo
log "Docker compose status:"
docker compose ps

echo
echo "============================================================"
echo " NocoDB deployment complete."
echo " - Public URL: ${NC_PUBLIC_URL}"
echo " - Traefik HTTP: ${TRAEFIK_HTTP_PORT} (local VM port)"
echo " - Traefik dashboard: http://<VM-IP>:8080 (protect via firewall/Cloudflare)"
echo
echo "If using Cloudflare:"
echo " - Ensure sales.palforge.it is proxied to this VM/tunnel."
echo " - Cloudflared is expected to route sales.palforge.it -> http://localhost"
echo "============================================================"
