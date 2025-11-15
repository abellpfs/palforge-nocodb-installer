#!/usr/bin/env bash
set -euo pipefail

IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"

echo "=== Pal Forge NocoDB VM Creator ==="

# --- Helper functions --------------------------------------------------------

cleanup() {
  if [[ -n "${TEMP_IMG:-}" && -f "${TEMP_IMG}" ]]; then
    echo "Cleaning up temporary image: ${TEMP_IMG}"
    rm -f "${TEMP_IMG}" || true
  fi

  if [[ -n "${TEMP_SSH_KEY_FILE:-}" && -f "${TEMP_SSH_KEY_FILE}" ]]; then
    echo "Cleaning up temporary SSH key file: ${TEMP_SSH_KEY_FILE}"
    rm -f "${TEMP_SSH_KEY_FILE}" || true
  fi
}

destroy_vm_on_error() {
  local exit_code=$?
  echo "An error occurred (exit code ${exit_code})."

  if [[ -n "${VMID:-}" ]]; then
    if qm status "${VMID}" &>/dev/null; then
      echo "Destroying VM ${VMID}..."
      qm destroy "${VMID}" --purge >/dev/null 2>&1 || true
      echo "VM ${VMID} destroyed."
    fi
  fi

  cleanup
  exit "${exit_code}"
}

trap destroy_vm_on_error ERR

require_cmd() {
  if ! command -v "$1" &>/dev/null; then
    echo "Error: required command '$1' is not installed or not in PATH."
    exit 1
  fi
}

# --- Sanity checks -----------------------------------------------------------

require_cmd qm
require_cmd pvesm
require_cmd curl

# --- Choose VM ID ------------------------------------------------------------

echo
echo "Finding first available VMID between 5000 and 6000..."
DEFAULT_VMID=""
for id in $(seq 5000 6000); do
  if ! qm status "$id" &>/dev/null; then
    DEFAULT_VMID="$id"
    break
  fi
done

if [[ -z "${DEFAULT_VMID}" ]]; then
  echo "Error: No free VMID found between 5000 and 6000."
  exit 1
fi

read -rp "Enter VM ID [${DEFAULT_VMID}]: " VMID
VMID="${VMID:-$DEFAULT_VMID}"

if qm status "${VMID}" &>/dev/null; then
  echo "Error: VMID ${VMID} already exists."
  exit 1
fi

# --- Basic VM details --------------------------------------------------------

read -rp "Enter VM name [nocodb]: " VM_NAME
VM_NAME="${VM_NAME:-nocodb}"

read -rp "vCPUs [2]: " CORES
CORES="${CORES:-2}"

read -rp "Memory in GB [4]: " MEM_GB
MEM_GB="${MEM_GB:-4}"
if ! [[ "${MEM_GB}" =~ ^[0-9]+$ ]]; then
  echo "Error: Memory must be an integer number of GB."
  exit 1
fi
MEM_MB=$((MEM_GB * 1024))

read -rp "Disk size in GB [40]: " DISK_GB
DISK_GB="${DISK_GB:-40}"
if ! [[ "${DISK_GB}" =~ ^[0-9]+$ ]]; then
  echo "Error: Disk size must be an integer number of GB."
  exit 1
fi

# --- Storage selection -------------------------------------------------------

