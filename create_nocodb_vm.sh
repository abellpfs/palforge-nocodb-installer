#!/usr/bin/env bash
set -euo pipefail

# -------- Helpers --------

error() {
  echo "Error: $*" >&2
}

# Cleanup flags
VM_CREATED=0
TMP_IMG=""

cleanup() {
  if [[ -n "${TMP_IMG:-}" && -f "$TMP_IMG" ]]; then
    echo "Cleaning up temporary image: $TMP_IMG"
    rm -f "$TMP_IMG" || true
  fi

  if [[ "$VM_CREATED" -eq 1 && -n "${VMID:-}" ]]; then
    echo "An error occurred. Destroying VM $VMID..."
    qm destroy "$VMID" --purge || true
  fi
}

trap cleanup EXIT

# -------- Pre-flight checks --------

if ! command -v qm &>/dev/null; then
  error "This script must be run on a Proxmox VE host (qm command not found)."
  exit 1
fi

if ! command -v pvesm &>/dev/null; then
  error "pvesm command not found. Are you on a Proxmox node?"
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  error "Please run as root (or with sudo)."
  exit 1
fi

# -------- Ask for basics --------

read -rp "VM name [nocodb]: " VM_NAME
VM_NAME=${VM_NAME:-nocodb}

# Suggest next free VMID between 5000–6000
DEFAULT_VMID=""
for id in {5000..6000}; do
  if ! qm status "$id" &>/dev/null; then
    DEFAULT_VMID="$id"
    break
  fi
done

if [[ -z "$DEFAULT_VMID" ]]; then
  echo "No free VMID found between 5000–6000. You'll need to choose manually."
  read -rp "VM ID: " VMID
else
  read -rp "VM ID [$DEFAULT_VMID]: " VMID
  VMID=${VMID:-$DEFAULT_VMID}
fi

if qm status "$VMID" &>/dev/null; then
  error "VM ID $VMID already exists. Choose another one."
  exit 1
fi

read -rp "CPU cores [2]: " CORES
CORES=${CORES:-2}

read -rp "Memory (in GB) [4]: " MEM_GB
MEM_GB=${MEM_GB:-4}
MEM_MB=$((MEM_GB * 1024))

read -rp "Disk size (in GB) [40]: " DISK_GB
DISK_GB=${DISK_GB:-40}

# -------- Storage selection --------

echo "Available storages:"
pvesm status

echo
read -rp "Storage for disk & cloud-init [local-lvm]: " STORAGE
STORAGE=${STORAGE:-local-lvm}

if ! pvesm status | awk 'NR>1 {print $1}' | grep -qx "$STORAGE"; then
  error "Storage '$STORAGE' not found in pvesm status."
  exit 1
fi

# -------- Network / bridge --------

read -rp "Bridge name [vmbr0]: " BRIDGE
BRIDGE=${BRIDGE:-vmbr0}

# -------- Cloud-init user & password --------

read -rp "VM username [ubuntu]: " CI_USER
CI_USER=${CI_USER:-ubuntu}

# Prompt for password (hidden)
while true; do
  read -srp "VM password: " CI_PASS
  echo
  read -srp "Confirm password: " CI_PASS_CONFIRM
  echo
  if [[ "$CI_PASS" == "$CI_PASS_CONFIRM" && -n "$CI_PASS" ]]; then
    break
  else
    echo "Passwords do not match or are empty. Try again."
  fi
done

# -------- SSH public key (optional) --------

read -rp "Use an SSH public key? (y/N): " USE_SSHKEY
USE_SSHKEY=${USE_SSHKEY:-N}

SSHKEY_FILE=""
if [[ "$USE_SSHKEY" =~ ^[Yy]$ ]]; then
  read -rp "Enter path to SSH public key file [~/.ssh/id_rsa.pub]: " SSHKEY_PATH
  SSHKEY_PATH=${SSHKEY_PATH:-~/.ssh/id_rsa.pub}
  SSHKEY_PATH=$(eval echo "$SSHKEY_PATH")
  if [[ ! -f "$SSHKEY_PATH" ]]; then
    error "SSH key file '$SSHKEY_PATH' not found."
    exit 1
  fi
  SSHKEY_FILE="$SSHKEY_PATH"
fi

# -------- IP config (cloud-init ipconfig0) --------

read -rp "Use static IP instead of DHCP? (y/N): " USE_STATIC
USE_STATIC=${USE_STATIC:-N}

if [[ "$USE_STATIC" =~ ^[Yy]$ ]]; then
  read -rp "Static IP (e.g. 10.1.10.50): " VM_IP
  read -rp "CIDR prefix (e.g. 24 for /24): " VM_CIDR
  read -rp "Gateway IP (e.g. 10.1.10.1): " VM_GW
  IP_CONFIG="ip=${VM_IP}/${VM_CIDR},gw=${VM_GW}"
else
  IP_CONFIG="ip=dhcp"
fi

# -------- Download Ubuntu cloud image --------

IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
echo "Downloading Ubuntu 24.04 (noble) cloud image..."
TMP_IMG=$(mktemp --suffix=.img)
curl -L "$IMG_URL" -o "$TMP_IMG"

# -------- Create VM --------

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

# Get the actual volume ID for this VM's imported disk
VOLID=$(pvesm list "$STORAGE" | awk -v vmid="$VMID" '$2 ~ ("vm-"vmid"-disk-0") {print $1}')

if [[ -z "$VOLID" ]]; then
  error "Could not determine imported disk volid on storage '$STORAGE'."
  exit 1
fi

echo "Attaching disk as scsi0 ($VOLID)..."
qm set "$VMID" --scsihw virtio-scsi-pci --scsi0 "$VOLID"

echo "Resizing disk to ${DISK_GB}G..."
qm resize "$VMID" scsi0 "${DISK_GB}G"

echo "Adding cloud-init drive..."
qm set "$VMID" --ide2 "${STORAGE}:cloudinit"

echo "Configuring boot & console..."
qm set "$VMID" --boot order=scsi0 --bootdisk scsi0
qm set "$VMID" --serial0 socket --vga serial0

echo "Setting cloud-init user & password..."
qm set "$VMID" --ciuser "$CI_USER" --cipassword "$CI_PASS"

if [[ -n "$SSHKEY_FILE" ]]; then
  echo "Adding SSH public key from $SSHKEY_FILE..."
  qm set "$VMID" --sshkey "$SSHKEY_FILE"
fi

echo "Configuring IP (${IP_CONFIG})..."
qm set "$VMID" --ipconfig0 "$IP_CONFIG"

echo "Final VM config:"
qm config "$VMID"

echo "Starting VM $VMID..."
qm start "$VMID"

# If we got here, everything is good – disable cleanup destroy
VM_CREATED=0
echo "VM $VMID ($VM_NAME) created and started successfully."
echo "You can now connect after cloud-init finishes."
