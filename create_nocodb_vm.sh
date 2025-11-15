#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------
# Pal Forge - NoCoDB Proxmox VM Creator
# ---------------------------------------------------

# ---------- Safety checks ----------
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (or with sudo)."
  exit 1
fi

if ! command -v qm >/dev/null 2>&1; then
  echo "Error: 'qm' command not found. This script must be run on a Proxmox host."
  exit 1
fi

if ! command -v pvesm >/dev/null 2>&1; then
  echo "Error: 'pvesm' command not found (Proxmox storage tools)."
  exit 1
fi

if ! command -v wget >/dev/null 2>&1; then
  echo "Error: 'wget' is required but not installed. Install it with: apt install wget"
  exit 1
fi

# ---------- Globals ----------
IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
TMP_IMG=""
VM_CREATED=0

cleanup() {
  local exit_code=$?

  # Remove downloaded image if present
  if [[ -n "${TMP_IMG:-}" && -f "$TMP_IMG" ]]; then
    echo "Cleaning up temporary image: $TMP_IMG"
    rm -f "$TMP_IMG" || true
  fi

  # If there was an error and VM was created, destroy it
  if [[ $exit_code -ne 0 && ${VM_CREATED:-0} -eq 1 && -n "${VMID:-}" ]]; then
    echo "An error occurred (exit code $exit_code). Destroying VM $VMID..."
    qm destroy "$VMID" --purge >/dev/null 2>&1 || true
  fi

  exit $exit_code
}
trap cleanup EXIT

# ---------- Helper: get next available VMID in range 5000–6000 ----------
get_next_vmid() {
  local start=5000
  local end=6000
  local id

  for ((id=start; id<=end; id++)); do
    if ! qm status "$id" >/dev/null 2>&1; then
      echo "$id"
      return 0
    fi
  done

  echo "Error: No free VMID found between $start and $end." >&2
  exit 1
}

# ---------- Prompt: VM basics ----------
echo "=== Pal Forge NoCoDB Proxmox VM Creator ==="
echo

DEFAULT_VMID="$(get_next_vmid)"
read -rp "VMID [$DEFAULT_VMID]: " VMID
VMID="${VMID:-$DEFAULT_VMID}"

read -rp "VM Name [nocodb]: " VM_NAME
VM_NAME="${VM_NAME:-nocodb}"

read -rp "Number of vCPUs [2]: " CORES
CORES="${CORES:-2}"

read -rp "Memory (GB) [4]: " MEM_GB
MEM_GB="${MEM_GB:-4}"
# convert GB to MB
MEM_MB=$(( MEM_GB * 1024 ))

read -rp "Disk size (GB) [40]: " DISK_GB
DISK_GB="${DISK_GB:-40}"

echo

# ---------- Storage selection ----------
echo "Available storages:"
pvesm status | awk 'NR>1 {print "  - "$1" ("$2")"}'

# Try to guess a reasonable default storage (first line after header)
DEFAULT_STORAGE="$(pvesm status | awk 'NR==2 {print $1}')"
read -rp "Storage ID for disk & cloud-init [$DEFAULT_STORAGE]: " STORAGE
STORAGE="${STORAGE:-$DEFAULT_STORAGE}"

if ! pvesm status | awk 'NR>1 {print $1}' | grep -qx "$STORAGE"; then
  echo "Error: Storage '$STORAGE' not found in pvesm status."
  exit 1
fi

# ---------- Bridge selection ----------
read -rp "Bridge to use for network [vmbr0]: " BRIDGE
BRIDGE="${BRIDGE:-vmbr0}"

# ---------- Username & password for cloud-init ----------
echo
echo "Cloud-init user configuration:"
read -rp "Username [nocodb]: " CI_USER
CI_USER="${CI_USER:-nocodb}"

# Read password twice
while true; do
  read -srp "Password for user '$CI_USER': " CI_PASS_1
  echo
  read -srp "Confirm password: " CI_PASS_2
  echo
  if [[ "$CI_PASS_1" == "$CI_PASS_2" && -n "$CI_PASS_1" ]]; then
    CI_PASS="$CI_PASS_1"
    break
  else
    echo "Passwords do not match or are empty. Please try again."
  fi
done

# ---------- Optional SSH key ----------
echo
read -rp "Use SSH public key authentication as well? (y/N): " USE_SSH
USE_SSH="${USE_SSH:-N}"

SSH_KEY_CONTENT=""
if [[ "$USE_SSH" =~ ^[Yy]$ ]]; then
  DEFAULT_KEY="$HOME/.ssh/id_rsa.pub"
  read -rp "Path to SSH public key file [$DEFAULT_KEY]: " SSH_KEY_PATH
  SSH_KEY_PATH="${SSH_KEY_PATH:-$DEFAULT_KEY}"

  if [[ ! -f "$SSH_KEY_PATH" ]]; then
    echo "Error: SSH public key file not found at '$SSH_KEY_PATH'."
    exit 1
  fi

  SSH_KEY_CONTENT="$(<"$SSH_KEY_PATH")"
