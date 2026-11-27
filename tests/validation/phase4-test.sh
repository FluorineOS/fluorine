#!/usr/bin/env bash
set -uo pipefail

# Non-destructive Phase 4 validation: the Calamares installer configuration and
# the three target-side helpers.
#
# Nothing here needs root, mounts a filesystem, touches a block device, or runs
# an installation. Every helper is executed against a temporary directory tree
# with stub commands, so the tests assert configuration semantics and control
# flow rather than the presence of a file.
#
# Run: bash tests/validation/phase4-test.sh

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
CAL="${REPO}/config/includes.chroot/etc/calamares"
MOD="${CAL}/modules"
LIB="${REPO}/config/includes.chroot/usr/lib/fluorineos"
SNAPPER="${LIB}/snapper-init"
CLEANUP="${LIB}/installer-cleanup"
LOGP="${LIB}/installer-log-preserve"
TMP=$(mktemp -d /tmp/flr-installer-phase4.XXXXXX)
PASS=0
FAIL=0
SKIP=0

ok() {
    PASS=$((PASS + 1))
    printf 'PASS  %s\n' "$1"
}

bad() {
    FAIL=$((FAIL + 1))
    printf 'FAIL  %s\n' "$1"
}

skip() {
    SKIP=$((SKIP + 1))
    printf 'SKIP  %s (%s)\n' "$1" "$2"
}

show_tail() {
    [ -f "$1" ] && tail -n 8 "$1" | sed 's/^/      /'
}

expect_status() {
    local expected=$1 name=$2 actual=0
    shift 2
    "$@" >"${TMP}/${name}.out" 2>&1 || actual=$?
    if [ "${actual}" -eq "${expected}" ]; then
        ok "${name}"
    else
        bad "${name} (exit ${actual}, expected ${expected})"
        show_tail "${TMP}/${name}.out"
    fi
}

contains() {
    local name=$1 file=$2 needle=$3
    if grep -Eq -- "${needle}" "${file}" 2>/dev/null; then
        ok "${name}"
    else
        bad "${name} (missing: ${needle} in ${file})"
    fi
}

not_contains() {
    local name=$1 file=$2 needle=$3
    if grep -Eq -- "${needle}" "${file}" 2>/dev/null; then
        bad "${name} (unexpected: ${needle} in ${file})"
    else
        ok "${name}"
    fi
}

file_has_value() {
    local name=$1 file=$2 key=$3 expected=$4 actual=""
    actual=$(sed -n -E "s/^[[:space:]]*${key}:[[:space:]]*//p" "${file}" 2>/dev/null |
        head -n 1 | sed -E 's/[[:space:]]+$//; s/^"(.*)"$/\1/')
    if [ "${actual}" = "${expected}" ]; then
        ok "${name}"
    else
        bad "${name} (${key}=${actual:-<unset>}, expected ${expected})"
    fi
}

