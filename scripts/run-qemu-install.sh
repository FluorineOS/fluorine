#!/usr/bin/env bash
set -euo pipefail

# Exercise the Calamares installer against a throwaway QCOW2 disk.
#
# Usage: scripts/run-qemu-install.sh [options]

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
DISK_SIZE="${FLUORINEOS_DISK_SIZE:-25G}"

BOOT_DISK=0
REUSE_DISK=0
DRY_RUN=0
REQUIRE_KVM=0
ISO_FROM_CLI=0
ISO_FROM_ENV=0
ORIGINAL_ARGS=()
ISO_REQUESTED="${FLUORINEOS_ISO:-}"
CHECKSUM_REQUESTED="${FLUORINEOS_ISO_SHA256_FILE:-}"
EVIDENCE_REQUESTED="${FLUORINEOS_EVIDENCE_DIR:-}"
SERIAL_SOCKET_REQUESTED="${FLUORINEOS_SERIAL_SOCKET:-}"
DISK_REQUESTED="${FLUORINEOS_DISK_IMAGE:-}"
VARS_REQUESTED="${FLUORINEOS_VARS_IMAGE:-}"
VNC_DISPLAY="${FLUORINEOS_VNC:-}"

if [ -n "${FLUORINEOS_ISO:-}" ]; then
    ISO_FROM_ENV=1
fi

usage() {
    cat <<'EOF'
Usage: scripts/run-qemu-install.sh [options]

Creates a new 25 GB QCOW2 disk in the evidence directory and boots the ISO
with UEFI firmware so Calamares can install onto it.

Options:
  --iso PATH              Use this ISO. Overrides FLUORINEOS_ISO and discovery.
  --sha256-file PATH      Verify the ISO with this sha256sum file.
  --evidence-dir DIR      Evidence directory. Must be outside the repository.
  --serial-socket PATH    Also expose serial traffic on a Unix socket.
  --disk PATH             Disk image, relative to the evidence directory or
                          absolute and inside it. Default <evidence>/disk.qcow2.
  --reuse-disk            Allow an existing QCOW2 disk to be reused.
  --boot-disk             Boot the installed disk instead of the installer ISO.
  --disk-size SIZE        Size for a new disk (default 25G).
  --dry-run               Validate and print the plan; create nothing.
  --require-kvm           Fail unless KVM is available.
  -h, --help              Show this help.

Environment:
  FLUORINEOS_ISO, FLUORINEOS_ISO_SHA256_FILE, FLUORINEOS_EVIDENCE_DIR,
  FLUORINEOS_SERIAL_SOCKET, FLUORINEOS_VNC, FLUORINEOS_DISK_IMAGE,
  FLUORINEOS_VARS_IMAGE, FLUORINEOS_DISK_SIZE

Disk images must be under the evidence directory. Existing images require
--reuse-disk; --boot-disk implies reuse. Block devices, symlinks, backing
files, non-QCOW2 files, and paths outside the evidence directory are refused.
The serial log is written to <evidence>/serial.log. A JSON manifest is written
to <evidence>/manifest.json for every non-dry run.
EOF
}

on_exit() {
    local status=$?

    trap - EXIT INT TERM
    if [ "${FLR_MANIFEST_ACTIVE:-0}" -eq 1 ]; then
        flr_manifest_finalize "${status}" || true
    fi
    exit "${status}"
}

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

