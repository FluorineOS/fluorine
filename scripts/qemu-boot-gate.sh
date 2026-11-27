#!/usr/bin/env bash
set -euo pipefail

# Cleanup and summary functions are invoked through traps.
# shellcheck disable=SC2317

# Shared boot-gate implementation for FluorineOS QEMU validation.
# This is the authoritative implementation used by CI and local validation.

GATE_EXIT_PASS=0
GATE_EXIT_USAGE=2
GATE_EXIT_PREFLIGHT=3
GATE_EXIT_QEMU=4
GATE_EXIT_TIMEOUT=5
GATE_EXIT_ASSERTION=6

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(dirname -- "${SCRIPT_DIR}")
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/qemu-common.sh
source "${SCRIPT_DIR}/lib/qemu-common.sh"

# Helper failures are preflight failures in this executable.
flr_die() {
    printf 'error: %s\n' "$*" >&2
    exit "${GATE_EXIT_PREFLIGHT}"
}

MODE=""
ISO_ARG=""
CHECKSUM_ARG=""
EVIDENCE_ARG=""
TIMEOUT_ARG=""
KERNEL_ARG=""
INITRD_ARG=""
MEMORY="2048"
CPUS="2"
ACCEL_MODE="auto"

TIMEOUT=0
POLL_INTERVAL="${FLR_BOOT_GATE_POLL_INTERVAL:-1}"
KERNEL=""
INITRD=""
TMP_DIR=""
ISO_MOUNT=""
MOUNTED_ISO=0
FIRMWARE_VARS=""
QEMU_PID=""
QEMU_LOG=""
SERIAL_LOG=""
STATUS="NOT-RUN"
STATUS_DETAIL=""
REQUIRED_PATTERNS=()
FORBIDDEN_PATTERNS=()

usage() {
    cat <<'EOF'
Usage: scripts/qemu-boot-gate.sh --mode MODE --iso PATH [options]

Run one headless FluorineOS boot gate. This is the single implementation used
by .github/workflows/build-iso.yml and by local validation.

Modes:
  firmware  OVMF starts an ISO boot entry (TEST_PLAN ISO-03).
  live      Direct-kernel boot reaches graphical.target (TEST_PLAN ISO-04).

Required:
  --mode MODE          firmware or live.
  --iso PATH           ISO to boot. Must be a readable regular file.

Options:
  --sha256-file PATH   Verify the ISO with a sha256sum file.
  --evidence-dir DIR   Evidence directory. Must be outside the repository.
                       Default: XDG data directory with a timestamp and PID.
  --timeout SECONDS    Stage timeout. Default: 60 firmware, 90 live.
  --memory MB          Guest memory. Default: 2048.
  --cpus N             Guest vCPUs. Default: 2.
  --accel MODE         auto, kvm, or tcg. Default: auto.
  --kernel PATH        Live mode only: use this kernel instead of extracting.
  --initrd PATH        Live mode only: use this initrd instead of extracting.
  -h, --help           Show this help.

Environment:
  FLUORINEOS_OVMF_CODE, FLUORINEOS_OVMF_VARS, FLUORINEOS_OVMF_BIOS
      Firmware overrides for the firmware mode and non-destructive tests.
  FLR_BOOT_GATE_POLL_INTERVAL
      Integer seconds between serial-log checks. Default: 1.

Evidence:
  <evidence>/gate.txt             Gate result and resolved settings.
  <evidence>/serial.log           QEMU serial output.
  <evidence>/<mode>.qemu.log      QEMU stdout and stderr.

Exit codes:
  0  PASS
  2  Usage error
  3  Preflight error (missing ISO, firmware, or tool)
  4  QEMU failed before the boot gate completed
  5  Stage timeout
  6  Boot assertion failure
EOF
}

usage_error() {
    usage >&2
    printf 'error: %s\n' "$*" >&2
    exit "${GATE_EXIT_USAGE}"
}