exec_sequence() {
    awk '
        /^  - exec:/ { in_exec = 1; next }
        /^  - show:/ { in_exec = 0 }
        in_exec && /^[[:space:]]*- / {
            line = $0
            sub(/^[[:space:]]*-[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*$/, "", line)
            if (line != "") print line
        }
    ' "${CAL}/settings.conf"
}

seq_index() {
    exec_sequence | grep -n -x -- "$1" | head -n 1 | cut -d: -f1
}

before() {
    local name=$1 first=$2 second=$3 a="" b=""
    a=$(seq_index "${first}")
    b=$(seq_index "${second}")
    if [ -n "${a}" ] && [ -n "${b}" ] && [ "${a}" -lt "${b}" ]; then
        ok "${name}"
    else
        bad "${name} (${first}=${a:-absent}, ${second}=${b:-absent})"
    fi
}

# --- 1. Module sequence ----------------------------------------------------

test_sequence() {
    local expected="${TMP}/expected-sequence.txt"
    local actual="${TMP}/actual-sequence.txt"
    local module=""

    cat > "${expected}" <<'EOF'
partition
mount
unpackfs
machineid
fstab
locale
keyboard
localecfg
luksbootkeyfile
users
hwclock
packages
initramfscfg
initramfs
bootloader
shellprocess
umount
EOF
    exec_sequence > "${actual}"

    if diff -u "${expected}" "${actual}" >"${TMP}/sequence.diff" 2>&1; then
        ok sequence-exact
    else
        bad sequence-exact
        show_tail "${TMP}/sequence.diff"
    fi

    before order-packages-before-initramfscfg packages initramfscfg
    before order-packages-before-initramfs packages initramfs
    before order-initramfscfg-before-initramfs initramfscfg initramfs
    before order-initramfs-before-bootloader initramfs bootloader
    before order-fstab-before-luksbootkeyfile fstab luksbootkeyfile
    before order-luksbootkeyfile-before-initramfscfg luksbootkeyfile initramfscfg
    before order-bootloader-before-shellprocess bootloader shellprocess
    before order-shellprocess-before-umount shellprocess umount
    before order-users-before-packages users packages
    before order-fstab-before-initramfs fstab initramfs

    # Modules that must not run, with the reason recorded in settings.conf.
    for module in displaymanager networkcfg services-systemd grubcfg luksopenswaphookcfg; do
        if seq_index "${module}" >/dev/null 2>&1 && [ -n "$(seq_index "${module}")" ]; then
            bad "sequence-excludes-${module}"
        else
            ok "sequence-excludes-${module}"
        fi
    done

    contains settings-documents-exclusions "${CAL}/settings.conf" 'Deliberately not in the sequence'
    contains displaymanager-marked-documentation "${MOD}/displaymanager.conf" 'DOCUMENTATION ONLY'
}

# --- 2. Configuration ownership and values ---------------------------------

test_config_ownership() {
    local module=""
    local configured=(
        partition unpackfs machineid fstab locale keyboard users packages
        initramfs bootloader shellprocess
    )
    local unconfigured=(mount localecfg luksbootkeyfile hwclock initramfscfg umount)

    for module in "${configured[@]}"; do
        if [ -f "${MOD}/${module}.conf" ]; then
            ok "config-present-${module}"
        else
            bad "config-present-${module}"
        fi
    done

    for module in "${unconfigured[@]}"; do
        if [ -f "${MOD}/${module}.conf" ]; then
            bad "config-not-needed-${module} (unexpected file)"
        else
            ok "config-not-needed-${module}"
        fi
    done

    if [ -f "${MOD}/welcome.conf" ] && [ -f "${MOD}/finished.conf" ]; then
        ok config-present-view-modules
    else
        bad config-present-view-modules
    fi
}

test_partition() {
    file_has_value partition-filesystem "${MOD}/partition.conf" defaultFileSystemType btrfs
    file_has_value partition-luks-generation "${MOD}/partition.conf" luksGeneration luks1
    file_has_value partition-luks-automated "${MOD}/partition.conf" enableLuksAutomatedPartitioning true

    not_contains partition-no-luks2 "${MOD}/partition.conf" 'luksGeneration: *luks2'
    contains partition-subvol-root "${MOD}/partition.conf" 'subvolume: /@$'
    contains partition-subvol-home "${MOD}/partition.conf" 'subvolume: /@home$'
    contains partition-subvol-snapshots "${MOD}/partition.conf" 'subvolume: /@snapshots$'
    contains partition-subvol-log "${MOD}/partition.conf" 'subvolume: /@log$'
    contains partition-log-mountpoint "${MOD}/partition.conf" 'mountPoint: /var/log$'
}

test_users() {
    file_has_value users-minlength "${MOD}/users.conf" minLength 8
    file_has_value users-maxlength "${MOD}/users.conf" maxLength -1
    file_has_value users-sudoers-group "${MOD}/users.conf" sudoersGroup sudo
    file_has_value users-root-password "${MOD}/users.conf" setRootPassword false
    file_has_value users-autologin "${MOD}/users.conf" doAutologin false
    file_has_value users-write-hosts "${MOD}/users.conf" writeHostsFile true
    file_has_value users-hostname-location "${MOD}/users.conf" location EtcFile

    contains users-group-sudo "${MOD}/users.conf" '^  - sudo$'
    contains users-shell "${MOD}/users.conf" 'shell: /bin/bash'
    contains users-home-permissions "${MOD}/users.conf" 'home_permissions: "o700"'
    not_contains users-no-empty-allowed "${MOD}/users.conf" 'minLength: -1'

    # No libpwquality section: the library is an optional build-time dependency
    # of Calamares, so a check configured here can disappear silently. Match the
    # YAML key only; the rationale is allowed to mention the library by name.
    if grep -Eq '^[[:space:]]*libpwquality:' "${MOD}/users.conf"; then
        bad users-no-libpwquality
    else
        ok users-no-libpwquality
    fi
}

test_welcome() {
    file_has_value welcome-storage "${MOD}/welcome.conf" requiredStorage 15.0
    file_has_value welcome-ram "${MOD}/welcome.conf" requiredRam 2.5

    # The check list must not contain internet: the installer is offline by
    # design, and an internet condition would also trigger a GeoIP request.
    if sed -n '/^  check:/,/^  required:/p' "${MOD}/welcome.conf" | grep -Eq '^[[:space:]]*- internet$'; then
        bad welcome-no-internet-check
    else
        ok welcome-no-internet-check
    fi

    if sed -n '/^  required:/,$p' "${MOD}/welcome.conf" | grep -Eq '^[[:space:]]*- storage$'; then
        ok welcome-storage-blocking
    else
        bad welcome-storage-blocking
    fi
    if sed -n '/^  required:/,$p' "${MOD}/welcome.conf" | grep -Eq '^[[:space:]]*- ram$'; then
        ok welcome-ram-blocking
    else
        bad welcome-ram-blocking
    fi

    not_contains welcome-no-geoip "${MOD}/welcome.conf" 'geoip.kde.org'
    not_contains welcome-no-donate "${MOD}/welcome.conf" 'showDonateUrl: *true'
}

test_locale_keyboard() {
    file_has_value locale-system-timezone "${MOD}/locale.conf" useSystemTimezone true
    file_has_value locale-geoip-style "${MOD}/locale.conf" style none
    not_contains locale-no-geoip-url "${MOD}/locale.conf" 'https://'

    file_has_value keyboard-write-file "${MOD}/keyboard.conf" writeEtcDefaultKeyboard true
    file_has_value keyboard-no-localed "${MOD}/keyboard.conf" useLocale1 false
    file_has_value keyboard-no-keymap-path "${MOD}/keyboard.conf" convertedKeymapPath ""
}

test_bootloader_and_fstab() {
    file_has_value bootloader-efi "${MOD}/bootloader.conf" efiBootLoader grub
    file_has_value bootloader-id "${MOD}/bootloader.conf" efiBootloaderId FluorineOS
    file_has_value bootloader-fallback "${MOD}/bootloader.conf" installEFIFallback true
    file_has_value bootloader-hybrid "${MOD}/bootloader.conf" installHybridGRUB false
    not_contains bootloader-no-systemd-boot "${MOD}/bootloader.conf" 'efiBootLoader: *"systemd-boot"'
    not_contains bootloader-no-sb-shim "${MOD}/bootloader.conf" 'efiBootLoader: *"sb-shim"'

    contains fstab-crypttab-options "${MOD}/fstab.conf" '^crypttabOptions: luks,keyscript=/bin/cat$'
    contains fstab-tmpoptions "${MOD}/fstab.conf" '^tmpOptions:'
}

test_grub_defaults() {
    local grub="${REPO}/config/includes.chroot/etc/default/grub"

    contains grub-cryptodisk "${grub}" '^GRUB_ENABLE_CRYPTODISK=y$'
    contains grub-os-prober "${grub}" '^GRUB_DISABLE_OS_PROBER="false"$'
    contains grub-quiet-splash "${grub}" '^GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"$'
    contains grub-empty-cmdline "${grub}" '^GRUB_CMDLINE_LINUX=""$'
    contains grub-recovery "${grub}" '^GRUB_CMDLINE_LINUX_RECOVERY="recovery"$'
    not_contains grub-no-resume "${grub}" 'resume='
    not_contains grub-no-root-param "${grub}" 'root=/dev'
}

test_live_privileges() {
    local hook="${REPO}/config/hooks/normal/0400-live-calamares-polkit.hook.chroot"
    local desktop="${REPO}/config/includes.chroot/etc/skel/Desktop/install-fluorineos.desktop"

    # Extract the rule lines from the hook so both the semantic assertions and
    # visudo see exactly what the image ships, not the explanatory comments.
    sed -n '/^Defaults:/p; /^%sudo /p' "${hook}" > "${TMP}/sudoers.fixture"

    contains sudoers-grants-calamares "${TMP}/sudoers.fixture" 'NOPASSWD: /usr/bin/calamares$'
    not_contains sudoers-no-env-grant "${TMP}/sudoers.fixture" '/usr/bin/env'
    not_contains sudoers-no-wildcard "${TMP}/sudoers.fixture" 'NOPASSWD: *ALL'
    contains sudoers-env-keep "${TMP}/sudoers.fixture" 'env_keep \+= "WAYLAND_DISPLAY XDG_RUNTIME_DIR XDG_SESSION_TYPE"'
    contains sudoers-single-command "${TMP}/sudoers.fixture" '^%sudo ALL=\(ALL\) NOPASSWD: /usr/bin/calamares$'

    contains desktop-exec "${desktop}" '^Exec=sudo calamares$'
    not_contains desktop-no-preserve-env "${desktop}" 'sudo -E'
    not_contains desktop-no-env-command "${desktop}" 'Exec=.*env '

    if command -v visudo >/dev/null 2>&1; then
        expect_status 0 sudoers-visudo-syntax visudo -cf "${TMP}/sudoers.fixture"
    else
        skip sudoers-visudo-syntax 'visudo not installed'
    fi
}

test_package_lists() {
    local installer="${REPO}/config/package-lists/installer.list.chroot"
    local base="${REPO}/config/package-lists/base.list.chroot"

    contains packages-os-prober "${installer}" '^os-prober$'
    contains packages-cryptsetup "${installer}" '^cryptsetup$'
    contains packages-btrfs "${installer}" '^btrfs-progs$'
    contains packages-locales "${base}" '^locales$'
    contains packages-initramfs-tools "${base}" '^initramfs-tools$'
    contains packages-keyboard-configuration "${base}" '^keyboard-configuration$'

    # No signed boot chain is installed, so no shim package may appear.
    if grep -Eq '^(shim-signed|grub-efi-amd64-signed)$' "${installer}"; then
        bad packages-no-shim
    else
        ok packages-no-shim
    fi
}

test_live_media_secure_boot() {
    local config="${REPO}/auto/config"

    not_contains autoconfig-no-secure-boot "${config}" '^  --uefi-secure-boot enable'
    contains autoconfig-documents-decision "${config}" 'Secure Boot is deliberately not enabled'
}

test_branding_hosts() {
    local hook="${REPO}/config/hooks/normal/0100-branding.hook.chroot"

    contains branding-writes-hosts "${hook}" 'write_hosts /etc/hosts fluorine'
    contains branding-hostname "${hook}" 'fluorine'
    contains branding-idempotent-filter "${hook}" '127\.0\.1\.1'
}

test_open_snapper_absent() {
    if seq_index luksopenswaphookcfg >/dev/null 2>&1 && [ -n "$(seq_index luksopenswaphookcfg)" ]; then
        bad openswap-not-in-sequence
    else
        ok openswap-not-in-sequence
    fi
    contains openswap-documented "${CAL}/settings.conf" 'mkinitcpio-only'
}

# --- 3. snapper-init behaviour ---------------------------------------------

make_snapper_stub() {
    local dir=$1
    mkdir -p "${dir}"
    cat > "${dir}/snapper" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
case "${1:-}" in
    --no-dbus)
        shift
        if [ "${1:-}" = "-c" ]; then shift 2; fi
        case "${1:-}" in
            create-config)
                if [ "${FAKE_SNAPPER_CREATE:-ok}" = "fail" ]; then exit 1; fi
                mkdir -p "${FAKE_SNAPPER_ROOT:?}/etc/snapper/configs"
                printf 'SUBVOLUME="/"\nTIMELINE_CREATE="yes"\n' \
                    > "${FAKE_SNAPPER_ROOT}/etc/snapper/configs/root"
                exit 0
                ;;
            list) exit "${FAKE_SNAPPER_LIST:-0}" ;;
        esac
        ;;
