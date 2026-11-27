#!/usr/bin/env bash
set -uo pipefail

# Non-destructive hardware support validation.
#
# Every check reads files in this repository and compares them against the
# package sets and service names documented in docs/HARDWARE.md. Nothing here
# needs root, a network connection, a package manager, or hardware: the point
# is to catch a package list that silently lost a firmware family, a duplicate
# entry across lists, or a service that nothing enables.
#
# Package availability in Debian trixie was verified against the trixie
# indexes when the list was written; this suite does not re-fetch them.
#
# Run: bash tests/validation/hardware-test.sh

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
LISTS="${REPO}/config/package-lists"
HARDWARE="${LISTS}/hardware.list.chroot"
SERVICES="${REPO}/config/hooks/normal/0200-services.hook.chroot"
DOC="${REPO}/docs/HARDWARE.md"
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

# Print every package name across all lists, one per line.
all_packages() {
    grep -h -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "${LISTS}"/*.list.chroot 2>/dev/null |
        sed -e 's/[[:space:]]*$//'
}

has_package() {
    all_packages | grep -qx -- "$1"
}

list_packages() {
    grep -h -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$1" 2>/dev/null |
        sed -e 's/[[:space:]]*$//'
}

# A hardware list exists and holds the firmware families the free drivers need.
if [ -r "${HARDWARE}" ]; then
    ok "hardware.list.chroot exists"
else
    bad "hardware.list.chroot is missing"
fi

required_firmware=(
    firmware-linux
    firmware-intel-graphics
    firmware-intel-sound
    firmware-sof-signed
    firmware-nvidia-graphics
    firmware-iwlwifi
    firmware-atheros
    firmware-realtek
    firmware-brcm80211
    firmware-mediatek
)

for package in "${required_firmware[@]}"; do
    if has_package "${package}"; then
        ok "firmware family present: ${package}"
    else
        bad "firmware family missing: ${package}"
    fi
done

# CPU microcode for both vendors.
for package in intel-microcode amd64-microcode; do
    if has_package "${package}"; then
        ok "microcode present: ${package}"
    else
        bad "microcode missing: ${package}"
    fi
done

# Integration packages documented in docs/HARDWARE.md.
required_integration=(
    wireless-regdb
    wpasupplicant
    mesa-va-drivers
    intel-media-va-driver
    vainfo
    pipewire-alsa
    udisks2
    exfatprogs
    power-profiles-daemon
    upower
    brightness-udev
    switcheroo-control
    qt6-wayland
    cups
    cups-pk-helper
    avahi-daemon
    libnss-mdns
    orca
)

missing_integration=()
for package in "${required_integration[@]}"; do
    if ! has_package "${package}"; then
        missing_integration+=("${package}")
    fi
done

if [ "${#missing_integration[@]}" -eq 0 ]; then
    ok "integration packages present (${#required_integration[@]})"
else
    bad "integration packages missing: ${missing_integration[*]}"
fi

# No package may be listed twice: a duplicate hides which subsystem owns it and
# makes a later removal look safe when it is not.
duplicates=$(all_packages | sort | uniq -d)

if [ -z "${duplicates}" ]; then
    ok "no package is listed twice"
else
    bad "duplicate package entries: $(printf '%s' "${duplicates}" | tr '\n' ' ')"
fi

# A power manager that fights power-profiles-daemon must not ship alongside it.
if has_package power-profiles-daemon && has_package tlp; then
    bad "tlp is installed next to power-profiles-daemon"
else
    ok "no conflicting power manager"
fi

# Every non-comment line must look like a package name and not a pin or option.
malformed=$(grep -h -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "${LISTS}"/*.list.chroot |
    grep -v -E '^[a-z0-9][a-z0-9+.-]*$')

if [ -z "${malformed}" ]; then
    ok "every package list line is a package name"
else
    bad "malformed package list lines: $(printf '%s' "${malformed}" | tr '\n' ' ')"
fi

# The audio stack is declared through the metapackage, so its members cannot
# drift out of sync.
if has_package pipewire-audio && ! has_package pipewire-pulse; then
    ok "audio stack declared through pipewire-audio"
else
    bad "audio stack is not declared through pipewire-audio alone"
fi

# Services the hardware support depends on are enabled by the services hook.
# Printing is listed by its socket: the daemon itself is deliberately started
# on demand, not at boot (see docs/PERFORMANCE.md).
for unit in power-profiles-daemon.service cups.socket avahi-daemon.service; do
    if grep -q -- "enable_unit ${unit}" "${SERVICES}" 2>/dev/null; then
        ok "hook enables ${unit}"
    else
        bad "hook does not enable ${unit}"
    fi
done

# The configuration documentation must exist and cover the manual-install set.
if [ -r "${DOC}" ]; then
    ok "docs/HARDWARE.md exists"
else
    bad "docs/HARDWARE.md is missing"
fi

for needle in "nvidia-driver" "Validation requirements" "mesa-vulkan-drivers"; do
    if grep -q -- "${needle}" "${DOC}" 2>/dev/null; then
        ok "docs/HARDWARE.md covers: ${needle}"
    else
        bad "docs/HARDWARE.md does not mention: ${needle}"
    fi
done

# Backlight access is granted by brightness-udev through group membership, so
# the installer has to place the user in the groups those rules target.
USERS_CONF="${REPO}/config/includes.chroot/etc/calamares/modules/users.conf"
for group in video input; do
    if grep -qE "^[[:space:]]+- ${group}$" "${USERS_CONF}" 2>/dev/null; then
        ok "installer places the user in group ${group}"
    else
        bad "installer does not place the user in group ${group}"
    fi
done

# The image is amd64 only, so arm64-only firmware must stay out.
if has_package firmware-qcom-soc; then
    bad "arm64-only firmware-qcom-soc is in the amd64 package list"
else
    ok "no arm64-only firmware in the amd64 list"
fi

printf '\nSummary: %d passed, %d failed\n' "${PASS}" "${FAIL}"

if [ "${FAIL}" -ne 0 ]; then
    exit 1
fi
