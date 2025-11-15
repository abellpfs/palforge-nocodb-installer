#!/usr/bin/env bash
# Pal Forge - NocoDB VM creator for Proxmox
# Creates a cloud-init Ubuntu 24.04 (Noble) VM ready for NocoDB install.

set -euo pipefail

### ===== Helpers & traps =====

TEMP_DIR="$(mktemp -d)"
VM_CREATED=0
VMID=""

cleanup() {
  # Remove temp dir
  if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi

  # Destroy partially created VM if script failed
  if [[ "$VM_CREATED" -eq 1 && -n "${VMID:-}" ]]; then
    echo "Cleaning up partially created VM $VMID..."
    qm stop "$VMID" >/dev/null 2>&1 || true
    qm destroy "$VMID" >/dev/null 2>&1 || true
  fi
}

trap 'echo "Error on line $LINENO"; cleanup' ERR
trap 'cleanup' EXIT

### ===== Pre-checks =====

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Please run this script as root on the Proxmox host."
  exit 1
fi

if ! command -v qm >/dev/null 2>&1; then
  echo "This script must be run on a Proxmox VE node (qm command not found)."
  exit 1
fi

if ! command -v pvesm >/dev/null 2>&1; then
  echo "pvesm command not found. This must be run on Proxmox."
  exit 1
fi

### ===== Ask questions =====

echo "=== Pal Forge NocoDB VM Creator ==="

# VM ID
read -rp "Enter VM ID (leave blank to auto-select next free ID): " VMID_INPUT
if [[ -z "$VMID_INPUT" ]]; then
  VMID="$(pvesh get /cluster/nextid)"
else
  VMID="$VMID_INPUT"
fi
echo "Using VM ID: $VMID"

# VM name / hostname
read -rp "Enter VM name (hostname) [nocodb]: " VM_NAME
VM_NAME="${VM_NAME:-nocodb}"

# vCPUs
read -rp "Number of vCPU cores [2]: " CORE_COUNT
CORE_COUNT="${CORE_COUNT:-2}"

# Memory in GB
read -rp "Memory (in GB) [4]: " MEM_GB
MEM_GB="${MEM_GB:-4}"
# Convert to MiB for Proxmox
if ! [[ "$MEM_GB" =~ ^[0-9]+$ ]]; then
  echo "Memory must be an integer in GB."
  exit 1
fi
MEM_MB=$((MEM_GB * 1024))

# Disk size in GB
read -rp "Disk size (in GB) [40]: " DISK_GB
DISK_GB="${DISK_GB:-40}"
if ! [[ "$DISK_GB" =~ ^[0-9]+$ ]]; then
  echo "Disk size must be an integer in GB."
  exit 1
fi
DISK_SIZE="${DISK_GB}G"

# Bridge
read -rp "Bridge to use [vmbr0]: " BRIDGE
BRIDGE="${BRIDGE:-vmbr0}"

# Storage selection (images-capable storage only)
echo "Detecting storage pools that support 'images'..."
STORAGE_LINES="$(pvesm status -content images | awk 'NR>1')"
if [[ -z "$STORAGE_LINES" ]]; then
  echo "No storage with 'images' content found. Configure storage in Proxmox first."
  exit 1
fi

echo
echo "Available storage pools (for disks & cloud-init):"
i=1
STORAGE_TAGS=()
while read -r line; do
  TAG=$(echo "$line" | awk '{print $1}')
  TYPE=$(echo "$line" | awk '{print $2}')
  FREE=$(echo "$line" | awk '{print $4}')
  echo "  [$i] $TAG (type: $TYPE, free: ${FREE}K)"
  STORAGE_TAGS+=("$TAG")
  i=$((i+1))
done <<< "$STORAGE_LINES"

read -rp "Select storage number [1]: " STORAGE_INDEX
STORAGE_INDEX="${STORAGE_INDEX:-1}"

if ! [[ "$STORAGE_INDEX" =~ ^[0-9]+$ ]]; then
  echo "Invalid storage selection."
  exit 1
fi