fi

# ---------- IP configuration ----------
echo
echo "IP Configuration:"
echo "  [1] DHCP (recommended)"
echo "  [2] Static IP"
read -rp "Choose IP mode [1]: " IP_MODE
IP_MODE="${IP_MODE:-1}"

CLOUDINIT_IP=""
CI_DNS=""

if [[ "$IP_MODE" == "1" ]]; then
  CLOUDINIT_IP="ip=dhcp"
else
  echo "You selected Static IP."

  read -rp "Static IPv4 address (example: 192.168.1.50): " STATIC_IP
  read -rp "Netmask/CIDR (example: 24): " STATIC_CIDR
  read -rp "Gateway (example: 192.168.1.1): " STATIC_GW
  read -rp "DNS server (example: 1.1.1.1 or 8.8.8.8): " STATIC_DNS

  if [[ -z "$STATIC_IP" || -z "$STATIC_CIDR" || -z "$STATIC_GW" ]]; then
    echo "Error: Static IP, CIDR, and Gateway are required for static configuration."
    exit 1
  fi

  CLOUDINIT_IP="ip=${STATIC_IP}/${STATIC_CIDR},gw=${STATIC_GW}"
  CI_DNS="$STATIC_DNS"
fi

echo
echo "Summary:"
echo "  VMID:        $VMID"
echo "  Name:        $VM_NAME"
echo "  vCPUs:       $CORES"
echo "  Memory:      ${MEM_GB}G"
echo "  Disk:        ${DISK_GB}G"
echo "  Storage:     $STORAGE"
echo "  Bridge:      $BRIDGE"
echo "  User:        $CI_USER"
echo "  IP Mode:     $([[ $IP_MODE == "1" ]] && echo "DHCP" || echo "Static ($STATIC_IP/$STATIC_CIDR, gw=$STATIC_GW)")"
echo

read -rp "Proceed with creating the VM? (y/N): " CONFIRM
CONFIRM="${CONFIRM:-N}"
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# ---------- Download cloud image ----------
TMP_IMG="$(mktemp --suffix=.img)"
echo "Downloading Ubuntu Noble cloud image..."
wget -qO "$TMP_IMG" "$IMG_URL"
echo "Downloaded image to: $TMP_IMG"

# ---------- Create VM ----------
echo "Creating VM $VMID ($VM_NAME)..."
qm create "$VMID" \
  --name "$VM_NAME" \
  --memory "$MEM_MB" \
  --cores "$CORES" \
  --net0 "virtio,bridge=${BRIDGE}" \
  --agent enabled=1 \
  --ostype l26

VM_CREATED=1

echo "Importing disk to storage '$STORAGE'..."
qm importdisk "$VMID" "$TMP_IMG" "$STORAGE" --format qcow2

# Attach imported disk as scsi0
echo "Attaching disk as scsi0..."
qm set "$VMID" --scsihw virtio-scsi-pci --scsi0 "${STORAGE}:vm-${VMID}-disk-0"

# Resize disk
echo "Resizing disk to ${DISK_GB}G..."
qm resize "$VMID" scsi0 "${DISK_GB}G"

# Add EFI & cloud-init drive
echo "Configuring EFI & cloud-init..."
qm set "$VMID" --bios ovmf --machine q35
qm set "$VMID" --efidisk0 "${STORAGE}:1,format=qcow2,efitype=4m,pre-enrolled-keys=1"
qm set "$VMID" --ide2 "${STORAGE}:cloudinit"

# Boot configuration
qm set "$VMID" --boot order=scsi0
qm set "$VMID" --serial0 socket --vga serial0

# Cloud-init user + password
echo "Configuring cloud-init user..."
qm set "$VMID" --ciuser "$CI_USER" --cipassword "$CI_PASS"

# SSH key if provided
if [[ -n "$SSH_KEY_CONTENT" ]]; then
  echo "Adding SSH public key to cloud-init..."
  qm set "$VMID" --sshkey <(printf '%s\n' "$SSH_KEY_CONTENT")
fi

# IP config
echo "Applying IP configuration..."
qm set "$VMID" --ipconfig0 "$CLOUDINIT_IP"
if [[ "$IP_MODE" == "2" && -n "$CI_DNS" ]]; then
  qm set "$VMID" --nameserver "$CI_DNS"
fi

# ---------- Start VM ----------
echo "Starting VM $VMID..."
qm start "$VMID"

echo
echo "===================================================="
echo " VM $VMID ($VM_NAME) created and started."
echo " - Storage:   $STORAGE"
echo " - Bridge:    $BRIDGE"
echo " - User:      $CI_USER"
echo " - IP Mode:   $([[ $IP_MODE == "1" ]] && echo "DHCP" || echo "Static")"
echo " You can check console via Proxmox Web UI or:"
echo "   qm terminal $VMID"
echo "===================================================="

# On success: just clean up the image (trap will still run, but VM won't be destroyed)
VM_CREATED=0
