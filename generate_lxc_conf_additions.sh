#!/bin/bash

# This script generates LXC configuration lines for NVIDIA and DRI devices.
# It parses the output of 'ls -alh /dev/nvidia* /dev/dri/* /dev/nvidia-caps/*'
# to extract major device IDs for cgroup allowances and full device paths for mount entries.

# Define the command to get device information.
# We include /dev/nvidia-caps/* to ensure all relevant NVIDIA devices are captured.
# '2>/dev/null' suppresses errors if some patterns don't match (e.g., if /dev/nvidia-caps is empty).
LS_COMMAND="ls -alh /dev/nvidia* /dev/dri/* /dev/nvidia-caps/* 2>/dev/null"

# Declare an associative array to store unique major IDs.
# The value '1' is arbitrary; we only care about the keys for uniqueness.
declare -A seen_major_ids

# Declare a regular array to store full device paths for mount entries.
mount_entries=()

echo "--- Generating LXC GPU Configuration ---"

# Read the output of the ls command line by line.
# IFS= read -r line prevents backslash interpretation and leading/trailing whitespace trimming.
while IFS= read -r line; do
    # Skip empty lines, lines starting with 'total' (summary lines from ls),
    # and lines that are directory headers (e.g., "/dev/dri:").
    if [[ -z "$line" || "$line" =~ ^total || "$line" =~ ^/dev/ ]]; then
        continue
    fi

    # Check if the line represents a character device.
    # Character devices start with 'c' in the permissions string (e.g., 'crw-rw-rw-').
    if [[ "$line" =~ ^c ]]; then
        # Extract the fifth field, which contains the major and minor device numbers (e.g., "195," or "226,").
        major_minor_field=$(echo "$line" | awk '{print $5}')
        # Extract the last field, which is the full device path (e.g., "/dev/nvidia0").
        device_path=$(echo "$line" | awk '{print $NF}')

        # Extract the major ID by removing the comma from the major_minor_field.
        major_id=$(echo "$major_minor_field" | sed 's/,//')

        # Add the extracted major ID to the associative array.
        # This automatically handles uniqueness, as duplicate keys overwrite.
        seen_major_ids["$major_id"]=1

        # Add the full device path to the mount_entries array.
        mount_entries+=("$device_path")
    fi
done < <($LS_COMMAND) # This syntax executes LS_COMMAND and feeds its output to the while loop.

echo ""
echo "# LXC Cgroup Device Allowances (for GPU access)"
# Iterate over the keys (major IDs) in the associative array.
for major_id in "${!seen_major_ids[@]}"; do
    # Print the formatted lxc.cgroup2.devices.allow line.
    # 'c' denotes a character device, '<major_id>:*' allows all minor devices for that major ID,
    # and 'rwm' grants read, write, and mknod permissions.
    echo "lxc.cgroup2.devices.allow: c ${major_id}:* rwm"
done

echo ""
echo "# LXC Mount Entries (to expose devices inside the container)"
# Iterate over the collected device paths.
for path in "${mount_entries[@]}"; do
    # For lxc.mount.entry, the destination path inside the container is typically
    # the same as the host path, but relative to the container's root filesystem.
    # We remove the leading '/' to get the relative path (e.g., "/dev/nvidia0" -> "dev/nvidia0").
    relative_path=$(echo "$path" | sed 's/^\///')
    # Print the formatted lxc.mount.entry line.
    # 'none bind,optional,create=file' are common options for device passthrough.
    echo "lxc.mount.entry: ${path} ${relative_path} none bind,optional,create=file"
done

echo ""
echo "--- LXC configuration generation complete. ---"
echo "Copy and paste the above lines into your LXC container's configuration file (e.g., /etc/pve/lxc/<VMID>.conf)."
