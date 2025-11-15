#!/usr/bin/env bash
# NocoDB + Postgres + Redis + Traefik (+ optional Cloudflare Tunnel) installer
# To run (inside the VM):
#   sudo bash <(curl -sSL https://raw.githubusercontent.com/abellpfs/palforge-nocodb-installer/main/setup_nocodb.sh)

set -e

#######################################
# Helpers
#######################################

log() {
  echo "[INFO] $*"
}

err() {
  echo "[ERROR] $*" >&2
}

random_password() {
  # random_password <length>
  local length="${1:-32}"
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${length}"
}

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    err "This script must be run as root. Try: sudo bash setup_nocodb.sh"
    exit 1
  fi
}

#######################################
# Docker install (if missing)
#######################################

install_docker_if_needed() {
  if command -v docker &>/dev/null; then
    log "Docker is already installed."
    return
  fi

  log "Installing Docker (engine + CLI)..."
  # Based on Docker's official Linux install instructions.
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  local codename
  codename="$(lsb_release -cs)"

  echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker
  log "Docker installed successfully."
}

#######################################
# Main
#######################################

require_root

log "Updating apt and installing base dependencies..."
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release jq

install_docker_if_needed

BASE_DIR="/opt/nocodb"
DOCKER_COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"

log "Ensuring base directory exists at ${BASE_DIR}..."
mkdir -p "${BASE_DIR}"

log "We will now collect configuration for NocoDB and its services."

# Domain / Host routing
read -r -p "Enter the domain for NocoDB (e.g. sales.palforge.it) [leave blank for no host routing]: " DOMAIN
DOMAIN="${DOMAIN:-}"

# Admin email
read -r -p "Enter NocoDB admin email [admin@example.com]: " ADMIN_EMAIL
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"

# Admin password
read -s -p "Enter NocoDB admin password (leave blank to auto-generate): " ADMIN_PASSWORD
echo
if [[ -z "${ADMIN_PASSWORD}" ]]; then
  ADMIN_PASSWORD="$(random_password 20)"
  log "Generated random admin password: ${ADMIN_PASSWORD}"
fi

# Postgres password
read -s -p "Enter Postgres password for 'nocodb' user (leave blank to auto-generate): " POSTGRES_PASSWORD
echo
if [[ -z "${POSTGRES_PASSWORD}" ]]; then
  POSTGRES_PASSWORD="$(random_password 24)"
  log "Generated random Postgres password: ${POSTGRES_PASSWORD}"
fi

# Traefik dashboard
read -r -p "Expose Traefik dashboard on port 8080? (y/N): " EXPOSE_DASHBOARD
EXPOSE_DASHBOARD="${EXPOSE_DASHBOARD:-N}"

# Cloudflare Tunnel
read -r -p "Do you want to run a Cloudflare Tunnel (cloudflared container)? (y/N): " INSTALL_CF
INSTALL_CF="${INSTALL_CF:-N}"

CF_TUNNEL_TOKEN=""
if [[ "${INSTALL_CF}" =~ ^[Yy]$ ]]; then
  read -r -p "Enter your Cloudflare Tunnel token (from Cloudflare dashboard): " CF_TUNNEL_TOKEN
  if [[ -z "${CF_TUNNEL_TOKEN}" ]]; then
    err "Cloudflare Tunnel token cannot be empty if Cloudflare integration is enabled."
    exit 1
  fi
fi

# JWT secret for NocoDB
JWT_SECRET="$(random_password 32)"

#######################################
# Generate docker-compose.yml
#######################################

log "Writing docker-compose stack to ${DOCKER_COMPOSE_FILE}..."

# We’ll always define services, and conditionally add labels / cloudflared.
{
cat <<EOF
services:
  nocodb-postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_DB: nocodb
      POSTGRES_USER: nocodb
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - ${BASE_DIR}/postgres_data:/var/lib/postgresql/data
    networks:
      - nocodb-net

  nocodb-redis:
    image: redis:7-alpine
    restart: unless-stopped
    command: ["redis-server", "--appendonly", "yes"]
    volumes:
      - ${BASE_DIR}/redis_data:/data
    networks:
      - nocodb-net

  nocodb-app:
    image: nocodb/nocodb:latest
    restart: unless-stopped
    depends_on:
      - nocodb-postgres
      - nocodb-redis
    environment:
      NC_DB: "pg://nocodb-postgres:5432?u=nocodb&p=${POSTGRES_PASSWORD}&d=nocodb"
      NC_REDIS_URL: "redis://nocodb-redis:6379"
      NC_AUTH_JWT_SECRET: "${JWT_SECRET}"
      NC_ADMIN_EMAIL: "${ADMIN_EMAIL}"
      NC_ADMIN_PASSWORD: "${ADMIN_PASSWORD}"
    volumes:
      - ${BASE_DIR}/nc_data:/usr/app/data
    networks:
      - nocodb-net
EOF

# If a domain was provided, add Traefik labels; otherwise expose port 8080 directly.
if [[ -n "${DOMAIN}" ]]; then
cat <<EOF
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.nocodb.rule=Host(\`${DOMAIN}\`)"
      - "traefik.http.routers.nocodb.entrypoints=web"
      - "traefik.http.services.nocodb.loadbalancer.server.port=8080"
EOF
else
cat <<EOF
    ports:
      - "8080:8080"
EOF
fi

# Traefik service
cat <<EOF

  traefik:
    image: traefik:v3.1
    restart: unless-stopped
    command:
      - "--providers.docker=true"
      - "--providers.docker.exposedByDefault=false"
      - "--entrypoints.web.address=:80"
EOF

if [[ "${EXPOSE_DASHBOARD}" =~ ^[Yy]$ ]]; then
cat <<'EOF'
      - "--api.dashboard=true"
      - "--api.insecure=true"
EOF
else
cat <<'EOF'
      - "--api.dashboard=false"
EOF
fi

cat <<EOF
    ports:
      - "80:80"
      - "8080:8080"
    environment:
      - DOCKER_API_VERSION=1.52
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - nocodb-net
EOF

# Optional cloudflared service
if [[ "${INSTALL_CF}" =~ ^[Yy]$ ]]; then
cat <<EOF

  cloudflared:
    image: cloudflare/cloudflared:latest
    restart: unless-stopped
    command: tunnel --no-autoupdate run --token ${CF_TUNNEL_TOKEN}
    networks:
      - nocodb-net
EOF
fi

# Watchtower (optional but nice)
cat <<EOF

  watchtower:
    image: containrrr/watchtower
    restart: unless-stopped
    command: --cleanup --interval 86400
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    networks:
      - nocodb-net

networks:
  nocodb-net:
    driver: bridge
EOF

} > "${DOCKER_COMPOSE_FILE}"

log "docker-compose.yml created."

#######################################
# Bring up the stack
#######################################

log "Starting NocoDB stack with Docker Compose..."
cd "${BASE_DIR}"

docker compose pull
docker compose up -d

log "Stack started."

if [[ -n "${DOMAIN}" ]]; then
  log "NocoDB should be reachable via Traefik at: http://${DOMAIN} (or via your Cloudflare Tunnel if configured)."
else
  log "NocoDB should be reachable at: http://<this-vm-ip>:8080"
fi

log "Admin email:    ${ADMIN_EMAIL}"
log "Admin password: ${ADMIN_PASSWORD}"
log "Postgres DB:    nocodb"
log "Postgres user:  nocodb"
log "Postgres pass:  ${POSTGRES_PASSWORD}"

log "Done."
