#!/usr/bin/env bash
set -uo pipefail

# Non-destructive Phase 3 validation tests for the shared boot gate.
# Fake QEMU processes write serial logs only; no VM, disk, or privileged command
# is started by this harness.

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
GATE="${REPO}/scripts/qemu-boot-gate.sh"
TMP=$(mktemp -d /tmp/flr-qemu-phase3.XXXXXX)
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

show_tail() {
    local file=$1
    if [ -f "${file}" ]; then
        tail -n 8 "${file}" | sed 's/^/      /'
    fi
}

expect_status() {
    local expected=$1
    local name=$2
    local actual=0
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
    local name=$1
    local file=$2
    local needle=$3

    if grep -Eq -- "${needle}" "${file}" 2>/dev/null; then
        ok "${name}"
    else
        bad "${name} (missing: ${needle})"
        show_tail "${file}"
    fi
}

not_contains() {
    local name=$1
    local file=$2
    local needle=$3

    if grep -Eq -- "${needle}" "${file}" 2>/dev/null; then
        bad "${name} (unexpected: ${needle})"
    else
        ok "${name}"
    fi
}

summary_field() {
    local file=$1
    local key=$2

    grep -E "^${key}=" "${file}" 2>/dev/null | head -n 1 | cut -d= -f2-
}

check_field() {
    local name=$1
    local file=$2
    local key=$3
    local expected=$4
    local actual=""

    actual=$(summary_field "${file}" "${key}")
    if [ "${actual}" = "${expected}" ]; then
        ok "${name}"
    else
        bad "${name} (${key}=${actual}, expected ${expected})"
        show_tail "${file}"
    fi
}

no_leftover_vars() {
    local name=$1
    local tmpdir=$2
    local found=""

    found=$(find "${tmpdir}" -maxdepth 1 -name '*-OVMF_VARS.fd' -print -quit 2>/dev/null)
    if [ -z "${found}" ]; then
        ok "${name}"
    else
        bad "${name} (leftover: ${found})"
    fi
}

main() {
    local iso="${TMP}/gate.iso"
    local checksum="${iso}.sha256"
    local code="${TMP}/OVMF_CODE.fd"
    local vars="${TMP}/OVMF_VARS.fd"
    local kernel="${TMP}/vmlinuz"
    local initrd="${TMP}/initrd.img"
    local basebin="${TMP}/basebin"
    local fakebin="${TMP}/fakebin"
    local noqemu="${TMP}/noqemu"
    local tool=""
    local target=""
    local case_name=""
    local case_evidence=""
    local case_tmp=""
    local cleanup_marker=""
    local args_log=""
    local summary=""
    local serial=""
    local qemu_log=""

    mkdir -p "${basebin}" "${fakebin}" "${noqemu}"
    for tool in bash dirname basename realpath stat sha256sum mktemp grep tail sleep \
        date mkdir rm rmdir cp chmod head cat tr truncate awk id hostname uname git; do
        target=$(command -v "${tool}" 2>/dev/null) || continue
        ln -s "${target}" "${basebin}/${tool}" 2>/dev/null || true
        ln -s "${target}" "${noqemu}/${tool}" 2>/dev/null || true
    done
    cp -a "${basebin}/." "${fakebin}/"

    printf 'synthetic boot gate ISO fixture\n' > "${iso}"
    sha256sum "${iso}" > "${checksum}"
    printf 'fake OVMF code\n' > "${code}"
    printf 'fake OVMF variables\n' > "${vars}"
    printf 'fake kernel fixture\n' > "${kernel}"
    printf 'fake initrd fixture\n' > "${initrd}"

    cat > "${fakebin}/qemu-system-x86_64" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

if [ "${1:-}" = "--version" ]; then
    printf 'QEMU emulator version 10.0.13 (fake phase 3 gate)\n'
    exit 0
fi

if [ -n "${BOOT_GATE_QEMU_ARG_LOG:-}" ]; then
    printf '%s\n' "$*" >> "${BOOT_GATE_QEMU_ARG_LOG}" 2>/dev/null || true
fi
if [ -n "${BOOT_GATE_QEMU_PID_FILE:-}" ]; then
    printf '%s\n' "$$" > "${BOOT_GATE_QEMU_PID_FILE}" 2>/dev/null || true
fi

serial=${FLR_BOOT_GATE_SERIAL_LOG:-}
fake_case=${FAKE_CASE:-}

case "${fake_case}" in
    firmware-pass)
        printf 'BdsDxe: starting Boot0001 via CDROM\n' >> "${serial}"
        exit 0
        ;;
    live-pass)
        cat >> "${serial}" <<'LOG'
