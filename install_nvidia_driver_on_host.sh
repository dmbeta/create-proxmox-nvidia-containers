#!/usr/bin/env bash
#
# Install the NVIDIA CUDA userspace driver and the matching DKMS kernel module
# on a Proxmox VE host.
#
# The script is safe to run on both Debian 12 (Bookworm / PVE 8) and Debian 13
# (Trixie / PVE 9).  It selects the matching NVIDIA CUDA repository.

set -euo pipefail

REBOOT=0
SCRIPT_DIR=""

usage() {
    cat <<'EOF'
Usage: install_nvidia_driver_on_host.sh [--reboot]

Options:
  --reboot   Reboot the host after the driver is installed.
  -h, --help Show this help.
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --reboot)
            REBOOT=1
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
apt install -y ca-certificates curl

# Add non-free/non-free-firmware and keep the sources in the current Debian
# suite.  Prefer the local copy when this script is run from a cloned repo.
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/update_debian_sources.sh" ]; then
    bash "$SCRIPT_DIR/update_debian_sources.sh"
else
    curl -fsSL -o- https://raw.githubusercontent.com/dmbeta/create-proxmox-nvidia-containers/main/update_debian_sources.sh | bash
fi

apt update

# Download the keyring before touching the existing repository, so a network
# failure leaves the current apt configuration intact.
KEYRING_DEB="$(mktemp "${TMPDIR:-/tmp}/cuda-keyring.XXXXXX.deb")"
curl -fsSL \
    "https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_REPO}/x86_64/cuda-keyring_1.1-1_all.deb" \
    -o "$KEYRING_DEB"

# Remove repository files left behind by a previous Debian release.  The
# cuda-keyring package installs a release-specific file, but does not reliably
# remove the old one.
rm -f /etc/apt/sources.list.d/cuda-debian*-x86_64.list
rm -f /etc/apt/sources.list.d/cuda-debian*-x86_64.sources

dpkg -i "$KEYRING_DEB"
rm -f "$KEYRING_DEB"

apt update

# proxmox-default-headers tracks the headers for the current default Proxmox
# kernel.  On an opt-in kernel, install proxmox-headers-"$(uname -r)" instead.
apt install -y proxmox-default-headers

if dpkg -s nvidia-kernel-dkms >/dev/null 2>&1; then
    apt install -y --reinstall nvidia-driver-cuda nvidia-kernel-dkms
else
    apt install -y nvidia-driver-cuda nvidia-kernel-dkms
fi

KERNEL="$(uname -r)"
if command -v dkms >/dev/null 2>&1; then
    if ! dkms status | grep -q "nvidia.*${KERNEL}.*installed"; then
        echo "Error: no NVIDIA DKMS module was built for the running kernel ${KERNEL}." >&2
        echo "If a newer kernel was just installed, reboot into it and re-run this script." >&2
        echo "If you are using an opt-in kernel, install its headers explicitly:" >&2
        echo "    apt install proxmox-headers-${KERNEL}" >&2
        echo "Then re-run this script." >&2
        exit 1
    fi
    echo "NVIDIA DKMS module is present for kernel ${KERNEL}."
else
    echo "Warning: dkms is not installed; skipping the DKMS module check." >&2
fi

if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    echo "nvidia-smi is working."
else
    echo "nvidia-smi is not working yet; a reboot is normally required after a driver change."
fi

if [ "$REBOOT" -eq 1 ]; then
    echo "Rebooting host."
    reboot now
else
    echo "Driver installation finished. Reboot the host before using the GPU."
fi
