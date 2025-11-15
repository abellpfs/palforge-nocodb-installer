#!/usr/bin/env bash
set -euo pipefail

############################################
# NocoDB + Traefik + Postgres + Redis installer
# For use *inside* the VM
############################################

# --- Auto-elevate to root if needed ---
if [[ "$EUID" -ne 0 ]]; then
  echo "[INFO] Not running as root. Re-running with sudo..."
  exec sudo bash "$0" "$@"
fi

# --- Helpers ---
random_password() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
}

prompt_default() {
  local prompt="$1"
  local default="$2"
  local var
  read -r -p "$prompt [$default]: " var
  echo "${var:-$default}"
}

prompt_hidden() {
  local prompt="$1"
  local var1 var2
  while true; do
    read -s -p "$prompt: " var1
    echo
    read -s -p "Confirm password: " var2
    echo
    if [[ "$var1" == "$var2" ]]; then
      echo "$var1"
      return 0
    else
      echo "[WARN] Passwords do not match. Try again."
    fi
  done
}

echo "======================================="
echo "  NocoDB + Traefik Installer (VM)      "
echo "======================================="

BASE_DIR="/opt/nocodb"
STACK_NAME="nocodb_stack"
DOCKER_COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# --- Install basic deps ---
echo "[INFO] Updating apt and installing dependencies..."
apt-get update -y
apt-get install -y \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  jq

# --- Install Docker if missing ---
if ! command -v docker >/dev/null 2>&1; then
  echo "[INFO] Docker not found. Installing Docker Engine..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" \
    >/etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable docker
  systemctl start docker
  echo "[INFO] Docker installed successfully."
else
  echo "[INFO] Docker is already installed."
fi

# --- Create base directory ---
echo "[INFO] Ensuring base directory exists at $BASE_DIR..."
mkdir -p "$BASE_DIR"
cd "$BASE_DIR"

# --- Collect configuration ---
echo "[INFO] We will now collect configuration for NocoDB and its services."

read -r -p "Enter the domain for NocoDB (e.g. sales.palforge.it) [leave blank for no host routing]: " NOCODB_HOST
read -r -p "Enter NocoDB admin email [admin@example.com]: " NOCODB_ADMIN_EMAIL
NOCODB_ADMIN_EMAIL=${NOCODB_ADMIN_EMAIL:-admin@example.com}

read -s -p "Enter NocoDB admin password (leave blank to auto-generate): " NOCODB_ADMIN_PASSWORD
echo
if [[ -z "$NOCODB_ADMIN_PASSWORD" ]]; then
  NOCODB_ADMIN_PASSWORD=$(random_password)
  echo "[INFO] Generated random NocoDB admin password: $NOCODB_ADMIN_PASSWORD"
fi

read -s -p "Enter Postgres password for 'nocodb' user (leave blank to auto-generate): " POSTGRES_PASSWORD
echo
if [[ -z "$POSTGRES_PASSWORD" ]]; then
  POSTGRES_PASSWORD=$(random_password)
  echo "[INFO] Generated random Postgres password: $POSTGRES_PASSWORD"
fi

read -r -p "Expose Traefik dashboard on port 8080? (y/N): " EXPOSE_DASH
EXPOSE_DASH=${EXPOSE_DASH,,} # lowercase
EXPOSE_DASH=${EXPOSE_DASH:-n}

read -r -p "Do you want to install and configure a Cloudflare Tunnel for this instance? (y/N): " USE_CF
USE_CF=${USE_CF,,}
USE_CF=${USE_CF:-n}

CF_TOKEN=""
if [[ "$USE_CF" == "y" ]]; then
  read -r -p "Enter your Cloudflare Tunnel token (from Cloudflare dashboard): " CF_TOKEN
fi

# --- Generate docker-compose.yml ---
echo "[INFO] Writing docker-compose stack to $DOCKER_COMPOSE_FILE..."

cat >"$DOCKER_COMPOSE_FILE" <<EOF
services:
  traefik:
    image: traefik:v3.1
    container_name: nocodb-traefik-1
    command:
      - "--api.dashboard=true"
      - "--providers.docker=true"
      - "--providers.docker.exposedByDefault=false"
      - "--entrypoints.web.address=:80"
EOF

if [[ "$EXPOSE_DASH" == "y" ]]; then
cat >>"$DOCKER_COMPOSE_FILE" <<EOF
      - "--entrypoints.traefik.address=:8080"