esac
exit 1
EOF
    chmod +x "${dir}/snapper"
}

snapper_fixture() {
    local root=$1
    mkdir -p "${root}/etc" "${root}/usr/share/snapper/config-templates" "${root}/.snapshots"
    printf 'SUBVOLUME="/"\nTIMELINE_CREATE="yes"\nTIMELINE_CLEANUP="no"\n' \
        > "${root}/usr/share/snapper/config-templates/default"
}

test_snapper() {
    local root=""
    local bin="${TMP}/snapper-bin"

    make_snapper_stub "${bin}"

    # Non-Btrfs roots are a documented non-applicability, not a failure.
    root="${TMP}/snapper-ext4"
    snapper_fixture "${root}"
    expect_status 0 snapper-skip-non-btrfs \
        env PATH="${bin}:${PATH}" FAKE_SNAPPER_ROOT="${root}" \
        bash "${SNAPPER}" --root "${root}" --root-fstype ext4
    contains snapper-skip-logged "${root}/var/log/fluorineos-install/snapper.log" \
        "not btrfs; Snapper does not apply"
    if [ -f "${root}/etc/snapper/configs/root" ]; then
        bad snapper-skip-writes-nothing
    else
        ok snapper-skip-writes-nothing
    fi

    # Btrfs with a working snapper: configuration created and normalized.
    root="${TMP}/snapper-create"
    snapper_fixture "${root}"
    expect_status 0 snapper-create \
        env PATH="${bin}:${PATH}" FAKE_SNAPPER_ROOT="${root}" \
        bash "${SNAPPER}" --root "${root}" --root-fstype btrfs
    contains snapper-create-subvolume "${root}/etc/snapper/configs/root" '^SUBVOLUME="/"$'
    contains snapper-create-timeline-off "${root}/etc/snapper/configs/root" '^TIMELINE_CREATE="no"$'
    contains snapper-create-logged "${root}/var/log/fluorineos-install/snapper.log" \
        'created and verified the Snapper root configuration'

    # Idempotence: a second run verifies and leaves the file byte-identical.
    local before_sum="" after_sum=""
    before_sum=$(sha256sum "${root}/etc/snapper/configs/root" | awk '{print $1}')
    expect_status 0 snapper-idempotent \
        env PATH="${bin}:${PATH}" FAKE_SNAPPER_ROOT="${root}" \
        bash "${SNAPPER}" --root "${root}" --root-fstype btrfs
    after_sum=$(sha256sum "${root}/etc/snapper/configs/root" | awk '{print $1}')
    if [ "${before_sum}" = "${after_sum}" ]; then
        ok snapper-idempotent-unchanged
    else
        bad snapper-idempotent-unchanged
    fi
    contains snapper-existing-verified "${root}/var/log/fluorineos-install/snapper.log" \
        'existing Snapper root configuration verified'

    # create-config fails because /.snapshots exists: seed from the template.
    root="${TMP}/snapper-seed"
    snapper_fixture "${root}"
    expect_status 0 snapper-seed \
        env PATH="${bin}:${PATH}" FAKE_SNAPPER_ROOT="${root}" FAKE_SNAPPER_CREATE=fail \
        bash "${SNAPPER}" --root "${root}" --root-fstype btrfs
    contains snapper-seed-logged "${root}/var/log/fluorineos-install/snapper.log" \
        'seeded the Snapper root configuration'
    contains snapper-seed-subvolume "${root}/etc/snapper/configs/root" '^SUBVOLUME="/"$'
    contains snapper-seed-timeline-off "${root}/etc/snapper/configs/root" '^TIMELINE_CREATE="no"$'

    # create-config fails and there is no template: must fail loudly.
    root="${TMP}/snapper-noseed"
    mkdir -p "${root}/etc" "${root}/.snapshots"
    expect_status 1 snapper-fails-without-template \
        env PATH="${bin}:${PATH}" FAKE_SNAPPER_ROOT="${root}" FAKE_SNAPPER_CREATE=fail \
        bash "${SNAPPER}" --root "${root}" --root-fstype btrfs

    # A configuration that cannot be validated must not be reported as success.
    root="${TMP}/snapper-invalid"
    snapper_fixture "${root}"
    mkdir -p "${root}/etc/snapper/configs"
    printf 'SUBVOLUME="/"\nTIMELINE_CREATE="no"\n' > "${root}/etc/snapper/configs/root"
    expect_status 1 snapper-rejects-broken-config \
        env PATH="${bin}:${PATH}" FAKE_SNAPPER_ROOT="${root}" FAKE_SNAPPER_LIST=1 \
        bash "${SNAPPER}" --root "${root}" --root-fstype btrfs

    # Snapper missing on a Btrfs root is an error, not a skip.
    root="${TMP}/snapper-missing"
    snapper_fixture "${root}"
    local nobin="${TMP}/snapper-nobin"
    mkdir -p "${nobin}"
    local tool=""
    for tool in bash sh dirname date stat install findmnt grep sed chmod cat id; do
        if command -v "${tool}" >/dev/null 2>&1; then
            ln -sf "$(command -v "${tool}")" "${nobin}/${tool}" 2>/dev/null || true
        fi
    done
    expect_status 1 snapper-fails-without-snapper \
        env PATH="${nobin}" bash "${SNAPPER}" --root "${root}" --root-fstype btrfs

    # A stale SUBVOLUME and timeline setting are repaired on an existing file.
    root="${TMP}/snapper-repair"
    snapper_fixture "${root}"
    mkdir -p "${root}/etc/snapper/configs"
    printf 'SUBVOLUME="/@home"\nTIMELINE_CREATE="yes"\n' > "${root}/etc/snapper/configs/root"
    expect_status 0 snapper-repair \
        env PATH="${bin}:${PATH}" FAKE_SNAPPER_ROOT="${root}" \
        bash "${SNAPPER}" --root "${root}" --root-fstype btrfs
    contains snapper-repair-subvolume "${root}/etc/snapper/configs/root" '^SUBVOLUME="/"$'
    contains snapper-repair-timeline "${root}/etc/snapper/configs/root" '^TIMELINE_CREATE="no"$'
}

