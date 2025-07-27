#!/bin/bash

# This script manages the Unattended-Upgrade::Package-Blacklist in
# /etc/apt/apt.conf.d/52unattended-upgrades-local.
# It ensures that 'nvidia-?' and 'libnvidia-?' are present and active
# in the blacklist.

# Define the configuration file path
CONFIG_FILE="/etc/apt/apt.conf.d/52unattended-upgrades-local"

# Define the blacklist entries to ensure are present (unescaped)
# The '?' character will be handled correctly for regex matching and literal insertion.
BLACKLIST_ENTRIES=("nvidia-?" "libnvidia-?")

echo "Processing $CONFIG_FILE..."

# Check for root privileges, as file modifications require them
if [ "$(id -u)" -ne 0 ]; then
    echo "This script requires root privileges. Please run with 'sudo'."
    exit 1
fi

# Function to reload systemd daemon and restart unattended-upgrades service
# This function is called at the end of the script to apply changes.
function finish_up {
    echo "Reloading systemctl daemon..."
    systemctl daemon-reload
    echo "Restarting unattended-upgrades service..."
    systemctl restart unattended-upgrades
    echo "Script finished."
    exit 0
}

# --- Section: Ensure the configuration file and Package-Blacklist block exist ---

# If the configuration file does not exist, create it and add the basic blacklist block.
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Configuration file $CONFIG_FILE not found. Creating it and adding initial block."
    echo "Unattended-Upgrade::Package-Blacklist {" | tee "$CONFIG_FILE" > /dev/null
    echo "}" | tee -a "$CONFIG_FILE" > /dev/null
# If the file exists but the 'Unattended-Upgrade::Package-Blacklist' block is missing,
# append the block to the end of the file.
elif ! grep -q 'Unattended-Upgrade::Package-Blacklist\s*{' "$CONFIG_FILE"; then
    echo "Unattended-Upgrade::Package-Blacklist block not found. Appending it."
    echo -e "\nUnattended-Upgrade::Package-Blacklist {" | tee -a "$CONFIG_FILE" > /dev/null
    echo "}" | tee -a "$CONFIG_FILE" > /dev/null
fi

# --- Section: Add or uncomment blacklist entries ---

# Loop through each desired blacklist entry
for BLACKLIST_ENTRY in "${BLACKLIST_ENTRIES[@]}"; do
    # Escape the '?' character for use in regular expressions with grep.
    # This allows grep to match the literal '?' in the file content.
    ESCAPED_ENTRY=$(echo "$BLACKLIST_ENTRY" | sed 's/\?/\\?/g')

    # Check if the entry is already present and active (uncommented)
    if grep -q -E "^\s*\"${ESCAPED_ENTRY}\";" "$CONFIG_FILE"; then
        echo "Package-Blacklist entry \"$BLACKLIST_ENTRY\" is already active. Leaving alone."
    # Check if the entry is present but commented out (e.g., // "nvidia-?";)
    elif grep -q -E "^\s*//\s*\"${ESCAPED_ENTRY}\";" "$CONFIG_FILE"; then
        echo "Package-Blacklist entry \"$BLACKLIST_ENTRY\" found commented. Uncommenting..."
        # Use sed to replace the commented line with an uncommented, active line.
        # We use '|' as the sed delimiter because the pattern contains '/' characters.
        # The replacement uses the unescaped BLACKLIST_ENTRY to insert the literal '?'.
        sed -i "s|^\s*//\s*\"${ESCAPED_ENTRY}\";|    \"${BLACKLIST_ENTRY}\";|" "$CONFIG_FILE"
    # If the entry is neither active nor commented, add it to the blacklist block.
    else
        echo "Package-Blacklist entry \"$BLACKLIST_ENTRY\" not found. Adding..."
        # Use sed to insert the new entry after the opening brace of the blacklist block.
        # The 'a\' command appends the specified text after the matched line.
        # The replacement uses the unescaped BLACKLIST_ENTRY.
        sed -i "/Unattended-Upgrade::Package-Blacklist\s*{/a\    \"$BLACKLIST_ENTRY\";" "$CONFIG_FILE"
    fi
done

# Call the finish_up function to apply changes by reloading systemd and restarting the service.
finish_up
