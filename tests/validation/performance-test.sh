#!/usr/bin/env bash
set -uo pipefail

# Static performance and startup checks.
#
# Every assertion reads a file in this repository, or in the sibling desktop
# checkout when it is present, and compares it against the decisions recorded in
# docs/PERFORMANCE.md. Nothing here needs root, a network connection, a running
# session, or the target hardware; the point is to catch a regression that would
# quietly put work back into the boot path or into a polling loop.
#
# Run: bash tests/validation/performance-test.sh

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SERVICES="${REPO}/config/hooks/normal/0200-services.hook.chroot"
SNAPPER_INIT="${REPO}/config/includes.chroot/usr/lib/fluorineos/snapper-init"
ZRAM="${REPO}/config/hooks/normal/0300-zram.hook.chroot"
DOC="${REPO}/docs/PERFORMANCE.md"
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

file_contains() {
    local label=$1 file=$2 pattern=$3

    if grep -Eq -- "${pattern}" "${file}" 2>/dev/null; then
        ok "${label}"
    else
        bad "${label}"
    fi
}

file_lacks() {
    local label=$1 file=$2 pattern=$3

    if grep -Eq -- "${pattern}" "${file}" 2>/dev/null; then
        bad "${label}"
    else
        ok "${label}"
    fi
}

# --- Boot path -------------------------------------------------------------

# Printing is socket activated: no scheduler at boot, one on first use.
file_contains "cups socket is enabled" "${SERVICES}" '^[[:space:]]*enable_unit cups\.socket$'
file_contains "cups service stays out of the boot path" "${SERVICES}" \
    '^[[:space:]]*disable_unit cups\.service$'
file_contains "cups path unit is disabled with it" "${SERVICES}" \
    '^[[:space:]]*disable_unit cups\.path$'
file_contains "the socket is enabled after the Also= disable" "${SERVICES}" \
    'enable_unit cups\.socket'

# No unit may be enabled twice; a duplicate is either dead code or a sign that a
# second copy of the decision was added without removing the first.
duplicates=$(grep -oE '^[[:space:]]*enable_unit [A-Za-z0-9@._-]+' "${SERVICES}" 2>/dev/null |
    awk '{print $2}' | sort | uniq -d)
if [ -z "${duplicates}" ]; then
    ok "no unit is enabled twice"
else
    bad "units enabled twice: $(printf '%s' "${duplicates}" | tr '\n' ' ')"
fi

# zram is a one-shot unit enabled by its own package, so the hook only writes
# the policy file and must not grow a second copy of that decision.
file_contains "zram policy is written by the hook" "${ZRAM}" '^PERCENT=50$'
file_contains "zram uses zstd" "${ZRAM}" '^ALGO=zstd$'
file_lacks "the hook does not duplicate the packaged zram unit" "${ZRAM}" 'systemctl enable'

# Snapper: the snapshot sources this configuration disables must not keep their
# timers running.
file_contains "boot snapshots are disabled" "${SNAPPER_INIT}" 'snapper-boot\.timer'
file_contains "the hourly timeline timer is disabled" "${SNAPPER_INIT}" 'snapper-timeline\.timer'
file_lacks "the cleanup timer is kept" "${SNAPPER_INIT}" 'snapper-cleanup\.timer.*disable|disable.*snapper-cleanup\.timer'
file_contains "timers are disabled offline, not masked" "${SNAPPER_INIT}" 'systemctl --root='
file_lacks "masking is not used" "${SNAPPER_INIT}" 'systemctl[^)]*mask'

# Nothing in the build enables a session daemon that the desktop already starts
# from the compositor, which would give two of each.
for unit in hypridle.service waybar kanshi; do
    file_lacks "no packaged unit is enabled for ${unit}" "${SERVICES}" "enable_unit ${unit}"
done

# --- Session start ---------------------------------------------------------

DESKTOP=""
for candidate in "${REPO}/../fluorine-desktop" \
    "${REPO}/../../../fluorine-workspace/fluorine-desktop"; do
    if [ -r "${candidate}/skel/.config/hypr/hyprland.lua" ]; then
        DESKTOP="${candidate}"
        break
    fi
done

if [ -n "${DESKTOP}" ]; then
    HYPRLAND="${DESKTOP}/skel/.config/hypr/hyprland.lua"
    WAYBAR="${DESKTOP}/skel/.config/waybar/config.jsonc"

    # The deprecated hyprlang directive, not the paragraph explaining that Lua
    # replaces it.
    file_lacks "the compositor does not use the removed exec-once directive" \
        "${HYPRLAND}" '^[[:space:]]*exec-once[[:space:]]*='

    # Every autostart entry must appear exactly once, or the session runs two
    # copies of a daemon that assumes it is alone.
    for daemon in waybar swaync lxpolkit hypridle kanshi; do
        count=$(grep -cE "hl\.exec_cmd\(\"${daemon}([ \"]|$)" "${HYPRLAND}" 2>/dev/null)
        if [ "${count}" -eq 1 ]; then
            ok "${daemon} is started exactly once"
        else
            bad "${daemon} is started ${count} times"
        fi
    done

    # No polling loop may be hidden in the startup block.
    file_lacks "no sleep loop in the compositor autostart" "${HYPRLAND}" \
        'while true|while :'

    # Waybar polls on an interval. Anything under ten seconds spends CPU on a
    # value that does not change that fast.
    fast=$(grep -oE '"interval":[[:space:]]*[0-9]+' "${WAYBAR}" 2>/dev/null |
        grep -oE '[0-9]+$' | awk '$1 < 10')
    if [ -z "${fast}" ]; then
        ok "no Waybar module polls faster than ten seconds"
    else
        bad "Waybar intervals under ten seconds: $(printf '%s' "${fast}" | tr '\n' ' ')"
    fi

    # The polling modules must be cheap commands, not a full session manager.
    file_contains "the power module uses the dedicated helper" "${WAYBAR}" \
        '"exec": "flr-power waybar"'
else
    printf 'SKIP  desktop session checks (sibling checkout not present)\n'
fi

# --- Documentation ---------------------------------------------------------

if [ -r "${DOC}" ]; then
    ok "docs/PERFORMANCE.md exists"
else
    bad "docs/PERFORMANCE.md is missing"
fi

for needle in "Measured" "Anticipated" "Verification" "upgrade"; do
    if grep -q -- "${needle}" "${DOC}" 2>/dev/null; then
        ok "docs/PERFORMANCE.md covers: ${needle}"
    else
        bad "docs/PERFORMANCE.md does not mention: ${needle}"
    fi
done

printf '\nSummary: %d passed, %d failed\n' "${PASS}" "${FAIL}"

if [ "${FAIL}" -ne 0 ]; then
    exit 1
fi