# --- 4. installer-cleanup behaviour ---------------------------------------

test_cleanup() {
    local root="${TMP}/cleanup-root"

    mkdir -p "${root}/etc/sudoers.d" \
        "${root}/etc/xdg/autostart" \
        "${root}/etc/skel/Desktop" \
        "${root}/home/tester/Desktop" \
        "${root}/usr/share/applications" \
        "${root}/usr/share/pixmaps" \
        "${root}/etc/calamares/modules" \
        "${root}/usr/share/calamares/branding/debian"

    : > "${root}/etc/sudoers.d/99-fluorine-live-installer"
    printf 'keep\n' > "${root}/etc/sudoers.d/10-installer"
    : > "${root}/etc/xdg/autostart/calamares-desktop-icon.desktop"
    printf 'keep\n' > "${root}/etc/xdg/autostart/other.desktop"
    : > "${root}/etc/skel/Desktop/install-fluorineos.desktop"
    printf 'keep\n' > "${root}/etc/skel/Desktop/keep.desktop"
    : > "${root}/home/tester/Desktop/install-fluorineos.desktop"
    printf 'keep\n' > "${root}/home/tester/Desktop/notes.txt"
    : > "${root}/usr/share/applications/calamares-install-debian.desktop"
    : > "${root}/usr/share/pixmaps/install-debian.png"
    printf 'quiet splash\n' > "${root}/etc/calamares/modules/partition.conf"
    : > "${root}/usr/share/calamares/branding/debian/logo.png"
    printf 'keep\n' > "${root}/etc/hostname"

    expect_status 1 cleanup-refuses-without-target bash "${CLEANUP}"
    expect_status 1 cleanup-refuses-unknown-argument bash "${CLEANUP}" --installed-target --bogus

    expect_status 0 cleanup-run bash "${CLEANUP}" --root "${root}"

    local path=""
    for path in \
        /etc/sudoers.d/99-fluorine-live-installer \
        /etc/xdg/autostart/calamares-desktop-icon.desktop \
        /etc/skel/Desktop/install-fluorineos.desktop \
        /home/tester/Desktop/install-fluorineos.desktop \
        /usr/share/applications/calamares-install-debian.desktop \
        /usr/share/pixmaps/install-debian.png \
        /etc/calamares \
        /usr/share/calamares/branding/debian; do
        if [ -e "${root}${path}" ]; then
            bad "cleanup-removes${path//\//-}"
        else
            ok "cleanup-removes${path//\//-}"
        fi
    done

    for path in \
        /etc/sudoers.d/10-installer \
        /etc/xdg/autostart/other.desktop \
        /etc/skel/Desktop/keep.desktop \
        /home/tester/Desktop/notes.txt \
        /etc/hostname; do
        if [ -f "${root}${path}" ]; then
            ok "cleanup-keeps${path//\//-}"
        else
            bad "cleanup-keeps${path//\//-}"
        fi
    done

    contains cleanup-log-removed "${root}/var/log/fluorineos-install/cleanup.log" 'removed /etc/calamares'
    not_contains cleanup-log-no-failures "${root}/var/log/fluorineos-install/cleanup.log" 'FAILED'

    # Idempotent: a second run finds nothing and still exits 0.
    expect_status 0 cleanup-idempotent bash "${CLEANUP}" --root "${root}"
    contains cleanup-log-absent "${root}/var/log/fluorineos-install/cleanup.log" 'absent  /etc/calamares'
}

