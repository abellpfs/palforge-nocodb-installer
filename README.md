# Pal Forge NocoDB Installer

Automation to spin up a **NocoDB + Postgres + Redis + Traefik** stack on a Proxmox VM,
with optional Cloudflare Tunnel integration.

## Flow

1. **On Proxmox host**

   ```bash
   git clone git@github.com:<YOUR_USERNAME>/palforge-nocodb-installer.git
   cd palforge-nocodb-installer

   chmod +x create_nocodb_vm.sh
   ./create_nocodb_vm.sh