need_value() {
    local option=$1
    local count=$2

    [ "${count}" -ge 2 ] || usage_error "option ${option} requires an argument"
}

validate_regular_file() {
    local path=$1
    local label=$2

    [ -n "${path}" ] || flr_die "${label} path is empty"
    [ -f "${path}" ] || flr_die "${label} is not a regular file: ${path}"
    [ -r "${path}" ] || flr_die "${label} is not readable: ${path}"
    [ -s "${path}" ] || flr_die "${label} is empty: ${path}"
}

# shellcheck disable=SC2317
stop_qemu() {
    local pid=${QEMU_PID}
    local waited=0

    [ -n "${pid}" ] || return 0
    if kill -0 "${pid}" 2>/dev/null; then
        kill -TERM "${pid}" 2>/dev/null || true
        while kill -0 "${pid}" 2>/dev/null && [ "${waited}" -lt 5 ]; do
            sleep 1
            waited=$((waited + 1))
        done
        if kill -0 "${pid}" 2>/dev/null; then
            kill -KILL "${pid}" 2>/dev/null || true
        fi
    fi
    wait "${pid}" 2>/dev/null || true
    QEMU_PID=""
}

# shellcheck disable=SC2317
cleanup() {
    if [ "${MOUNTED_ISO}" -eq 1 ] && [ -n "${ISO_MOUNT}" ]; then
        sudo umount "${ISO_MOUNT}" 2>/dev/null || true
        MOUNTED_ISO=0
    fi
    stop_qemu

    if [ -n "${FIRMWARE_VARS}" ] && [ -f "${FIRMWARE_VARS}" ]; then
        rm -f -- "${FIRMWARE_VARS}"
    fi
    if [ -n "${TMP_DIR}" ] && [ -d "${TMP_DIR}" ]; then
        rmdir -- "${TMP_DIR}" 2>/dev/null || true
    fi
}

# shellcheck disable=SC2317
write_summary() {
    local exit_code=$1
    local pattern=""

    [ -n "${FLR_EVIDENCE_DIR}" ] || return 0
    [ -d "${FLR_EVIDENCE_DIR}" ] || return 0

    {
        printf 'schema=fluorineos.boot-gate/1\n'
        printf 'mode=%s\n' "${MODE:-none}"
        printf 'status=%s\n' "${STATUS}"
        printf 'detail=%s\n' "${STATUS_DETAIL:-none}"
        printf 'exit_code=%s\n' "${exit_code}"
        printf 'iso_path=%s\n' "${FLR_ISO_PATH:-none}"
        printf 'iso_sha256=%s\n' "${FLR_ISO_SHA256:-none}"
        printf 'checksum_status=%s\n' "${FLR_CHECKSUM_STATUS:-none}"
        printf 'evidence_dir=%s\n' "${FLR_EVIDENCE_DIR}"
        printf 'serial_log=%s\n' "${SERIAL_LOG:-none}"
        printf 'qemu_log=%s\n' "${QEMU_LOG:-none}"
        printf 'timeout_seconds=%s\n' "${TIMEOUT}"
        printf 'memory_mb=%s\n' "${MEMORY}"
        printf 'cpus=%s\n' "${CPUS}"
        printf 'acceleration=%s\n' "${FLR_ACCEL:-none}"
        printf 'accel_mode=%s\n' "${ACCEL_MODE}"
        printf 'firmware_mode=%s\n' "${FLR_FIRMWARE_MODE:-none}"
        printf 'firmware=%s\n' "${FLR_FIRMWARE_DESC:-none}"
        printf 'kernel=%s\n' "${KERNEL:-none}"
        printf 'initrd=%s\n' "${INITRD:-none}"
        for pattern in "${REQUIRED_PATTERNS[@]}"; do
            printf 'required_pattern=%s\n' "${pattern}"
        done
        for pattern in "${FORBIDDEN_PATTERNS[@]}"; do
            printf 'forbidden_pattern=%s\n' "${pattern}"
        done
    } > "${FLR_EVIDENCE_DIR}/gate.txt" || true
}

