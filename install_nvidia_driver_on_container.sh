apt install sudo -y
# update sources with non-free and non-free-firmware
curl -o- https://raw.githubusercontent.com/dmbeta/create-proxmox-nvidia-containers/main/update_debian_sources.sh | bash
apt update && apt upgrade -y
wget https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/cuda-keyring_1.1-1_all.deb && dpkg -i cuda-keyring_1.1-1_all.deb && apt update && apt install nvidia-driver-cuda -y
systemctl stop nvidia-persistenced.service || true
systemctl disable nvidia-persistenced.service || true
systemctl mask nvidia-persistenced.service || true

# remove kernel config
echo "" > /etc/modprobe.d/nvidia.conf
echo "" > /etc/modprobe.d/nvidia-modeset.conf

# block kernel modules
echo -e "blacklist nvidia\nblacklist nvidia_drm\nblacklist nvidia_modeset\nblacklist nvidia_uvm" > /etc/modprobe.d/blacklist-nvidia.conf

reboot now