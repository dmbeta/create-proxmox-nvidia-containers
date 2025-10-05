# install NVIDIA Container Toolkit
apt install -y curl sudo
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt update
apt install nvidia-container-toolkit

# make sure that docker is configured
# this will modify your existing /etc/docker/daemon.json by adding relevant config
nvidia-ctk runtime configure --runtime=docker

# restart systemd + docker (if you don't reload systemd, it might not work)
systemctl daemon-reload
systemctl restart docker