echo
echo "Available storages (for VM disk):"
mapfile -t STORAGES < <(pvesm status -content images | awk 'NR>1 {print $1}')
if [[ ${#STORAGES[@]} -eq 0 ]]; then
  echo "Error: No storage with 'images' content found."
  exit 1
fi

for i in "${!STORAGES[@]}"; do
  idx=$((i + 1))
  printf "  %d) %s\n" "$idx" "${STORAGES[$i]}"
done

read -rp "Select storage for VM disk [1]: " DISK_STORAGE_IDX
DISK_STORAGE_IDX="${DISK_STORAGE_IDX:-1}"
if ! [[ "${DISK_STORAGE_IDX}" =~ ^[0-9]+$ ]] || (( DISK_STORAGE_IDX < 1 || DISK_STORAGE_IDX > ${#STORAGES[@]} )); then
  echo "Error: Invalid selection."
  exit 1
fi
DISK_STORAGE="${STORAGES[$((DISK_STORAGE_IDX - 1))]}"

echo
echo "Available storages (for cloud-init):"
mapfile -t CI_STORAGES < <(pvesm status -content images | awk 'NR>1 {print $1}')
if [[ ${#CI_STORAGES[@]} -eq 0 ]]; then
  echo "Error: No storage with 'images' content found for cloud-init."
  exit 1
fi

for i in "${!CI_STORAGES[@]}"; do
  idx=$((i + 1))
  printf "  %d) %s\n" "$idx" "${CI_STORAGES[$i]}"
done

read -rp "Select storage for cloud-init disk [1]: " CI_STORAGE_IDX
CI_STORAGE_IDX="${CI_STORAGE_IDX:-1}"
if ! [[ "${CI_STORAGE_IDX}" =~ ^[0-9]+$ ]] || (( CI_STORAGE_IDX < 1 || CI_STORAGE_IDX > ${#CI_STORAGES[@]} )); then
  echo "Error: Invalid selection."
  exit 1
fi
CI_STORAGE="${CI_STORAGES[$((CI_STORAGE_IDX - 1))]}"

# --- Network configuration ---------------------------------------------------

echo
echo "Network configuration:"
read -rp "Use DHCP for IP? [Y/n]: " USE_DHCP
USE_DHCP="${USE_DHCP:-Y}"

IPCONFIG0=""
if [[ "${USE_DHCP}" =~ ^[Yy]$ ]]; then
  IPCONFIG0="ip=dhcp"
else
  echo "Static IP configuration:"
  read -rp "IP (with CIDR), e.g. 10.0.0.50/24: " STATIC_IP
  read -rp "Gateway IP, e.g. 10.0.0.1: " GATEWAY_IP

  if [[ -z "${STATIC_IP}" || -z "${GATEWAY_IP}" ]]; then
    echo "Error: Static IP and gateway must both be provided."
    exit 1
  fi
  IPCONFIG0="ip=${STATIC_IP},gw=${GATEWAY_IP}"
fi

# --- SSH / cloud-init user configuration ------------------------------------

echo
read -rp "VM username [nocodbadmin]: " CI_USER
CI_USER="${CI_USER:-nocodbadmin}"

while true; do
  read -srp "Password for user '${CI_USER}': " CI_PASS
  echo
  read -srp "Confirm password: " CI_PASS_CONFIRM
  echo
  if [[ "${CI_PASS}" == "${CI_PASS_CONFIRM}" ]]; then
    break
  else
    echo "Passwords do not match. Please try again."
  fi
done

echo
read -rp "Provide SSH public key for '${CI_USER}'? [y/N]: " USE_SSH_KEY
USE_SSH_KEY="${USE_SSH_KEY:-N}"

TEMP_SSH_KEY_FILE=""
if [[ "${USE_SSH_KEY}" =~ ^[Yy]$ ]]; then
  read -rp "Enter path to SSH public key file (leave blank to paste key): " SSH_KEY_PATH
  if [[ -n "${SSH_KEY_PATH}" && -f "${SSH_KEY_PATH}" ]]; then
    TEMP_SSH_KEY_FILE="${SSH_KEY_PATH}"
  else
    echo "Paste SSH public key (single line, then press Enter):"
    read -r SSH_KEY_LINE
    if [[ -n "${SSH_KEY_LINE}" ]]; then
      TEMP_SSH_KEY_FILE="$(mktemp)"
      echo "${SSH_KEY_LINE}" > "${TEMP_SSH_KEY_FILE}"
    fi
  fi
fi

# --- Download cloud image ----------------------------------------------------

echo
TEMP_IMG="$(mktemp --suffix=.img)"
echo "Downloading Ubuntu Noble cloud image to ${TEMP_IMG}..."
curl -L "${IMG_URL}" -o "${TEMP_IMG}"

# --- Create VM ---------------------------------------------------------------

echo
echo "Creating VM ${VMID} (${VM_NAME})..."
qm create "${VMID}" \
  --name "${VM_NAME}" \
  --memory "${MEM_MB}" \
  --cores "${CORES}" \
  --net0 "virtio,bridge=vmbr0" \
  --ostype l26 \
  --scsihw virtio-scsi-pci \
  --agent enabled=1

echo "Importing cloud image to storage '${DISK_STORAGE}'..."
qm importdisk "${VMID}" "${TEMP_IMG}" "${DISK_STORAGE}" --format qcow2

echo "Determining imported disk volid on storage '${DISK_STORAGE}'..."
IMPORTED_VOLID=$(pvesm list "${DISK_STORAGE}" | awk -v vmid="${VMID}" '
  NR>1 && $2 ~ ("^" vmid "/vm-" vmid "-disk-0") { print $1 ":" $2; exit }
')

if [[ -z "${IMPORTED_VOLID}" ]]; then
  # Fallback guess; works on most directory / thin-lvm setups
  IMPORTED_VOLID="${DISK_STORAGE}:${VMID}/vm-${VMID}-disk-0.qcow2"
  echo "Warning: Could not auto-detect volid, guessing: ${IMPORTED_VOLID}"
fi

echo "Attaching disk as scsi0 (${IMPORTED_VOLID})..."
qm set "${VMID}" --scsi0 "${IMPORTED_VOLID}",discard=on

echo "Resizing disk to ${DISK_GB}G..."
qm resize "${VMID}" scsi0 "${DISK_GB}G"

echo "Attaching cloud-init drive on '${CI_STORAGE}'..."
qm set "${VMID}" --ide2 "${CI_STORAGE}:cloudinit"

echo "Setting boot options..."
qm set "${VMID}" --boot c --bootdisk scsi0

echo "Enabling serial console..."
qm set "${VMID}" --serial0 socket --vga serial0

echo "Configuring IP (${IPCONFIG0})..."
qm set "${VMID}" --ipconfig0 "${IPCONFIG0}"

echo "Configuring cloud-init user '${CI_USER}' and password..."
qm set "${VMID}" --ciuser "${CI_USER}" --cipassword "${CI_PASS}"

if [[ -n "${TEMP_SSH_KEY_FILE}" ]]; then
  echo "Adding SSH public key from ${TEMP_SSH_KEY_FILE}..."
  qm set "${VMID}" --sshkey "${TEMP_SSH_KEY_FILE}"
fi

# --- Start VM ----------------------------------------------------------------

echo "Starting VM ${VMID}..."
qm start "${VMID}"

echo "VM ${VMID} (${VM_NAME}) created and started successfully."
echo "You can now connect via SSH once cloud-init finishes applying configuration."

# --- Clean up temp image / temp key -----------------------------------------

cleanup
