#!/usr/bin/env bash
#
# Install the NVIDIA userspace driver inside a Debian LXC container.
#
# The script is safe to run on both Debian 12 (Bookworm) and Debian 13
# (Trixie) containers.  It selects the matching NVIDIA CUDA repository.

set -euo pipefail

REBOOT=1
SCRIPT_DIR=""

usage() {
    cat <<'EOF'
Usage: install_nvidia_driver_on_container.sh [--no-reboot]

Options:
  --no-reboot  Do not reboot the container after installation.
  -h, --help   Show this help.
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-reboot)
            REBOOT=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    die "this script requires root privileges. Please run with 'sudo'."
fi

if [ -f "${BASH_SOURCE[0]:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# shellcheck source=/dev/null
. /etc/os-release
CODENAME="${VERSION_CODENAME:-}"
if [ -z "$CODENAME" ] && command -v lsb_release >/dev/null 2>&1; then
    CODENAME="$(lsb_release -cs)"
fi

case "$CODENAME" in
    bookworm)
        CUDA_REPO="debian12"
        ;;
    trixie)
        CUDA_REPO="debian13"
        ;;
    *)
        die "unsupported Debian release '${CODENAME:-unknown}'. Expected bookworm or trixie."
        ;;
esac

echo "Detected Debian codename: $CODENAME (CUDA repository: $CUDA_REPO)"

apt update
DEBIAN_FRONTEND=noninteractive apt-get install -y sudo ca-certificates curl

# Add non-free/non-free-firmware.  Prefer the local copy when this script is
# run from a cloned repo or pushed alongside the helper.
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/update_debian_sources.sh" ]; then
    bash "$SCRIPT_DIR/update_debian_sources.sh"
else
    curl -fsSL -o- https://raw.githubusercontent.com/dmbeta/create-proxmox-nvidia-containers/main/update_debian_sources.sh | bash
fi

apt update
DEBIAN_FRONTEND=noninteractive apt-get -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    upgrade

# Download the keyring before touching the existing repository, so a network
# failure leaves the current apt configuration intact.
KEYRING_DEB="$(mktemp "${TMPDIR:-/tmp}/cuda-keyring.XXXXXX.deb")"
curl -fsSL \
    "https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_REPO}/x86_64/cuda-keyring_1.1-1_all.deb" \
    -o "$KEYRING_DEB"

# Remove repository files from a previous Debian release.  The cuda-keyring
# package installs a release-specific file but does not reliably remove the
# old one.
rm -f /etc/apt/sources.list.d/cuda-debian*-x86_64.list
rm -f /etc/apt/sources.list.d/cuda-debian*-x86_64.sources

DEBIAN_FRONTEND=noninteractive dpkg -i "$KEYRING_DEB"
rm -f "$KEYRING_DEB"

apt update
DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-driver-cuda

systemctl stop nvidia-persistenced.service || true
systemctl disable nvidia-persistenced.service || true
systemctl mask nvidia-persistenced.service || true

# Remove kernel module configuration; the container uses the host's modules.
: > /etc/modprobe.d/nvidia.conf
: > /etc/modprobe.d/nvidia-modeset.conf

# Block the kernel modules inside the container.
cat > /etc/modprobe.d/blacklist-nvidia.conf <<'EOF'
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidia_uvm
EOF

if [ "$REBOOT" -eq 1 ]; then
    echo "Rebooting container."
    reboot now
else
    echo "Driver installation finished. Reboot the container before using the GPU."
fi
