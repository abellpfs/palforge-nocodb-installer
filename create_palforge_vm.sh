#!/usr/bin/env bash
set -euo pipefail

# Pal Forge IT - General Purpose VM Factory for Proxmox
# Creates a cloud-init Ubuntu VM with standard Pal Forge naming, tags, and options.

# ------------- Globals -------------

VM_CREATED=0
IMAGE_PATH=""

CACHE_DIR="/var/lib/pf-vmfactory/images"
CACHE_MAX_AGE_DAYS=30

# ------------- Helpers -------------

err() {
  echo "ERROR: $*" >&2
}

cleanup() {
  # If VM was partially created and something failed, destroy it
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

is_positive_int() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" > 0 ))
}

is_cidr() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 0 && "$1" <= 32 ))
}

is_ip() {
  local ip="$1"
  if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    return 1
  fi
  IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
  for o in "$o1" "$o2" "$o3" "$o4"; do
    if (( o < 0 || o > 255 )); then
      return 1
    fi
  done
  return 0
}

# Simple text progress bar that works in xterm.js (goes to stderr)
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

  # Single-line, carriage-return update (xterm.js friendly, stderr)
  printf "\rDownloading Image |%s| %3d%%" "$bar" "$percent" >&2
}

# Download with a smooth, time-based progress bar (no noisy curl output)
# Progress output -> stderr, so stdout stays clean for path returns
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
    echo >&2
    err "Image download failed."
    rm -f "$outfile" || true
    exit 1
  fi

  # Finish at 100% and show a clean 'Done' line (stderr)
  progress_bar 100
  printf "\rDownloading Image | %-30s |\n" "Done" >&2
}

