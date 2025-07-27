# Check if at least one argument is provided
if [ -z "$1" ]; then
    echo "Usage: $0 <container_id>"
    exit 1
fi

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    echo "Usage: $0 <container_id>"
    exit 0
fi

# Check if the first argument is a valid container ID
if ! pct list | grep -q "^$1"; then
    echo "Invalid container ID: $1"
    exit 1
fi

# Check that the container is running
if ! pct status $1 | grep -q "running"; then
    echo "Container $1 is not running"
    exit 1
fi

# Assign the first command-line argument to a variable
containerid="$1"

read -r -d '' updatedebiansources << EOF
# This script modifies /etc/apt/sources.list to ensure 'non-free' and 'non-free-firmware'
# components are present at the end of each 'deb' line.

SOURCES_LIST="/etc/apt/sources.list"
TEMP_SOURCES_LIST="/tmp/sources.list.temp.$$" # Using $$ for a unique temporary file

echo "Checking and modifying $SOURCES_LIST..."

# Check if the sources.list file exists
if [ ! -f "$SOURCES_LIST" ]; then
    echo "Error: $SOURCES_LIST not found. Exiting."
    exit 1
fi

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "This script requires root privileges. Please run with 'sudo'."
    exit 1
fi

# Read the sources.list file line by line
# Process each line and write to a temporary file
while IFS= read -r line; do
    # Check if the line starts with 'deb ' and is not commented out
    if [[ "$line" =~ ^deb[[:space:]] ]]; then
        # Check if 'non-free' is missing
        if ! echo "$line" | grep -qE '\bnon-free\b'; then
            line="$line non-free"
            echo "Added 'non-free' to line: $line"
        fi
        # Check if 'non-free-firmware' is missing
        if ! echo "$line" | grep -qE '\bnon-free-firmware\b'; then
            line="$line non-free-firmware"
            echo "Added 'non-free-firmware' to line: $line"
        fi
    fi
    # Write the (potentially modified) line to the temporary file
    echo "$line" >> "$TEMP_SOURCES_LIST"
done < "$SOURCES_LIST"

# Compare original and modified files
if cmp -s "$SOURCES_LIST" "$TEMP_SOURCES_LIST"; then
    echo "No changes were needed for $SOURCES_LIST."
    rm "$TEMP_SOURCES_LIST"
else
    echo "Changes were made. Backing up original $SOURCES_LIST to ${SOURCES_LIST}.bak"
    sudo cp "$SOURCES_LIST" "${SOURCES_LIST}.bak"
    echo "Updating $SOURCES_LIST with modified content."
    sudo mv "$TEMP_SOURCES_LIST" "$SOURCES_LIST"
    echo "Remember to run 'sudo apt update' after modifying sources.list."
fi

echo "Script finished."
exit 0
EOF

pct exec $containerid -- sh -c 'apt install sudo -y'
pct exec $containerid -- sh -c '$updatedebiansources'
pct exec $containerid -- sh -c 'apt update && apt upgrade -y'
pct exec $containerid -- sh -c 'wget https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/cuda-keyring_1.1-1_all.deb && dpkg -i cuda-keyring_1.1-1_all.deb && apt update && apt install nvidia-driver-cuda -y'
pct exec $containerid -- sh -c 'systemctl stop nvidia-persistenced.service || true'
pct exec $containerid -- sh -c 'systemctl disable nvidia-persistenced.service || true'
pct exec $containerid -- sh -c 'systemctl mask nvidia-persistenced.service || true'

# remove kernel config
pct exec $containerid -- sh -c 'echo "" > /etc/modprobe.d/nvidia.conf'
pct exec $containerid -- sh -c 'echo "" > /etc/modprobe.d/nvidia-modeset.conf'

# block kernel modules
pct exec $containerid -- sh -c 'echo -e "blacklist nvidia\nblacklist nvidia_drm\nblacklist nvidia_modeset\nblacklist nvidia_uvm" > /etc/modprobe.d/blacklist-nvidia.conf'

pct exec $containerid -- sh -c 'reboot now'