# shellcheck disable=SC2317
on_exit() {
    local status=$?

    trap - EXIT INT TERM
    if [ "${status}" -ne 0 ] && [ "${STATUS}" = "NOT-RUN" ]; then
        STATUS="ERROR"
        STATUS_DETAIL="gate did not complete"
    fi
    write_summary "${status}"
    cleanup
    exit "${status}"
}

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

print_failure_logs() {
    printf '\nSerial log tail (%s):\n' "${SERIAL_LOG:-none}" >&2
    if [ -n "${SERIAL_LOG}" ]; then
        tail -n 60 "${SERIAL_LOG}" >&2 2>/dev/null || true
    fi
    printf '\nQEMU log tail (%s):\n' "${QEMU_LOG:-none}" >&2
    if [ -n "${QEMU_LOG}" ]; then
        tail -n 30 "${QEMU_LOG}" >&2 2>/dev/null || true
    fi
}

fail_gate() {
    local code=$1
    local label=$2
    shift 2

    STATUS=${label}
    STATUS_DETAIL="$*"
    printf 'error: %s\n' "${STATUS_DETAIL}" >&2
    print_failure_logs
    exit "${code}"
}

forbidden_match() {
    local pattern=""

    for pattern in "${FORBIDDEN_PATTERNS[@]}"; do
        if grep -aqE "${pattern}" "${SERIAL_LOG}" 2>/dev/null; then
            printf '%s\n' "${pattern}"
            return 0
        fi
    done
    return 1
}

assert_serial_log() {
    local pattern=""
    local missing=0
    local hit=""

    if hit=$(forbidden_match); then
        fail_gate "${GATE_EXIT_ASSERTION}" "FAIL" \
            "forbidden boot error in serial log: ${hit}"
    fi

    for pattern in "${REQUIRED_PATTERNS[@]}"; do
        if grep -aqE "${pattern}" "${SERIAL_LOG}" 2>/dev/null; then
            printf 'found: %s\n' "${pattern}"
        else
            printf 'missing: %s\n' "${pattern}" >&2
            missing=1
        fi
    done

    if [ "${missing}" -ne 0 ]; then
        fail_gate "${GATE_EXIT_ASSERTION}" "FAIL" \
            "required boot markers are missing from ${SERIAL_LOG}"
    fi
}