# Get cached image or download a fresh one (with expiration)
# IMPORTANT: Only the final echo of $img goes to stdout
get_or_download_image() {
  local url="$1"
  local cache_dir="$2"
  local max_days="$3"

  mkdir -p "$cache_dir"

  local filename
  filename="$(basename "$url")"
  local img="${cache_dir}/${filename}"
  local stamp="${img}.stamp"

  # If cached and stamp exists, check age
  if [[ -f "$img" && -f "$stamp" ]]; then
    local now ts age_days
    now=$(date +%s)
    ts=$(cat "$stamp" 2>/dev/null || echo 0)
    if [[ "$ts" =~ ^[0-9]+$ ]]; then
      age_days=$(( (now - ts) / 86400 ))
      if (( age_days <= max_days )); then
        printf '%s\n' "$img"
        return
      fi
    fi
    # Too old or bad stamp, purge
    rm -f "$img" "$stamp"
  fi

  # Need a fresh download (progress goes to stderr)
  download_image_with_progress "$url" "$img"
  date +%s > "$stamp"

  # Return path on stdout only
  printf '%s\n' "$img"
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

# ------------- Host Selection -------------

CURRENT_NODE=$(hostname)
if [[ -d /etc/pve/nodes ]]; then
  mapfile -t AVAILABLE_NODES < <(ls -1 /etc/pve/nodes)
else
  AVAILABLE_NODES=("$CURRENT_NODE")
fi

if ((${#AVAILABLE_NODES[@]} == 0)); then
  err "No Proxmox nodes found under /etc/pve/nodes."
  exit 1
fi

echo "Available Proxmox Hosts:"
for i in "${!AVAILABLE_NODES[@]}"; do
  idx=$((i+1))
  echo "  $idx) ${AVAILABLE_NODES[$i]}"
done

read -r -p "Select host to create VM on [$CURRENT_NODE]: " HOST_CHOICE
if [[ -z "$HOST_CHOICE" ]]; then
  TARGET_NODE="$CURRENT_NODE"
else
  if ! [[ "$HOST_CHOICE" =~ ^[0-9]+$ ]] || (( HOST_CHOICE < 1 || HOST_CHOICE > ${#AVAILABLE_NODES[@]} )); then
    err "Invalid host choice."
    exit 1
  fi
  TARGET_NODE="${AVAILABLE_NODES[$((HOST_CHOICE-1))]}"
fi

echo "Selected Host: $TARGET_NODE"

# Ensure script is executed on the correct node
if [[ "$TARGET_NODE" != "$CURRENT_NODE" ]]; then
  echo
  echo "ERROR: You selected host '$TARGET_NODE' but this script is running on '$CURRENT_NODE'."
  echo
  echo "Please SSH into $TARGET_NODE and run the script there:"
  echo "  ssh root@$TARGET_NODE"
  echo
  exit 1
fi

echo "Host verified: running on correct node ($TARGET_NODE)."
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

if ! is_positive_int "$CORES"; then
  err "CPU cores must be a positive integer."
  exit 1
fi
if ! is_positive_int "$MEM_GB"; then
  err "Memory (GB) must be a positive integer."
  exit 1
fi
if ! is_positive_int "$DISK_GB"; then
  err "Disk size (GB) must be a positive integer."
  exit 1
fi

# Convert memory to MB
MEMORY=$((MEM_GB * 1024))

# ------------- Storage & network -------------

echo
echo "Available storages:"
pvesm status

echo
echo "Select storage for disk & cloud-init:"
mapfile -t STORAGE_NAMES < <(pvesm status | awk 'NR>1 {print $1}')
if ((${#STORAGE_NAMES[@]} == 0)); then
  err "No storages found from 'pvesm status'."
  exit 1
fi

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
    OS_NAME="Ubuntu 22.04 (jammy)"
    ;;
  *)
    IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
    OS_NAME="Ubuntu 24.04 (noble)"
    ;;
esac

echo "Using image: $IMAGE_URL"
echo

# ------------- Auth mode & user -------------

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
AUTH_MODE_HUMAN=""

case "$AUTH_CHOICE" in
  2)
    # SSH key only
    SSH_PW_AUTH="false"
    AUTH_MODE_HUMAN="SSH key only"
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
    AUTH_MODE_HUMAN="SSH key + password"
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
    AUTH_MODE_HUMAN="Password only"
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
  if ! is_ip "$STATIC_IP"; then
    err "Invalid Static IP format."
    exit 1
  fi
  read -r -p "CIDR prefix (e.g. 24 for /24): " CIDR
  if ! is_cidr "$CIDR"; then
    err "Invalid CIDR prefix. Must be 0–32."
    exit 1
  fi
  read -r -p "Gateway IP (e.g. 10.1.10.1): " GATEWAY
  if ! is_ip "$GATEWAY"; then
    err "Invalid Gateway IP format."
    exit 1
  fi
  IPCONFIG0="ip=${STATIC_IP}/${CIDR},gw=${GATEWAY}"
  NET_DESC="Static (${STATIC_IP}/${CIDR}, gw ${GATEWAY})"
else
  IPCONFIG0="ip=dhcp"
  NET_DESC="DHCP"
fi

# ------------- Pre-flight Summary & Confirm -------------

echo
echo "=========================================="
echo " VM Creation Summary (Review Below)"
echo "------------------------------------------"
echo " Host        : $TARGET_NODE"
echo " VM ID       : $VMID"
echo " Name        : $VM_NAME"
echo " Environment : $ENV"
echo " Role        : $ROLE"
echo " Site        : $SITE"
echo " OS          : $OS_NAME"
echo " CPU cores   : $CORES"
echo " Memory      : ${MEM_GB} GB"
echo " Disk        : ${DISK_GB} GB"
echo " Storage     : $STORAGE"
echo " Bridge      : $BRIDGE"
echo " Network     : $NET_DESC"
echo " Username    : $VM_USER"
echo " Auth mode   : $AUTH_MODE_HUMAN"
echo "=========================================="
if ! yes_no_default "Proceed with VM creation?" "y"; then
  echo "Aborting by user request."
  exit 0
fi

# ------------- Download / Cache cloud image -------------

echo
echo "Preparing Ubuntu cloud image (cache: $CACHE_DIR, max age: ${CACHE_MAX_AGE_DAYS}d)..."
IMAGE_PATH="$(get_or_download_image "$IMAGE_URL" "$CACHE_DIR" "$CACHE_MAX_AGE_DAYS")"
echo "Using image file: $IMAGE_PATH"

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
qm importdisk "$VMID" "$IMAGE_PATH" "$STORAGE" --format qcow2

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
echo " Host        : $TARGET_NODE"
echo " Environment : $ENV"
echo " Role        : $ROLE"
echo " Site        : $SITE"
echo " OS          : $OS_NAME"
echo " CPU cores   : $CORES"
echo " Memory      : ${MEM_GB} GB"
echo " Disk        : ${DISK_GB} GB"
echo " Storage     : $STORAGE"
echo " Bridge      : $BRIDGE"
echo " Username    : $VM_USER"
echo " Auth mode   : $AUTH_MODE_HUMAN"
echo " Network     : $NET_DESC"
echo " Tags        : $TAGS"
echo "=========================================="
echo "You can connect after cloud-init finishes."
echo
