#!/usr/bin/env bash
#
# Fixture tests for update_debian_sources.sh.
#
# These tests do not touch the host apt configuration.  They create a fake
# root under a temporary directory and pass it with --root.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/../update_debian_sources.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-update-debian-sources.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_file_equals() {
    local file="$1"
    local expected="$2"
    expected="${expected%$'\n'}"
    if ! diff -u <(printf '%s\n' "$expected") "$file"; then
        fail "unexpected content in $file"
    fi
}

assert_file_unchanged() {
    local file="$1"
    local expected="$2"
    expected="${expected%$'\n'}"
    if ! diff -u <(printf '%s\n' "$expected") "$file"; then
        fail "$file changed unexpectedly"
    fi
}

make_root() {
    local name="$1"
    local root="${TMP_ROOT}/${name}"
    mkdir -p "${root}/etc/apt/sources.list.d"
    printf '%s\n' "$root"
}

# 1. Legacy sources.list: update only Debian archive lines.
root="$(make_root legacy)"
cat > "${root}/etc/apt/sources.list" <<'EOF'
deb http://deb.debian.org/debian bookworm main non-free-firmware
deb http://deb.debian.org/debian-security bookworm-security main
deb [arch=amd64] https://download.docker.com/linux/debian bookworm stable
deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription
EOF
cp "${root}/etc/apt/sources.list" "${root}/expected-original"

bash "$SCRIPT" --root "$root" --suite trixie >/dev/null

assert_file_equals "${root}/etc/apt/sources.list" \
'deb http://deb.debian.org/debian trixie main non-free-firmware non-free
deb http://deb.debian.org/debian-security trixie-security main non-free non-free-firmware
deb [arch=amd64] https://download.docker.com/linux/debian bookworm stable
deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription
'
assert_file_equals "${root}/etc/apt/sources.list.bak" "$(cat "${root}/expected-original")"

# 2. Deb822 sources: update Debian archive stanzas only.
root="$(make_root deb822)"
cat > "${root}/etc/apt/sources.list.d/debian.sources" <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian/
Suites: bookworm bookworm-updates
Components: main non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security/
Suites: bookworm-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: bookworm
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
cp "${root}/etc/apt/sources.list.d/debian.sources" "${root}/expected-original"

bash "$SCRIPT" --root "$root" --suite trixie >/dev/null

assert_file_equals "${root}/etc/apt/sources.list.d/debian.sources" \
'Types: deb
URIs: http://deb.debian.org/debian/
Suites: trixie trixie-updates
Components: main non-free-firmware non-free
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security/
Suites: trixie-security
Components: main non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: bookworm
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
'
assert_file_equals "${root}/etc/apt/sources.list.d/debian.sources.bak" "$(cat "${root}/expected-original")"

# 3. Running the script again must be idempotent and must not overwrite the
#    original .bak file.
before_checksum="$(cksum "${root}/etc/apt/sources.list.d/debian.sources.bak")"
bash "$SCRIPT" --root "$root" --suite trixie >/dev/null
after_checksum="$(cksum "${root}/etc/apt/sources.list.d/debian.sources.bak")"
[ "$before_checksum" = "$after_checksum" ] || fail "the .bak file was overwritten on the second run"

# 4. A Debian stanza without a Components field gets one.
root="$(make_root no-components)"
cat > "${root}/etc/apt/sources.list.d/debian.sources" <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: bookworm
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

bash "$SCRIPT" --root "$root" --suite trixie >/dev/null

assert_file_equals "${root}/etc/apt/sources.list.d/debian.sources" \
'Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
Components: main non-free non-free-firmware
'

# 5. Non-Debian deb822 repositories must not be rewritten.
root="$(make_root third-party)"
cat > "${root}/etc/apt/sources.list.d/docker.sources" <<'EOF'
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: bookworm
Components: stable
Signed-By: /usr/share/keyrings/docker-archive-keyring.gpg
EOF
cp "${root}/etc/apt/sources.list.d/docker.sources" "${root}/expected-original"

bash "$SCRIPT" --root "$root" --suite trixie >/dev/null

assert_file_unchanged "${root}/etc/apt/sources.list.d/docker.sources" "$(cat "${root}/expected-original")"

# 6. Legacy .list files in sources.list.d must be handled too, while
#    third-party .list files stay untouched.
root="$(make_root list-in-sources-d)"
cat > "${root}/etc/apt/sources.list.d/debian.list" <<'EOF'
deb http://deb.debian.org/debian bookworm main
deb [arch=amd64] https://download.docker.com/linux/debian bookworm stable
EOF

bash "$SCRIPT" --root "$root" --suite trixie >/dev/null

assert_file_equals "${root}/etc/apt/sources.list.d/debian.list" \
'deb http://deb.debian.org/debian trixie main non-free non-free-firmware
deb [arch=amd64] https://download.docker.com/linux/debian bookworm stable
'

echo "All update_debian_sources.sh tests passed."
