cat >/root/setup_nocodb_fresh.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "============================================================"
echo " Pal Forge NocoDB + Traefik Setup (Clean Deploy)"
echo "============================================================"
echo

#-------------------------------
# 0. Pre-checks (Docker + compose)
#-------------------------------
if ! command -v docker >/dev/null 2>&1; then
  echo "[ERROR] Docker is not installed or not in PATH."
  echo "        Please install Docker first, then re-run this script."
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "[ERROR] docker compose plugin is not available."
  echo "        Install it with: apt-get install -y docker-compose-plugin"
  exit 1
fi

echo "[OK] Docker and docker compose are available."
echo

#-------------------------------
# 1. Ask basic questions
#-------------------------------
read -rp "Domain for NocoDB [sales.palforge.it]: " NC_HOST
NC_HOST=${NC_HOST:-sales.palforge.it}

read -rp "External HTTP port for Traefik [80]: " TRAEFIK_HTTP_PORT
TRAEFIK_HTTP_PORT=${TRAEFIK_HTTP_PORT:-80}

read -rsp "Postgres password for 'nocodb' user [auto-generate]: " NC_DB_PASSWORD
echo
if [[ -z "${NC_DB_PASSWORD}" ]]; then
  NC_DB_PASSWORD=$(openssl rand -hex 16)
  echo "[INFO] Generated DB password: ${NC_DB_PASSWORD}"
fi

NC_PUBLIC_URL="https://${NC_HOST}"

echo
echo "================ SUMMARY ================"
echo "  Domain:           ${NC_HOST}"
echo "  Public URL:       ${NC_PUBLIC_URL}"
echo "  HTTP Port:        ${TRAEFIK_HTTP_PORT}"
echo "  DB Password:      ${NC_DB_PASSWORD}"
echo "========================================="
echo

read -rp "Proceed with clean NocoDB stack deploy at /opt/nocodb? [y/N]: " CONFIRM
CONFIRM=${CONFIRM:-n}
if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
  echo "[ABORT] User cancelled."
  exit 1
fi

#-------------------------------
# 2. Prepare /opt/nocodb cleanly
#-------------------------------
INSTALL_DIR="/opt/nocodb"
echo "[INFO] Creating clean install dir: ${INSTALL_DIR}"

mkdir -p "${INSTALL_DIR}"
cd "${INSTALL_DIR}"

# Stop any existing compose stack in /opt/nocodb
if docker compose ps >/dev/null 2>&1; then
  echo "[INFO] Stopping any existing NocoDB stack in ${INSTALL_DIR}..."
  docker compose down --remove-orphans || true
fi

# Remove old data dirs if you truly want a fresh instance
# Comment these out if you want to keep old DB data.
rm -rf "${INSTALL_DIR}/data"
mkdir -p "${INSTALL_DIR}/data/postgres" "${INSTALL_DIR}/data/redis"

#-------------------------------
# 3. Write docker-compose.yml
#   - Use an explicit named network: nocodb_nocodb-net
#   - Traefik and NocoDB share this network
#-------------------------------
cat > "${INSTALL_DIR}/docker-compose.yml" <<EOF_INNER
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
      - "8080:8080"  # Traefik dashboard
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
      - "traefik.docker.network=nocodb_nocodb-net"
      - "traefik.http.routers.nocodb.rule=Host(\`${NC_HOST}\`)"
      - "traefik.http.routers.nocodb.entrypoints=web"
      - "traefik.http.services.nocodb.loadbalancer.server.port=8080"
    networks:
      - nocodb-net
    restart: unless-stopped

networks:
  nocodb-net:
    name: nocodb_nocodb-net
    driver: bridge
EOF_INNER

echo "[INFO] docker-compose.yml written to ${INSTALL_DIR}/docker-compose.yml"
echo

#-------------------------------
# 4. Bring stack up
#-------------------------------
echo "[INFO] Starting NocoDB stack..."
docker compose up -d

echo
echo "[INFO] Current containers:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo

#-------------------------------
# 5. Quick local routing test
#-------------------------------
echo "[INFO] Testing Traefik route locally..."
sleep 5
curl -sS -o /tmp/nocodb_test.html -w "%{http_code}\n" \
  -H "Host: ${NC_HOST}" \
  http://localhost/ || true

HTTP_CODE=$(tail -n1 /tmp/nocodb_test.html || echo "unknown")

echo
echo "============================================================"
echo " Setup complete (stack started)"
echo "============================================================"
echo "  Try opening: http://${NC_HOST}  (if DNS points to this server)"
echo "  Or from this VM: curl -H \"Host: ${NC_HOST}\" http://localhost"
echo "  Local Traefik dashboard: http://<server-ip>:8080"
echo
echo "  Last local test HTTP code: ${HTTP_CODE}"
echo "============================================================"
EOF

chmod +x /root/setup_nocodb_fresh.sh
echo
echo "[READY] Run the installer with:"
echo "  sudo /root/setup_nocodb_fresh.sh"
EOF
