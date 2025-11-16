#!/usr/bin/env bash
set -euo pipefail

# Pal Forge IT - General Purpose VM Factory for Proxmox
# Creates a cloud-init Ubuntu VM with standard Pal Forge naming, tags, and options.

# ------------- Globals -------------

TMP_IMG=""
VM_CREATED=0

# ------------- Helpers -------------

err() {
  echo "ERROR: $*" >&2
}

cleanup() {
  if [[ -n "${TMP_IMG:-}" && -f "$TMP_IMG" ]]; then
    echo "Cleaning up temporary image: $TMP_IMG"
    rm -f "$TMP_IMG"
  fi
  if [[ "${VM_CREATED:-0}" -eq 1 ]]; then
    echo "An error occurred. Destroying VM $VMID..."
    qm destroy "$VMID" --purge || true
  fi
}
trap cleanup EXIT

require_cmd() {
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      err "Required command '$cmd' not found. Please install it first."
      exit 1
    fi
  done
}

read_default() {
  local prompt="$1"
  local default="$2"
  local value
  read -r -p "$prompt [$default]: " value
  if [[ -z "$value" ]]; then
    echo "$default"
  else
    echo "$value"
  fi
}

yes_no_default() {
  local prompt="$1"
  local default="$2" # y or n
  local value
  read -r -p "$prompt ($( [[ "$default" == "y" ]] && echo "Y/n" || echo "y/N" )): " value
  value="${value,,}" # lowercase
  if [[ -z "$value" ]]; then
    value="$default"
  fi
  if [[ "$value" == "y" || "$value" == "yes" ]]; then
    return 0
  else
    return 1
  fi
}

# Simple text progress bar that works in xterm.js
progress_bar() {
  local percent="$1"
  local width=30
  local filled=$((percent * width / 100))
  local empty=$((width - filled))
  local bar=""
  local i

  for ((i=0; i<filled; i++)); do
    bar+="#"
  done
  for ((i=0; i<empty; i++)); do
    bar+=" "
  done

  # Single-line, carriage-return update (xterm.js friendly)
  printf "\rDownloading Image |%s| %3d%%" "$bar" "$percent"
}

# Download with a smooth, time-based progress bar (no noisy curl output)
download_image_with_progress() {
  local url="$1"
  local outfile="$2"

  # Start curl quietly in the background
  (
    curl -L -sSf "$url" -o "$outfile"
  ) &
  local curl_pid=$!

  local percent=0
  progress_bar "$percent"

  # Animate while curl is running
  while kill -0 "$curl_pid" 2>/dev/null; do
    if (( percent < 99 )); then
      percent=$((percent + 1))
    fi
    progress_bar "$percent"
    sleep 0.2
  done

  # Wait for curl to finish and check result
  if ! wait "$curl_pid"; then
    echo
    err "Image download failed."
    exit 1
  fi

  # Finish at 100% and show a clean 'Done' line
  progress_bar 100
  # Overwrite with a nice Done line
  printf "\rDownloading Image | %-30s |\n" "Done"
}

# ------------- Pre-flight checks -------------

if [[ "$(id -u)" -ne 0 ]]; then
  err "This script must be run as root on a Proxmox node."
  exit 1
fi

require_cmd qm pvesm curl awk sed grep

echo "=========================================="
echo " Pal Forge IT - Proxmox VM Factory"
echo "=========================================="
echo

# ------------- Environment / role / naming -------------

# Environment
echo "Choose environment:"
echo "  1) prod"
echo "  2) dev"
echo "  3) test"
echo "  4) lab"
read -r -p "Choice [2]: " ENV_CHOICE
case "$ENV_CHOICE" in
  1) ENV="prod" ;;
  3) ENV="test" ;;
  4) ENV="lab" ;;
  *) ENV="dev" ;;
esac

