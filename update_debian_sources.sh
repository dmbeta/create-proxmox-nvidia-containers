#!/usr/bin/env bash
#
# Ensure the Debian archive sources include the non-free and non-free-firmware
# components.  Handles both the legacy /etc/apt/sources.list format and the
# deb822 /etc/apt/sources.list.d/*.sources format used by newer Proxmox and
# Debian installations.
#
# Usage:
#   update_debian_sources.sh [--suite <codename>]
#
# --suite replaces the "bookworm" codename with the given codename in Debian
# archive stanzas only.  This is used by the PVE 8 -> 9 upgrade helper.

set -euo pipefail

SUITE=""
ROOT=""

usage() {
    cat <<'EOF'
Usage: update_debian_sources.sh [--suite <codename>] [--root <dir>]

Options:
  --suite <codename>  Replace "bookworm" with <codename> in Debian archive
                      stanzas (for example: --suite trixie).
  --root <dir>        Operate on <dir>/etc/apt instead of /etc/apt.  Intended
                      for tests only.
  -h, --help          Show this help.
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --suite)
            [ "$#" -ge 2 ] || die "--suite requires a codename"
            SUITE="$2"
            shift 2
            ;;
        --suite=*)
            SUITE="${1#*=}"
            shift
            ;;
        --root)
            [ "$#" -ge 2 ] || die "--root requires a directory"
            ROOT="$2"
            shift 2
            ;;
        --root=*)
            ROOT="${1#*=}"
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

if [ -n "$SUITE" ] && ! [[ "$SUITE" =~ ^[a-z][a-z0-9-]*$ ]]; then
    die "invalid suite codename: $SUITE"
fi

if [ -n "$ROOT" ]; then
    ROOT="${ROOT%/}"
else
    ROOT=""
fi

if [ -z "$ROOT" ] && [ "$(id -u)" -ne 0 ]; then
    die "this script requires root privileges. Please run with 'sudo'."
fi

APT_DIR="${ROOT}/etc/apt"
SOURCES_LIST="${APT_DIR}/sources.list"
SOURCES_DIR="${APT_DIR}/sources.list.d"

CHANGED=0

# Return true if the line points at a Debian archive.
is_debian_archive_line() {
    [[ "$1" =~ (deb\.debian\.org|security\.debian\.org|ftp\.debian\.org) ]]
}

# Return true if the line already contains the given component as a token.
has_component() {
    local line="$1"
    local component="$2"
    [[ "$line" =~ (^|[[:space:]])${component}([[:space:]]|$) ]]
}

# Back up a file once.  Keeping the first backup is intentional: repeated runs
# must not overwrite the original file with an already-modified version.
backup_file() {
    local file="$1"
    if [ ! -e "${file}.bak" ]; then
        cp -p "$file" "${file}.bak"
        echo "Backed up $file to ${file}.bak"
    fi
}

process_legacy_file() {
    local file="$1"
    local tmp
    local line

    tmp="$(mktemp "${TMPDIR:-/tmp}/update-debian-sources.XXXXXX")"
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^[[:space:]]*deb(-src)?[[:space:]] ]] && is_debian_archive_line "$line"; then
            if [ -n "$SUITE" ]; then
                line="${line//bookworm/$SUITE}"
            fi
            if ! has_component "$line" "non-free"; then
                line="$line non-free"
            fi
            if ! has_component "$line" "non-free-firmware"; then
                line="$line non-free-firmware"
            fi
        fi
        printf '%s\n' "$line" >> "$tmp"
    done < "$file"

    if cmp -s "$file" "$tmp"; then
        echo "No changes needed for $file."
        rm -f "$tmp"
        return 0
    fi

    backup_file "$file"
    cat "$tmp" > "$file"
    rm -f "$tmp"
    CHANGED=1
    echo "Updated $file."
    return 0
}

process_deb822_file() {
    local file="$1"
    local tmp

    tmp="$(mktemp "${TMPDIR:-/tmp}/update-debian-sources.XXXXXX")"
    awk -v target="$SUITE" '
        function has_token(value, token,    parts, count, i) {
            count = split(value, parts, /[ \t]+/)
            for (i = 1; i <= count; i++) {
                if (parts[i] == token) {
                    return 1
                }
            }
            return 0
        }

        function emit_stanza(    i, line, value, has_components) {
            if (n == 0) {
                return
            }

            if (is_debian) {
                has_components = 0
                for (i = 1; i <= n; i++) {
                    line = lines[i]
                    if (target != "" && line ~ /^Suites:/) {
                        gsub(/bookworm/, target, line)
                    }
                    if (line ~ /^Components:/) {
                        has_components = 1
                        value = line
                        sub(/^Components:[ \t]*/, "", value)
                        if (!has_token(value, "non-free")) {
                            line = line " non-free"
                        }
                        if (!has_token(value, "non-free-firmware")) {
                            line = line " non-free-firmware"
                        }
                    }
                    print line
                }
                if (!has_components) {
                    print "Components: main non-free non-free-firmware"
                }
            } else {
                for (i = 1; i <= n; i++) {
                    print lines[i]
                }
            }

            split("", lines)
            n = 0
            is_debian = 0
            in_uris = 0
        }

        BEGIN {
            n = 0
            is_debian = 0
            in_uris = 0
        }

        /^[[:space:]]*$/ {
            emit_stanza()
            print ""
            next
        }

        {
            lines[++n] = $0
            if ($0 ~ /^URIs:/) {
                in_uris = 1
                if ($0 ~ /(deb\.debian\.org|security\.debian\.org|ftp\.debian\.org)/) {
                    is_debian = 1
                }
            } else if (in_uris && $0 ~ /^[ \t]/) {
                if ($0 ~ /(deb\.debian\.org|security\.debian\.org|ftp\.debian\.org)/) {
                    is_debian = 1
                }
            } else {
                in_uris = 0
            }
        }

        END {
            emit_stanza()
        }
    ' "$file" > "$tmp"

    if cmp -s "$file" "$tmp"; then
        echo "No changes needed for $file."
        rm -f "$tmp"
        return 0
    fi

    backup_file "$file"
    cat "$tmp" > "$file"
    rm -f "$tmp"
    CHANGED=1
    echo "Updated $file."
    return 0
}

echo "Checking Debian apt sources under $APT_DIR..."

processed=0

if [ -f "$SOURCES_LIST" ]; then
    processed=1
    process_legacy_file "$SOURCES_LIST"
fi

if [ -d "$SOURCES_DIR" ]; then
    for file in "$SOURCES_DIR"/*.sources; do
        [ -e "$file" ] || continue
        processed=1
        process_deb822_file "$file"
    done
    for file in "$SOURCES_DIR"/*.list; do
        [ -e "$file" ] || continue
        processed=1
        process_legacy_file "$file"
    done
fi

if [ "$processed" -eq 0 ]; then
    die "no apt sources found under $APT_DIR"
fi

if [ "$CHANGED" -eq 1 ]; then
    echo "Remember to run 'apt update' after modifying the apt sources."
else
    echo "All Debian apt sources already have the required components."
fi

exit 0
