#!/usr/bin/env bash
set -euo pipefail

#############################################
#  NocoDB + Traefik basic installer
#  - For running *inside* the VM
#  - Uses Docker + docker compose
#  - No Cloudflare or daemon.json tweaks
#############################################

if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] This script must be run as root (or via sudo)." >&2
  exit 1
fi

BASE_DIR="/opt/nocodb"
mkdir -p "$BASE_DIR"
cd "$BASE_DIR"
echo "[INFO] Working directory: $BASE_DIR"

#############################################
# 1. Ensure Docker (with compose v2) exists
#############################################
if ! command -v docker >/dev/null 2>&1; then
  echo "[INFO] Docker not found. Installing via get.docker.com..."
  curl -fsSL https://get.docker.com | sh
fi

if ! docker version >/dev/null 2>&1; then
  echo "[ERROR] Docker is installed but not working correctly." >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "[ERROR] 'docker compose' CLI not available."
  echo "        Please ensure Docker Compose v2 is installed."
  exit 1
fi

#############################################
# 2. If an existing stack is present, offer reuse
#############################################
if [[ -f "docker-compose.yml" ]]; then
  echo "=============================================="
  echo "[INFO] Existing docker-compose.yml detected."
  echo "  - Location: $BASE_DIR/docker-compose.yml"
  echo "=============================================="
  read -rp "Reuse existing config and just (re)start containers? [Y/n]: " REUSE
  REUSE=${REUSE:-Y}

  if [[ "$REUSE" =~ ^[Yy]$ ]]; then
    echo "[INFO] Reusing existing docker-compose.yml"
    echo "[INFO] Pulling images and (re)starting stack..."
    docker compose pull
    docker compose up -d
    echo
    echo "===================================================="
    echo "[DONE] Existing NocoDB stack has been (re)started."
    echo "       If you were previously using sales.palforge.it,"
    echo "       it should be reachable the same way."
    echo "===================================================="
    exit 0
  else
    echo "[INFO] Proceeding to overwrite docker-compose.yml with new config."
  fi
fi

#############################################
# 3. Ask for configuration
#############################################

read -rp "Domain for NocoDB [sales.palforge.it]: " NC_HOST
NC_HOST=${NC_HOST:-sales.palforge.it}

read -rp "External HTTP port for Traefik [80]: " TRAEFIK_HTTP_PORT
TRAEFIK_HTTP_PORT=${TRAEFIK_HTTP_PORT:-80}

# NocoDB will prompt for admin on first visit; DB password we control here.
read -rsp "Postgres password for 'nocodb' user [auto-generate]: " NC_DB_PASSWORD
echo
if [[ -z "${NC_DB_PASSWORD}" ]]; then
  NC_DB_PASSWORD="$(openssl rand -hex 16)"
  echo "[INFO] Generated random DB password: ${NC_DB_PASSWORD}"
fi

NC_PUBLIC_URL="https://${NC_HOST}"

echo
echo "============== Summary =============="
echo "  Domain:           ${NC_HOST}"
echo "  Public URL:       ${NC_PUBLIC_URL}"
echo "  HTTP Port:        ${TRAEFIK_HTTP_PORT}"
echo "  DB Password:      ${NC_DB_PASSWORD}"
echo "====================================="
echo

read -rp "Proceed and write docker-compose.yml + start stack? [y/N]: " CONFIRM
CONFIRM=${CONFIRM:-n}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "[INFO] Aborting by user request."
  exit 0
fi

#############################################
# 4. Write docker-compose.yml (rollback style)
#############################################

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
      - "8080:8080"   # Traefik dashboard (http://<host>:8080) - lock down via firewall/Cloudflare
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
      - "traefik.docker.network=nocodb-net"
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

echo "[INFO] docker-compose.yml written to $BASE_DIR/docker-compose.yml"

#############################################
# 5. Prepare data directories
#############################################
mkdir -p data/postgres data/redis

#############################################
# 6. Start the stack
#############################################
echo "[INFO] Pulling images..."
docker compose pull

echo "[INFO] Starting containers..."
docker compose up -d

echo
echo "============== Status =============="
docker compose ps
echo "===================================="
echo

#############################################
# 7. Quick internal sanity check
#############################################

echo "[INFO] Checking Traefik docker provider -> NocoDB container IP..."

NOCODB_NET_JSON="$(docker inspect nocodb-nocodb | jq '.[0].NetworkSettings.Networks')"
echo "$NOCODB_NET_JSON"

# Very simple check for non-empty IP
NOCODB_IP=$(echo "$NOCODB_NET_JSON" | jq -r '.[].IPAddress' | head -n1)
if [[ -z "$NOCODB_IP" || "$NOCODB_IP" == "null" ]]; then
  echo "===================================================="
  echo "[WARN] NocoDB container has no IP address on docker network."
  echo "       Traefik will not be able to route until Docker networking is healthy."
  echo "       Investigate: 'docker network inspect nocodb-net'"
  echo "===================================================="
else
  echo "[INFO] NocoDB container IP on nocodb-net: $NOCODB_IP"
fi

echo
echo "===================================================="
echo "[DONE] NocoDB + Traefik basic stack is running."
echo
echo "  - Public URL (via Traefik): http://${NC_HOST}  (or behind Cloudflare: https://${NC_HOST})"
echo "  - Local test from this VM:"
echo '        curl -v http://localhost -H "Host: '"${NC_HOST}"'"'
echo
echo "If you use Cloudflare Tunnel:"
echo "  - Point your tunnel to http://127.0.0.1:${TRAEFIK_HTTP_PORT}"
echo "  - Keep your existing cloudflared systemd service as-is."
echo "===================================================="
