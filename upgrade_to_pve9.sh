#!/usr/bin/env bash
#
# Upgrade an existing Proxmox VE 8 / Debian 12 host and its running Debian 12
# LXC containers to Proxmox VE 9 / Debian 13.
#
# This script is deliberately staged.  It never reboots automatically and it
# refuses to continue when the pre-upgrade checks find a condition that needs
# human attention.
#
# Typical use:
#   ./upgrade_to_pve9.sh check
#   ./upgrade_to_pve9.sh prepare --backups-confirmed
#   reboot
#   ./upgrade_to_pve9.sh host-nvidia
#   reboot
#   ./upgrade_to_pve9.sh containers

set -euo pipefail

RAW_BASE="https://raw.githubusercontent.com/dmbeta/create-proxmox-nvidia-containers/main"
STATE_DIR="/var/lib/pve-nvidia-upgrade"
STATE_FILE="${STATE_DIR}/state"
HELPER_DIR="/root/pve9-upgrade"

BACKUPS_CONFIRMED=0
ALLOW_CLUSTER=0
ACCEPT_UNKNOWN_REPOS=0
ALLOW_RUNNING_VMS=0
FORCE_LOW_SPACE=0
NO_SNAPSHOT=0
PVE_REPO=""

STAGE=""
BACKUP_PATH=""
STOPPED_CONTAINERS=""

SCRIPT_DIR=""
SCRIPT_PATH=""

usage() {
    cat <<'EOF'
Usage: upgrade_to_pve9.sh <command> [options]

Commands:
  check        Show the current state and run the read-only pre-upgrade checks.
  prepare      Update PVE 8, switch apt to PVE 9 / Debian 13, and dist-upgrade.
  host-nvidia  Install the Debian 13 CUDA repository and NVIDIA driver on the host.
  containers   Upgrade running Debian 12 LXC containers to Debian 13.

Options:
  --backups-confirmed     Confirm that tested backups of all VMs and containers exist.
  --allow-cluster         Allow running on a quorate cluster node.
  --accept-unknown-repos  Continue even if unknown "bookworm" repositories remain.
  --allow-running-vms     Continue even if VMs are running (not recommended).
  --force-low-space       Continue with less than 10 GB free on /.
  --no-snapshot           Do not create container snapshots.
  --repo <type>           Select the Proxmox repository: enterprise or no-subscription.
  -h, --help              Show this help.

The script logs to /var/log/pve9-upgrade-*.log and stores its state in
/var/lib/pve-nvidia-upgrade/state.  It does not reboot automatically.
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

warn() {
    echo "Warning: $*" >&2
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "this script requires root privileges. Please run with 'sudo'."
    fi
}

require_script_file() {
    if [ ! -f "${BASH_SOURCE[0]:-}" ]; then
        die "download this script to a file and run it; do not pipe it to bash."
    fi
}

require_tty() {
    if [ ! -t 0 ]; then
        if [ ! -c /dev/tty ]; then
            die "this command needs an interactive terminal. Run it from SSH, a physical console, or tmux/screen."
        fi
        exec </dev/tty
    fi
}

setup_paths() {
    if [ -f "${BASH_SOURCE[0]:-}" ]; then
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || printf '%s\n' "$0")"
    fi
}

setup_logging() {
    mkdir -p /var/log
    LOG_FILE="/var/log/pve9-upgrade-$(date +%Y%m%d-%H%M%S).log"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "Logging to $LOG_FILE"
}

load_state() {
    if [ -f "$STATE_FILE" ]; then
        # shellcheck disable=SC1090
        . "$STATE_FILE"
    fi
}

state_set() {
    local key="$1"
    local value="$2"
    local tmp

    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    tmp="$(mktemp "${STATE_DIR}/state.XXXXXX")"

    if [ -f "$STATE_FILE" ]; then
        grep -v "^${key}=" "$STATE_FILE" > "$tmp" || true
    fi

    printf '%s=%q\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$STATE_FILE"
    chmod 600 "$STATE_FILE"
    printf -v "$key" '%s' "$value"
}

pve_version() {
    pveversion 2>/dev/null | sed -n 's|^pve-manager/\([0-9][0-9.]*\)/.*|\1|p' | head -n 1
}

latest_installed_kernel() {
    local kernel

    for kernel in /boot/vmlinuz-*; do
        [ -e "$kernel" ] || continue
        printf '%s\n' "${kernel##*/vmlinuz-}"
    done | sort -V | tail -n 1
}

backup_once() {
    local file="$1"
    [ -f "$file" ] || return 0
    if [ ! -e "${file}.bak" ]; then
        cp -p "$file" "${file}.bak"
        echo "Backed up $file to ${file}.bak"
    fi
}

