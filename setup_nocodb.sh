#!/usr/bin/env bash
set -euo pipefail

echo "======================================="
echo "  NocoDB + Traefik Installer (Ubuntu)  "
echo "======================================="

# --- safety: must be root ---
if [[ "$EUID" -ne 0 ]]; then
  echo "[ERROR] This script must be run as root (or via sudo)."
  exit 1
fi

BASE_DIR="/opt/nocodb"
DAEMON_JSON="/etc/docker/daemon.json"

# --- helpers ---
gen_password() {
  # reasonably strong random password
  openssl rand -base64 24 | tr -d '\n'
}

# --- install base dependencies ---
echo "[INFO] Updating apt and installing base dependencies..."
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release jq

# --- install docker if needed ---
if ! command -v docker >/dev/null 2>&1; then
  echo "[INFO] Docker not found. Installing Docker Engine from official repository..."

  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
      gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  fi
  chmod a+r /etc/apt/keyrings/docker.gpg

  CODENAME="$(lsb_release -cs)"
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

  systemctl enable docker
  systemctl start docker
else
  echo "[INFO] Docker is already installed."
fi

# --- docker daemon.json: min-api-version + logs ---
echo "[INFO] Configuring /etc/docker/daemon.json with min-api-version=1.24..."
if [[ -f "${DAEMON_JSON}" ]]; then
  cp "${DAEMON_JSON}" "${DAEMON_JSON}.bak.$(date +%s)" || true
fi

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

echo "[INFO] Restarting Docker to apply daemon.json..."
systemctl restart docker

# --- ensure base directory ---
echo "[INFO] Ensuring base directory exists at ${BASE_DIR}..."
mkdir -p "${BASE_DIR}"
cd "${BASE_DIR}"

# --- collect config ---
echo "[INFO] We will now collect configuration for NocoDB and its services."

# Domain (required for Traefik Host routing)
DOMAIN=""
while [[ -z "${DOMAIN}" ]]; do
  read -r -p "Enter the domain for NocoDB (e.g. sales.palforge.it): " DOMAIN
  if [[ -z "${DOMAIN}" ]]; then
    echo "[WARN] Domain is required for Host-based routing. Please enter a value."
  fi
done

read -r -p "Enter NocoDB admin email [admin@example.com]: " ADMIN_EMAIL
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"

read -r -s -p "Enter NocoDB admin password (leave blank to auto-generate): " ADMIN_PASS
echo ""
if [[ -z "${ADMIN_PASS}" ]]; then
  ADMIN_PASS="$(gen_password)"
  echo "[INFO] Generated random NocoDB admin password:"
  echo "       ${ADMIN_PASS}"
fi

read -r -s -p "Enter Postgres password for 'nocodb' user (leave blank to auto-generate): " PG_PASS
echo ""
if [[ -z "${PG_PASS}" ]]; then
  PG_PASS="$(gen_password)"
  echo "[INFO] Generated random Postgres password for user 'nocodb':"
  echo "       ${PG_PASS}"
fi

# Traefik dashboard
read -r -p "Expose Traefik dashboard on port 8080? (y/N): " EXPOSE_DASHBOARD
EXPOSE_DASHBOARD="${EXPOSE_DASHBOARD:-N}"

# Cloudflare Tunnel
read -r -p "Do you want to install and configure a Cloudflare Tunnel on this VM? (y/N): " USE_CF
USE_CF="${USE_CF:-N}"
CF_TOKEN=""
if [[ "${USE_CF}" =~ ^[Yy]$ ]]; then
  read -r -p "Enter your Cloudflare Tunnel token (from Cloudflare dashboard): " CF_TOKEN
fi

# --- generate .env for docker compose ---
echo "[INFO] Generating .env file for docker compose..."
JWT_SECRET="$(openssl rand -hex 32)"

cat > .env <<EOF
NC_ADMIN_EMAIL=${ADMIN_EMAIL}
NC_ADMIN_PASSWORD=${ADMIN_PASS}
NC_DB_PASSWORD=${PG_PASS}
NC_JWT_SECRET=${JWT_SECRET}
NC_DOMAIN=${DOMAIN}
NC_PUBLIC_URL=https://${DOMAIN}
EOF

echo "[INFO] .env written with admin email, DB password, JWT secret, and domain."

# --- write docker-compose.yml ---
echo "[INFO] Writing docker-compose.yml stack to ${BASE_DIR}..."

cat > docker-compose.yml <<'EOF'
version: "3.9"

