#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Pal Forge - NoCoDB VM Creator for Proxmox
# - Creates a Ubuntu 24.04 (Noble) cloud-init based VM
# - Prepares it for running NoCoDB installer inside the VM
# - Handles dir/LVM/ZFS storage correctly
# - Cleans up downloaded cloud image from /tmp
# ==============================================================================

UBUNTU_IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
TMP_DIR="/tmp"
LOCAL_IMG="$TMP_DIR/noble-server-cloudimg-amd64.img"

CLEANUP_FILES=()

cleanup() {
  echo "🧹 Running cleanup..."
  for f in "${CLEANUP_FILES[@]}"; do
    if [[ -f "$f" ]]; then
      echo "  - Removing $f"
      rm -f "$f" || true
    fi
  done
}
trap cleanup EXIT

echo "=============================================="
echo "  Pal Forge - NoCoDB Proxmox VM Creator"
echo "=============================================="
echo

# --- Ask for basic VM parameters ---------------------------------------------

read -rp "VM ID (e.g. 5000): " VMID
if [[ -z "${VMID}" ]]; then
  echo "VM ID is required."
  exit 1
fi

read -rp "VM Name (e.g. nocodb-vm): " VMNAME
VMNAME=${VMNAME:-nocodb-vm}

read -rp "Number of vCPUs [2]: " VCPUS
VCPUS=${VCPUS:-2}

read -rp "Memory in GB [4]: " MEM_GB
MEM_GB=${MEM_GB:-4}
# Convert to MB for Proxmox
MEM_MB=$(( MEM_GB * 1024 ))

# --- Choose storage for disk + cloud-init ------------------------------------

echo
echo "Available storages (for disk & cloud-init):"
pvesm status | awk 'NR==1 {print} NR>1 {printf "  - %-15s %-10s %s\n", $1, $2, $3}'

echo
read -rp "Storage name to use (exact from list above) [local-lvm]: " DISK_STORAGE
DISK_STORAGE=${DISK_STORAGE:-local-lvm}

# Validate storage exists
if ! pvesm status | awk 'NR>1 {print $1}' | grep -qx "$DISK_STORAGE"; then
  echo "❌ Storage '$DISK_STORAGE' not found in pvesm status. Aborting."
  exit 1
fi

read -rp "Disk size in GB [20]: " DISK_GB
DISK_GB=${DISK_GB:-20}

# --- Network settings --------------------------------------------------------

read -rp "Bridge to use [vmbr0]: " BRIDGE
BRIDGE=${BRIDGE:-vmbr0}

read -rp "VLAN tag (blank for none): " VLAN
if [[ -n "${VLAN}" ]]; then
  NET0="virtio,bridge=${BRIDGE},tag=${VLAN}"
else
  NET0="virtio,bridge=${BRIDGE}"
fi

# --- SSH key / access --------------------------------------------------------

echo
read -rp "Use an SSH public key for cloud-init? [y/N]: " USE_SSH_KEY
USE_SSH_KEY=${USE_SSH_KEY:-N}

SSH_KEY=""
if [[ "${USE_SSH_KEY}" =~ ^[Yy]$ ]]; then
  echo "Paste your SSH PUBLIC key (e.g. starts with ssh-ed25519 or ssh-rsa):"
  read -r SSH_KEY
  if [[ -z "${SSH_KEY}" ]]; then
    echo "No SSH key provided, continuing without."
  fi
fi

# Cloud-init user
read -rp "Cloud-init username [nocodb]: " CI_USER
CI_USER=${CI_USER:-nocodb}

