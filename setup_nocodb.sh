#!/usr/bin/env bash
set -euo pipefail

echo "=== Pal Forge | NocoDB Stack Installer (inside VM) ==="
echo

# Determine sudo usage and user home
if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=""
  DEFAULT_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
else
  SUDO="sudo"
  DEFAULT_USER="$(whoami)"
fi

read -rp "Linux user to own the NocoDB files [$DEFAULT_USER]: " APP_USER
APP_USER=${APP_USER:-$DEFAULT_USER}

APP_HOME=$(eval echo "~${APP_USER}")
NOCODB_DIR="${APP_HOME}/nocodb"

echo "Using app user: ${APP_USER}"
echo "NocoDB directory: ${NOCODB_DIR}"
mkdir -p "$NOCODB_DIR"
chown -R "${APP_USER}:${APP_USER}" "$NOCODB_DIR"

# --- Ask for basic config ---
read -rp "Public domain for NocoDB (e.g. sales.palforge.it): " NC_DOMAIN
NC_DOMAIN=${NC_DOMAIN:-sales.palforge.it}

read -rp "Postgres DB name [nocodb]: " NC_DB_NAME
NC_DB_NAME=${NC_DB_NAME:-nocodb}

read -rp "Postgres DB user [nocodb]: " NC_DB_USER
NC_DB_USER=${NC_DB_USER:-nocodb}

read -rsp "Postgres DB password (leave blank to auto-generate): " NC_DB_PASSWORD
echo
if [[ -z "${NC_DB_PASSWORD}" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    NC_DB_PASSWORD=$(openssl rand -base64 18)
  else
    NC_DB_PASSWORD="ChangeMe_$(date +%s)"
  fi
  echo "Generated DB password: ${NC_DB_PASSWORD}"
fi

TIMEZONE_DEFAULT="America/Denver"
read -rp "Timezone for containers [$TIMEZONE_DEFAULT]: " TZ
TZ=${TZ:-$TIMEZONE_DEFAULT}

# --- Install required packages & Docker if missing ---

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker not found. Installing Docker Engine + docker compose plugin..."
  $SUDO apt-get update
  $SUDO apt-get install -y ca-certificates curl gnupg lsb-release

  $SUDO install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  fi
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null

  $SUDO apt-get update
  $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  # Allow app user to use docker without sudo (after re-login)
  $SUDO usermod -aG docker "$APP_USER"
  echo "Docker installed. You may need to log out and back in for docker group membership to apply."
else
  echo "Docker already installed."
fi

# --- Optional: Cloudflare Tunnel (cloudflared) ---
read -rp "Install Cloudflare Tunnel (cloudflared)? [y/N]: " INSTALL_CF
INSTALL_CF=${INSTALL_CF:-n}

if [[ "$INSTALL_CF" =~ ^[Yy]$ ]]; then
  echo "Installing cloudflared..."
  $SUDO mkdir -p /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/cloudflare-main.gpg ]]; then
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | \
      $SUDO gpg --dearmor -o /etc/apt/keyrings/cloudflare-main.gpg
  fi

  echo "deb [signed-by=/etc/apt/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflare-main $(lsb_release -cs) main" | \
    $SUDO tee /etc/apt/sources.list.d/cloudflare.list >/dev/null

  $SUDO apt-get update
  $SUDO apt-get install -y cloudflared

  read -rp "Cloudflare Tunnel token (leave blank to skip service install): " CF_TOKEN
  if [[ -n "$CF_TOKEN" ]]; then
    $SUDO cloudflared service install "$CF_TOKEN" || echo "cloudflared service install failed; configure manually if needed."
  else
    echo "Skipping automatic cloudflared service install."
  fi
fi

# --- Write .env file ---
ENV_FILE="${NOCODB_DIR}/.env"

cat > "$ENV_FILE" <<EOF
NC_DOMAIN=${NC_DOMAIN}
NC_DB_NAME=${NC_DB_NAME}
NC_DB_USER=${NC_DB_USER}
NC_DB_PASSWORD=${NC_DB_PASSWORD}
TZ=${TZ}
EOF

chown "${APP_USER}:${APP_USER}" "$ENV_FILE"

echo ".env written at ${ENV_FILE}"

# --- Write docker-compose.yml ---
COMPOSE_FILE="${NOCODB_DIR}/docker-compose.yml"

cat > "$COMPOSE_FILE" <<'EOF'
services:
  postgres:
    image: postgres:16
    container_name: nocodb-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${NC_DB_NAME}
      POSTGRES_USER: ${NC_DB_USER}
      POSTGRES_PASSWORD: ${NC_DB_PASSWORD}
      TZ: ${TZ}
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    networks:
      - nocodb-net

  redis:
    image: redis:7
    container_name: nocodb-redis
    restart: unless-stopped
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - ./data/redis:/data
    networks:
      - nocodb-net

  app:
    image: nocodb/nocodb:latest
    container_name: nocodb-app
    restart: unless-stopped
    depends_on:
      - postgres
      - redis
    env_file:
      - .env
    environment:
      NC_DB: "pg://postgres:5432?u=${NC_DB_USER}&p=${NC_DB_PASSWORD}&d=${NC_DB_NAME}"
      NC_REDIS_URL: "redis://redis:6379"
      NC_PUBLIC_URL: "https://${NC_DOMAIN}"
      TZ: ${TZ}
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.nocodb.rule=Host(`${NC_DOMAIN}`)"
      - "traefik.http.routers.nocodb.entrypoints=web"
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
      - "8080:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - nocodb-net

  watchtower:
    image: containrrr/watchtower
    container_name: nocodb-watchtower
    restart: unless-stopped
    command: "--cleanup --label-enable --interval 3600"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock

networks:
  nocodb-net:
    driver: bridge
EOF

chown "${APP_USER}:${APP_USER}" "$COMPOSE_FILE"

echo "docker-compose.yml written at ${COMPOSE_FILE}"

# --- Bring up the stack ---

cd "$NOCODB_DIR"
echo "Starting NocoDB stack with: docker compose up -d"
$SUDO docker compose pull
$SUDO docker compose up -d

echo
echo "=== Done ==="
echo "NocoDB stack is starting."
echo "  - If DNS is set:   http://${NC_DOMAIN}  (or https via Cloudflare proxy)"
echo "  - Local (VM IP):   http://<vm-ip> (Traefik on port 80)"
echo
echo "You can manage containers with:   docker ps   /   docker compose logs -f"
