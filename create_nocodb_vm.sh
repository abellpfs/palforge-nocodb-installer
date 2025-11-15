#!/usr/bin/env bash
set -euo pipefail

echo "=== Pal Forge | NocoDB Proxmox VM Creator ==="
echo "This script must be run on your Proxmox host as root."
echo

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: Please run this script as root on the Proxmox host (e.g. via sudo)."
  exit 1
fi

read_with_default() {
  local prompt="$1"
  local default="$2"
  local var
  read -rp "$prompt [$default]: " var
  echo "${var:-$default}"
}

# --- Collect settings ---

VMID=$(read_with_default "VM ID" "120")
VM_NAME=$(read_with_default "VM Name" "nocodb-vm")
TEMPLATE_ID=$(read_with_default "Cloud-init template ID (Ubuntu 22.04/24.04)" "9000")
STORAGE=$(read_with_default "Storage (for disk & cloud-init)" "local-lvm")
DISK_SIZE=$(read_with_default "Disk size" "40G")
CORES=$(read_with_default "CPU cores" "2")
MEMORY=$(read_with_default "Memory (MB)" "4096")
BRIDGE=$(read_with_default "Bridge" "vmbr0")
VLAN_TAG=$(read_with_default "VLAN tag (empty for none)" "")
IPADDR=$(read_with_default "VM IP/CIDR" "192.168.1.50/24")
GATEWAY=$(read_with_default "Gateway" "192.168.1.1")
CI_USER=$(read_with_default "Cloud-init username" "abell")
TIMEZONE=$(read_with_default "Timezone" "America/Denver")

SSH_KEY_PATH=$(read_with_default "Path to SSH public key" "$HOME/.ssh/id_ed25519.pub")
if [[ ! -f "$SSH_KEY_PATH" ]]; then
  echo "ERROR: SSH key not found at $SSH_KEY_PATH"
  exit 1
fi
SSH_KEY_CONTENT=$(<"$SSH_KEY_PATH")

SNIPPET_DIR="/var/lib/vz/snippets"
mkdir -p "$SNIPPET_DIR"
SNIPPET_NAME="nocodb-cloudinit-${VMID}.yaml"
USERDATA_PATH="${SNIPPET_DIR}/${SNIPPET_NAME}"

echo
echo "=== Summary ==="
echo "VMID:       $VMID"
echo "Name:       $VM_NAME"
echo "Template:   $TEMPLATE_ID"
echo "Storage:    $STORAGE"
echo "Disk:       $DISK_SIZE"
echo "CPU:        $CORES"
echo "RAM:        $MEMORY MB"
echo "Bridge:     $BRIDGE"
echo "VLAN tag:   ${VLAN_TAG:-<none>}"
echo "IP:         $IPADDR"
echo "Gateway:    $GATEWAY"
echo "User:       $CI_USER"
echo "Timezone:   $TIMEZONE"
echo "SSH key:    $SSH_KEY_PATH"
echo "Cloud-init: $USERDATA_PATH"
echo

read -rp "Proceed and create VM? [y/N]: " CONFIRM
CONFIRM=${CONFIRM:-n}
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "Aborting."
  exit 0
fi

# --- Create cloud-init user-data snippet ---

cat > "$USERDATA_PATH" <<EOF
#cloud-config
users:
  - name: ${CI_USER}
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${SSH_KEY_CONTENT}

timezone: ${TIMEZONE}

package_update: true
package_upgrade: true

runcmd:
  - [bash, -c, "echo 'Cloud-init complete for ${CI_USER}'"]
EOF

echo "Wrote cloud-init user-data to: $USERDATA_PATH"

SNIPPET_STORAGE="local"   # default Proxmox storage for snippets

# --- Create VM from template ---

echo "Cloning template ${TEMPLATE_ID} to VM ${VMID}..."
qm clone "$TEMPLATE_ID" "$VMID" --name "$VM_NAME" --full true --storage "$STORAGE"

echo "Configuring VM hardware and cloud-init..."
NET_CONF="virtio,bridge=${BRIDGE}"
if [[ -n "$VLAN_TAG" ]]; then
  NET_CONF="${NET_CONF},tag=${VLAN_TAG}"
fi

qm set "$VMID" \
  --cores "$CORES" \
  --memory "$MEMORY" \
  --net0 "$NET_CONF" \
  --ipconfig0 "ip=${IPADDR},gw=${GATEWAY}"

# Attach cloud-init drive & snippet
qm set "$VMID" \
  --ide2 "${STORAGE}:cloudinit" \
  --cicustom "user=${SNIPPET_STORAGE}:snippets/${SNIPPET_NAME}" \
  --serial0 socket \
  --boot c \
  --bootdisk scsi0

# Resize disk
qm resize "$VMID" scsi0 "$DISK_SIZE"

echo "Starting VM ${VMID}..."
qm start "$VMID"

echo
echo "=== Done ==="
echo "VM ${VMID} (${VM_NAME}) created and started."
echo "SSH once it's up:  ssh ${CI_USER}@<${IPADDR%/*}>"
echo "Then run:  ./setup_nocodb.sh  (inside the VM)"
