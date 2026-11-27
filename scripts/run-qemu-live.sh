#!/usr/bin/env bash
set -euo pipefail

# Boot the FluorineOS live image in QEMU with UEFI firmware.
#
# Usage: scripts/run-qemu-live.sh [options]

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(dirname -- "${SCRIPT_DIR}")
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/qemu-common.sh
source "${SCRIPT_DIR}/lib/qemu-common.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/qemu-manifest.sh
source "${SCRIPT_DIR}/lib/qemu-manifest.sh"

MEMORY=4096
CPUS=4

EXPORT_WIN=0
DRY_RUN=0
REQUIRE_KVM=0
ISO_FROM_CLI=0
ISO_FROM_ENV=0
ORIGINAL_ARGS=()
ISO_REQUESTED="${FLUORINEOS_ISO:-}"
CHECKSUM_REQUESTED="${FLUORINEOS_ISO_SHA256_FILE:-}"
EVIDENCE_REQUESTED="${FLUORINEOS_EVIDENCE_DIR:-}"
SERIAL_SOCKET_REQUESTED="${FLUORINEOS_SERIAL_SOCKET:-}"
VNC_DISPLAY="${FLUORINEOS_VNC:-}"
VARS_COPY=""

if [ -n "${FLUORINEOS_ISO:-}" ]; then
    ISO_FROM_ENV=1
fi

usage() {
    cat <<'EOF'
Usage: scripts/run-qemu-live.sh [options]

Boots the FluorineOS live ISO in QEMU with UEFI firmware.

Options:
  --iso PATH              Use this ISO. Overrides FLUORINEOS_ISO and discovery.
  --sha256-file PATH      Verify the ISO with this sha256sum file.
  --evidence-dir DIR      Evidence directory. Must be outside the repository.
  --serial-socket PATH    Also expose serial traffic on a Unix socket.
  --dry-run               Validate and print the plan; create nothing.
  --require-kvm           Fail unless KVM is available.
  --export-win            Copy the selected ISO to Windows Downloads first.
  -h, --help              Show this help.

Environment:
  FLUORINEOS_ISO, FLUORINEOS_ISO_SHA256_FILE, FLUORINEOS_EVIDENCE_DIR,
  FLUORINEOS_SERIAL_SOCKET, FLUORINEOS_VNC

Without --iso, the launcher reads VERSION and accepts only one matching
live-build output, including the doubled-architecture .hybrid.iso name.
The serial log is written to <evidence>/serial.log. A JSON manifest is written
to <evidence>/manifest.json for every non-dry run.
EOF
}

cleanup() {
    if [ -n "${VARS_COPY}" ] && [ -f "${VARS_COPY}" ]; then
        rm -f -- "${VARS_COPY}"
    fi
}

on_exit() {
    local status=$?

    trap - EXIT INT TERM
    if [ "${FLR_MANIFEST_ACTIVE:-0}" -eq 1 ]; then
        flr_manifest_finalize "${status}" || true
    fi
    cleanup
    exit "${status}"
}

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

