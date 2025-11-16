#!/usr/bin/env bash
#
# NocoDB + Traefik one-shot installer for a fresh VM
# - Installs Docker if needed
# - Configures Docker daemon with min-api-version=1.24 (fixes "client version too old" for Traefik)
# - Deploys NocoDB, Postgres, Redis, Traefik via docker compose
# - Optionally installs Cloudflare Tunnel as a system service
#

set -u  # no unset vars; avoid set -e so we can handle errors gracefully

BASE_DIR="/opt/nocodb"
DOCKER_DAEMON_JSON="/etc/docker/daemon.json"

# ---------- Helper functions ----------

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "This script must be run as root (or via sudo)."
  fi
}

pause() {
  read -r -p "Press Enter to continue..." _
}

rand_pw() {
  # 24-char random alphanumeric
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
}

# ---------- System setup ----------

install_dependencies() {
  echo "======================================="
  echo "  NocoDB + Traefik Installer (VM)      "
  echo "======================================="
  echo "[INFO] Updating apt and installing dependencies..."

  apt-get update -y >/dev/null 2>&1 || die "apt-get update failed."

  apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    jq >/dev/null 2>&1 || die "Failed to install base dependencies."
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    echo "[INFO] Docker is already installed."
    return
  fi

  echo "[INFO] Installing Docker (Engine + CLI + compose plugin)..."

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    >/etc/apt/sources.list.d/docker.list

  apt-get update -y >/dev/null 2>&1 || die "apt-get update for Docker failed."

  apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin >/dev/null 2>&1 || die "Failed to install Docker."

  systemctl enable --now docker >/dev/null 2>&1 || die "Failed to start Docker service."

  echo "[INFO] Docker installed successfully."
}