create_host_backup() {
    local timestamp
    local backup_path
    local p
    local tar_rc
    local -a paths
    local -a existing

    timestamp="$(date +%Y%m%d-%H%M%S)"
    backup_path="/root/pve9-config-backup-${timestamp}.tar.gz"

    paths=(
        etc/apt
        etc/network/interfaces
        etc/hosts
        etc/resolv.conf
        etc/fstab
        etc/pve
        etc/sysctl.conf
        etc/sysctl.d
    )
    existing=()
    for p in "${paths[@]}"; do
        if [ -e "/$p" ]; then
            existing+=("$p")
        fi
    done

    [ "${#existing[@]}" -gt 0 ] || die "no configuration paths found to back up"
    # /etc/pve is a FUSE filesystem and can change while tar reads it.  Treat
    # that warning as non-fatal instead of aborting the upgrade, but still fail
    # on real tar errors.
    set +e
    tar --warning=no-file-changed -czf "$backup_path" -C / "${existing[@]}"
    tar_rc=$?
    set -e
    if [ "$tar_rc" -ge 2 ]; then
        die "could not create configuration backup (tar exit code $tar_rc)"
    elif [ "$tar_rc" -eq 1 ]; then
        warn "configuration backup completed with warnings: $backup_path"
    fi
    chmod 600 "$backup_path"
    pveversion -v > "/root/pve9-version-before-${timestamp}.txt" 2>/dev/null || true
    pct list > "/root/pve9-pct-list-before-${timestamp}.txt" 2>/dev/null || true
    qm list > "/root/pve9-qm-list-before-${timestamp}.txt" 2>/dev/null || true

    BACKUP_PATH="$backup_path"
    state_set BACKUP_PATH "$backup_path"
    echo "Configuration backup: $backup_path"
}

ensure_helpers() {
    local name
    mkdir -p "$HELPER_DIR"
    chmod 700 "$HELPER_DIR"

    for name in update_debian_sources.sh install_nvidia_driver_on_host.sh install_nvidia_driver_on_container.sh; do
        if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/$name" ]; then
            cp "$SCRIPT_DIR/$name" "$HELPER_DIR/$name"
        elif [ ! -f "$HELPER_DIR/$name" ]; then
            if ! command -v curl >/dev/null 2>&1; then
                apt update
                apt install -y curl ca-certificates
            fi
            curl -fsSL "${RAW_BASE}/${name}" -o "$HELPER_DIR/$name"
        fi
        bash -n "$HELPER_DIR/$name"
        chmod 755 "$HELPER_DIR/$name"
    done
}

check_disk_space() {
    local available_kb
    local required_kb
    available_kb="$(df -Pk / | awk 'NR == 2 {print $4}')"
    required_kb=$((10 * 1024 * 1024))

    if [ "${available_kb:-0}" -lt "$required_kb" ]; then
        if [ "$FORCE_LOW_SPACE" -ne 1 ]; then
            die "only $(( ${available_kb:-0} / 1024 )) MB free on /; at least 10 GB is recommended. Free space or pass --force-low-space."
        fi
        warn "continuing with less than 10 GB free on /"
    fi
}

check_ceph() {
    if [ -f /etc/ceph/ceph.conf ] || [ -f /etc/pve/ceph.conf ]; then
        die "Ceph is configured on this node. This script does not upgrade Ceph; follow the official PVE 8 -> 9 guide and the Ceph upgrade guide first."
    fi
}

check_cluster() {
    local has_cluster=0
    local status

    if [ -f /etc/pve/corosync.conf ]; then
        has_cluster=1
    fi

    if command -v pvecm >/dev/null 2>&1 && pvecm status >/dev/null 2>&1; then
        has_cluster=1
    elif [ "$has_cluster" -eq 1 ]; then
        die "this node has a cluster configuration but 'pvecm status' failed. Restore cluster health before upgrading."
    fi

    [ "$has_cluster" -eq 1 ] || return 0

    if ! command -v pvecm >/dev/null 2>&1; then
        die "this node has a cluster configuration but pvecm is not installed. Restore the Proxmox tools before upgrading."
    fi

    status="$(pvecm status 2>/dev/null || true)"
    if ! printf '%s\n' "$status" | grep -qE 'Quorate:[[:space:]]*Yes'; then
        die "this node is part of a cluster without quorum. Restore quorum before upgrading."
    fi

    if [ "$ALLOW_CLUSTER" -ne 1 ]; then
        die "this node is part of a cluster. Upgrade one node at a time and pass --allow-cluster after reading the official guide."
    fi

    warn "cluster mode enabled: upgrade one node at a time and do not continue if the cluster is unhealthy."
}

check_running_vms() {
    local running_vms
    local reply

    command -v qm >/dev/null 2>&1 || return 0
    running_vms="$(qm list | awk 'NR > 1 && $3 == "running" {print $1}')"
    [ -n "$running_vms" ] || return 0

    echo "Running VMs: $running_vms"
    if [ "$ALLOW_RUNNING_VMS" -eq 1 ]; then
        warn "continuing with running VMs: $running_vms"
        return 0
    fi

    echo "Stop or migrate all VMs before continuing."
    read -r -p "Type 'vms-stopped' after they are stopped: " reply
    [ "$reply" = "vms-stopped" ] || die "aborted"
    running_vms="$(qm list | awk 'NR > 1 && $3 == "running" {print $1}')"
    [ -z "$running_vms" ] || die "these VMs are still running: $running_vms"
}