# Role
echo
echo "Choose role:"
echo "  1) nocodb"
echo "  2) web"
echo "  3) app"
echo "  4) db"
echo "  5) util"
echo "  6) other"
read -r -p "Choice [1]: " ROLE_CHOICE
case "$ROLE_CHOICE" in
  2) ROLE="web" ;;
  3) ROLE="app" ;;
  4) ROLE="db" ;;
  5) ROLE="util" ;;
  6)
    read -r -p "Enter custom role (e.g. suitecrm): " ROLE
    ROLE="${ROLE:-util}"
    ;;
  *) ROLE="nocodb" ;;
esac

# Site code
SITE=$(read_default "Site/location code" "den")

# Default base name
BASE_NAME="pfs-${ENV}-${ROLE}-${SITE}"
VM_NAME=$(read_default "VM name" "${BASE_NAME}-01")

echo
echo "Environment: $ENV"
echo "Role:        $ROLE"
echo "Site:        $SITE"
echo "VM Name:     $VM_NAME"
echo

# ------------- VMID selection -------------

# Find first free VMID between 5000-5999
DEFAULT_VMID=""
for id in $(seq 5000 5999); do
  if ! qm status "$id" >/dev/null 2>&1; then
    DEFAULT_VMID="$id"
    break
  fi
done

if [[ -z "$DEFAULT_VMID" ]]; then
  err "No free VMID found between 5000 and 5999. Please free one or expand the range."
  exit 1
fi

read -r -p "VM ID [$DEFAULT_VMID]: " VMID
VMID="${VMID:-$DEFAULT_VMID}"

if qm status "$VMID" >/dev/null 2>&1; then
  err "VM ID $VMID already exists. Choose a different VMID."
  exit 1
fi

# ------------- Resources (CPU / RAM / Disk) -------------

# Environment-based defaults
case "$ENV" in
  prod)
    DEF_CORES=4
    DEF_MEM_GB=8
    DEF_DISK_GB=80
    ;;
  dev)
    DEF_CORES=2
    DEF_MEM_GB=4
    DEF_DISK_GB=40
    ;;
  test|lab)
    DEF_CORES=2
    DEF_MEM_GB=2
    DEF_DISK_GB=30
    ;;
  *)
    DEF_CORES=2
    DEF_MEM_GB=4
    DEF_DISK_GB=40
    ;;
esac

CORES=$(read_default "CPU cores" "$DEF_CORES")
MEM_GB=$(read_default "Memory (in GB)" "$DEF_MEM_GB")
DISK_GB=$(read_default "Disk size (in GB)" "$DEF_DISK_GB")

# Convert memory to MB
MEMORY=$((MEM_GB * 1024))

# ------------- Storage & network -------------

echo
echo "Available storages:"
pvesm status

echo
echo "Select storage for disk & cloud-init:"
mapfile -t STORAGE_NAMES < <(pvesm status | awk 'NR>1 {print $1}')
for i in "${!STORAGE_NAMES[@]}"; do
  idx=$((i+1))
  printf "  %d) %s\n" "$idx" "${STORAGE_NAMES[$i]}"
done

