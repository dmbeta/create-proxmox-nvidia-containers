# How to create Proxmox LXC containers with nvidia GPU permissions
Scripts for creating Proxmox VE LXC containers with nvidia GPU permissions based on [jocke's guide to Plex GPU transcoding](https://jocke.no/2025/04/20/plex-gpu-transcoding-in-docker-on-lxc-on-proxmox-v2/).

These were _absolutely_ vibe-coded (using Gemini) as my sed, awk, and grep skills are pretty rusty, but these scripts were tested on Proxmox VE 8.4.5 with Debian 12.11.

## Proxmox setup prior to containers

We need to update the `/etc/apt/sources.list` file to include non-free and non-free-firmware sources so that we can install the nvidia drivers.

```bash
curl -fsSL -o- https://raw.githubusercontent.com/dmbeta/create-proxmox-nvidia-containers/main/update_debian_sources.sh | bash
apt update
apt install proxmox-headers-$(uname -r)
wget https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/cuda-keyring_1.1-1_all.deb
dpkg -i cuda-keyring_1.1-1_all.deb
apt update
apt install nvidia-driver-cuda nvidia-kernel-dkms
reboot now
```

## Creating the container
1. Create a new LXC container with the following options:
    - Container type: Container
    - OS: Debian
    - Version: 12 (Bookworm)

    But do not start it just yet.

2. Add the necessary cgroup2 devices and lxc mount points to the container's configuration file. You can generate them by utilizing the generate_lxc_conf_additions.sh script by running:

    ```bash
    # run on the host
    curl -fsSL -o- https://raw.githubusercontent.com/dmbeta/create-proxmox-nvidia-containers/main/generate_lxc_conf_additions.sh | bash
    ```

    and then copy the output to the container's configuration file, usually located at /etc/lxc/<container_id>.conf.

    NOTE: All following commands can be run from the container, or pushed to the container by running on the host with the command copied inside like so:

    ```bash
    pct exec <container_id> -- sh -c "<command>"
    ```

3. Start the container and then run the following command inside to install the NVIDIA driver on the container.

    First install sudo and curl if they are not already installed.

    ```bash
    apt update && apt upgrade -y && apt-get install -y sudo curl
    ```

    Then install the NVIDIA driver:

    ```bash
    curl -fsSL -o- https://raw.githubusercontent.com/dmbeta/create-proxmox-nvidia-containers/main/install_nvidia_driver_on_container.sh | bash
    ```

    Everything after this step is optional if you just needed an LXC container with the NVIDIA driver installed but didn't want to install docker and the NVIDIA Container Toolkit.

4. (Optional) Install docker and the NVIDIA Container Toolkit on the container. This is required for running NVIDIA containers on the container.

    ```bash
    curl -fsSL -o- https://raw.githubusercontent.com/dmbeta/create-proxmox-nvidia-containers/main/install_docker_and_nvidia_runtime.sh | bash
    ```

5. (Optional) Set up a cron job to delete unused images, containers, and volumes. This helps keep the container size down.

    ```bash
    crontab -e # open the crontab file
    ```

    Add the following lines to the crontab file to run the commands at 10:00 AM every day.

    ```cron
    0 10 * * * docker container prune -f > /dev/null 2>&1
    0 10 * * * docker image prune -f > /dev/null 2>&1
    0 10 * * * docker volume prune -f > /dev/null 2>&1
    0 10 * * * docker network prune -f > /dev/null 2>&1
    0 10 * * * docker builder prune -f > /dev/null 2>&1
    ```

6. (Optional) Configure unattended-upgrades for the container while disabling unattended-upgrades for nvidia driver updates. This is so that you can keep the container up to date with the latest security updates, but nvidia driver updates require a different approach to avoid conflicts with the host.

    ```bash
    curl -fsSL -o- https://raw.githubusercontent.com/dmbeta/create-proxmox-nvidia-containers/main/install_unattended_upgrades_on_container.sh | bash
    ```

7. (Optional, but recommended): Once you verify the container works using `nvidia-smi` and a sample container, turn it into a template. This will allow you to easily create new containers from this template.

    ```bash
    rm /etc/ssh/ssh_host_*
    truncate -s 0 /etc/machine-id
    shutdown now
    ```

    In the UI, right click the (now stopped) container, and select "Convert to template". This requires that there are no snapshots of the container, and you won't be able to run the container after converting to a template.

    ![convert to template](images/convert_to_template.png)

    You can then create new containers from this template by right clicking the template and selecting clone. When cloning, change mode to "Full Clone".

    ![full clone](images/full_clone.png)


# Upgrade NVIDIA Driver on Host and Containers

This script assumes all running containers are using the GPU. If you have containers that are not using the GPU, I'd recommend stopping them before running this script. This script will upgrade the NVIDIA driver on the host, the containers, restart the containers, and then restart the host.

```bash
# please run this on the Proxmox host
curl -fsSL -o- https://raw.githubusercontent.com/dmbeta/create-proxmox-nvidia-containers/main/upgrade_host_and_containers.sh | bash
```

# Other Useful Sources

- [Proxmox VE Helper-Scripts](https://community-scripts.github.io/ProxmoxVE/scripts)
- [Habitats Open Tech's Guide to Proxmox](https://portal.habitats.tech/Proxmox+VE+8+(PVE)/1.+PVE+8.x+-+Introduction)

## Cool Tools

- [Beszel](https://github.com/henrygd/beszel) for monitoring both Proxmox and LXC containers resource utilization. 
  - It has helped me with discovering that my LXC containers were running out of disk space.
- [Dockge](https://github.com/louislam/dockge) a docker compose manager.
- [Tailscale](https://tailscale.com/). I'd be surprised if you hadn't heard about this. It's a VPN that allows you to connect to your Proxmox host and your containers from anywhere.
    - I set up Tailscale in each of my containers like so:
        ```sh
        curl -fsSL https://tailscale.com/install.sh | sh
        sudo tailscale set --auto-update
        sudo tailscale up --ssh --accept-routes --accept-dns
        ```
        This allows you to SSH into your container without having to port forward or manage ssh keys.
    - One important note though, is that your LXC container must either be privileged _or_ have the following line in its `/etc/pve/lxc/<container_id>.conf` file:
        ```yaml
        lxc.mount.entry: /dev/net dev/net none bind,create=dir
        lxc.cgroup2.devices.allow: c 10:200 rwm # this must correspond to the ids you see when you run `ls -l /dev/net`
        ```