configure_docker_daemon() {
  echo "[INFO] Configuring Docker daemon (min API version & logging)..."

  # Backup previous config if exists
  if [[ -f "$DOCKER_DAEMON_JSON" && ! -f "${DOCKER_DAEMON_JSON}.bak" ]]; then
    cp "$DOCKER_DAEMON_JSON" "${DOCKER_DAEMON_JSON}.bak"
    echo "[INFO] Backed up existing daemon.json to daemon.json.bak"
  fi

  cat >"$DOCKER_DAEMON_JSON" <<'EOF'
{
  "min-api-version": "1.24",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

  systemctl restart docker || die "Failed to restart Docker after daemon.json update."

  echo "[INFO] Docker daemon.json written and Docker restarted."
  echo "[INFO] This fixes the 'client version 1.24 is too old (min 1.44)' error from Traefik."
}

ensure_base_dir() {
  echo "[INFO] Ensuring base directory exists at $BASE_DIR..."
  mkdir -p "$BASE_DIR" || die "Failed to create $BASE_DIR."
}

# ---------- Collect configuration ----------

collect_config() {
  echo "[INFO] We will now collect configuration for NocoDB and its services."

  read -r -p "Enter the domain for NocoDB (e.g. sales.palforge.it) [leave blank for no host routing]: " NC_DOMAIN
  NC_DOMAIN="${NC_DOMAIN:-}"

  read -r -p "Enter NocoDB admin email [admin@example.com]: " NC_ADMIN_EMAIL
  NC_ADMIN_EMAIL="${NC_ADMIN_EMAIL:-admin@example.com}"

  read -r -s -p "Enter NocoDB admin password (leave blank to auto-generate): " NC_ADMIN_PASSWORD
  echo ""
  if [[ -z "$NC_ADMIN_PASSWORD" ]]; then
    NC_ADMIN_PASSWORD="$(rand_pw)"
    echo "[INFO] Generated random NocoDB admin password: $NC_ADMIN_PASSWORD"
  fi

  read -r -s -p "Enter Postgres password for 'nocodb' user (leave blank to auto-generate): " NC_DB_PASSWORD
  echo ""
  if [[ -z "$NC_DB_PASSWORD" ]]; then
    NC_DB_PASSWORD="$(rand_pw)"
    echo "[INFO] Generated random Postgres password: $NC_DB_PASSWORD"
  fi

  # JWT secret for NocoDB
  NC_JWT_SECRET="$(rand_pw)"

  # Traefik dashboard
  read -r -p "Expose Traefik dashboard on port 8080? (y/N): " EXPOSE_DASH
  EXPOSE_DASH="${EXPOSE_DASH:-N}"

  # Cloudflare Tunnel
  read -r -p "Do you want to install and configure a Cloudflare Tunnel for this instance? (y/N): " USE_CF
  USE_CF="${USE_CF:-N}"
  CF_TUNNEL_TOKEN=""

  if [[ "$USE_CF" =~ ^[Yy]$ ]]; then
    while [[ -z "$CF_TUNNEL_TOKEN" ]]; do
      read -r -p "Enter your Cloudflare Tunnel token (from Cloudflare dashboard): " CF_TUNNEL_TOKEN
      [[ -z "$CF_TUNNEL_TOKEN" ]] && echo "[WARN] Token cannot be empty."
    done
  fi

  export NC_DOMAIN NC_ADMIN_EMAIL NC_ADMIN_PASSWORD NC_DB_PASSWORD NC_JWT_SECRET EXPOSE_DASH USE_CF CF_TUNNEL_TOKEN
}

# ---------- Docker compose stack ----------

write_docker_compose() {
  echo "[INFO] Writing docker-compose stack to $BASE_DIR/docker-compose.yml..."

  local DASH_PORTS=""
  if [[ "$EXPOSE_DASH" =~ ^[Yy]$ ]]; then
    DASH_PORTS='      - "8080:8080"'
  fi

  local TRAEFIK_LABEL_DOMAIN=""
  if [[ -n "$NC_DOMAIN" ]]; then
    TRAEFIK_LABEL_DOMAIN="      - \"traefik.http.routers.nocodb.rule=Host(\`$NC_DOMAIN\`)\""
  else
    # If no domain specified, route everything on /
    TRAEFIK_LABEL_DOMAIN="      - \"traefik.http.routers.nocodb.rule=PathPrefix(\`/\`)\""
  fi

  cat >"$BASE_DIR/docker-compose.yml" <<EOF
services:
  nocodb:
    image: nocodb/nocodb:latest
    container_name: nocodb-nocodb
    restart: unless-stopped
    depends_on:
      - postgres
      - redis
    environment:
      NC_DB: "pg://postgres:5432?u=nocodb&p=${NC_DB_PASSWORD}&d=nocodb"
      NC_REDIS_URL: "redis://redis:6379"
      NC_AUTH_JWT_SECRET: "${NC_JWT_SECRET}"
      NC_ADMIN_EMAIL: "${NC_ADMIN_EMAIL}"
      NC_ADMIN_PASSWORD: "${NC_ADMIN_PASSWORD}"
    expose:
      - "8080"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.nocodb.entrypoints=web"
${TRAEFIK_LABEL_DOMAIN}
      - "traefik.http.services.nocodb.loadbalancer.server.port=8080"

  postgres:
    image: postgres:16
    container_name: nocodb-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: nocodb
      POSTGRES_PASSWORD: "${NC_DB_PASSWORD}"
      POSTGRES_DB: nocodb
    volumes:
      - ./pgdata:/var/lib/postgresql/data

  redis:
    image: redis:7
    container_name: nocodb-redis
    restart: unless-stopped
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - ./redisdata:/data

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
${DASH_PORTS}
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"

# Optional: if you later want watchtower, add it manually.
#  watchtower:
#    image: containrrr/watchtower
#    container_name: nocodb-watchtower
#    restart: unless-stopped
#    command: --cleanup --interval 300
#    volumes:
#      - "/var/run/docker.sock:/var/run/docker.sock"
EOF

  echo "[INFO] docker-compose.yml created."
}

cleanup_old_containers() {
  echo "[INFO] Cleaning up any old NocoDB/Traefik containers from previous runs..."

  # This removes containers whose names start with "nocodb-" or match older names.
  local OLD_CONTAINERS
  OLD_CONTAINERS="$(docker ps -a --format '{{.Names}}' | grep -E '^nocodb-|^nocodb$|^nocodb-app$|^traefik$' || true)"

  if [[ -n "$OLD_CONTAINERS" ]]; then
    echo "[INFO] Removing old containers:"
    echo "$OLD_CONTAINERS"
    docker rm -f $OLD_CONTAINERS >/dev/null 2>&1 || echo "[WARN] Some containers could not be removed. You may clean them manually."
  else
    echo "[INFO] No old containers found."
  fi
}

bring_up_stack() {
  echo "[INFO] Bringing up NocoDB stack with docker compose..."
  cd "$BASE_DIR" || die "Failed to cd into $BASE_DIR."

  # Down first for idempotency
  docker compose down >/dev/null 2>&1 || true

  docker compose pull >/dev/null 2>&1 || echo "[WARN] Failed to pull images (using cached/local if present)."

  docker compose up -d || die "docker compose up failed."

  echo "[INFO] Docker containers now running:"
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

# ---------- Cloudflare Tunnel ----------

install_cloudflared() {
  if ! [[ "$USE_CF" =~ ^[Yy]$ ]]; then
    echo "[INFO] Cloudflare Tunnel installation skipped."
    return
  fi

  echo "[INFO] Installing Cloudflare Tunnel (cloudflared) natively..."

  mkdir -p --mode=0755 /usr/share/keyrings

  # Add Cloudflare GPG key
  curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg \
    | tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null || {
      echo "[WARN] Failed to download Cloudflare GPG key. Skipping Tunnel setup."
      return
    }

  echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' \
    >/etc/apt/sources.list.d/cloudflared.list

  apt-get update -y >/dev/null 2>&1 || {
    echo "[WARN] apt-get update failed while installing cloudflared."
    return
  }

  apt-get install -y cloudflared >/dev/null 2>&1 || {
    echo "[WARN] Failed to install cloudflared package."
    return
  }

  # Install service with provided token
  cloudflared service install "$CF_TUNNEL_TOKEN" >/dev/null 2>&1 || {
    echo "[WARN] cloudflared service install failed. You may need to run it manually."
    return
  }

  systemctl enable --now cloudflared >/dev/null 2>&1 || {
    echo "[WARN] Failed to start/enable cloudflared service."
    return
  }

  echo "[INFO] Cloudflare Tunnel installed and running as a system service."
}

# ---------- Health check ----------

health_check() {
  echo "[INFO] Waiting a few seconds for NocoDB to start..."
  sleep 10

  # Find NocoDB container IP
  local APP_CONTAINER="nocodb-nocodb"
  if ! docker ps --format '{{.Names}}' | grep -q "^${APP_CONTAINER}\$"; then
    echo "[WARN] NocoDB container '${APP_CONTAINER}' is not running."
    return
  fi

  local APP_IP
  APP_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$APP_CONTAINER" 2>/dev/null || echo "")"

  if [[ -z "$APP_IP" ]]; then
    echo "[WARN] Could not determine NocoDB container IP."
  else
    echo "[INFO] NocoDB internal IP: $APP_IP"
    echo "[INFO] Testing direct HTTP from host..."
    curl -s -o /dev/null -w "%{http_code}\n" "http://${APP_IP}:8080" || echo "[WARN] curl test to NocoDB failed."
  fi

  echo ""
  echo "======================================="
  echo "  Setup Complete                        "
  echo "======================================="
  if [[ -n "$NC_DOMAIN" ]]; then
    echo "-> If DNS (and Cloudflare/Tunnel) is configured, access NocoDB at: http://${NC_DOMAIN}"
  else
    echo "-> No domain provided. You can test locally by:"
    echo "     curl -v http://localhost -H \"Host: your.domain.example\""
  fi
  echo "Admin login:"
  echo "  Email:    ${NC_ADMIN_EMAIL}"
  echo "  Password: ${NC_ADMIN_PASSWORD}"
}

# ---------- Main ----------

main() {
  require_root
  install_dependencies
  install_docker
  configure_docker_daemon
  ensure_base_dir
  collect_config
  write_docker_compose
  cleanup_old_containers
  bring_up_stack
  install_cloudflared
  health_check
}

main "$@"