wait_for_boot_marker() {
    local final_marker=${REQUIRED_PATTERNS[${#REQUIRED_PATTERNS[@]} - 1]}
    local deadline=$((SECONDS + TIMEOUT))
    local qemu_status=0
    local hit=""

    while [ "${SECONDS}" -lt "${deadline}" ]; do
        if hit=$(forbidden_match); then
            fail_gate "${GATE_EXIT_ASSERTION}" "FAIL" \
                "forbidden boot error in serial log: ${hit}"
        fi

        if grep -aqE "${final_marker}" "${SERIAL_LOG}" 2>/dev/null; then
            return 0
        fi

        if [ -n "${QEMU_PID}" ] && ! kill -0 "${QEMU_PID}" 2>/dev/null; then
            qemu_status=0
            wait "${QEMU_PID}" 2>/dev/null || qemu_status=$?
            QEMU_PID=""

            if grep -aqE "${final_marker}" "${SERIAL_LOG}" 2>/dev/null; then
                return 0
            fi
            if [ "${qemu_status}" -ne 0 ]; then
                fail_gate "${GATE_EXIT_QEMU}" "QEMU-FAIL" \
                    "QEMU exited with status ${qemu_status} before the boot gate completed"
            fi
            fail_gate "${GATE_EXIT_ASSERTION}" "FAIL" \
                "QEMU exited before the boot gate reached: ${final_marker}"
        fi

        sleep "${POLL_INTERVAL}"
    done

    fail_gate "${GATE_EXIT_TIMEOUT}" "TIMEOUT" \
        "boot gate timed out after ${TIMEOUT}s waiting for: ${final_marker}"
}

configure_patterns() {
    if [ "${MODE}" = "firmware" ]; then
        REQUIRED_PATTERNS=('BdsDxe: starting Boot[0-9]+')
        FORBIDDEN_PATTERNS=(
            'Boot Failed'
            'No bootable option'
            'Failed to load image'
        )
    else
        REQUIRED_PATTERNS=(
            'Linux version [0-9]'
            'squashfs: version'
            'Reached target multi-user.target'
            'Reached target graphical.target'
        )
        FORBIDDEN_PATTERNS=(
            'Kernel panic'
            'SQUASHFS error'
            'Unable to find a medium containing a live file system'
            'Failed to mount'
        )
    fi
}

configure_acceleration() {
    flr_detect_kvm

    case "${ACCEL_MODE}" in
        auto)
            flr_build_accel_args
            if [ "${FLR_KVM_AVAILABLE}" -ne 1 ]; then
                printf 'warning: hardware acceleration is unavailable; this gate runs under TCG (%s)\n' \
                    "${FLR_KVM_REASON}" >&2
            fi
            ;;
        kvm)
            flr_require_kvm
            FLR_ACCEL="KVM"
            FLR_ACCEL_ARGS=(-accel kvm -cpu host)
            ;;
        tcg)
            FLR_ACCEL="TCG"
            FLR_ACCEL_ARGS=(-accel tcg)
            ;;
        *)
            usage_error "invalid --accel value: ${ACCEL_MODE}"
            ;;
    esac

    flr_classify_environment
    flr_source_metadata
    FLR_WSL=0
    if flr_is_wsl; then
        FLR_WSL=1
    fi
    FLR_QEMU_VERSION="unknown"
    if command -v qemu-system-x86_64 >/dev/null 2>&1; then
        FLR_QEMU_VERSION=$(qemu-system-x86_64 --version 2>/dev/null | head -n 1) ||
            FLR_QEMU_VERSION="unknown"
    fi
}

prepare_live_kernel() {
    local -a kernels=()
    local -a initrds=()

    if [ -n "${KERNEL_ARG}" ]; then
        validate_regular_file "${KERNEL_ARG}" "kernel"
        validate_regular_file "${INITRD_ARG}" "initrd"
        KERNEL=$(flr_realpath "${KERNEL_ARG}")
        INITRD=$(flr_realpath "${INITRD_ARG}")
        return 0
    fi

    flr_require_cmd sudo
    flr_require_cmd mount
    flr_require_cmd umount

    TMP_DIR=$(mktemp -d) || flr_die "cannot create a temporary directory"
    ISO_MOUNT="${TMP_DIR}/iso"
    mkdir -p -- "${ISO_MOUNT}" ||
        flr_die "cannot create ISO mount point: ${ISO_MOUNT}"

    if ! sudo mount -o loop,ro "${FLR_ISO_PATH}" "${ISO_MOUNT}"; then
        flr_die "cannot mount the ISO read-only: ${FLR_ISO_PATH}"
    fi
    MOUNTED_ISO=1

    kernels=("${ISO_MOUNT}"/live/vmlinuz-*)
    initrds=("${ISO_MOUNT}"/live/initrd.img-*)
    [ "${#kernels[@]}" -eq 1 ] ||
        flr_die "expected exactly one live/vmlinuz-* in ${FLR_ISO_PATH}, found ${#kernels[@]}"
    [ "${#initrds[@]}" -eq 1 ] ||
        flr_die "expected exactly one live/initrd.img-* in ${FLR_ISO_PATH}, found ${#initrds[@]}"
    validate_regular_file "${kernels[0]}" "ISO kernel"
    validate_regular_file "${initrds[0]}" "ISO initrd"

    KERNEL="${TMP_DIR}/vmlinuz"
    INITRD="${TMP_DIR}/initrd"
    cp -- "${kernels[0]}" "${KERNEL}" || flr_die "cannot copy the live kernel"
    cp -- "${initrds[0]}" "${INITRD}" || flr_die "cannot copy the live initrd"

    if ! sudo umount "${ISO_MOUNT}"; then
        flr_die "cannot unmount the ISO: ${ISO_MOUNT}"
    fi
    MOUNTED_ISO=0
}