if (( STORAGE_INDEX < 1 || STORAGE_INDEX > ${#STORAGE_TAGS[@]} )); then
  echo "Storage index out of range."
  exit 1
fi

STORAGE="${STORAGE_TAGS[$((STORAGE_INDEX-1))]}"
echo "Using storage: $STORAGE"

# Ask about SSH key usage
USE_SSH_KEY="n"
read -rp "Do you want to inject an SSH public key for cloud-init? (y/N): " USE_SSH_KEY
USE_SSH_KEY="${USE_SSH_KEY:-n}"

SSH_PUB_KEY=""
if [[ "$USE_SSH_KEY" =~ ^[Yy]$ ]]; then
  echo "Choose how to provide the SSH public key:"
  echo "  [1] Path to an existing public key file (e.g. ~/.ssh/id_rsa.pub)"
  echo "  [2] Paste the key manually"
  read -rp "Choice [1]: " KEY_CHOICE
  KEY_CHOICE="${KEY_CHOICE:-1}"

  if [[ "$KEY_CHOICE" == "1" ]]; then
    read -rp "Enter path to SSH public key file [~/.ssh/id_rsa.pub]: " KEY_PATH
    KEY_PATH="${KEY_PATH:-$HOME/.ssh/id_rsa.pub}"
    if [[ ! -f "$KEY_PATH" ]]; then
      echo "File '$KEY_PATH' not found."
      exit 1
    fi
    SSH_PUB_KEY="$(sed -e 's/[[:space:]]*$//' "$KEY_PATH")"
  else
    echo "Paste your SSH public key (single line), then press Enter:"
    read -r SSH_PUB_KEY
  fi

  if [[ -z "$SSH_PUB_KEY" ]]; then
    echo "No SSH key provided; continuing without SSH key."
  fi
fi

### ===== Download cloud image =====

pushd "$TEMP_DIR" >/dev/null

IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
IMG_FILE="$(basename "$IMG_URL")"

echo "Downloading Ubuntu 24.04 cloud image..."
curl -fSL -o "$IMG_FILE" "$IMG_URL"

### ===== Determine storage type & disk naming =====

STORAGE_TYPE=$(pvesm status -storage "$STORAGE" | awk 'NR>1 {print $2}')
THIN="discard=on,ssd=1,"      # mimic tteck's THIN usage for non-dir/nfs/cifs
DISK_EXT=""
DISK_REF=""
DISK_IMPORT=""
EFI_FORMAT=",efitype=4m"

case "$STORAGE_TYPE" in
  nfs|dir|cifs)
    # directory-like storage
    DISK_EXT=".qcow2"
    DISK_REF="$VMID/"
    DISK_IMPORT="-format qcow2"
    THIN=""                 # THIN not used on dir-like storage
    ;;
  btrfs)
    DISK_EXT=".raw"
    DISK_REF="$VMID/"
    DISK_IMPORT="-format raw"
    EFI_FORMAT=",efitype=4m"
    THIN=""
    ;;
  *)
    # LVM / ZFS / etc - keep default THIN
    DISK_EXT=""
    DISK_REF=""
    DISK_IMPORT=""
    ;;
esac

# Build disk names similar to tteck:
DISK0="vm-${VMID}-disk-0${DISK_EXT}"
DISK1="vm-${VMID}-disk-1${DISK_EXT}"
DISK0_REF="${STORAGE}:${DISK_REF}${DISK0}"
DISK1_REF="${STORAGE}:${DISK_REF}${DISK1}"

### ===== Create VM and attach disks =====

echo "Creating VM $VMID ($VM_NAME)..."
qm create "$VMID" \
  -name "$VM_NAME" \
  -agent 1 \
  -localtime 1 \
  -bios ovmf \
  -cores "$CORE_COUNT" \
  -memory "$MEM_MB" \
  -net0 virtio,bridge="$BRIDGE" \
  -onboot 1 \
  -ostype l26 \
  -scsihw virtio-scsi-pci

VM_CREATED=1

echo "Allocating EFI disk..."
pvesm alloc "$STORAGE" "$VMID" "$DISK0" 4M >/dev/null

echo "Importing cloud image to storage..."
qm importdisk "$VMID" "$IMG_FILE" "$STORAGE" ${DISK_IMPORT:-} >/dev/null

echo "Attaching disks & cloud-init..."
qm set "$VMID" \
  -efidisk0 "${DISK0_REF}${EFI_FORMAT}" \
  -scsi0 "${DISK1_REF},${THIN}size=${DISK_SIZE}" \
  -ide2 "${STORAGE}:cloudinit" \
  -boot order=scsi0 \
  -serial0 socket >/dev/null

### ===== Cloud-init configuration =====

echo "Configuring cloud-init for $VM_NAME..."

qm set "$VMID" \
  -ciuser nocodb \
  -cipassword "ChangeMeNow123!" >/dev/null

if [[ -n "$SSH_PUB_KEY" ]]; then
  qm set "$VMID" --sshkey <(printf '%s\n' "$SSH_PUB_KEY") >/dev/null
fi

# (Optional) set dns and ip to DHCP (cloud-init defaults usually DHCP)
qm set "$VMID" -ipconfig0 ip=dhcp >/dev/null

### ===== Start VM =====

echo "Starting VM $VMID..."
qm start "$VMID" >/dev/null

# If we reach here successfully, do not destroy VM on normal exit.
VM_CREATED=0

popd >/dev/null

echo
echo "======================================="
echo " NocoDB VM created successfully!"
echo " VM ID:     $VMID"
echo " Name:      $VM_NAME"
echo " vCPUs:     $CORE_COUNT"
echo " Memory:    ${MEM_GB}G (${MEM_MB} MiB)"
echo " Disk:      ${DISK_GB}G on storage $STORAGE"
echo " Bridge:    $BRIDGE"
if [[ -n "$SSH_PUB_KEY" ]]; then
  echo " SSH user:  nocodb"
  echo " SSH key:   injected via cloud-init"
else
  echo " SSH user:  nocodb"
  echo " Password:  ChangeMeNow123!"
fi
echo "---------------------------------------"
echo "Next steps:"
echo " - Get the VM IP from Proxmox (e.g., qm guest cmd $VMID network-get-interfaces)"
echo " - SSH in as 'nocodb' and run setup_nocodb.sh inside the VM."
echo "======================================="