# --- 5. installer-log-preserve behaviour ----------------------------------

test_log_preserve() {
    local source="${TMP}/log-source"
    local target="${TMP}/log-target"
    local missing="${TMP}/log-missing"

    mkdir -p "${source}" "${target}"
    cat > "${source}/session.log" <<'EOF'
Calamares session 0.4.0
Running command cryptsetup luksFormat /dev/vda2
password: hunter2
passphrase=correct-horse
normal diagnostic line
EOF

    expect_status 0 log-preserve-run bash "${LOGP}" "${target}" --source "${source}"

    local dest="${target}/var/log/fluorineos-install/session.log"
    if [ -f "${dest}" ]; then
        ok log-preserve-created
    else
        bad log-preserve-created
    fi
    contains log-preserve-content "${dest}" 'normal diagnostic line'
    not_contains log-preserve-redacts-password "${dest}" 'hunter2'
    not_contains log-preserve-redacts-passphrase "${dest}" 'correct-horse'
    contains log-preserve-redaction-marker "${dest}" '\[REDACTED\]'
    contains log-preserve-context "${target}/var/log/fluorineos-install/install-context.txt" 'bytes:'

    local mode=""
    mode=$(stat -c %a "${dest}" 2>/dev/null || printf 'unknown')
    if [ "${mode}" = "640" ]; then
        ok log-preserve-mode
    else
        bad "log-preserve-mode (got ${mode}, expected 640)"
    fi

    local dir_mode=""
    dir_mode=$(stat -c %a "${target}/var/log/fluorineos-install" 2>/dev/null || printf 'unknown')
    if [ "${dir_mode}" = "750" ]; then
        ok log-preserve-directory-mode
    else
        bad "log-preserve-directory-mode (got ${dir_mode}, expected 750)"
    fi

    # Newest log wins when several exist.
    local newer="${TMP}/log-source-newer"
    mkdir -p "${newer}"
    printf 'newest log line\n' > "${newer}/session.log"
    touch -d '2030-01-01 00:00:00' "${newer}/session.log" 2>/dev/null || true
    mkdir -p "${TMP}/log-target-newer"
    expect_status 0 log-preserve-newest bash "${LOGP}" "${TMP}/log-target-newer" --source "${newer}"
    contains log-preserve-newest-content \
        "${TMP}/log-target-newer/var/log/fluorineos-install/session.log" 'newest log line'

    # A missing log must not fail the install, and the absence is recorded.
    mkdir -p "${missing}"
    expect_status 0 log-preserve-missing-source bash "${LOGP}" "${missing}" --source "${TMP}/no-logs-here"
    contains log-preserve-missing-note "${missing}/var/log/fluorineos-install/session.log" \
        'No Calamares session log was found'

    expect_status 1 log-preserve-requires-target bash "${LOGP}"
    expect_status 1 log-preserve-rejects-missing-target bash "${LOGP}" "${TMP}/no-such-root"
}