start_qemu() {
    local -a args=()
    local arg=""

    args+=(
        -machine q35
        "${FLR_ACCEL_ARGS[@]}"
        -m "${MEMORY}"
        -smp "${CPUS}"
    )

    if [ "${MODE}" = "firmware" ]; then
        args+=(
            "${FLR_FIRMWARE_ARGS[@]}"
            -device virtio-vga
            -display none
            -drive "file=${FLR_ISO_PATH},media=cdrom,readonly=on"
            -boot d
        )
    else
        args+=(
            -kernel "${KERNEL}"
            -initrd "${INITRD}"
            -append "boot=live components console=ttyS0,115200 systemd.journald.forward_to_console=1 systemd.setenv=WLR_RENDERER_ALLOW_SOFTWARE=1"
            -device virtio-vga
            -display none
            -drive "file=${FLR_ISO_PATH},media=cdrom,readonly=on"
        )
    fi

    args+=("${FLR_SERIAL_ARGS[@]}" -no-reboot)

    printf 'Gate command: qemu-system-x86_64'
    for arg in "${args[@]}"; do
        printf ' %q' "${arg}"
    done
    printf '\n'

    qemu-system-x86_64 "${args[@]}" > "${QEMU_LOG}" 2>&1 &
    QEMU_PID=$!
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --mode)
                need_value "$1" "$#"
                MODE=$2
                shift 2
                ;;
            --iso)
                need_value "$1" "$#"
                ISO_ARG=$2
                shift 2
                ;;
            --sha256-file)
                need_value "$1" "$#"
                CHECKSUM_ARG=$2
                shift 2
                ;;
            --evidence-dir)
                need_value "$1" "$#"
                EVIDENCE_ARG=$2
                shift 2
                ;;
            --timeout)
                need_value "$1" "$#"
                TIMEOUT_ARG=$2
                shift 2
                ;;
            --memory)
                need_value "$1" "$#"
                MEMORY=$2
                shift 2
                ;;
            --cpus)
                need_value "$1" "$#"
                CPUS=$2
                shift 2
                ;;
            --accel)
                need_value "$1" "$#"
                ACCEL_MODE=$2
                shift 2
                ;;
            --kernel)
                need_value "$1" "$#"
                KERNEL_ARG=$2
                shift 2
                ;;
            --initrd)
                need_value "$1" "$#"
                INITRD_ARG=$2
                shift 2
                ;;
            -h | --help)
                usage
                exit "${GATE_EXIT_PASS}"
                ;;
            --)
                shift
                [ "$#" -eq 0 ] || usage_error "unexpected positional argument: $1"
                break
                ;;
            *)
                usage_error "unknown option: $1"
                ;;
        esac
    done
}

