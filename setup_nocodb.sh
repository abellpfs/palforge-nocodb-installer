#!/usr/bin/env bash
set -euo pipefail

#############################################
#  Pal Forge NocoDB Installer (VM)
#  - Run INSIDE the VM, as root
#  - Installs Docker + Compose
#  - Sets Docker min-api-version (1.24) to fix old client issues
#  - Installs cloudflared via apt repo
#  - Sets up Traefik + NocoDB + Postgres + Redis
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
# 1. Base dependencies
#############################################
echo "[INFO] Installing base dependencies (curl, ca-certificates, gnupg, lsb-release, jq)..."
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release jq

#############################################
# 2. Install Docker (if missing)
#############################################
if ! command -v docker >/dev/null 2>&1; then
  echo "[INFO] Docker not found. Installing via get.docker.com..."
  curl -fsSL https://get.docker.com | sh
else
  echo "[INFO] Docker already installed."
fi

if ! docker version >/dev/null 2>&1; then
  echo "[ERROR] Docker appears installed but 'docker version' failed." >&2
  exit 1
fi

#############################################
# 3. Ensure docker compose v2 is available
#############################################
if ! docker compose version >/dev/null 2>&1; then
  echo "[ERROR] 'docker compose' CLI not available."
  echo "        On Ubuntu, this usually comes with the Docker Engine package."
  echo "        Please ensure you're using the official Docker packages."
  exit 1
fi

#############################################
# 4. Ensure /etc/docker/daemon.json with min-api-version fix
#############################################
DAEMON_JSON="/etc/docker/daemon.json"

echo "[INFO] Ensuring Docker daemon.json has min-api-version 1.24 and log options..."

if [[ -f "$DAEMON_JSON" ]]; then
  echo "[INFO] Existing $DAEMON_JSON found. Backing up to ${DAEMON_JSON}.bak"
  cp "$DAEMON_JSON" "${DAEMON_JSON}.bak"
  # Try to merge, but simplest / safest for now: overwrite with known-good config.
fi