export_to_windows() {
    local iso=$1
    local name=""
    local cmd="/mnt/c/Windows/System32/cmd.exe"
    local profile=""
    local downloads=""

    [ -x "${cmd}" ] || flr_die "cmd.exe not found; --export-win requires WSL2"
    command -v wslpath >/dev/null 2>&1 ||
        flr_die "wslpath not found; --export-win requires WSL2"

    profile=$("${cmd}" /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r')
    [ -n "${profile}" ] || flr_die "could not resolve the Windows user profile"

    name=$(basename -- "${iso}")
    downloads=$(wslpath -u "${profile}")/Downloads
    mkdir -p -- "${downloads}"
    cp -- "${iso}" "${downloads}/${name}"
    printf '%s  %s\n' "${FLR_ISO_SHA256}" "${name}" > "${downloads}/${name}.sha256"
    printf 'Exported ISO to %s\n' "${downloads}/${name}"
    printf 'Exported checksum to %s\n' "${downloads}/${name}.sha256"
}

main() {
    local iso_version=""
    local options_json=""
    local qemu_status=0

    ORIGINAL_ARGS=("$@")
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --iso)
                [ "$#" -ge 2 ] || flr_die "option --iso requires an argument"
                ISO_REQUESTED=$2
                ISO_FROM_CLI=1
                shift 2
                ;;
            --sha256-file)
                [ "$#" -ge 2 ] || flr_die "option --sha256-file requires an argument"
                CHECKSUM_REQUESTED=$2
                shift 2
                ;;
            --evidence-dir)
                [ "$#" -ge 2 ] || flr_die "option --evidence-dir requires an argument"
                EVIDENCE_REQUESTED=$2
                shift 2
                ;;
            --serial-socket)
                [ "$#" -ge 2 ] || flr_die "option --serial-socket requires an argument"
                SERIAL_SOCKET_REQUESTED=$2
                shift 2
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --require-kvm)
                REQUIRE_KVM=1
                shift
                ;;
            --export-win)
                EXPORT_WIN=1
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            --)
                shift
                [ "$#" -eq 0 ] || flr_die "unexpected positional argument: $1"
                break
                ;;
            *)
                usage >&2
                flr_die "unknown option: $1"
                ;;
        esac
    done

    flr_require_cmd qemu-system-x86_64
    flr_require_cmd sha256sum
    flr_require_cmd realpath
    flr_require_cmd stat

    if [ -z "${ISO_REQUESTED}" ]; then
        iso_version=$(flr_detect_version) ||
            flr_die "cannot derive the ISO version from ${REPO_ROOT}/VERSION; use --iso PATH or FLUORINEOS_ISO"
        ISO_REQUESTED=$(flr_find_iso "${iso_version}")
    elif [ -n "${FLUORINEOS_ISO:-}" ] && [ "${ISO_REQUESTED}" != "${FLUORINEOS_ISO}" ]; then
        printf 'ISO selection: --iso overrides FLUORINEOS_ISO\n'
    fi

    if [ "${ISO_FROM_CLI}" -eq 1 ]; then
        FLR_ISO_SOURCE="explicit"
    elif [ "${ISO_FROM_ENV}" -eq 1 ]; then
        FLR_ISO_SOURCE="environment"
    else
        FLR_ISO_SOURCE="discovered"
    fi

    flr_resolve_iso "${ISO_REQUESTED}"
    flr_resolve_checksum "${CHECKSUM_REQUESTED}"
    flr_verify_iso

    if [ -z "${EVIDENCE_REQUESTED}" ]; then
        EVIDENCE_REQUESTED=$(flr_default_evidence_dir)
    fi
    flr_resolve_evidence_dir "${EVIDENCE_REQUESTED}"
    if [ -n "${SERIAL_SOCKET_REQUESTED}" ]; then
        flr_validate_socket_path "${SERIAL_SOCKET_REQUESTED}"
    fi
    flr_build_serial_args "${FLR_SERIAL_SOCKET}"

    flr_detect_environment
    if [ "${REQUIRE_KVM}" -eq 1 ]; then
        flr_require_kvm
    fi
    flr_build_gpu_args "${VNC_DISPLAY}"

    flr_print_environment

    if [ "${DRY_RUN}" -eq 1 ]; then
        printf 'Dry run: no evidence directory, firmware copy, export, manifest, or QEMU process was created.\n'
        return 0
    fi

    flr_require_cmd jq
    mkdir -p -- "${FLR_EVIDENCE_DIR}"
    options_json=$(flr_manifest_sanitize_args "${ORIGINAL_ARGS[@]}") ||
        flr_die "cannot sanitize command-line options"
    flr_manifest_init "run-qemu-live.sh" "${MEMORY}" "${CPUS}" "${options_json}" \
        preflight version qemu boot shutdown
    flr_manifest_stage preflight PASS \
        "ISO verified; checksum status ${FLR_CHECKSUM_STATUS}; acceleration ${FLR_ACCEL}"
    printf 'Manifest: %s\n' "${FLR_MANIFEST_PATH}"

    flr_write_artifact_record
    flr_write_environment_record "${MEMORY}" "${CPUS}"

    if [ "${EXPORT_WIN}" -eq 1 ]; then
        export_to_windows "${FLR_ISO_PATH}"
    fi

    VARS_COPY=$(mktemp --suffix=-OVMF_VARS.fd)
    flr_prepare_firmware "${VARS_COPY}" 1

    printf 'Booting %s\n' "${FLR_ISO_PATH}"
    printf 'Serial log: %s\n' "${FLR_SERIAL_LOG}"

    flr_manifest_stage qemu RUNNING "QEMU is starting"
    qemu-system-x86_64 \
        -machine q35 \
        "${FLR_ACCEL_ARGS[@]}" \
        -m "${MEMORY}" \
        -smp "${CPUS}" \
        "${FLR_FIRMWARE_ARGS[@]}" \
        "${FLR_GPU_ARGS[@]}" \
        -cdrom "${FLR_ISO_PATH}" \
        -boot d \
        -netdev user,id=net0 \
        -device virtio-net-pci,netdev=net0 \
        "${FLR_SERIAL_ARGS[@]}" || qemu_status=$?

    if [ "${qemu_status}" -eq 0 ]; then
        flr_manifest_stage qemu PASS \
            "QEMU exited with status 0; boot evidence must be recorded separately"
    else
        flr_manifest_stage qemu FAIL "QEMU exited with status ${qemu_status}"
        printf 'QEMU exited with status %s\n' "${qemu_status}" >&2
        exit "${qemu_status}"
    fi
}

main "$@"
