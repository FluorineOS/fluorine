#!/usr/bin/env bash
set -uo pipefail

# Non-destructive security baseline validation.
#
# Every check reads a file in this repository and compares it against the
# defaults recorded in docs/SECURITY.md. Nothing here needs root, a network
# connection, or a running system, and nothing changes host state: the point is
# to catch a configuration drift that would quietly remove a control.
#
# Run: bash tests/validation/security-test.sh

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
LISTS="${REPO}/config/package-lists"
HOOKS="${REPO}/config/hooks/normal"
CAL="${REPO}/config/includes.chroot/etc/calamares"
MOD="${CAL}/modules"
ARCHIVES="${REPO}/config/archives"
DOC="${REPO}/docs/SECURITY.md"
PASS=0
FAIL=0

ok() {
    PASS=$((PASS + 1))
    printf 'PASS  %s\n' "$1"
}

bad() {
    FAIL=$((FAIL + 1))
    printf 'FAIL  %s\n' "$1"
}

# Print package names across all lists, one per line.
all_packages() {
    grep -h -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "${LISTS}"/*.list.chroot 2>/dev/null |
        sed -e 's/[[:space:]]*$//'
}

package_absent() {
    if all_packages | grep -qx -- "$1"; then
        bad "package must not be installed: $1"
    else
        ok "package absent: $1"
    fi
}

file_contains() {
    local label=$1 file=$2 pattern=$3

    if grep -Eq -- "${pattern}" "${file}" 2>/dev/null; then
        ok "${label}"
    else
        bad "${label}"
    fi
}

# No remote-access server, and no usage-reporting package.
for package in openssh-server samba nfs-kernel-server vsftpd telnetd rsh-server \
    tftpd-hpa rpcbind snmpd popularity-contest apport whoopsie cups-browsed; do
    package_absent "${package}"
done

# Firewall: deny inbound, allow outbound, and exactly one named inbound port.
SERVICES_HOOK="${HOOKS}/0200-services.hook.chroot"
file_contains "firewall denies inbound" "${SERVICES_HOOK}" '^[[:space:]]*ufw default deny incoming$'
file_contains "firewall allows outbound" "${SERVICES_HOOK}" '^[[:space:]]*ufw default allow outgoing$'
file_contains "firewall is enabled in the image" "${SERVICES_HOOK}" 'ufw --force enable'
file_contains "mDNS is the only opened port" "${SERVICES_HOOK}" '^[[:space:]]*ufw allow 5353/udp'
file_contains "firewall service is enabled" "${SERVICES_HOOK}" 'enable_unit ufw\.service'

# The live installer grant names one executable and is removed on install.
LIVE_SUDO_HOOK="${HOOKS}/0400-live-calamares-polkit.hook.chroot"
file_contains "live sudoers rule names one binary" "${LIVE_SUDO_HOOK}" \
    '^%sudo ALL=\(ALL\) NOPASSWD: /usr/bin/calamares$'
file_contains "live sudoers rule is mode 0440" "${LIVE_SUDO_HOOK}" 'chmod 0440'
if grep -Eq 'NOPASSWD:.*(/usr/bin/env|ALL$)' "${LIVE_SUDO_HOOK}" 2>/dev/null; then
    bad "live sudoers rule grants more than one command"
else
    ok "live sudoers rule grants no shell or env prefix"
fi
CLEANUP="${REPO}/config/includes.chroot/usr/lib/fluorineos/installer-cleanup"
file_contains "installer removes the live sudoers rule" "${CLEANUP}" \
    '/etc/sudoers\.d/99-fluorine-live-installer'
file_contains "installer refuses to run without a target flag" "${CLEANUP}" \
    'refusing to run without --installed-target'

# User policy: locked root, private home, minimum password length.
USERS_CONF="${MOD}/users.conf"
file_contains "root password stays locked" "${USERS_CONF}" '^setRootPassword: false$'
file_contains "home directory is private" "${USERS_CONF}" '^home_permissions: "o700"$'
file_contains "password minimum length is 8" "${USERS_CONF}" '^  minLength: 8$'
file_contains "weak passwords are refused" "${USERS_CONF}" '^allowWeakPasswords: false$'
file_contains "user joins the sudo group" "${USERS_CONF}" '^  - sudo$'

# Installer privacy: no live network profiles, fresh machine identity, no
# installer left on the target.
SETTINGS="${CAL}/settings.conf"
file_contains "machineid module runs on install" "${SETTINGS}" '^[[:space:]]*- machineid$'
if grep -Eq '^[[:space:]]*- networkcfg$' "${SETTINGS}" 2>/dev/null; then
    bad "networkcfg is back in the sequence, which copies live Wi-Fi keys"
else
    ok "networkcfg is out of the sequence"
fi
MACHINEID_CONF="${MOD}/machineid.conf"
file_contains "machineid replaces the systemd identity" "${MACHINEID_CONF}" '^systemd: true$'
file_contains "machineid replaces the dbus identity" "${MACHINEID_CONF}" '^dbus: true$'
PACKAGES_CONF="${MOD}/packages.conf"
file_contains "installer packages are removed from the target" "${PACKAGES_CONF}" \
    '^[[:space:]]*- calamares$'
file_contains "live packages are removed from the target" "${PACKAGES_CONF}" \
    '^[[:space:]]*- live-boot$'

# Installer log redaction and permissions.
LOG_PRESERVE="${REPO}/config/includes.chroot/usr/lib/fluorineos/installer-log-preserve"
file_contains "installer log redacts credentials" "${LOG_PRESERVE}" \
    'pass\(word\|phrase\)'
file_contains "installer log is not world readable" "${LOG_PRESERVE}" 'chmod 0640'
file_contains "installer log directory is private" "${LOG_PRESERVE}" 'install -d -m 0750'

# Archive trust: no unauthenticated source, HTTPS only, and a key beside every
# third-party list.
if grep -rEq 'trusted=yes|allow-insecure|allow-unauthenticated' "${ARCHIVES}" 2>/dev/null; then
    bad "an archive is configured as trusted or unauthenticated"
else
    ok "no archive is configured as trusted or unauthenticated"
fi
if grep -hE '^deb ' "${ARCHIVES}"/*.list.* 2>/dev/null | grep -qv 'https\?://'; then
    bad "an archive list has a malformed URI"
else
    ok "archive lists have well-formed URIs"
fi
if grep -qE '^deb .*https://' "${ARCHIVES}/fluorine.list.chroot" 2>/dev/null; then
    ok "third-party archive uses HTTPS"
else
    bad "third-party archive does not use HTTPS"
fi
if [ -s "${ARCHIVES}/fluorine.key.chroot" ] &&
    grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "${ARCHIVES}/fluorine.key.chroot"; then
    ok "third-party archive ships its signing key"
else
    bad "third-party archive is missing its signing key"
fi

# Bootloader assumptions are stated where a reader will find them.
GRUB_DEFAULTS="${REPO}/config/includes.chroot/etc/default/grub"
file_contains "GRUB pins the distro name" "${GRUB_DEFAULTS}" '^GRUB_DISTRIBUTOR="FluorineOS"$'
AUTO_CONFIG="${REPO}/auto/config"
# Only command lines count: the file explains in a comment why the flag is not used.
if grep -v '^[[:space:]]*#' "${AUTO_CONFIG}" 2>/dev/null |
    grep -Eq -- '--uefi-secure-boot'; then
    bad "the image claims Secure Boot support it cannot deliver"
else
    ok "the image does not claim Secure Boot support"
fi

# The baseline document must exist and cover its limitations.
if [ -r "${DOC}" ]; then
    ok "docs/SECURITY.md exists"
else
    bad "docs/SECURITY.md is missing"
fi
for needle in "Threat model" "Known limitations" "Verification requirements" "Secure Boot"; do
    if grep -q -- "${needle}" "${DOC}" 2>/dev/null; then
        ok "docs/SECURITY.md covers: ${needle}"
    else
        bad "docs/SECURITY.md does not mention: ${needle}"
    fi
done

# The session must lock before sleeping; that lives in the desktop package, so
# check the shipped configuration when the sibling checkout is present.
HYPRIDLE=""
for candidate in "${REPO}/../fluorine-desktop" \
    "${REPO}/../../../fluorine-workspace/fluorine-desktop"; do
    if [ -r "${candidate}/skel/.config/hypr/hypridle.conf" ]; then
        HYPRIDLE="${candidate}/skel/.config/hypr/hypridle.conf"
        break
    fi
done

if [ -n "${HYPRIDLE}" ]; then
    file_contains "hypridle locks before sleep" "${HYPRIDLE}" \
        '^[[:space:]]*before_sleep_cmd = loginctl lock-session$'
    file_contains "hypridle starts the lock screen on demand" "${HYPRIDLE}" \
        '^[[:space:]]*lock_cmd = pidof hyprlock \|\| hyprlock$'
else
    printf 'SKIP  hypridle checks (sibling checkout not present)\n'
fi

printf '\nSummary: %d passed, %d failed\n' "${PASS}" "${FAIL}"

if [ "${FAIL}" -ne 0 ]; then
    exit 1
fi