main() {
    local iso_version=""
    local reuse_requested=0
    local boot_args=()
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
            --disk)
                [ "$#" -ge 2 ] || flr_die "option --disk requires an argument"
                DISK_REQUESTED=$2
                shift 2
                ;;
            --disk-size)
                [ "$#" -ge 2 ] || flr_die "option --disk-size requires an argument"
                DISK_SIZE=$2
                shift 2
                ;;
            --reuse-disk)
                REUSE_DISK=1
                shift
                ;;
            --boot-disk)
                BOOT_DISK=1
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --require-kvm)
                REQUIRE_KVM=1
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

    reuse_requested=${REUSE_DISK}

    [[ "${DISK_SIZE}" =~ ^[0-9]+[KkMmGgTtPp]$ ]] ||
        flr_die "invalid disk size: ${DISK_SIZE}"
    FLR_DISK_SIZE_SPEC=${DISK_SIZE}

    flr_require_cmd qemu-system-x86_64
    flr_require_cmd qemu-img
    flr_require_cmd sha256sum
    flr_require_cmd realpath
    flr_require_cmd stat

    if [ -z "${EVIDENCE_REQUESTED}" ]; then
        EVIDENCE_REQUESTED=$(flr_default_evidence_dir)
    fi
    flr_resolve_evidence_dir "${EVIDENCE_REQUESTED}"

    if [ "${BOOT_DISK}" -eq 1 ]; then
        reuse_requested=1
        FLR_ISO_SOURCE="none"
        if [ -n "${ISO_REQUESTED}" ] || [ -n "${CHECKSUM_REQUESTED}" ]; then
            flr_warn "--boot-disk ignores ISO and checksum selection"
        fi
    fi

    flr_resolve_disk "${DISK_REQUESTED}" "${reuse_requested}"
    flr_resolve_vars "${VARS_REQUESTED}"

    if [ "${BOOT_DISK}" -eq 0 ]; then
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
    fi

    if [ -n "${SERIAL_SOCKET_REQUESTED}" ]; then
        flr_validate_socket_path "${SERIAL_SOCKET_REQUESTED}"
    fi
    flr_build_serial_args "${FLR_SERIAL_SOCKET}"

    flr_detect_environment
    if [ "${REQUIRE_KVM}" -eq 1 ]; then
        flr_require_kvm
    fi
    flr_build_gpu_args "${VNC_DISPLAY}"

    if [ "${BOOT_DISK}" -eq 1 ] && [ "${FLR_VARS_EXISTS}" -eq 0 ]; then
        flr_warn "booting the installed disk with a new UEFI variable store; NVRAM boot entries will not be preserved"
    fi

    flr_print_environment

    if [ "${DRY_RUN}" -eq 1 ]; then
        printf 'Dry run: no evidence directory, disk, firmware copy, manifest, or QEMU process was created.\n'
        return 0
    fi

    flr_require_cmd jq
    mkdir -p -- "${FLR_EVIDENCE_DIR}"
    mkdir -p -- "$(dirname -- "${FLR_DISK_PATH}")"
    options_json=$(flr_manifest_sanitize_args "${ORIGINAL_ARGS[@]}") ||
        flr_die "cannot sanitize command-line options"
    flr_manifest_init "run-qemu-install.sh" "${MEMORY}" "${CPUS}" "${options_json}" \
        preflight version disk-prepare qemu installer first-boot
    flr_manifest_stage preflight PASS \
        "Disk and ISO checks complete; checksum status ${FLR_CHECKSUM_STATUS}; acceleration ${FLR_ACCEL}"
    printf 'Manifest: %s\n' "${FLR_MANIFEST_PATH}"

    flr_write_artifact_record
    flr_write_environment_record "${MEMORY}" "${CPUS}"

    flr_prepare_firmware "${FLR_VARS_PATH}" 0

    flr_manifest_stage disk-prepare RUNNING "Preparing the QCOW2 target disk"
    if [ "${FLR_DISK_EXISTS}" -eq 0 ]; then
        printf 'Creating new disk: %s (%s)\n' "${FLR_DISK_PATH}" "${DISK_SIZE}"
        if ! qemu-img create -f qcow2 "${FLR_DISK_PATH}" "${DISK_SIZE}"; then
            flr_manifest_stage disk-prepare FAIL "qemu-img create failed"
            flr_die "could not create disk image: ${FLR_DISK_PATH}"
        fi
        flr_manifest_stage disk-prepare PASS "New QCOW2 disk created (${DISK_SIZE})"
    else
        printf 'Reusing existing disk: %s\n' "${FLR_DISK_PATH}"
        flr_manifest_stage disk-prepare PASS "Existing QCOW2 disk reused"
    fi

    if [ "${BOOT_DISK}" -eq 1 ]; then
        boot_args=(-boot c)
        printf 'Booting the installed disk\n'
    else
        boot_args=(-cdrom "${FLR_ISO_PATH}" -boot d)
        printf 'Booting the installer from %s\n' "${FLR_ISO_PATH}"
    fi
    printf 'Serial log: %s\n' "${FLR_SERIAL_LOG}"

    flr_manifest_stage qemu RUNNING "QEMU is starting"
    qemu-system-x86_64 \
        -machine q35 \
        "${FLR_ACCEL_ARGS[@]}" \
        -m "${MEMORY}" \
        -smp "${CPUS}" \
        "${FLR_FIRMWARE_ARGS[@]}" \
        "${FLR_GPU_ARGS[@]}" \
        "${boot_args[@]}" \
        -drive "file=${FLR_DISK_PATH},format=qcow2,if=virtio" \
        -netdev user,id=net0 \
        -device virtio-net-pci,netdev=net0 \
        "${FLR_SERIAL_ARGS[@]}" || qemu_status=$?

    if [ "${qemu_status}" -eq 0 ]; then
        flr_manifest_stage qemu PASS \
            "QEMU exited with status 0; installer evidence must be recorded separately"
    else
        flr_manifest_stage qemu FAIL "QEMU exited with status ${qemu_status}"
        printf 'QEMU exited with status %s\n' "${qemu_status}" >&2
        exit "${qemu_status}"
    fi
}

main "$@"