validate_args() {
    [ -n "${MODE}" ] || usage_error "--mode is required"
    case "${MODE}" in
        firmware | live) ;;
        *) usage_error "invalid --mode value: ${MODE}" ;;
    esac

    [ -n "${ISO_ARG}" ] || usage_error "--iso is required"

    if [ -n "${TIMEOUT_ARG}" ]; then
        [[ "${TIMEOUT_ARG}" =~ ^[1-9][0-9]*$ ]] ||
            usage_error "invalid --timeout value: ${TIMEOUT_ARG}"
        TIMEOUT=${TIMEOUT_ARG}
    elif [ "${MODE}" = "firmware" ]; then
        TIMEOUT=60
    else
        TIMEOUT=90
    fi

    [[ "${MEMORY}" =~ ^[1-9][0-9]*$ ]] ||
        usage_error "invalid --memory value: ${MEMORY}"
    [[ "${CPUS}" =~ ^[1-9][0-9]*$ ]] ||
        usage_error "invalid --cpus value: ${CPUS}"

    case "${ACCEL_MODE}" in
        auto | kvm | tcg) ;;
        *) usage_error "invalid --accel value: ${ACCEL_MODE}" ;;
    esac

    [[ "${POLL_INTERVAL}" =~ ^[1-9][0-9]*$ ]] ||
        usage_error "invalid FLR_BOOT_GATE_POLL_INTERVAL: ${POLL_INTERVAL}"

    if [ "${MODE}" = "firmware" ]; then
        if [ -n "${KERNEL_ARG}" ] || [ -n "${INITRD_ARG}" ]; then
            usage_error "--kernel and --initrd are only valid with --mode live"
        fi
    else
        if { [ -n "${KERNEL_ARG}" ] && [ -z "${INITRD_ARG}" ]; } ||
            { [ -z "${KERNEL_ARG}" ] && [ -n "${INITRD_ARG}" ]; }; then
            usage_error "--kernel and --initrd must be supplied together"
        fi
    fi
}

main() {
    parse_args "$@"
    validate_args

    flr_require_cmd qemu-system-x86_64
    flr_require_cmd sha256sum
    flr_require_cmd realpath
    flr_require_cmd stat
    flr_require_cmd mktemp
    flr_require_cmd grep
    flr_require_cmd tail
    flr_require_cmd sleep

    flr_resolve_iso "${ISO_ARG}"
    flr_resolve_checksum "${CHECKSUM_ARG}"
    flr_verify_iso

    if [ -z "${EVIDENCE_ARG}" ]; then
        EVIDENCE_ARG=$(flr_default_evidence_dir)
    fi
    flr_resolve_evidence_dir "${EVIDENCE_ARG}"
    mkdir -p -- "${FLR_EVIDENCE_DIR}" ||
        flr_die "cannot create evidence directory: ${FLR_EVIDENCE_DIR}"

    SERIAL_LOG="${FLR_EVIDENCE_DIR}/serial.log"
    QEMU_LOG="${FLR_EVIDENCE_DIR}/${MODE}.qemu.log"
    : > "${SERIAL_LOG}" || flr_die "cannot create serial log: ${SERIAL_LOG}"
    : > "${QEMU_LOG}" || flr_die "cannot create QEMU log: ${QEMU_LOG}"
    flr_build_serial_args ""

    configure_acceleration
    configure_patterns

    if [ "${MODE}" = "firmware" ]; then
        flr_detect_firmware
        FIRMWARE_VARS=$(mktemp --suffix=-OVMF_VARS.fd) ||
            flr_die "cannot create a temporary OVMF variables file"
        flr_prepare_firmware "${FIRMWARE_VARS}" 1
    else
        FLR_FIRMWARE_MODE="not-used"
        FLR_FIRMWARE_DESC="not used (direct kernel boot)"
        prepare_live_kernel
    fi

    printf 'Boot gate: %s\n' "${MODE}"
    printf 'ISO: %s\n' "${FLR_ISO_PATH}"
    printf 'Serial log: %s\n' "${SERIAL_LOG}"
    printf 'Acceleration: %s\n' "${FLR_ACCEL}"
    printf 'Timeout: %s seconds\n' "${TIMEOUT}"

    export FLR_BOOT_GATE_MODE="${MODE}"
    export FLR_BOOT_GATE_SERIAL_LOG="${SERIAL_LOG}"
    export FLR_BOOT_GATE_TIMEOUT="${TIMEOUT}"

    start_qemu
    wait_for_boot_marker
    assert_serial_log

    STATUS="PASS"
    STATUS_DETAIL="all required boot markers found; no forbidden boot errors"
    printf 'BOOT-GATE PASS: %s\n' "${STATUS_DETAIL}"
    exit "${GATE_EXIT_PASS}"
}

main "$@"