services:
  postgres:
    image: postgres:16
    container_name: nocodb-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: nocodb
      POSTGRES_PASSWORD: ${NC_DB_PASSWORD}
      POSTGRES_DB: nocodb
    volumes:
      - ./postgres-data:/var/lib/postgresql/data

  redis:
    image: redis:7
    container_name: nocodb-redis
    restart: unless-stopped
    volumes:
      - ./redis-data:/data

  nocodb:
    image: nocodb/nocodb:latest
    container_name: nocodb-nocodb
    restart: unless-stopped
    environment:
      NC_DB: "pg://postgres:5432?u=nocodb&p=${NC_DB_PASSWORD}&d=nocodb"
      NC_REDIS_URL: "redis://redis:6379"
      NC_AUTH_JWT_SECRET: "${NC_JWT_SECRET}"
      NC_ADMIN_EMAIL: "${NC_ADMIN_EMAIL}"
      NC_ADMIN_PASSWORD: "${NC_ADMIN_PASSWORD}"
      NC_PUBLIC_URL: "${NC_PUBLIC_URL}"
    depends_on:
      - postgres
      - redis
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.nocodb.rule=Host(`${NC_DOMAIN}`)"
      - "traefik.http.routers.nocodb.entrypoints=web"
      - "traefik.http.services.nocodb.loadbalancer.server.port=8080"

  traefik:
    image: traefik:v3.1
    container_name: nocodb-traefik
    restart: unless-stopped
    environment:
      - DOCKER_API_VERSION=1.44
    command:
      - "--api.dashboard=true"
      - "--providers.docker=true"
      - "--providers.docker.exposedByDefault=false"
      - "--entrypoints.web.address=:80"
    ports:
      - "80:80"
      # - "8080:8080"  # Traefik dashboard (optional)
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
EOF

# --- optionally expose Traefik dashboard port ---
if [[ "${EXPOSE_DASHBOARD}" =~ ^[Yy]$ ]]; then
  echo "[INFO] Enabling Traefik dashboard on host port 8080..."
  # uncomment the dashboard port line
  sed -i 's/# - "8080:8080"/      - "8080:8080"/' docker-compose.yml || true
else
  echo "[INFO] Traefik dashboard will NOT be exposed on 8080."
fi

# --- install Cloudflare Tunnel (system-wide), if requested ---
if [[ "${USE_CF}" =~ ^[Yy]$ ]]; then
  if ! command -v cloudflared >/dev/null 2>&1; then
    echo "[INFO] Installing Cloudflare Tunnel (cloudflared) via official repo..."

    mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg \
      | tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null

    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' \
      > /etc/apt/sources.list.d/cloudflared.list

    apt-get update -y
    apt-get install -y cloudflared
  else
    echo "[INFO] cloudflared already installed."
  fi

  if [[ -n "${CF_TOKEN}" ]]; then
    echo "[INFO] Installing Cloudflare Tunnel service..."
    # this will create/overwrite the systemd service
    cloudflared service install "${CF_TOKEN}"
    systemctl enable cloudflared || true
    systemctl restart cloudflared || true
  else
    echo "[WARN] Cloudflare token was empty; skipping tunnel service install."
  fi
else
  echo "[INFO] Skipping Cloudflare Tunnel installation."
fi

# --- bring up the stack ---
echo "[INFO] Bringing up NocoDB stack with docker compose..."
docker compose pull
docker compose up -d

echo "[INFO] Current docker compose services:"
docker compose ps

echo "[INFO] Checking Traefik for Docker API errors..."
docker logs nocodb-traefik --tail=50 2>&1 | grep -i "docker" || echo "[INFO] No Docker-related errors found in Traefik logs."

# --- quick routing test ---
echo "[INFO] Testing HTTP routing via Traefik locally..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost -H "Host: ${DOMAIN}" || echo "000")

echo "[INFO] curl http://localhost (Host: ${DOMAIN}) returned HTTP ${HTTP_CODE}"

if [[ "${HTTP_CODE}" == "200" || "${HTTP_CODE}" == "302" ]]; then
  echo "==============================================="
  echo "[SUCCESS] NocoDB appears to be reachable via:"
  echo "         http://${DOMAIN}"
  echo "Or via your Cloudflare Tunnel / DNS setup."
  echo "==============================================="
else
  echo "===================================================="
  echo "[WARN] Traefik returned HTTP ${HTTP_CODE} for Host: ${DOMAIN}"
  echo "      - Check Traefik dashboard (if enabled) or logs:"
  echo "          docker logs nocodb-traefik --tail=100"
  echo "      - Check that DNS / Cloudflare points to this VM."
  echo "      - Inside VM, test again with:"
  echo "          curl -v http://localhost -H \"Host: ${DOMAIN}\""
  echo "===================================================="
fi