[    0.000000] Linux version 6.12.0-amd64
[    1.200000] squashfs: version 4.0 (2009/01/31)
[   12.000000] systemd[1]: Reached target multi-user.target - Multi-User System.
[   13.000000] systemd[1]: Reached target graphical.target - Graphical Interface.
LOG
        exit 0
        ;;
    boot-fail)
        cat >> "${serial}" <<'LOG'
[    0.000000] Linux version 6.12.0-amd64
[    1.200000] squashfs: version 4.0 (2009/01/31)
LOG
        exit 0
        ;;
    qemu-fail)
        printf 'fake QEMU launch failure\n' >&2
        exit 7
        ;;
    timeout|panic|mount-fail)
        trap 'printf terminated > "${BOOT_GATE_CLEANUP_MARKER:?}" 2>/dev/null || true; exit 0' TERM
        case "${fake_case}" in
            panic)
                printf 'Kernel panic - not syncing: fake failure\n' >> "${serial}"
                ;;
            mount-fail)
                printf 'Failed to mount a fake filesystem\n' >> "${serial}"
                ;;
        esac
        while :; do
            sleep 1
        done
        ;;
    *)
        printf 'unknown fake gate case: %s\n' "${fake_case}" >&2
        exit 99
        ;;
esac
EOF
    chmod +x "${fakebin}/qemu-system-x86_64"

    expect_status 0 gate-help bash "${GATE}" --help
    contains gate-help-usage "${TMP}/gate-help.out" --mode
    expect_status 2 gate-missing-mode bash "${GATE}" --iso "${iso}"
    expect_status 2 gate-invalid-mode bash "${GATE}" --mode bogus --iso "${iso}"
    contains gate-invalid-mode-message "${TMP}/gate-invalid-mode.out" 'invalid --mode'
    expect_status 2 gate-missing-arg bash "${GATE}" --iso
    contains gate-missing-arg-message "${TMP}/gate-missing-arg.out" 'requires an argument'
    expect_status 2 gate-invalid-timeout \
        bash "${GATE}" --mode firmware --iso "${iso}" --timeout 0
    expect_status 2 gate-invalid-memory \
        bash "${GATE}" --mode firmware --iso "${iso}" --memory zero
    expect_status 2 gate-invalid-accel \
        bash "${GATE}" --mode firmware --iso "${iso}" --accel xen
    expect_status 2 gate-kernel-in-firmware \
        bash "${GATE}" --mode firmware --iso "${iso}" --kernel "${kernel}" --initrd "${initrd}"
    expect_status 2 gate-half-kernel \
        bash "${GATE}" --mode live --iso "${iso}" --kernel "${kernel}"
    contains gate-half-kernel-message "${TMP}/gate-half-kernel.out" 'must be supplied together'

    expect_status 3 gate-missing-iso \
        env PATH="${fakebin}" FAKE_CASE=none \
        bash "${GATE}" --mode firmware --iso "${TMP}/no-such.iso" \
        --evidence-dir "${TMP}/evidence-missing-iso" --accel tcg
    contains gate-missing-iso-message "${TMP}/gate-missing-iso.out" 'ISO not found'

    expect_status 3 gate-checksum-mismatch \
        env PATH="${fakebin}" FAKE_CASE=none \
        bash "${GATE}" --mode firmware --iso "${iso}" \
        --sha256-file "${TMP}/bad.sha256" \
        --evidence-dir "${TMP}/evidence-bad-checksum" --accel tcg
    printf '%064d  %s\n' 0 "$(basename -- "${iso}")" > "${TMP}/bad.sha256"
    expect_status 3 gate-checksum-mismatch-real \
        env PATH="${fakebin}" FAKE_CASE=none \
        bash "${GATE}" --mode firmware --iso "${iso}" \
        --sha256-file "${TMP}/bad.sha256" \
        --evidence-dir "${TMP}/evidence-bad-checksum" --accel tcg
    contains gate-checksum-message "${TMP}/gate-checksum-mismatch-real.out" 'SHA-256 mismatch'

    expect_status 3 gate-missing-firmware \
        env PATH="${fakebin}" FAKE_CASE=none \
        FLUORINEOS_OVMF_CODE="${TMP}/no-such-code.fd" FLUORINEOS_OVMF_VARS="${vars}" \
        bash "${GATE}" --mode firmware --iso "${iso}" --sha256-file "${checksum}" \
        --evidence-dir "${TMP}/evidence-missing-firmware" --accel tcg
    contains gate-missing-firmware-message "${TMP}/gate-missing-firmware.out" 'OVMF code override'

    expect_status 3 gate-qemu-unavailable \
        env PATH="${noqemu}" \
        FLUORINEOS_OVMF_CODE="${code}" FLUORINEOS_OVMF_VARS="${vars}" \
        bash "${GATE}" --mode firmware --iso "${iso}" --sha256-file "${checksum}" \
        --evidence-dir "${TMP}/evidence-no-qemu" --accel tcg
    contains gate-qemu-unavailable-message "${TMP}/gate-qemu-unavailable.out" 'qemu-system-x86_64 not found'

    # Successful firmware handoff.
    case_name=firmware-pass
    case_evidence="${TMP}/evidence-${case_name}"
    case_tmp="${TMP}/tmp-${case_name}"
    cleanup_marker="${TMP}/${case_name}.cleanup"
    args_log="${TMP}/${case_name}.args"
    mkdir -p "${case_tmp}"
    expect_status 0 gate-firmware-pass \
        env PATH="${fakebin}" FAKE_CASE="${case_name}" \
        TMPDIR="${case_tmp}" \
        FLUORINEOS_OVMF_CODE="${code}" FLUORINEOS_OVMF_VARS="${vars}" \
        BOOT_GATE_QEMU_ARG_LOG="${args_log}" \
        bash "${GATE}" --mode firmware --iso "${iso}" --sha256-file "${checksum}" \
        --evidence-dir "${case_evidence}" --timeout 5 \
        --memory 2048 --cpus 2 --accel tcg
    summary="${case_evidence}/gate.txt"
    serial="${case_evidence}/serial.log"
    qemu_log="${case_evidence}/firmware.qemu.log"
    contains gate-firmware-pass-message "${TMP}/gate-firmware-pass.out" 'BOOT-GATE PASS'
    contains gate-firmware-marker "${serial}" 'BdsDxe: starting Boot0001'
    check_field gate-firmware-summary-status "${summary}" status PASS
    check_field gate-firmware-summary-exit "${summary}" exit_code 0
    check_field gate-firmware-summary-timeout "${summary}" timeout_seconds 5
    contains gate-firmware-args "${args_log}" '-machine q35'
    contains gate-firmware-args-accel "${args_log}" '-accel tcg'
    contains gate-firmware-args-pflash "${args_log}" '-drive if=pflash,format=raw,readonly=on,file='
    contains gate-firmware-args-cdrom "${args_log}" 'media=cdrom,readonly=on'
    contains gate-firmware-args-display "${args_log}" '-display none'
    contains gate-firmware-args-no-reboot "${args_log}" '-no-reboot'
    if [ -f "${summary}" ] && [ -f "${serial}" ] && [ -f "${qemu_log}" ]; then
        ok gate-firmware-evidence-files
    else
        bad gate-firmware-evidence-files
    fi
    no_leftover_vars gate-firmware-cleanup "${case_tmp}"

    # Successful direct-kernel boot to graphical.target.
    case_name=live-pass
    case_evidence="${TMP}/evidence-${case_name}"
    case_tmp="${TMP}/tmp-${case_name}"
    cleanup_marker="${TMP}/${case_name}.cleanup"
    args_log="${TMP}/${case_name}.args"
    mkdir -p "${case_tmp}"
    expect_status 0 gate-live-pass \
        env PATH="${fakebin}" FAKE_CASE="${case_name}" \
        TMPDIR="${case_tmp}" \
        BOOT_GATE_QEMU_ARG_LOG="${args_log}" \
        bash "${GATE}" --mode live --iso "${iso}" --sha256-file "${checksum}" \
        --evidence-dir "${case_evidence}" --timeout 5 \
        --kernel "${kernel}" --initrd "${initrd}" \
        --memory 2048 --cpus 2 --accel tcg
    summary="${case_evidence}/gate.txt"
    serial="${case_evidence}/serial.log"
    contains gate-live-pass-message "${TMP}/gate-live-pass.out" 'BOOT-GATE PASS'
    contains gate-live-graphical "${serial}" 'Reached target graphical.target'
    check_field gate-live-summary-status "${summary}" status PASS
    check_field gate-live-summary-mode "${summary}" mode live
    check_field gate-live-summary-firmware "${summary}" firmware_mode not-used
    contains gate-live-args-kernel "${args_log}" "-kernel ${kernel}"
    contains gate-live-args-initrd "${args_log}" "-initrd ${initrd}"
    contains gate-live-args-console "${args_log}" 'console=ttyS0,115200'
    not_contains gate-live-args-no-pflash "${args_log}" 'if=pflash'
    no_leftover_vars gate-live-cleanup "${case_tmp}"

    # Timeout is a failure, and cleanup still runs.
    case_name=timeout
    case_evidence="${TMP}/evidence-${case_name}"
    case_tmp="${TMP}/tmp-${case_name}"
    cleanup_marker="${TMP}/${case_name}.cleanup"
    args_log="${TMP}/${case_name}.args"
    mkdir -p "${case_tmp}"
    expect_status 5 gate-timeout \
        env PATH="${fakebin}" FAKE_CASE="${case_name}" \
        TMPDIR="${case_tmp}" \
        FLUORINEOS_OVMF_CODE="${code}" FLUORINEOS_OVMF_VARS="${vars}" \
        BOOT_GATE_QEMU_ARG_LOG="${args_log}" \
        BOOT_GATE_QEMU_PID_FILE="${TMP}/${case_name}.pid" \
        BOOT_GATE_CLEANUP_MARKER="${cleanup_marker}" \
        bash "${GATE}" --mode firmware --iso "${iso}" --sha256-file "${checksum}" \
        --evidence-dir "${case_evidence}" --timeout 1 --accel tcg
    summary="${case_evidence}/gate.txt"
    contains gate-timeout-message "${TMP}/gate-timeout.out" 'timed out after 1s'
    check_field gate-timeout-summary-status "${summary}" status TIMEOUT
    check_field gate-timeout-summary-exit "${summary}" exit_code 5
    if [ -f "${cleanup_marker}" ] && grep -q terminated "${cleanup_marker}"; then
        ok gate-timeout-cleanup-kills-qemu
    else
        bad gate-timeout-cleanup-kills-qemu
    fi
    no_leftover_vars gate-timeout-cleanup-vars "${case_tmp}"

    # Kernel panic is a forbidden boot error, even though other markers exist.
    case_name=panic
    case_evidence="${TMP}/evidence-${case_name}"
    case_tmp="${TMP}/tmp-${case_name}"
    cleanup_marker="${TMP}/${case_name}.cleanup"
    args_log="${TMP}/${case_name}.args"
    mkdir -p "${case_tmp}"
    expect_status 6 gate-panic \
        env PATH="${fakebin}" FAKE_CASE="${case_name}" \
        TMPDIR="${case_tmp}" \
        BOOT_GATE_QEMU_ARG_LOG="${args_log}" \
        BOOT_GATE_QEMU_PID_FILE="${TMP}/${case_name}.pid" \
        BOOT_GATE_CLEANUP_MARKER="${cleanup_marker}" \
        bash "${GATE}" --mode live --iso "${iso}" --sha256-file "${checksum}" \
        --evidence-dir "${case_evidence}" --timeout 5 \
        --kernel "${kernel}" --initrd "${initrd}" --accel tcg
    summary="${case_evidence}/gate.txt"
    contains gate-panic-message "${TMP}/gate-panic.out" 'forbidden boot error'
    contains gate-panic-log "${case_evidence}/serial.log" 'Kernel panic'
    check_field gate-panic-summary-status "${summary}" status FAIL
    check_field gate-panic-summary-exit "${summary}" exit_code 6
    if [ -f "${cleanup_marker}" ] && grep -q terminated "${cleanup_marker}"; then
        ok gate-panic-cleanup-kills-qemu
    else
        bad gate-panic-cleanup-kills-qemu
    fi

    # A process that exits without the final marker is a boot failure.
    case_name=boot-fail
    case_evidence="${TMP}/evidence-${case_name}"
    args_log="${TMP}/${case_name}.args"
    expect_status 6 gate-boot-fail \
        env PATH="${fakebin}" FAKE_CASE="${case_name}" \
        BOOT_GATE_QEMU_ARG_LOG="${args_log}" \
        bash "${GATE}" --mode live --iso "${iso}" --sha256-file "${checksum}" \
        --evidence-dir "${case_evidence}" --timeout 5 \
        --kernel "${kernel}" --initrd "${initrd}" --accel tcg
    summary="${case_evidence}/gate.txt"
    contains gate-boot-fail-message "${TMP}/gate-boot-fail.out" 'exited before the boot gate'
    check_field gate-boot-fail-summary-status "${summary}" status FAIL
    check_field gate-boot-fail-summary-exit "${summary}" exit_code 6

    # Forbidden mount errors are detected in the live gate.
    case_name=mount-fail
    case_evidence="${TMP}/evidence-${case_name}"
    cleanup_marker="${TMP}/${case_name}.cleanup"
    args_log="${TMP}/${case_name}.args"
    expect_status 6 gate-mount-fail \
        env PATH="${fakebin}" FAKE_CASE="${case_name}" \
        BOOT_GATE_QEMU_ARG_LOG="${args_log}" \
        BOOT_GATE_QEMU_PID_FILE="${TMP}/${case_name}.pid" \
        BOOT_GATE_CLEANUP_MARKER="${cleanup_marker}" \
        bash "${GATE}" --mode live --iso "${iso}" --sha256-file "${checksum}" \
        --evidence-dir "${case_evidence}" --timeout 5 \
        --kernel "${kernel}" --initrd "${initrd}" --accel tcg
    contains gate-mount-fail-message "${TMP}/gate-mount-fail.out" 'Failed to mount'

    # A nonzero QEMU exit before the marker has its own exit code.
    case_name=qemu-fail
    case_evidence="${TMP}/evidence-${case_name}"
    args_log="${TMP}/${case_name}.args"
    expect_status 4 gate-qemu-fail \
        env PATH="${fakebin}" FAKE_CASE="${case_name}" \
        BOOT_GATE_QEMU_ARG_LOG="${args_log}" \
        bash "${GATE}" --mode live --iso "${iso}" --sha256-file "${checksum}" \
        --evidence-dir "${case_evidence}" --timeout 5 \
        --kernel "${kernel}" --initrd "${initrd}" --accel tcg
    summary="${case_evidence}/gate.txt"
    contains gate-qemu-fail-message "${TMP}/gate-qemu-fail.out" 'exited with status 7'
    check_field gate-qemu-fail-summary-status "${summary}" status QEMU-FAIL
    check_field gate-qemu-fail-summary-exit "${summary}" exit_code 4

    printf '\nSummary: %s passed, %s failed\n' "${PASS}" "${FAIL}"
    printf 'Fixtures: %s\n' "${TMP}"
    [ "${FAIL}" -eq 0 ]
}

main "$@"