read -r -p "Choice [1]: " STORAGE_CHOICE
STORAGE_CHOICE="${STORAGE_CHOICE:-1}"
if ! [[ "$STORAGE_CHOICE" =~ ^[0-9]+$ ]] || (( STORAGE_CHOICE < 1 || STORAGE_CHOICE > ${#STORAGE_NAMES[@]} )); then
  err "Invalid storage choice."
  exit 1
fi
STORAGE="${STORAGE_NAMES[$((STORAGE_CHOICE-1))]}"
echo "Using storage: $STORAGE"

BRIDGE=$(read_default "Bridge name" "vmbr0")

# ------------- OS Image selection -------------

echo
echo "Choose OS image:"
echo "  1) Ubuntu 24.04 (noble) cloudimg"
echo "  2) Ubuntu 22.04 (jammy) cloudimg"
read -r -p "Choice [1]: " OS_CHOICE

case "$OS_CHOICE" in
  2)
    IMAGE_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
    ;;
  *)
    IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
    ;;
esac

echo "Using image: $IMAGE_URL"

# ------------- Auth mode & user -------------

echo
VM_USER=$(read_default "VM username" "pfsadmin")

echo
echo "Authentication mode:"
echo "  1) Password only"
echo "  2) SSH key only"
echo "  3) SSH key + password"
read -r -p "Choice [1]: " AUTH_CHOICE
AUTH_CHOICE="${AUTH_CHOICE:-1}"

VM_PASS=""
SSH_KEY_PATH=""
SSH_KEY_DATA=""
SSH_PW_AUTH="true"  # default

case "$AUTH_CHOICE" in
  2)
    # SSH key only
    SSH_PW_AUTH="false"
    if yes_no_default "Use default SSH public key at ~/.ssh/id_rsa.pub?" "y"; then
      SSH_KEY_PATH="${HOME}/.ssh/id_rsa.pub"
    else
      read -r -p "Enter path to SSH public key file: " SSH_KEY_PATH
    fi
    SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"
    if [[ ! -f "$SSH_KEY_PATH" ]]; then
      err "SSH key file '$SSH_KEY_PATH' not found."
      exit 1
    fi
    SSH_KEY_DATA="$(cat "$SSH_KEY_PATH")"
    ;;
  3)
    # SSH key + password
    SSH_PW_AUTH="true"
    if yes_no_default "Use default SSH public key at ~/.ssh/id_rsa.pub?" "y"; then
      SSH_KEY_PATH="${HOME}/.ssh/id_rsa.pub"
    else
      read -r -p "Enter path to SSH public key file: " SSH_KEY_PATH
    fi
    SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"
    if [[ ! -f "$SSH_KEY_PATH" ]]; then
      err "SSH key file '$SSH_KEY_PATH' not found."
      exit 1
    fi
    SSH_KEY_DATA="$(cat "$SSH_KEY_PATH")"
    read -s -p "VM password: " VM_PASS
    echo
    read -s -p "Confirm password: " VM_PASS2
    echo
    if [[ "$VM_PASS" != "$VM_PASS2" ]]; then
      err "Passwords do not match."
      exit 1
    fi
    ;;
  *)
    # Password only
    SSH_PW_AUTH="true"
    read -s -p "VM password: " VM_PASS
    echo
    read -s -p "Confirm password: " VM_PASS2
    echo
    if [[ "$VM_PASS" != "$VM_PASS2" ]]; then
      err "Passwords do not match."
      exit 1
    fi
    ;;
esac

# ------------- Networking: DHCP vs Static -------------

echo
if yes_no_default "Use static IP instead of DHCP?" "n"; then
  read -r -p "Static IP (e.g. 10.1.10.200): " STATIC_IP
  read -r -p "CIDR prefix (e.g. 24 for /24): " CIDR
  read -r -p "Gateway IP (e.g. 10.1.10.1): " GATEWAY
  IPCONFIG0="ip=${STATIC_IP}/${CIDR},gw=${GATEWAY}"
else
  IPCONFIG0="ip=dhcp"
fi

# ------------- Download cloud image -------------

echo
echo "Downloading Ubuntu cloud image..."
TMP_IMG="$(mktemp --suffix=.img)"
download_image_with_progress "$IMAGE_URL" "$TMP_IMG"

# ------------- Create VM -------------

echo
echo "Creating VM $VMID ($VM_NAME)..."
qm create "$VMID" \
  --name "$VM_NAME" \
  --memory "$MEMORY" \
  --cores "$CORES" \
  --net0 "virtio,bridge=${BRIDGE}" \
  --ostype l26

VM_CREATED=1

echo "Importing disk to storage '$STORAGE'..."
qm importdisk "$VMID" "$TMP_IMG" "$STORAGE" --format qcow2

# Find the imported disk volid
DISK_VOLID="$(pvesm list "$STORAGE" | awk -v vmid="$VMID" '$1 ~ ("vm-"vmid"-disk-0") {print $1; exit}')"

if [[ -z "$DISK_VOLID" ]]; then
  err "Could not determine imported disk volid on storage '$STORAGE'."
  exit 1