stop_running_containers() {
    local id
    local -a current_ids
    local -a still_running

    mapfile -t current_ids < <(pct list | awk 'NR > 1 && $2 == "running" {print $1}')
    if [ "${#current_ids[@]}" -eq 0 ]; then
        echo "No running containers to stop."
        return 0
    fi

    echo "Stopping running containers: ${current_ids[*]}"
    for id in "${current_ids[@]}"; do
        if ! pct shutdown "$id" --timeout 120; then
            warn "graceful shutdown failed for container $id; forcing stop"
            pct stop "$id" || warn "could not stop container $id"
        fi
        if [ -z "$STOPPED_CONTAINERS" ]; then
            STOPPED_CONTAINERS="$id"
        elif ! printf ' %s ' "$STOPPED_CONTAINERS" | grep -q " $id "; then
            STOPPED_CONTAINERS="$STOPPED_CONTAINERS $id"
        fi
    done
    state_set STOPPED_CONTAINERS "$STOPPED_CONTAINERS"

    mapfile -t still_running < <(pct list | awk 'NR > 1 && $2 == "running" {print $1}')
    if [ "${#still_running[@]}" -gt 0 ]; then
        die "these containers are still running: ${still_running[*]}. Stop them manually, then re-run prepare."
    fi
}

start_recorded_containers() {
    local id
    local failed=0
    local started

    if [ -z "$STOPPED_CONTAINERS" ]; then
        return 0
    fi

    # shellcheck disable=SC2086
    for id in $STOPPED_CONTAINERS; do
        if ! pct status "$id" >/dev/null 2>&1; then
            warn "container $id recorded in state no longer exists"
            continue
        fi
        if pct status "$id" | grep -q running; then
            continue
        fi

        echo "Starting container $id"
        if ! pct start "$id"; then
            warn "could not start container $id"
            failed=1
            continue
        fi
        started=0
        for _ in $(seq 1 30); do
            if pct status "$id" | grep -q running; then
                started=1
                break
            fi
            sleep 2
        done
        if [ "$started" -ne 1 ]; then
            warn "container $id did not start"
            failed=1
        fi
    done

    return "$failed"
}

run_pve8to9_checker() {
    local rc=0
    local reply

    if ! command -v pve8to9 >/dev/null 2>&1; then
        die "pve8to9 was not found. Update the host to the latest PVE 8.4 packages first."
    fi

    echo "Running pve8to9 --full..."
    set +e
    pve8to9 --full
    rc=$?
    set -e
    echo "pve8to9 exit code: $rc"
    echo "Review the output above. Warnings must be understood before continuing."
    read -r -p "Type 'checked' to continue: " reply
    [ "$reply" = "checked" ] || die "aborted"
}

ensure_proxmox_keyring() {
    if [ ! -f /usr/share/keyrings/proxmox-archive-keyring.gpg ]; then
        echo "Installing proxmox-archive-keyring..."
        apt update
        apt install -y proxmox-archive-keyring
    fi
}

comment_matching_repo_lines() {
    local file="$1"
    local pattern="$2"

    [ -f "$file" ] || return 0
    if grep -qE "^[[:space:]]*deb(-src)?[[:space:]].*${pattern}" "$file"; then
        backup_once "$file"
        sed -i -E "s|^([[:space:]]*deb(-src)?[[:space:]].*${pattern}.*)$|# disabled by upgrade_to_pve9: \\1|" "$file"
        echo "Commented out ${pattern} entries in $file"
    fi
}

disable_repo_files_by_uri() {
    local pattern="$1"
    local file

    for file in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [ -e "$file" ] || continue
        if grep -qE "$pattern" "$file"; then
            mv "$file" "${file}.disabled"
            echo "Disabled $file"
        fi
    done
}

detect_pve_repo() {
    local enterprise=0
    local no_subscription=0
    local text

    text="$(grep -RhsE '^[[:space:]]*(deb(-src)?[[:space:]]|Types:|URIs:|Suites:|Components:)' \
        /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true)"

    if printf '%s\n' "$text" | grep -q 'pve-enterprise'; then
        enterprise=1
    fi
    if printf '%s\n' "$text" | grep -q 'pve-no-subscription'; then
        no_subscription=1
    fi

    if [ -n "$PVE_REPO" ]; then
        case "$PVE_REPO" in
            enterprise|no-subscription) ;;
            *) die "--repo must be 'enterprise' or 'no-subscription'" ;;
        esac
        return 0
    fi

    if [ "$enterprise" -eq 1 ] && [ "$no_subscription" -eq 1 ]; then
        die "both enterprise and no-subscription Proxmox repositories are active. Re-run with --repo enterprise or --repo no-subscription."
    elif [ "$enterprise" -eq 1 ]; then
        PVE_REPO="enterprise"
    elif [ "$no_subscription" -eq 1 ]; then
        PVE_REPO="no-subscription"
    else
        die "could not detect an active Proxmox package repository. Re-run with --repo enterprise or --repo no-subscription."
    fi
}

