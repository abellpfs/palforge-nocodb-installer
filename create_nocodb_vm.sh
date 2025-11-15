#!/usr/bin/env bash
set -euo pipefail

# Simple Proxmox VM creator for NocoDB
# Creates an Ubuntu 24.04 (noble) cloud-init VM, then you run setup_nocodb.sh inside it.

UBUNTU_IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"

#######################################
# Helpers
#######################################
error() {
  echo "ERROR: $*" >&2
  exit 1
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    error "This script must be run as root on the Proxmox host."
  fi
}

require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || error "Required command '$c' not found."
  done
}

cleanup() {
  if [[ -n "${WORKDIR:-}" && -d "${WORKDIR:-}" ]]; then
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT

#######################################
# Input helpers
#######################################
ask_default() {
  local prompt="$1"; shift
  local default="$1"; shift || true
  local var
  read -rp "$prompt [$default]: " var
  echo "${var:-$default}"
}

ask_required_int() {
  local prompt="$1"
  local val
  while true; do
    read -rp "$prompt: " val
    if [[ "$val" =~ ^[0-9]+$ ]] && (( val > 0 )); then
      echo "$val"
      return 0
    else
      echo "Please enter a positive integer."
    fi
  done
}

#######################################
# Main
#######################################
require_root
require_cmd pvesh pvesm qm curl

echo "=== NocoDB Proxmox VM Creator ==="

# VMID
default_vmid=$(pvesh get /cluster/nextid)
VMID=$(ask_default "VM ID" "$default_vmid")

# Hostname / name
VM_NAME=$(ask_default "VM name (hostname)" "nocodb")

# CPU & RAM
CPU_CORES=$(ask_required_int "vCPU cores")
RAM_GB=$(ask_required_int "Memory (GB)")
RAM_MB=$((RAM_GB * 1024))

# Disk size
DISK_GB=$(ask_required_int "Disk size (GB) for main disk")

# Network bridge
BRIDGE=$(ask_default "Bridge" "vmbr0")

# Storage selection (for disks & cloud-init)
echo
echo "Available storage (content: images):"
pvesm status -content images | awk 'NR==1 || NR>1 {print}'
echo

# Build storage menu
mapfile -t STORAGE_LINES < <(pvesm status -content images | awk 'NR>1')
if [[ ${#STORAGE_LINES[@]} -eq 0 ]]; then
  error "No storage with 'images' content found. Configure storage in Proxmox first."
fi

echo "Select storage for disks & cloud-init:"
idx=1
for line in "${STORAGE_LINES[@]}"; do
  # Example line: local-lvm data 1 1 1 ...
  tag=$(awk '{print $1}' <<< "$line")
  type=$(awk '{print $2}' <<< "$line")
  free_kb=$(awk '{print $6}' <<< "$line")
  # Convert to GiB-ish
  free_gb=$(( free_kb / 1024 / 1024 ))
  printf "  [%d] %s (type: %s, approx free: %d GiB)\n" "$idx" "$tag" "$type" "$free_gb"
  ((idx++))
done

while true; do
  read -rp "Enter storage option number [1-${#STORAGE_LINES[@]}]: " choice
  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#STORAGE_LINES[@]} )); then
    STORAGE_TAG=$(awk '{print $1}' <<< "${STORAGE_LINES[choice-1]}")
    STORAGE_TYPE=$(awk '{print $2}' <<< "${STORAGE_LINES[choice-1]}")
    break
  else
    echo "Invalid choice. Try again."
  fi
done

echo "Using storage: $STORAGE_TAG (type: $STORAGE_TYPE)"

# SSH key
echo
read -rp "Do you want to add an SSH public key to cloud-init? [y/N]: " use_ssh
use_ssh=${use_ssh,,}
SSH_KEY=""
if [[ "$use_ssh" == "y" || "$use_ssh" == "yes" ]]; then
  echo "Paste your SSH public key (single line), then press Enter:"
  read -r SSH_KEY
  [[ -z "$SSH_KEY" ]] && error "SSH key was empty."
fi

WORKDIR=$(mktemp -d)
cd "$WORKDIR"

echo
echo "Downloading Ubuntu cloud image..."
IMG_FILE=$(basename "$UBUNTU_IMG_URL")
curl -fSL -o "$IMG_FILE" "$UBUNTU_IMG_URL" || error "Failed to download $UBUNTU_IMG_URL"

echo "Downloaded image: $IMG_FILE"

# Figure out disk extension / refs like tteck script
DISK_EXT=""
DISK_REF=""
DISK_IMPORT_OPT=""
THIN_OPT=",discard=on,ssd=1"

case "$STORAGE_TYPE" in
  nfs|dir|cifs)
    DISK_EXT=".qcow2"
    DISK_REF="$VMID/"
    DISK_IMPORT_OPT="-format qcow2"
    THIN_OPT=""  # thin provisioning handled by qcow2
    ;;
  btrfs)
    DISK_EXT=".raw"
    DISK_REF="$VMID/"
    DISK_IMPORT_OPT="-format raw"
    THIN_OPT=""  # btrfs thin
    ;;
  *)
    # For lvm-thin, zfs, etc, Proxmox handles LV/ZVOL naming; no extension or dir ref
    DISK_EXT=""
    DISK_REF=""
    DISK_IMPORT_OPT=""
    ;;
esac

# Build disk names & refs
DISK0="vm-${VMID}-disk-0${DISK_EXT}"
DISK1="vm-${VMID}-disk-1${DISK_EXT}"
if [[ -n "$DISK_REF" ]]; then
  DISK0_REF="${STORAGE_TAG}:${DISK_REF}${DISK0}"
  DISK1_REF="${STORAGE_TAG}:${DISK_REF}${DISK1}"
else
  DISK0_REF="${STORAGE_TAG}:${DISK0}"
  DISK1_REF="${STORAGE_TAG}:${DISK1}"
fi

echo
echo "Creating VM $VMID ($VM_NAME)..."

# Create base VM
qm create "$VMID" \
  -name "$VM_NAME" \
  -memory "$RAM_MB" \
  -cores "$CPU_CORES" \
  -net0 "virtio,bridge=$BRIDGE" \
  -agent 1 \
  -ostype l26 \
  -serial0 socket \
  -scsihw virtio-scsi-pci \
  -onboot 1

# Allocate EFI disk (4M is plenty)
echo "Allocating EFI disk..."
pvesm alloc "$STORAGE_TAG" "$VMID" "$DISK0" 4M >/dev/null

# Import cloud image as data disk
echo "Importing cloud image to storage..."
qm importdisk "$VMID" "$IMG_FILE" "$STORAGE_TAG" $DISK_IMPORT_OPT >/dev/null

# Attach disks & cloud-init
echo "Attaching disks & cloud-init..."
qm set "$VMID" \
  -efidisk0 "${DISK0_REF},efitype=4m" \
  -scsi0    "${DISK1_REF}${THIN_OPT},size=${DISK_GB}G" \
  -ide2     "${STORAGE_TAG}:cloudinit" \
  -boot     "order=scsi0" >/dev/null

# Cloud-init base config
qm set "$VMID" \
  -ciuser ubuntu \
  -cipassword 'ubuntu' >/dev/null

if [[ -n "$SSH_KEY" ]]; then
  echo "Adding SSH key to cloud-init..."
  tmp_ssh=$(mktemp)
  echo "$SSH_KEY" > "$tmp_ssh"
  qm set "$VMID" --sshkey "$tmp_ssh" >/dev/null
  rm -f "$tmp_ssh"
fi

echo
echo "VM $VMID ($VM_NAME) created successfully."

read -rp "Start the VM now? [Y/n]: " start_vm
start_vm=${start_vm,,}
if [[ -z "$start_vm" || "$start_vm" == "y" || "$start_vm" == "yes" ]]; then
  echo "Starting VM..."
  qm start "$VMID"
  echo "VM started."
else
  echo "VM created but not started."
fi

echo
echo "Done. Once the VM is up, SSH in and run your setup script (setup_nocodb.sh)."