echo
echo "--------------------------------------------------"
echo "VMID:        ${VMID}"
echo "Name:        ${VMNAME}"
echo "vCPUs:       ${VCPUS}"
echo "Memory:      ${MEM_GB} GB (${MEM_MB} MB)"
echo "Storage:     ${DISK_STORAGE}"
echo "Disk size:   ${DISK_GB} GB"
echo "Network:     bridge=${BRIDGE} ${VLAN:+, VLAN=${VLAN}}"
echo "CI user:     ${CI_USER}"
echo "SSH key:     ${USE_SSH_KEY}"
echo "--------------------------------------------------"
read -rp "Proceed with creation? [y/N]: " CONFIRM
CONFIRM=${CONFIRM:-N}
if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
  echo "Aborting."
  exit 1
fi

# --- Download Ubuntu cloud image (if needed) ---------------------------------

if [[ -f "${LOCAL_IMG}" ]]; then
  echo "✅ Found existing image at ${LOCAL_IMG}"
else
  echo "📥 Downloading Ubuntu Noble cloud image..."
  curl -fSL "${UBUNTU_IMG_URL}" -o "${LOCAL_IMG}"
  CLEANUP_FILES+=("${LOCAL_IMG}")
fi

# --- Create VM ---------------------------------------------------------------

echo "💻 Creating VM ${VMID} (${VMNAME})..."

# Remove existing VM if already present (optional – comment out if undesired)
if qm status "${VMID}" &>/dev/null; then
  echo "⚠️  VMID ${VMID} already exists. Aborting to avoid overwriting."
  exit 1
fi

qm create "${VMID}" \
  --name "${VMNAME}" \
  --memory "${MEM_MB}" \
  --cores "${VCPUS}" \
  --net0 "${NET0}" \
  --ostype l26 \
  --scsihw virtio-scsi-pci

echo "📦 Importing cloud-image disk into ${DISK_STORAGE}..."
qm importdisk "${VMID}" "${LOCAL_IMG}" "${DISK_STORAGE}" --format qcow2

# Determine storage type (dir vs lvm-thin/zfs/etc.)
STYPE=$(pvesm status | awk -v s="${DISK_STORAGE}" '$1==s {print $2}')

if [[ "${STYPE}" == "dir" ]]; then
  # Directory storage: storage:VMID/filename
  DISK_VOL="${DISK_STORAGE}:${VMID}/vm-${VMID}-disk-0.qcow2"
else
  # LVM-thin, ZFS, etc.: storage:vm-VMID-disk-0
  DISK_VOL="${DISK_STORAGE}:vm-${VMID}-disk-0"
fi

echo "💽 Using disk volume: ${DISK_VOL}"

qm set "${VMID}" \
  --scsi0 "${DISK_VOL}" \
  --serial0 socket \
  --vga serial0

# Resize disk
qm resize "${VMID}" scsi0 "${DISK_GB}G"

# --- Cloud-init configuration -----------------------------------------------

echo "⚙️  Configuring cloud-init..."

# Add cloud-init drive
qm set "${VMID}" --ide2 "${DISK_STORAGE}:cloudinit"

# Set boot order
qm set "${VMID}" --boot c --bootdisk scsi0

# Cloud-init user
qm set "${VMID}" --ciuser "${CI_USER}"

# Optionally inject SSH key
if [[ -n "${SSH_KEY}" ]]; then
  qm set "${VMID}" --sshkeys <(echo "${SSH_KEY}")
fi

# Network via DHCP
qm set "${VMID}" --ipconfig0 ip=dhcp

echo
echo "✅ VM ${VMID} (${VMNAME}) created successfully!"
echo "   - Storage: ${DISK_STORAGE}"
echo "   - Disk:    ${DISK_GB} GB"
echo "   - RAM:     ${MEM_GB} GB"
echo "   - vCPUs:   ${VCPUS}"
echo
echo "👉 Next steps:"
echo "   1. Start the VM:  qm start ${VMID}"
echo "   2. Once it boots, SSH in using the user '${CI_USER}'."
echo "   3. Inside the VM, run the NoCoDB setup script (setup_nocodb.sh)."
echo
echo "🧹 Cleanup complete (downloaded image removed from /tmp if created)."