write_pve9_repo() {
    local pve_uri
    local component
    local sources_file

    if [ "$PVE_REPO" = "enterprise" ]; then
        pve_uri="https://enterprise.proxmox.com/debian/pve"
        component="pve-enterprise"
        sources_file="/etc/apt/sources.list.d/pve-enterprise.sources"
    else
        pve_uri="http://download.proxmox.com/debian/pve"
        component="pve-no-subscription"
        sources_file="/etc/apt/sources.list.d/proxmox.sources"
    fi

    disable_repo_files_by_uri 'proxmox\.com/debian/pve'
    comment_matching_repo_lines /etc/apt/sources.list 'proxmox\.com/debian/pve'

    backup_once "$sources_file"
    cat > "$sources_file" <<EOF
Types: deb
URIs: ${pve_uri}
Suites: trixie
Components: ${component}
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
    chmod 644 "$sources_file"
    echo "Configured PVE 9 repository: $sources_file ($PVE_REPO)"
}

install_cuda13_keyring() {
    local keyring_deb
    local cuda_uri="https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64"
    local cuda_list="/etc/apt/sources.list.d/cuda-debian13-x86_64.list"

    if ! command -v curl >/dev/null 2>&1; then
        apt update
        apt install -y ca-certificates curl
    fi

    keyring_deb="$(mktemp "${TMPDIR:-/tmp}/cuda-keyring.XXXXXX.deb")"
    curl -fsSL \
        "${cuda_uri}/cuda-keyring_1.1-1_all.deb" \
        -o "$keyring_deb"

    rm -f /etc/apt/sources.list.d/cuda-debian*-x86_64.list
    rm -f /etc/apt/sources.list.d/cuda-debian*-x86_64.sources
    disable_repo_files_by_uri 'developer\.download\.nvidia\.com/compute/cuda/repos'
    comment_matching_repo_lines /etc/apt/sources.list 'developer\.download\.nvidia\.com/compute/cuda/repos'

    DEBIAN_FRONTEND=noninteractive dpkg -i "$keyring_deb"
    rm -f "$keyring_deb"

    # The repository file is a dpkg conffile.  If it was removed previously,
    # dpkg will keep it removed when the same keyring version is reinstalled.
    # Write it explicitly so the CUDA repository is always available.
    printf 'deb [signed-by=/usr/share/keyrings/cuda-archive-keyring.gpg] %s/ /\n' \
        "$cuda_uri" > "$cuda_list"
    chmod 644 "$cuda_list"

    echo "Configured CUDA repository for Debian 13."
}

