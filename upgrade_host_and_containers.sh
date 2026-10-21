#!/usr/bin/env bash
#
# Upgrade the Proxmox host and the NVIDIA driver on the host and all running
# LXC containers.  This is the routine driver refresh, not the PVE 8 -> 9
# distribution upgrade.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "This script requires root privileges. Please run with 'sudo'." >&2
    exit 1
fi

# Upgrade Proxmox packages.
pveupdate
pveupgrade -y

# Install headers for the current default Proxmox kernel.  pve-headers is a
# transitional alias; proxmox-default-headers is the real metapackage.
apt install proxmox-default-headers -y || \
    echo "Warning: could not install proxmox-default-headers; continuing with running-kernel headers." >&2

# Opt-in kernels need headers for the exact running kernel as well.
KERNEL="$(uname -r)"
if [ ! -d "/lib/modules/${KERNEL}/build" ]; then
    if ! apt install -y "proxmox-headers-${KERNEL}"; then
        echo "Error: could not install headers for running kernel ${KERNEL}." >&2
        echo "Install proxmox-headers-${KERNEL} manually or boot the default kernel." >&2
        exit 1
    fi
fi

if [ ! -d "/lib/modules/${KERNEL}/build" ]; then
    echo "Error: headers for running kernel ${KERNEL} are still missing." >&2
    exit 1
fi

# Rebuild the NVIDIA modules against the running kernel's headers.
apt install --reinstall nvidia-driver-cuda nvidia-kernel-dkms -y

# For each running container, upgrade packages and refresh the Docker Compose
# binary.  The driver itself comes from the CUDA repository configured when
# the container was created.
read -r -d '' upgrade_driver <<'EOF' || true
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade

# Update docker compose.
curl -fL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Update docker bash completion.
curl -fL \
    https://raw.githubusercontent.com/docker/cli/master/contrib/completion/bash/docker \
    -o /etc/bash_completion.d/docker-compose
EOF

mapfile -t running_pcts < <(pct list | awk '$2 == "running" {print $1}')
for node in "${running_pcts[@]}"; do
    echo "Upgrading node $node"
    if pct exec "$node" -- sh -c "$upgrade_driver"; then
        echo "Rebooting node $node"
        pct reboot "$node" || echo "Warning: could not reboot node $node" >&2
    else
        echo "Warning: upgrade failed for node $node; leaving it running" >&2
    fi
done

echo "Rebooting host"
reboot now
