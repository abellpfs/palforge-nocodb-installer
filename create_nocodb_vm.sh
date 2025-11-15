#!/usr/bin/env bash
set -euo pipefail

### ===========================================================================
###  Pal Forge – NocoDB Proxmox VM Creator
###  Creates a VM using Ubuntu 24.04 AMD64 cloud image + cloud-init
### ===========================================================================

if [[ $EUID -ne 0 ]]; then
  echo "⚠️  Run this script as root: sudo -i"
  exit 1
fi

# Check dependencies
for cmd in qm pvesm wget; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "❌ Missing required command: $cmd"
    exit 1
  fi
done

echo "=== Pal Forge – NocoDB VM Creator ==="
echo

### ---------------------------------------------------------------------------
### USER INPUT
### ---------------------------------------------------------------------------

DEFAULT_NODE="$(hostname)"
read -rp "Proxmox node name [${DEFAULT_NODE}]: " NODE
NODE="${NODE:-$DEFAULT_NODE}"

read -rp "VM ID [9001]: " VMID
VMID="${VMID:-9001}"

read -rp "VM Name [nocodb-vm]: " VMNAME
VMNAME="${VMNAME:-nocodb-vm}"

read -rp "Number of vCPUs [2]: " VCPUS
VCPUS="${VCPUS:-2}"

read -rp "RAM in GB [4]: " RAM_GB
RAM_GB="${RAM_GB:-4}"
RAM_MB=$(( RAM_GB * 1024 ))

read -rp "Disk size in GB [40]: " DISK_GB
DISK_GB="${DISK_GB:-40}"

### Storage selection
echo
echo "Detecting Proxmox storage pools..."
mapfile -t STORAGES < <(pvesm status -content images | awk 'NR>1 {print $1}')

if [[ ${#STORAGES[@]} -eq 0 ]]; then
  echo "❌ No storage pools with content=images found."
  exit 1
fi

echo "Available storage pools:"
for i in "${!STORAGES[@]}"; do
  echo "  $((i+1))) ${STORAGES[$i]}"
done

read -rp "Select storage for main disk [1]: " DISK_IDX
DISK_IDX="${DISK_IDX:-1}"
DISK_STORAGE="${STORAGES[$((DISK_IDX-1))]}"

read -rp "Use same storage for cloud-init disk? [Y/n]: " SAME
if [[ "$SAME" =~ ^[Nn]$ ]]; then
  read -rp "Select storage for cloud-init disk [1]: " CI_IDX
  CI_IDX="${CI_IDX:-1}"
  CI_STORAGE="${STORAGES[$((CI_IDX-1))]}"
else
  CI_STORAGE="$DISK_STORAGE"
fi

### SSH Key
echo
read -rp "Inject SSH public key? [y/N]: " USEKEY

USE_SSH_KEY="no"
SSH_KEY_FILE=""
if [[ "$USEKEY" =~ ^[Yy]$ ]]; then
  USE_SSH_KEY="yes"
  DEFAULT_KEY="$HOME/.ssh/id_rsa.pub"
  read -rp "Path to SSH public key [$DEFAULT_KEY]: " SSH_KEY_FILE
  SSH_KEY_FILE="${SSH_KEY_FILE:-$DEFAULT_KEY}"
  SSH_KEY_FILE="${SSH_KEY_FILE/#\~/$HOME}"

  if [[ ! -f "$SSH_KEY_FILE" ]]; then
    echo "❌ SSH key file not found."
    exit 1
  fi
fi

### ---------------------------------------------------------------------------
### CONFIRM
### ---------------------------------------------------------------------------

echo
echo "=== Summary ==="
echo "VM ID:                $VMID"
echo "Name:                 $VMNAME"
echo "vCPUs:                $VCPUS"
echo "RAM:                  ${RAM_GB}GB"
echo "Disk Size:            ${DISK_GB}GB"
echo "Main Disk Storage:    $DISK_STORAGE"
echo "Cloud-Init Storage:   $CI_STORAGE"
echo "SSH Key Injection:    $USE_SSH_KEY"
echo

read -rp "Proceed? [y/N]: " GO
if ! [[ "$GO" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

### ---------------------------------------------------------------------------
### DOWNLOAD CLOUD IMAGE (AMD64)
### ---------------------------------------------------------------------------

IMG_DIR="/var/lib/vz/template/iso"
mkdir -p "$IMG_DIR"

AMD64_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
LOCAL_IMG="$IMG_DIR/ubuntu-24.04-amd64.img"

echo "Downloading Ubuntu 24.04 AMD64 cloud image..."
wget -O "$LOCAL_IMG" "$AMD64_URL"

### ---------------------------------------------------------------------------
### CREATE VM
### ---------------------------------------------------------------------------

echo "Creating VM $VMID..."

if qm status "$VMID" &>/dev/null; then
  echo "❌ VM ID $VMID already exists."
  exit 1
fi

qm create "$VMID" \
  --name "$VMNAME" \
  --memory "$RAM_MB" \
  --cores "$VCPUS" \
  --net0 "virtio,bridge=vmbr0" \
  --agent 1 \
  --ostype l26 \
  --scsihw virtio-scsi-pci \
  --bios ovmf \
  --boot order=scsi0

echo "Importing cloud-image disk..."
qm importdisk "$VMID" "$LOCAL_IMG" "$DISK_STORAGE" --format qcow2

qm set "$VMID" \
  --scsi0 "${DISK_STORAGE}:vm-${VMID}-disk-0" \
  --serial0 socket \
  --vga serial0

echo "Adding cloud-init drive..."
qm set "$VMID" \
  --ide2 "${CI_STORAGE}:cloudinit" \
  --ciuser nocodb \
  --cipassword nocodb

if [[ "$USE_SSH_KEY" == "yes" ]]; then
  qm set "$VMID" --sshkey "$SSH_KEY_FILE"
fi

echo "=== VM CREATED SUCCESSFULLY ==="
echo
echo "Start the VM:"
echo "  qm start $VMID"
echo
echo "Then SSH into it and run:"
echo "  bash <(curl -sSL https://raw.githubusercontent.com/abellpfs/palforge-nocodb-installer/main/setup_nocodb.sh)"
echo