# --- 6. Script syntax and documentation -----------------------------------

test_shell_syntax() {
    local file=""
    for file in "${SNAPPER}" "${CLEANUP}" "${LOGP}" \
        "${REPO}/config/hooks/normal/0100-branding.hook.chroot" \
        "${REPO}/config/hooks/normal/0200-services.hook.chroot" \
        "${REPO}/config/hooks/normal/0300-zram.hook.chroot" \
        "${REPO}/config/hooks/normal/0400-live-calamares-polkit.hook.chroot" \
        "${REPO}/auto/config"; do
        if bash -n "${file}" 2>"${TMP}/syntax.out"; then
            ok "syntax-clean $(basename "${file}")"
        else
            bad "syntax-clean $(basename "${file}")"
            show_tail "${TMP}/syntax.out"
        fi
    done
}

test_yaml() {
    local file=""
    local files=(
        "${CAL}/settings.conf"
        "${MOD}/partition.conf"
        "${MOD}/packages.conf"
        "${MOD}/unpackfs.conf"
        "${MOD}/shellprocess.conf"
        "${MOD}/users.conf"
        "${MOD}/welcome.conf"
        "${MOD}/locale.conf"
        "${MOD}/keyboard.conf"
        "${MOD}/bootloader.conf"
        "${MOD}/fstab.conf"
        "${MOD}/initramfs.conf"
        "${MOD}/machineid.conf"
        "${MOD}/finished.conf"
        "${MOD}/displaymanager.conf"
    )

    if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import yaml' >/dev/null 2>&1; then
        skip yaml-parses 'python3 with PyYAML is not available'
        return 0
    fi

    for file in "${files[@]}"; do
        if python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1], encoding="utf-8"))' "${file}" >/dev/null 2>&1; then
            ok "yaml-parses $(basename "${file}")"
        else
            bad "yaml-parses $(basename "${file}")"
        fi
    done
}

