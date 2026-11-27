#!/usr/bin/env bash
set -uo pipefail

# Static maintenance and recovery checks.
#
# Reads the update, snapshot and diagnostic scripts in the desktop checkout and
# the image configuration, and compares them with docs/MAINTENANCE.md. Nothing
# here runs apt, snapper, or any privileged command.
#
# Run: bash tests/validation/maintenance-test.sh

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
DOC="${REPO}/docs/MAINTENANCE.md"
INSTALLER_DOC="${REPO}/docs/INSTALLER.md"
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

DESKTOP=""
for candidate in "${REPO}/../fluorine-desktop" \
    "${REPO}/../../../fluorine-workspace/fluorine-desktop"; do
    if [ -r "${candidate}/bin/flr-update" ]; then
        DESKTOP="${candidate}"
        break
    fi
done

if [ -z "${DESKTOP}" ]; then
    printf 'SKIP  desktop checkout not present\n'
    exit 0
fi

UPDATE="${DESKTOP}/bin/flr-update"
SNAPSHOT="${DESKTOP}/bin/flr-snapshot"
DOCTOR="${DESKTOP}/bin/flr-doctor"

# --- Update workflow -------------------------------------------------------

file_contains "flr-update refreshes metadata first" "${UPDATE}" 'apt-get update'
file_contains "flr-update previews the upgrade" "${UPDATE}" 'apt-get -s upgrade'
file_contains "flr-update snapshots before applying" "${UPDATE}" 'flr-snapshot create pre-update'
file_contains "a failed snapshot aborts the upgrade" "${UPDATE}" 'pre-update snapshot failed'
file_contains "flr-update applies upgrades" "${UPDATE}" 'apt-get upgrade'
file_contains "flr-update checks free space" "${UPDATE}" 'df -Pk /'
file_contains "the free-space floor is one GiB" "${UPDATE}" '1048576'
file_contains "flr-update names the repair sequence" "${UPDATE}" 'dpkg --configure -a'

# The update path must not grow a removal step: a package conflict has to stay a
# visible held-back package, not an unrequested removal.
file_lacks "flr-update never calls autoremove" "${UPDATE}" 'apt-get .*autoremove'
file_lacks "flr-update never runs full-upgrade" "${UPDATE}" 'apt-get .*(full-upgrade|dist-upgrade)'

# --- Diagnostics -----------------------------------------------------------

file_contains "flr-doctor audits the package database" "${DOCTOR}" 'dpkg --audit'
file_contains "flr-doctor reports free space" "${DOCTOR}" 'df -Pk'
file_contains "flr-doctor reports the snapshot path" "${DOCTOR}" '/etc/snapper/configs/root'
file_contains "flr-doctor reads previous boots" "${DOCTOR}" 'journalctl --list-boots'
file_lacks "flr-doctor needs no privileges" "${DOCTOR}" '^[[:space:]]*(pkexec|sudo)[[:space:]]'

# --- Snapshot boundaries ---------------------------------------------------

file_contains "rollback requires a typed confirmation" "${SNAPSHOT}" 'refusing to roll back without confirmation'
file_contains "rollback refuses snapshot 0" "${SNAPSHOT}" 'snapshot 0 is the current state'
file_contains "snapshots are refused on a non-Btrfs root" "${SNAPSHOT}" 'snapshots are unavailable'
file_lacks "flr-snapshot deletes nothing" "${SNAPSHOT}" 'rm -rf'
file_lacks "flr-snapshot repairs nothing" "${SNAPSHOT}" 'mkfs|fsck|wipefs'

# --- Image configuration ---------------------------------------------------

# No automatic upgrade: no unattended-upgrades package and no periodic apt
# configuration in the image.
if grep -qE '^unattended-upgrades$' "${REPO}"/config/package-lists/*.list.chroot 2>/dev/null; then
    bad "unattended-upgrades is installed, which contradicts the documented workflow"
else
    ok "no unattended-upgrades package"
fi
if find "${REPO}/config/includes.chroot" -name '*auto-upgrades*' -o -name '10periodic' 2>/dev/null | grep -q .; then
    bad "the image ships an APT periodic configuration"
else
    ok "the image ships no APT periodic configuration"
fi

# Snapper cleanup has to stay enabled or the snapshot store grows without bound.
SNAPPER_INIT="${REPO}/config/includes.chroot/usr/lib/fluorineos/snapper-init"
file_lacks "the cleanup timer is not disabled" "${SNAPPER_INIT}" 'disable.*snapper-cleanup'

# --- Documentation ---------------------------------------------------------

if [ -r "${DOC}" ]; then
    ok "docs/MAINTENANCE.md exists"
else
    bad "docs/MAINTENANCE.md is missing"
fi

for needle in "not a backup" "not bootable" "dpkg --configure -a" "apt-get -f install" \
    "Runtime validation" "1 GiB" "full-upgrade"; do
    if grep -q -- "${needle}" "${DOC}" 2>/dev/null; then
        ok "docs/MAINTENANCE.md covers: ${needle}"
    else
        bad "docs/MAINTENANCE.md does not mention: ${needle}"
    fi
done

# The two documents must not disagree about bootability.
if grep -q "not bootable from GRUB" "${INSTALLER_DOC}" 2>/dev/null &&
    grep -q "not bootable from the GRUB menu" "${DOC}" 2>/dev/null; then
    ok "both documents say snapshots are not in the GRUB menu"
else
    bad "the snapshot bootability statement drifted between documents"
fi

# --- Staged packages -------------------------------------------------------

# The image installs the .deb files in config/packages.chroot. Report a staged
# version that is behind the source instead of failing: rebuilding the package is
# a release step, not a source change.
for repo in "${DESKTOP}" "${REPO}/../fluorine-artwork" \
    "${REPO}/../../../fluorine-workspace/fluorine-artwork"; do
    [ -r "${repo}/debian/changelog" ] || continue
    name=$(sed -n '1s/^\([a-z0-9-]*\) (.*/\1/p' "${repo}/debian/changelog")
    [ -n "${name}" ] || continue
    source_version=$(sed -n '1s/^[^(]* (\([^)]*\)).*/\1/p' "${repo}/debian/changelog")
    staged=$(ls "${REPO}/config/packages.chroot/${name}"_*.deb 2>/dev/null | head -1)
    [ -n "${staged}" ] || continue
    staged_version=$(basename "${staged}" .deb)
    staged_version=${staged_version#"${name}"_}
    staged_version=${staged_version%_all}
    staged_version=${staged_version%_amd64}
    if [ "${staged_version}" = "${source_version}" ]; then
        ok "staged ${name} matches the source (${source_version})"
    else
        printf 'WARN  staged %s is %s while the source is %s: rebuild before release\n' \
            "${name}" "${staged_version}" "${source_version}"
    fi
done

printf '\nSummary: %d passed, %d failed\n' "${PASS}" "${FAIL}"

if [ "${FAIL}" -ne 0 ]; then
    exit 1
fi
