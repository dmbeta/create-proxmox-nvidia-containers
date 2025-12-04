# handle proxmox header and nvidia driver upgrades for host and all LXC nodes
# upgrade packages
pveupdate
pveupgrade -y

# download new headers
apt install proxmox-headers-$(uname -r) -y

# reinstall the drivers with new headers installed
apt install --reinstall nvidia-driver-cuda nvidia-kernel-dkms -y

# for each proxmox node, run the following
read -r -d '' upgrade_driver << EOF
# upgrade packages
apt update
apt upgrade -y

# update docker compose
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# update docker bash completion
curl \
    -L https://raw.githubusercontent.com/docker/cli/master/contrib/completion/bash/docker \
    -o /etc/bash_completion.d/docker-compose

echo "Rebooting node"
reboot now
EOF

IFS=$'\n' running_pcts=($(pct list | awk '$2 == "running" {print $1}'))
for node in "${running_pcts[@]}"; do
    echo "Upgrading node $node"
    pct exec $node -- sh -c "$upgrade_driver"
done

echo "Rebooting host"
reboot now