update_docker_repos() {
    local file
    local changed=0

    for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
        [ -e "$file" ] || continue
        if grep -qE '^[[:space:]]*deb[[:space:]].*download\.docker\.com/linux/debian' "$file"; then
            if grep -q 'bookworm' "$file"; then
                backup_once "$file"
                sed -i -E '/download\.docker\.com\/linux\/debian/ s/bookworm/trixie/g' "$file"
                changed=1
                echo "Updated Docker repository in $file"
            fi
        fi
    done

    for file in /etc/apt/sources.list.d/*.sources; do
        [ -e "$file" ] || continue
        if grep -q 'download.docker.com/linux/debian' "$file" && grep -q 'bookworm' "$file"; then
            backup_once "$file"
            sed -i -E '/^Suites:/ s/bookworm/trixie/g' "$file"
            changed=1
            echo "Updated Docker repository in $file"
        fi
    done

    if [ "$changed" -eq 0 ]; then
        echo "No Docker repository needed a suite update."
    fi
}

scan_unknown_bookworm_repos() {
    local output
    local file
    local -a files

    files=()
    [ -f /etc/apt/sources.list ] && files+=(/etc/apt/sources.list)
    for file in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [ -e "$file" ] && files+=("$file")
    done
    [ "${#files[@]}" -gt 0 ] || return 0

    output="$(grep -nE '^[[:space:]]*(deb(-src)?[[:space:]].*bookworm|Suites:[[:space:]]*.*bookworm)' "${files[@]}" 2>/dev/null || true)"
    [ -n "$output" ] || return 0

    echo "Active repository entries still referencing bookworm:"
    printf '%s\n' "$output"
    return 1
}

prepare() {
    local pve_ver
    local latest_kernel
    local candidate
    local reply

    require_tty
    load_state

    if [ "$STAGE" = "reboot-required" ]; then
        die "PVE 9 packages are already installed. Reboot, then run '$SCRIPT_PATH host-nvidia'."
    fi
    if [ "$STAGE" = "containers-ready" ] || [ "$STAGE" = "done" ] || [ "$STAGE" = "containers-partial" ]; then
        die "the host upgrade stage is already complete. Run '$SCRIPT_PATH containers'."
    fi

    pve_ver="$(pve_version)"
    [ -n "$pve_ver" ] || die "could not determine the Proxmox VE version"

    case "$pve_ver" in
        8.4|8.4.*)
            ;;
        8.*)
            die "PVE $pve_ver is too old. Update to the latest 8.4 release first."
            ;;
        9.*)
            die "this host is already running PVE $pve_ver. Run '$SCRIPT_PATH host-nvidia' after rebooting."
            ;;
        *)
            die "unsupported Proxmox VE version: $pve_ver"
            ;;
    esac

    if [ -f /var/run/reboot-required ]; then
        die "a reboot is already pending. Reboot, then re-run '$SCRIPT_PATH prepare'."
    fi

    # shellcheck source=/dev/null
    echo "Proxmox VE $pve_ver detected on Debian $(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-unknown}")."

    if [ "$BACKUPS_CONFIRMED" -ne 1 ]; then
        echo "This operation can make the host unbootable. Tested backups of every VM and container are required."
        read -r -p "Type 'backups-confirmed' if tested backups exist: " reply
        [ "$reply" = "backups-confirmed" ] || die "aborted"
    fi

    check_disk_space
    check_ceph
    check_cluster
    check_running_vms

    if [ -z "$BACKUP_PATH" ] || [ ! -f "$BACKUP_PATH" ]; then
        create_host_backup
    else
        echo "Using existing configuration backup: $BACKUP_PATH"
    fi

    stop_running_containers

    echo "Updating PVE 8 packages before the release upgrade..."
    apt update
    # Keep headers for the default kernel present so DKMS can build for any
    # kernel installed by this update.
    apt install -y proxmox-default-headers || warn "could not install proxmox-default-headers yet"
    apt dist-upgrade

    if [ -f /var/run/reboot-required ]; then
        state_set STAGE pve8-reboot-required
        echo "A reboot is required after the PVE 8 update."
        echo "Reboot, then run: $SCRIPT_PATH prepare"
        return 0
    fi

    latest_kernel="$(latest_installed_kernel)"
    if [ -n "$latest_kernel" ] && [ "$latest_kernel" != "$(uname -r)" ]; then
        state_set STAGE pve8-reboot-required
        echo "A newer kernel ($latest_kernel) is installed but the running kernel is $(uname -r)."
        echo "Reboot, then run: $SCRIPT_PATH prepare"
        return 0
    fi

    pve_ver="$(pve_version)"
    case "$pve_ver" in
        8.4|8.4.*) ;;
        *) die "expected PVE 8.4 after updating, but found $pve_ver" ;;
    esac

    run_pve8to9_checker

    ensure_proxmox_keyring
    ensure_helpers

    # Detect the Proxmox repository before changing any sources, so a
    # detection failure leaves the PVE 8 apt configuration intact.
    detect_pve_repo

    echo "Switching Debian sources to trixie..."
    bash "$HELPER_DIR/update_debian_sources.sh" --suite trixie

    write_pve9_repo

    echo "Switching the host CUDA repository to Debian 13..."
    install_cuda13_keyring

    update_docker_repos
    if ! scan_unknown_bookworm_repos; then
        if [ "$ACCEPT_UNKNOWN_REPOS" -ne 1 ]; then
            die "update or disable the repositories above, or pass --accept-unknown-repos after reviewing them."
        fi
        warn "continuing with unknown bookworm repository entries"
    fi

    echo "Verifying that the PVE 9 repository is visible..."
    apt update
    candidate="$(apt-cache policy proxmox-ve | awk '/Candidate:/ {print $2; exit}')"
    case "$candidate" in
        9.*)
            echo "proxmox-ve candidate: $candidate"
            ;;
        *)
            die "proxmox-ve candidate is '${candidate:-none}', not PVE 9. Fix the repositories and re-run prepare."
            ;;
    esac

    echo "About to run 'apt dist-upgrade' to Proxmox VE 9 / Debian 13."
    echo "Approve config-file prompts carefully. 'q' exits apt-listchanges."
    read -r -p "Type 'dist-upgrade' to continue: " reply
    [ "$reply" = "dist-upgrade" ] || die "aborted"

    apt dist-upgrade

    pve_ver="$(pve_version)"
    case "$pve_ver" in
        9.*)
            echo "Proxmox VE $pve_ver is installed."
            ;;
        *)
            die "expected PVE 9 after dist-upgrade, but found ${pve_ver:-unknown}. Review the log: $LOG_FILE"
            ;;
    esac

    if command -v pve8to9 >/dev/null 2>&1; then
        echo "Running the post-upgrade pve8to9 check..."
        set +e
        pve8to9 --full
        echo "pve8to9 exit code: $?"
        set -e
    fi

    state_set STAGE reboot-required
    echo "Host upgrade prepared successfully. Reboot now."
    echo "After reboot, run: $SCRIPT_PATH host-nvidia"
    echo "Log: $LOG_FILE"
}

host_nvidia() {
    local pve_ver

    require_tty
    load_state

    pve_ver="$(pve_version)"
    case "$pve_ver" in
        9.*)
            ;;
        *)
            die "expected PVE 9, but found ${pve_ver:-unknown}. Finish '$SCRIPT_PATH prepare' and reboot first."
            ;;
    esac

    if [ -f /var/run/reboot-required ]; then
        die "a reboot is still pending. Reboot, then re-run '$SCRIPT_PATH host-nvidia'."
    fi

    if [ "$STAGE" = "done" ]; then
        die "the upgrade is already complete."
    fi
    if [ "$STAGE" = "containers-ready" ]; then
        die "the host NVIDIA stage is already complete. Reboot, then run '$SCRIPT_PATH containers'."
    fi
    if [ "$STAGE" = "containers-partial" ]; then
        die "the host upgrade is already complete. Run '$SCRIPT_PATH containers' to retry the failed containers."
    fi

    ensure_helpers
    bash "$HELPER_DIR/install_nvidia_driver_on_host.sh"

    if command -v dkms >/dev/null 2>&1; then
        if ! dkms status | grep -q "nvidia.*$(uname -r).*installed"; then
            die "no NVIDIA DKMS module was built for kernel $(uname -r). Check dkms status and install proxmox-headers-$(uname -r) if this is an opt-in kernel."
        fi
    fi

    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
        echo "nvidia-smi is working."
    else
        warn "nvidia-smi is not working yet; reboot and verify it before running the containers stage."
    fi

    state_set STAGE containers-ready
    echo "Host NVIDIA driver installation finished. Reboot the host."
    echo "After reboot, run: $SCRIPT_PATH containers"
    echo "Log: $LOG_FILE"
}

container_os_id() {
    local id="$1"
    # shellcheck disable=SC2016
    pct exec "$id" -- sh -c '. /etc/os-release 2>/dev/null; printf "%s" "${ID:-}"' 2>/dev/null || true
}

container_codename() {
    local id="$1"
    # shellcheck disable=SC2016
    pct exec "$id" -- sh -c '. /etc/os-release 2>/dev/null; printf "%s" "${VERSION_CODENAME:-}"' 2>/dev/null || true
}

container_version_id() {
    local id="$1"
    # shellcheck disable=SC2016
    pct exec "$id" -- sh -c '. /etc/os-release 2>/dev/null; printf "%s" "${VERSION_ID:-}"' 2>/dev/null || true
}

wait_for_container_running() {
    local id="$1"
    for _ in $(seq 1 60); do
        if pct status "$id" 2>/dev/null | grep -q running; then
            return 0
        fi
        sleep 2
    done
    return 1
}

prepare_container_sources() {
    local id="$1"

    pct exec "$id" -- bash -s <<'CONTAINER_PREP'
set -e
bash /tmp/update_debian_sources.sh --suite trixie

for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [ -f "$file" ] || continue
    if grep -qE '^[[:space:]]*deb[[:space:]].*download\.docker\.com/linux/debian' "$file"; then
        sed -i -E '/download\.docker\.com\/linux\/debian/ s/bookworm/trixie/g' "$file"
    fi
done
for file in /etc/apt/sources.list.d/*.sources; do
    [ -f "$file" ] || continue
    if grep -q 'download.docker.com/linux/debian' "$file"; then
        sed -i -E '/^Suites:/ s/bookworm/trixie/g' "$file"
    fi
done

rm -f /etc/apt/sources.list.d/cuda-debian*-x86_64.list
rm -f /etc/apt/sources.list.d/cuda-debian*-x86_64.sources

remaining="$(grep -RInE '^[[:space:]]*(deb(-src)?[[:space:]].*bookworm|Suites:[[:space:]]*.*bookworm)' \
    /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true)"
if [ -n "$remaining" ]; then
    echo "Active repository entries still referencing bookworm:"
    printf '%s\n' "$remaining"
    exit 42
fi

apt update
CONTAINER_PREP
}

upgrade_container() {
    local id="$1"
    local os_id
    local codename
    local snapshot
    local new_version
    local has_gpu=0

    if ! pct status "$id" | grep -q running; then
        echo "Skipping container $id: not running."
        return 2
    fi

    os_id="$(container_os_id "$id")"
    codename="$(container_codename "$id")"

    if [ "$os_id" != "debian" ]; then
        echo "Skipping container $id: OS is '${os_id:-unknown}', not Debian."
        return 2
    fi
    if [ "$codename" = "trixie" ]; then
        if pct exec "$id" -- test -e /dev/nvidia0 2>/dev/null; then
            if ! pct exec "$id" -- nvidia-smi >/dev/null 2>&1; then
                echo "Error: container $id is Debian 13 but nvidia-smi is failing. Install the NVIDIA driver inside it manually, or roll back to the pre-upgrade snapshot." >&2
                return 1
            fi
        fi
        echo "Skipping container $id: already Debian 13."
        return 0
    fi
    if [ "$codename" != "bookworm" ]; then
        echo "Skipping container $id: Debian codename is '${codename:-unknown}', not bookworm."
        return 2
    fi

    if pct exec "$id" -- test -e /dev/nvidia0 2>/dev/null; then
        has_gpu=1
    fi

    echo "Upgrading container $id (Debian 12 -> 13)..."
    if [ "$NO_SNAPSHOT" -eq 0 ]; then
        snapshot="pre-debian13-$(date +%Y%m%d-%H%M%S)-${id}"
        if ! pct snapshot "$id" "$snapshot" --description "Before Debian 13 upgrade"; then
            echo "Error: could not create a snapshot for container $id. Use --no-snapshot only if you have a separate tested backup." >&2
            return 1
        fi
        echo "Snapshot: $snapshot"
        echo "Rollback with: pct rollback $id $snapshot"
    else
        warn "snapshots disabled for container $id"
    fi

    if ! pct push "$id" "$HELPER_DIR/update_debian_sources.sh" /tmp/update_debian_sources.sh --perms 0755; then
        echo "Error: could not push the sources helper to container $id." >&2
        return 1
    fi
    if ! pct push "$id" "$HELPER_DIR/install_nvidia_driver_on_container.sh" /tmp/install_nvidia_driver_on_container.sh --perms 0755; then
        echo "Error: could not push the driver helper to container $id." >&2
        return 1
    fi

    set +e
    prepare_container_sources "$id"
    local rc=$?
    set -e
    if [ "$rc" -eq 42 ]; then
        echo "Skipping container $id: unknown bookworm repositories remain. Update or disable them, then re-run." >&2
        return 1
    elif [ "$rc" -ne 0 ]; then
        echo "Error: source preparation failed for container $id." >&2
        return 1
    fi

    if ! pct exec "$id" -- env DEBIAN_FRONTEND=noninteractive apt-get -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        full-upgrade; then
        echo "Error: apt full-upgrade failed for container $id." >&2
        return 1
    fi

    if [ "$has_gpu" -eq 1 ]; then
        if ! pct exec "$id" -- bash /tmp/install_nvidia_driver_on_container.sh --no-reboot; then
            echo "Error: NVIDIA driver installation failed for container $id." >&2
            return 1
        fi
    else
        echo "No NVIDIA device found in container $id; skipping driver installation."
    fi

    if ! pct reboot "$id"; then
        echo "Error: could not reboot container $id." >&2
        return 1
    fi
    sleep 2
    if ! wait_for_container_running "$id"; then
        echo "Error: container $id did not come back after reboot." >&2
        return 1
    fi

    new_version="$(container_version_id "$id")"
    case "$new_version" in
        13*)
            echo "Container $id is now Debian $new_version."
            ;;
        *)
            echo "Error: container $id reports Debian version '${new_version:-unknown}', not 13." >&2
            return 1
            ;;
    esac

    if [ "$has_gpu" -eq 1 ]; then
        if ! pct exec "$id" -- nvidia-smi >/dev/null 2>&1; then
            echo "Error: nvidia-smi failed inside container $id." >&2
            return 1
        fi
        echo "GPU check passed inside container $id."
    fi

    return 0
}

containers() {
    local pve_ver
    local id
    local status
    local rc
    local failed=0
    local -a ids

    require_tty
    load_state

    pve_ver="$(pve_version)"
    case "$pve_ver" in
        9.*)
            ;;
        *)
            die "expected PVE 9, but found ${pve_ver:-unknown}. Finish the host upgrade first."
            ;;
    esac

    if [ -f /var/run/reboot-required ]; then
        die "a reboot is still pending. Reboot, then re-run '$SCRIPT_PATH containers'."
    fi

    if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi >/dev/null 2>&1; then
        die "nvidia-smi is not working on the host. Run '$SCRIPT_PATH host-nvidia', reboot, and verify nvidia-smi before upgrading containers."
    fi

    ensure_helpers
    if ! start_recorded_containers; then
        failed=1
    fi

    mapfile -t ids < <(pct list | awk 'NR > 1 {print $1}')
    if [ "${#ids[@]}" -eq 0 ]; then
        echo "No containers found."
        state_set STOPPED_CONTAINERS ""
        state_set STAGE "done"
        return 0
    fi

    for id in "${ids[@]}"; do
        status="$(pct status "$id" | awk '{print $2}')"
        if [ "$status" != "running" ]; then
            echo "Skipping container $id: status is $status."
            continue
        fi

        set +e
        upgrade_container "$id"
        rc=$?
        set -e
        if [ "$rc" -eq 2 ]; then
            continue
        elif [ "$rc" -ne 0 ]; then
            failed=1
        fi
    done

    if [ "$failed" -ne 0 ]; then
        state_set STAGE containers-partial
        echo "One or more containers failed. Review the output and roll back failed containers with 'pct rollback <id> <snapshot>'." >&2
        echo "Log: $LOG_FILE"
        exit 1
    fi

    state_set STOPPED_CONTAINERS ""
    state_set STAGE "done"
    echo "Container stage finished."
    echo "Snapshots were kept for manual verification. Remove them with 'pct delsnapshot <id> <snapshot>' after testing."
    echo "Log: $LOG_FILE"
}

check() {
    local pve_ver
    local file
    local id
    local codename
    local -a ids

    load_state
    pve_ver="$(pve_version)"

    echo "=== Proxmox VE upgrade check ==="
    echo "Stage: ${STAGE:-not started}"
    echo "PVE version: ${pve_ver:-unknown}"
    echo "Running kernel: $(uname -r)"
    if [ -f /var/run/reboot-required ]; then
        echo "Reboot required: yes"
    else
        echo "Reboot required: no"
    fi
    echo "Free space on /: $(df -Ph / | awk 'NR == 2 {print $4}') available"
    echo

    echo "Active source files:"
    for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [ -e "$file" ] || continue
        echo "  $file"
    done
    echo

    echo "Known repository state:"
    grep -RhsE '^[[:space:]]*(deb(-src)?[[:space:]]|Types:|URIs:|Suites:|Components:)' \
        /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null \
        | sed 's/^/  /' || true
    echo

    if grep -q 'developer\.download\.nvidia\.com/compute/cuda/repos' \
        /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null; then
        echo "NVIDIA CUDA repository: configured"
    elif dpkg -s nvidia-kernel-dkms >/dev/null 2>&1 || dpkg -s nvidia-driver-cuda >/dev/null 2>&1; then
        echo "NVIDIA CUDA repository: not configured (NVIDIA packages are installed)"
    else
        echo "NVIDIA CUDA repository: not configured"
    fi
    echo

    if [ -f /etc/pve/corosync.conf ] || { command -v pvecm >/dev/null 2>&1 && pvecm status >/dev/null 2>&1; }; then
        echo "Cluster:"
        pvecm status 2>&1 | sed 's/^/  /' || true
        echo
    else
        echo "Cluster: standalone node"
        echo
    fi

    if [ -f /etc/ceph/ceph.conf ] || [ -f /etc/pve/ceph.conf ]; then
        echo "Ceph: configured (this script will refuse to upgrade it)"
    else
        echo "Ceph: no cluster detected"
    fi
    echo

    echo "Containers:"
    pct list 2>/dev/null | sed 's/^/  /' || true
    mapfile -t ids < <(pct list 2>/dev/null | awk 'NR > 1 && $2 == "running" {print $1}')
    for id in "${ids[@]}"; do
        codename="$(container_codename "$id")"
        echo "  $id: Debian codename ${codename:-unknown}"
    done
    echo

    echo "Unknown bookworm repository entries:"
    scan_unknown_bookworm_repos || true
    echo

    if command -v pve8to9 >/dev/null 2>&1; then
        echo "Running pve8to9 --full..."
        set +e
        pve8to9 --full
        echo "pve8to9 exit code: $?"
        set -e
    else
        echo "pve8to9: not installed"
    fi

    echo
    echo "No host or apt configuration changes were made."
}

main() {
    local command

    if [ "$#" -eq 0 ]; then
        usage
        exit 1
    fi

    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
    esac

    command="$1"
    shift

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --backups-confirmed)
                BACKUPS_CONFIRMED=1
                shift
                ;;
            --allow-cluster)
                ALLOW_CLUSTER=1
                shift
                ;;
            --accept-unknown-repos)
                ACCEPT_UNKNOWN_REPOS=1
                shift
                ;;
            --allow-running-vms)
                ALLOW_RUNNING_VMS=1
                shift
                ;;
            --force-low-space)
                FORCE_LOW_SPACE=1
                shift
                ;;
            --no-snapshot)
                NO_SNAPSHOT=1
                shift
                ;;
            --repo)
                [ "$#" -ge 2 ] || die "--repo requires a value"
                PVE_REPO="$2"
                shift 2
                ;;
            --repo=*)
                PVE_REPO="${1#*=}"
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

    if [ -n "$PVE_REPO" ]; then
        case "$PVE_REPO" in
            enterprise|no-subscription) ;;
            *) die "--repo must be 'enterprise' or 'no-subscription'" ;;
        esac
    fi

    require_root
    require_script_file
    setup_paths
    setup_logging

    case "$command" in
        check)
            check
            ;;
        prepare)
            prepare
            ;;
        host-nvidia)
            host_nvidia
            ;;
        containers)
            containers
            ;;
        *)
            die "unknown command: $command"
            ;;
    esac
}

main "$@"
