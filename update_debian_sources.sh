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