test_documentation() {
    local doc="${REPO}/docs/INSTALLER.md"

    if [ -f "${doc}" ]; then
        ok docs-installer-present
    else
        bad docs-installer-present
        return 0
    fi

    contains docs-encryption-contract "${doc}" 'LUKS1'
    contains docs-secure-boot-contract "${doc}" 'Unsupported for installed systems'
    contains docs-dual-boot-contract "${doc}" 'os-prober'
    contains docs-hibernation-contract "${doc}" 'Hibernation is unsupported'
    contains docs-snapper-contract "${doc}" 'TIMELINE_CREATE'
    contains docs-logging-contract "${doc}" '/var/log/fluorineos-install/'
    contains docs-no-bootable-snapshots "${doc}" 'not bootable from GRUB'
    contains docs-sequence-matches-settings "${doc}" 'initramfscfg,$'
    contains docs-sequence-order "${doc}" 'initramfs, bootloader, shellprocess, umount'
}

main() {
    test_sequence
    test_config_ownership
    test_partition
    test_users
    test_welcome
    test_locale_keyboard
    test_bootloader_and_fstab
    test_grub_defaults
    test_live_privileges
    test_package_lists
    test_live_media_secure_boot
    test_branding_hosts
    test_open_snapper_absent
    test_snapper
    test_cleanup
    test_log_preserve
    test_shell_syntax
    test_yaml
    test_documentation

    printf '\nSummary: %s passed, %s failed, %s skipped\n' "${PASS}" "${FAIL}" "${SKIP}"
    printf 'Fixtures: %s\n' "${TMP}"
    [ "${FAIL}" -eq 0 ]
}

main "$@"