fi

echo "Attaching disk as scsi0 ($DISK_VOLID)..."
qm set "$VMID" --scsihw virtio-scsi-pci --scsi0 "$DISK_VOLID"

echo "Resizing disk to ${DISK_GB}G..."
qm resize "$VMID" scsi0 "${DISK_GB}G"

echo "Allocating EFI disk..."
qm set "$VMID" --efidisk0 "${STORAGE}:0,pre-enrolled-keys=1"

echo "Adding cloud-init drive..."
qm set "$VMID" --ide2 "${STORAGE}:cloudinit"

echo "Configuring boot & console..."
qm set "$VMID" --boot order=scsi0 --bootdisk scsi0
qm set "$VMID" --serial0 socket --vga serial0

echo "Enabling QEMU agent..."
qm set "$VMID" --agent enabled=1

# ------------- Cloud-init: user, password, sshkeys -------------

echo "Setting cloud-init user..."
qm set "$VMID" --ciuser "$VM_USER"

if [[ "$AUTH_CHOICE" == "1" || "$AUTH_CHOICE" == "3" ]]; then
  echo "Setting cloud-init password..."
  qm set "$VMID" --cipassword "$VM_PASS"
fi

if [[ -n "$SSH_KEY_DATA" ]]; then
  echo "Adding SSH public key..."
  qm set "$VMID" --sshkeys "$SSH_KEY_DATA"
fi

echo "Configuring IP (ipconfig0=${IPCONFIG0})..."
qm set "$VMID" --ipconfig0 "$IPCONFIG0"

# ------------- Cloud-init custom snippet for ssh_pwauth (optional) -------------

SNIPPETS_SUPPORTED=0
if pvesm config "$STORAGE" 2>/dev/null | grep -q "snippets"; then
  SNIPPETS_SUPPORTED=1
fi

if [[ "$SNIPPETS_SUPPORTED" -eq 1 ]]; then
  SNIPPET_DIR="/mnt/pve/${STORAGE}/snippets"
  mkdir -p "$SNIPPET_DIR"
  SNIPPET_FILE="${SNIPPET_DIR}/pfs-user-${VMID}.yml"

  cat > "$SNIPPET_FILE" <<EOF
#cloud-config
ssh_pwauth: ${SSH_PW_AUTH}
EOF

  echo "Applying custom cloud-init user-data snippet (ssh_pwauth=${SSH_PW_AUTH})..."
  qm set "$VMID" --cicustom "user=${STORAGE}:snippets/pfs-user-${VMID}.yml"
else
  echo "WARNING: Storage '$STORAGE' does not advertise 'snippets' content."
  echo "         ssh_pwauth cannot be explicitly controlled via snippet."
fi

# ------------- Tags -------------

TAGS="palforge,env-${ENV},role-${ROLE},site-${SITE}"
echo "Setting tags: $TAGS"
qm set "$VMID" --tags "$TAGS"

# ------------- Start VM -------------

echo "Starting VM $VMID..."
qm start "$VMID"

# We are done successfully; don't destroy VM in trap.
VM_CREATED=0

echo
echo "=========================================="
echo " VM $VMID ($VM_NAME) created successfully"
echo "------------------------------------------"
echo " Environment : $ENV"
echo " Role        : $ROLE"
echo " Site        : $SITE"
echo " CPU cores   : $CORES"
echo " Memory      : ${MEM_GB} GB"
echo " Disk        : ${DISK_GB} GB"
echo " Storage     : $STORAGE"
echo " Bridge      : $BRIDGE"
echo " Username    : $VM_USER"
echo " Auth mode   : $(case "$AUTH_CHOICE" in 1) echo 'Password only' ;; 2) echo 'SSH key only' ;; 3) echo 'SSH key + password' ;; esac)"
echo " IP config   : $IPCONFIG0"
echo " Tags        : $TAGS"
echo "=========================================="
echo "You can connect after cloud-init finishes."
echo