cat > "$DAEMON_JSON" <<EOF
{
  "min-api-version": "1.24",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

echo "[INFO] Restarting Docker to apply daemon.json..."
systemctl restart docker

# Re-validate
sleep 2
if ! docker version >/dev/null 2>&1; then
  echo "[ERROR] Docker did not come back cleanly after daemon.json change." >&2
  exit 1
fi

#############################################
# 5. Handle existing docker-compose.yml
#############################################
if [[ -f "docker-compose.yml" ]]; then
  echo "=============================================="
  echo "[INFO] Existing docker-compose.yml detected:"
  echo "  $BASE_DIR/docker-compose.yml"
  echo "=============================================="
  read -rp "Reuse existing compose file and just (re)start containers? [Y/n]: " REUSE
  REUSE=${REUSE:-Y}
  if [[ "$REUSE" =~ ^[Yy]$ ]]; then
    echo "[INFO] Reusing existing docker-compose.yml"
    docker compose pull
    docker compose up -d
    echo
    echo "===================================================="
    echo "[DONE] Existing NocoDB stack has been (re)started."
    echo "===================================================="
    exit 0
  else
    echo "[INFO] Will overwrite docker-compose.yml with new config."
  fi
fi

#############################################
# 6. Install cloudflared via apt repository
#############################################
if ! command -v cloudflared >/dev/null 2>&1; then
  echo "[INFO] Installing cloudflared via official apt repo..."

  mkdir -p --mode=0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg \
    | tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null

  echo "deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main" \
    | tee /etc/apt/sources.list.d/cloudflared.list >/dev/null

  apt-get update -y
  apt-get install -y cloudflared
else
  echo "[INFO] cloudflared already installed."
fi

#############################################
# 7. Ask core questions (domain, ports, passwords)
#############################################

echo
echo "[INFO] We will now collect configuration for NocoDB and Traefik."

read -rp "Domain for NocoDB [sales.palforge.it]: " NC_HOST
NC_HOST=${NC_HOST:-sales.palforge.it}

read -rp "External HTTP port for Traefik [80]: " TRAEFIK_HTTP_PORT
TRAEFIK_HTTP_PORT=${TRAEFIK_HTTP_PORT:-80}

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
echo "  HTTP Port:        ${TRAEIK_HTTP_PORT:-$TRAEFIK_HTTP_PORT}"  # fallback
echo "  DB Password:      ${NC_DB_PASSWORD}"
echo "====================================="
echo

#############################################
# 8. Optional: Cloudflare Tunnel setup
#############################################
USE_CF="n"
read -rp "Configure Cloudflare Tunnel service on this VM? (y/N): " USE_CF
USE_CF=${USE_CF:-n}

CF_TOKEN=""
if [[ "$USE_CF" =~ ^[Yy]$ ]]; then
  read -rp "Enter your Cloudflare Tunnel token: " CF_TOKEN
fi

echo
read -rp "Proceed, write docker-compose.yml and start stack? [y/N]: " CONFIRM
CONFIRM=${CONFIRM:-n}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "[INFO] Aborting by user request."
  exit 0
fi

#############################################
# 9. Write docker-compose.yml (clean, simple)
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
# 10. Prepare data dirs and start stack
#############################################
mkdir -p data/postgres data/redis

echo "[INFO] Pulling images..."
docker compose pull

echo "[INFO] Starting containers..."
docker compose up -d

echo
echo "============== docker compose ps =============="
docker compose ps
echo "==============================================="
echo

#############################################
# 11. Configure Cloudflare Tunnel service (if requested)
#############################################
if [[ "$USE_CF" =~ ^[Yy]$ && -n "$CF_TOKEN" ]]; then
  echo "[INFO] Configuring Cloudflare Tunnel as a systemd service..."
  set +e
  CF_OUTPUT=$(cloudflared service install "$CF_TOKEN" 2>&1)
  CF_EXIT=$?
  set -e

  echo "$CF_OUTPUT"

  if [[ $CF_EXIT -ne 0 ]]; then
    # If the specific "already installed" message appears, treat as success
    if echo "$CF_OUTPUT" | grep -q "cloudflared service is already installed"; then
      echo "[WARN] cloudflared service already installed; skipping re-install."
    else
      echo "[WARN] cloudflared service install returned non-zero exit code. Check output above."
    fi
  else
    echo "[INFO] cloudflared service installed/updated successfully."
  fi

  systemctl enable cloudflared || true
  systemctl restart cloudflared || true
fi

#############################################
# 12. Quick checks: NocoDB IP & Traefik routing
#############################################
echo "[INFO] Checking NocoDB container network info..."
NOCODB_NET_JSON="$(docker inspect nocodb-nocodb | jq '.[0].NetworkSettings.Networks')"
echo "$NOCODB_NET_JSON"

NOCODB_IP=$(echo "$NOCODB_NET_JSON" | jq -r '.[].IPAddress' | head -n1)
if [[ -z "$NOCODB_IP" || "$NOCODB_IP" == "null" ]]; then
  echo "===================================================="
  echo "[WARN] NocoDB container has no IP on nocodb-net."
  echo "       Traefik will not be able to route until Docker networking is healthy."
  echo "       Check: docker network inspect nocodb-net"
  echo "===================================================="
else
  echo "[INFO] NocoDB container IP on nocodb-net: $NOCODB_IP"
fi

echo
echo "===================================================="
echo "[DONE] NocoDB + Traefik stack is running."
echo
echo "  - Local test from this VM:"
echo "        curl -v http://localhost -H \"Host: ${NC_HOST}\""
echo
echo "  - External (if DNS / Cloudflare is correct):"
echo "        http://${NC_HOST}  (or https://${NC_HOST} via Cloudflare)"
echo "===================================================="
