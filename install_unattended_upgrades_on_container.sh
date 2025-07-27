read -r -d '' blacklist_nvidia << EOF
#!/bin/bash

# Define the file path
CONFIG_FILE="/etc/apt/apt.conf.d/52unattended-upgrades-local"

# Define the blacklist entries to add
BLACKLIST_ENTRY_1='"nvidia-?";'
BLACKLIST_ENTRY_2='"libnvidia-?";'

# Check if the file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file $CONFIG_FILE not found."
    exit 1
fi

echo "Processing $CONFIG_FILE..."

# Read the file content
FILE_CONTENT=$(<"$CONFIG_FILE")

# If FILE_CONTENT is empty, insert the following config
if [ -z "$FILE_CONTENT" ]; then
    echo "File is empty. Adding Unattended-Upgrade::Package-Blacklist block."
    echo -e "\nUnattended-Upgrade::Package-Blacklist {" | sudo tee "$CONFIG_FILE" > /dev/null
    echo "    $BLACKLIST_ENTRY_1" | sudo tee -a "$CONFIG_FILE" > /dev/null
    echo "    $BLACKLIST_ENTRY_2" | sudo tee -a "$CONFIG_FILE" > /dev/null
    echo "}" | sudo tee -a "$CONFIG_FILE" > /dev/null
    echo "Script finished."
    exit 0
fi

# Check and add "nvidia-?"
if grep -q -E '^\s*(//\s*)?"nvidia-\?["[:space:]]*;' "$CONFIG_FILE"; then
    if grep -q -E '^\s*//\s*"nvidia-\?["[:space:]]*;' "$CONFIG_FILE"; then
        echo "nvidia already present and commented. Leaving alone."
    else
        echo "'nvidia-?' already present and uncommented."
    fi
else
    echo "Adding 'nvidia-?' to Package-Blacklist..."
    # Find the line after "Unattended-Upgrade::Package-Blacklist {" and insert
    # If the block doesn't exist, this will add it at the end.
    if ! grep -q 'Unattended-Upgrade::Package-Blacklist\s*{' "$CONFIG_FILE"; then
        echo "Adding Unattended-Upgrade::Package-Blacklist block."
        echo -e "\nUnattended-Upgrade::Package-Blacklist {" | sudo tee -a "$CONFIG_FILE" > /dev/null
        echo "    $BLACKLIST_ENTRY_1" | sudo tee -a "$CONFIG_FILE" > /dev/null
        echo "    $BLACKLIST_ENTRY_2" | sudo tee -a "$CONFIG_FILE" > /dev/null
        echo "}" | sudo tee -a "$CONFIG_FILE" > /dev/null
    else
        # Insert after the opening brace of the blacklist
        sudo sed -i "/Unattended-Upgrade::Package-Blacklist\s*{/a\    $BLACKLIST_ENTRY_1" "$CONFIG_FILE"
    fi
fi

# Check and add "libnvidia-?"
if grep -q -E '^\s*(//\s*)?"libnvidia-\?["[:space:]]*;' "$CONFIG_FILE"; then
    if grep -q -E '^\s*//\s*"libnvidia-\?["[:space:]]*;' "$CONFIG_FILE"; then
        echo "'libnvidia-?' already present and commented. Leaving alone."
    else
        echo "'libnvidia-?' already present and uncommented."
    fi
else
    echo "Adding 'libnvidia-?' to Package-Blacklist..."
    # Find the line after "Unattended-Upgrade::Package-Blacklist {" and insert
    # This will assume "nvidia-?" was already handled, so we just add it to the block.
    if ! grep -q 'Unattended-Upgrade::Package-Blacklist\s*{' "$CONFIG_FILE"; then
        # This case should ideally not happen if the previous block already added it.
        # But as a fallback, ensure the block is there if somehow only libnvidia was missing.
        echo "Adding Unattended-Upgrade::Package-Blacklist block (for libnvidia-?)."
        echo -e "\nUnattended-Upgrade::Package-Blacklist {" | sudo tee -a "$CONFIG_FILE" > /dev/null
        echo "    $BLACKLIST_ENTRY_1" | sudo tee -a "$CONFIG_FILE" > /dev/null
        echo "    $BLACKLIST_ENTRY_2" | sudo tee -a "$CONFIG_FILE" > /dev/null
        echo "}" | sudo tee -a "$CONFIG_FILE" > /dev/null
    else
        # Insert after the opening brace of the blacklist, or after the last entry if it exists
        if grep -q "^\s*\"nvidia-\?\"" "$CONFIG_FILE"; then
            sudo sed -i "/^\s*\"nvidia-\?\"/a\    $BLACKLIST_ENTRY_2" "$CONFIG_FILE"
        else
            sudo sed -i "/Unattended-Upgrade::Package-Blacklist\s*{/a\    $BLACKLIST_ENTRY_2" "$CONFIG_FILE"
        fi
    fi
fi

echo "Script finished."
EOF

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

pct exec $containerid -- sh -c 'apt install unattended-upgrades apt-listchanges -y'
pct exec $containerid -- sh -c 'echo unattended-upgrades unattended-upgrades/enable_auto_updates boolean true | debconf-set-selections'
pct exec $containerid -- sh -c 'dpkg-reconfigure -f noninteractive unattended-upgrades'
pct exec $containerid -- sh -c '$blacklist_nvidia'