EOF
fi

cat >>"$DOCKER_COMPOSE_FILE" <<EOF
    ports:
      - "80:80"
EOF

if [[ "$EXPOSE_DASH" == "y" ]]; then
cat >>"$DOCKER_COMPOSE_FILE" <<EOF
      - "8080:8080"
EOF
fi

cat >>"$DOCKER_COMPOSE_FILE" <<EOF
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
    restart: unless-stopped

  postgres:
    image: postgres:16
    container_name: nocodb-postgres
    environment:
      POSTGRES_DB: nocodb
      POSTGRES_USER: nocodb
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - "postgres_data:/var/lib/postgresql/data"
    restart: unless-stopped

  redis:
    image: redis:7-alpine
    container_name: nocodb-redis
    restart: unless-stopped

  nocodb:
    image: nocodb/nocodb:latest
    container_name: nocodb-app
    environment:
      NC_DB: "pg://postgres:5432?u=nocodb&p=${POSTGRES_PASSWORD}&d=nocodb"
      NC_REDIS_URL: "redis://redis:6379"
      NC_AUTH_EMAIL: "${NOCODB_ADMIN_EMAIL}"
      NC_AUTH_PASSWORD: "${NOCODB_ADMIN_PASSWORD}"
      NC_PUBLIC_URL: "http://${NOCODB_HOST:-localhost}"
    depends_on:
      - postgres
      - redis
    labels:
      - "traefik.enable=true"
EOF

if [[ -n "$NOCODB_HOST" ]]; then
cat >>"$DOCKER_COMPOSE_FILE" <<EOF
      - "traefik.http.routers.nocodb.rule=Host(\`${NOCODB_HOST}\`)"
      - "traefik.http.routers.nocodb.entrypoints=web"
EOF
else
cat >>"$DOCKER_COMPOSE_FILE" <<EOF
      - "traefik.http.routers.nocodb.rule=PathPrefix(\`/\`)"
      - "traefik.http.routers.nocodb.entrypoints=web"
EOF
fi

cat >>"$DOCKER_COMPOSE_FILE" <<EOF
    restart: unless-stopped

volumes:
  postgres_data:
EOF

echo "[INFO] docker-compose.yml created."

# --- Install Cloudflare Tunnel (cloudflared) if requested ---
if [[ "$USE_CF" == "y" ]]; then
  echo "[INFO] Installing Cloudflare Tunnel (cloudflared) via APT..."

  # Add Cloudflare GPG key & repo (new method)
  mkdir -p --mode=0755 /usr/share/keyrings

  curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg \
    -o /usr/share/keyrings/cloudflare-public-v2.gpg

  echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' \
    >/etc/apt/sources.list.d/cloudflared.list

  apt-get update -y
  apt-get install -y cloudflared

  echo "[INFO] cloudflared installed."

  # Create systemd unit for cloudflared using token
  cat >/etc/systemd/system/cloudflared-nocodb.service <<EOF
[Unit]
Description=Cloudflare Tunnel for NocoDB
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/cloudflared tunnel run --token ${CF_TOKEN}
Restart=always
RestartSec=5s
User=root

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable cloudflared-nocodb.service
  systemctl start cloudflared-nocodb.service

  echo "[INFO] Cloudflare Tunnel systemd service created and started."
fi

# --- Bring up the stack ---
echo "[INFO] Pulling images and starting NocoDB stack..."
docker compose -f "$DOCKER_COMPOSE_FILE" pull
docker compose -f "$DOCKER_COMPOSE_FILE" up -d

echo
echo "======================================="
echo "      NocoDB Installation Complete     "
echo "======================================="
if [[ -n "$NOCODB_HOST" ]]; then
  echo "NocoDB should be available at: http://${NOCODB_HOST}"
else
  echo "NocoDB should be available at: http://<this-vm-ip>/"
fi
echo
echo "Admin login:"
echo "  Email:    $NOCODB_ADMIN_EMAIL"
echo "  Password: $NOCODB_ADMIN_PASSWORD"
echo
echo "Postgres:"
echo "  Host:     postgres"
echo "  DB:       nocodb"
echo "  User:     nocodb"
echo "  Password: $POSTGRES_PASSWORD"
echo
if [[ "$USE_CF" == "y" ]]; then
  echo "Cloudflare Tunnel is configured and running using your token."
fi
echo "Done."
