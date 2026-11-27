#!/usr/bin/env bash
# shellcheck disable=SC2034
# Shared helpers for the FluorineOS QEMU launchers.
# This file is sourced. It must not execute anything at load time.

FLR_ISO_REQUESTED=""
FLR_ISO_PATH=""
FLR_ISO_SIZE=""
FLR_ISO_SHA256=""
FLR_ISO_VERSION_FROM_NAME=""
FLR_CHECKSUM_FILE=""
FLR_CHECKSUM_EXPECTED=""
FLR_CHECKSUM_STATUS="not-supplied"
FLR_EVIDENCE_DIR=""
FLR_SERIAL_LOG=""
FLR_SERIAL_SOCKET=""
FLR_SERIAL_ARGS=()
FLR_ACCEL=""
FLR_ACCEL_ARGS=()
FLR_KVM_AVAILABLE=0
FLR_KVM_REASON=""
FLR_ENV_CLASS=""
FLR_WSL=0
FLR_QEMU_VERSION=""
FLR_SOURCE_COMMIT=""
FLR_SOURCE_DIRTY=""
FLR_SOURCE_BRANCH=""
FLR_REPO_VERSION=""
FLR_FIRMWARE_MODE=""
FLR_FIRMWARE_CODE=""
FLR_FIRMWARE_VARS_SOURCE=""
FLR_FIRMWARE_BIOS=""
FLR_FIRMWARE_DESC=""
FLR_FIRMWARE_ARGS=()
FLR_GPU_ARGS=()
FLR_GPU_DESC=""
FLR_GPU_MODE=""
FLR_ISO_SOURCE="none"
FLR_DISK_PATH=""
FLR_DISK_EXISTS=0
FLR_DISK_REUSE=0
FLR_DISK_SIZE_SPEC=""
FLR_VARS_PATH=""
FLR_VARS_EXISTS=0

flr_die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

flr_warn() {
    printf 'warning: %s\n' "$*" >&2
}

flr_require_cmd() {
    local cmd=$1
    command -v "${cmd}" >/dev/null 2>&1 ||
        flr_die "${cmd} not found in PATH"
}

flr_realpath() {
    realpath -m -- "$1"
}

flr_is_wsl() {
    [ -n "${WSL_DISTRO_NAME:-}" ] ||
        grep -qi microsoft /proc/version 2>/dev/null
}

flr_detect_version() {
    local version_file="${REPO_ROOT}/VERSION"
    local version=""

    [ -f "${version_file}" ] || return 1
    version=$(tr -d '[:space:]' < "${version_file}") || return 1
    [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    printf '%s\n' "${version}"
}

flr_iso_version_from_name() {
    local name=$1

    if [[ "${name}" =~ ^FluorineOS-([0-9]+\.[0-9]+\.[0-9]+)- ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    fi
}

flr_find_iso() {
    local version=$1
    local candidate
    local found=()

    [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
        flr_die "invalid VERSION value: ${version}"

    for candidate in \
        "${REPO_ROOT}/FluorineOS-${version}-amd64.iso" \
        "${REPO_ROOT}/FluorineOS-${version}-amd64.hybrid.iso" \
        "${REPO_ROOT}/FluorineOS-${version}-amd64-amd64.iso" \
        "${REPO_ROOT}/FluorineOS-${version}-amd64-amd64.hybrid.iso" \
        "${REPO_ROOT}/live-image-amd64.iso" \
        "${REPO_ROOT}/live-image-amd64.hybrid.iso"; do
        if [ -f "${candidate}" ]; then
            found+=("${candidate}")
        fi
    done

    if [ "${#found[@]}" -eq 0 ]; then
        flr_die "no ISO for version ${version} found in ${REPO_ROOT}; use --iso PATH or FLUORINEOS_ISO"
    fi

    if [ "${#found[@]}" -gt 1 ]; then
        printf 'error: multiple ISO candidates for version %s:\n' "${version}" >&2
        printf '  %s\n' "${found[@]}" >&2
        flr_die "refusing ambiguous ISO selection; use --iso PATH"
    fi

    case "$(basename -- "${found[0]}")" in
        live-image-amd64.iso | live-image-amd64.hybrid.iso)
            flr_warn "using unversioned live-build output; verify the intended artifact"
            ;;
    esac

    printf '%s\n' "${found[0]}"
}

flr_resolve_iso() {
    local requested=$1
    local resolved=""
    local size=""
    local expected_version=""

    [ -n "${requested}" ] || flr_die "ISO path is empty"

    case "${requested}" in
        /dev/*)
            flr_die "refusing device path as ISO: ${requested}"
            ;;
    esac

    if [ ! -e "${requested}" ]; then
        flr_die "ISO not found: ${requested}"
    fi
    if [ -b "${requested}" ]; then
        flr_die "refusing block device as ISO: ${requested}"
    fi
    if [ ! -f "${requested}" ]; then
        flr_die "ISO is not a regular file: ${requested}"
    fi
    if [ ! -r "${requested}" ]; then
        flr_die "ISO is not readable: ${requested}"
    fi

    resolved=$(flr_realpath "${requested}") ||
        flr_die "cannot resolve ISO path: ${requested}"
    if [ ! -s "${resolved}" ]; then
        flr_die "ISO is empty: ${resolved}"
    fi

    size=$(stat -c %s -- "${resolved}") ||
        flr_die "cannot determine ISO size: ${resolved}"
    [[ "${size}" =~ ^[0-9]+$ ]] ||
        flr_die "invalid ISO size for ${resolved}: ${size}"

    FLR_ISO_REQUESTED=${requested}
    FLR_ISO_PATH=${resolved}
    FLR_ISO_SIZE=${size}
    FLR_ISO_VERSION_FROM_NAME=$(flr_iso_version_from_name "$(basename -- "${resolved}")")

    if expected_version=$(flr_detect_version); then
        if [ -n "${FLR_ISO_VERSION_FROM_NAME}" ] &&
            [ "${FLR_ISO_VERSION_FROM_NAME}" != "${expected_version}" ]; then
            flr_warn "ISO filename reports version ${FLR_ISO_VERSION_FROM_NAME}, but VERSION is ${expected_version}"
        fi
    fi
}

flr_parse_checksum_file() {
    local file=$1
    local base=$2
    local line=""
    local digest=""
    local name=""
    local expected=""
    local bare=""

    while IFS= read -r line || [ -n "${line}" ]; do
        line=${line%$'\r'}
        if [ -z "${line//[[:space:]]/}" ]; then
            continue
        fi
        if [[ "${line}" == \#* ]]; then
            continue
        fi

        digest=${line%%[[:space:]]*}
        name=${line#"${digest}"}
        name=${name#"${name%%[![:space:]]*}"}
        name=${name#\*}
        name=${name%"${name##*[![:space:]]}"}

        [[ "${digest}" =~ ^[0-9a-fA-F]{64}$ ]] ||
            flr_die "invalid SHA-256 entry in ${file}: ${line}"

        if [ -z "${name}" ]; then
            if [ -n "${bare}" ] && [ "${bare,,}" != "${digest,,}" ]; then
                flr_die "conflicting bare digests in ${file}"
            fi
            bare=${digest}
            continue
        fi

        if [ "$(basename -- "${name}")" != "${base}" ]; then
            continue
        fi

        if [ -n "${expected}" ] && [ "${expected,,}" != "${digest,,}" ]; then
            flr_die "conflicting digests for ${base} in ${file}"
        fi
        expected=${digest}
    done < "${file}"

    if [ -n "${expected}" ]; then
        printf '%s\n' "${expected}"
        return 0
    fi
    if [ -n "${bare}" ]; then
        printf '%s\n' "${bare}"
        return 0
    fi

    flr_die "checksum file ${file} has no entry for ${base}"
}

flr_resolve_checksum() {
    local explicit=${1:-}
    local base=""
    local expected=""

    FLR_CHECKSUM_FILE=""
    FLR_CHECKSUM_EXPECTED=""
    FLR_CHECKSUM_STATUS="recorded-only"

    if [ -n "${explicit}" ]; then
        if [ ! -e "${explicit}" ]; then
            flr_die "checksum file not found: ${explicit}"
        fi
        if [ ! -f "${explicit}" ] || [ ! -r "${explicit}" ]; then
            flr_die "checksum file is not a readable regular file: ${explicit}"
        fi
        FLR_CHECKSUM_FILE=$(flr_realpath "${explicit}") ||
            flr_die "cannot resolve checksum file: ${explicit}"
    elif [ -f "${FLR_ISO_PATH}.sha256" ]; then
        FLR_CHECKSUM_FILE="${FLR_ISO_PATH}.sha256"
    else
        return 0
    fi

    base=$(basename -- "${FLR_ISO_PATH}")
    expected=$(flr_parse_checksum_file "${FLR_CHECKSUM_FILE}" "${base}") ||
        exit 1
    FLR_CHECKSUM_EXPECTED=${expected}
    FLR_CHECKSUM_STATUS="pending"
}

flr_verify_iso() {
    local actual=""
    local expected=""

    flr_require_cmd sha256sum
    actual=$(sha256sum -- "${FLR_ISO_PATH}" | awk '{print $1}') ||
        flr_die "could not compute SHA-256 for ${FLR_ISO_PATH}"
    [[ "${actual}" =~ ^[0-9a-fA-F]{64}$ ]] ||
        flr_die "invalid computed SHA-256 for ${FLR_ISO_PATH}: ${actual}"
    actual=${actual,,}

    if [ -n "${FLR_CHECKSUM_EXPECTED}" ]; then
        expected=${FLR_CHECKSUM_EXPECTED,,}
        if [ "${actual}" != "${expected}" ]; then
            flr_die "SHA-256 mismatch for ${FLR_ISO_PATH}: expected ${expected}, got ${actual} (checksum file ${FLR_CHECKSUM_FILE})"
        fi
        FLR_CHECKSUM_STATUS="verified"
    else
        FLR_CHECKSUM_STATUS="recorded-only"
        flr_warn "no SHA-256 checksum supplied for ${FLR_ISO_PATH}; recording the computed digest only"
    fi

    FLR_ISO_SHA256=${actual}
}

flr_resolve_evidence_dir() {
    local requested=$1
    local resolved=""
    local repo_real=""

    [ -n "${requested}" ] || flr_die "evidence directory is empty"
    resolved=$(flr_realpath "${requested}") ||
        flr_die "cannot resolve evidence directory: ${requested}"

    case "${resolved}" in
        / | /dev | /dev/* | /proc | /proc/* | /sys | /sys/*)
            flr_die "refusing unsafe evidence directory: ${resolved}"
            ;;
        *,*)
            flr_die "evidence directory must not contain a comma: ${resolved}"
            ;;
    esac

    repo_real=$(flr_realpath "${REPO_ROOT}") ||
        flr_die "cannot resolve repository root: ${REPO_ROOT}"
    case "${resolved}/" in
        "${repo_real}/"*)
            flr_die "evidence directory must be outside the source repository: ${resolved}"
            ;;
    esac

    FLR_EVIDENCE_DIR=${resolved}
}

flr_default_evidence_dir() {
    local base="${XDG_DATA_HOME:-${HOME}/.local/share}"
    local version=""
    local stamp=""

    version=$(flr_detect_version 2>/dev/null || printf 'unknown')
    stamp=$(date -u +%Y%m%dT%H%M%SZ)
    printf '%s/fluorineos/validation/%s-%s-%s\n' \
        "${base}" "${version}" "${stamp}" "$$"
}

flr_validate_socket_path() {
    local requested=$1
    local resolved=""
    local repo_real=""

    [ -n "${requested}" ] || flr_die "serial socket path is empty"
    resolved=$(flr_realpath "${requested}") ||
        flr_die "cannot resolve serial socket path: ${requested}"

    case "${resolved}" in
        / | /dev | /dev/* | /proc | /proc/* | /sys | /sys/*)
            flr_die "refusing unsafe serial socket path: ${resolved}"
            ;;
        *,*)
            flr_die "serial socket path must not contain a comma: ${resolved}"
            ;;
    esac

    repo_real=$(flr_realpath "${REPO_ROOT}") ||
        flr_die "cannot resolve repository root: ${REPO_ROOT}"
    case "${resolved}/" in
        "${repo_real}/"*)
            flr_die "serial socket must be outside the source repository: ${resolved}"
            ;;
    esac

    if [ -L "${resolved}" ] || [ -e "${resolved}" ]; then
        flr_die "serial socket path already exists: ${resolved}"
    fi

    FLR_SERIAL_SOCKET=${resolved}
}

flr_detect_firmware() {
    local code_override=${FLUORINEOS_OVMF_CODE:-}
    local vars_override=${FLUORINEOS_OVMF_VARS:-}
    local bios_override=${FLUORINEOS_OVMF_BIOS:-}
    local code=""
    local vars=""
    local candidate=""

    FLR_FIRMWARE_MODE=""
    FLR_FIRMWARE_CODE=""
    FLR_FIRMWARE_VARS_SOURCE=""
    FLR_FIRMWARE_BIOS=""
    FLR_FIRMWARE_DESC=""

    if [ -n "${code_override}" ]; then
        if [ ! -f "${code_override}" ] || [ ! -r "${code_override}" ]; then
            flr_die "OVMF code override is not a readable regular file: ${code_override}"
        fi
        [ -n "${vars_override}" ] ||
            flr_die "FLUORINEOS_OVMF_VARS is required when FLUORINEOS_OVMF_CODE is set"
        if [ ! -f "${vars_override}" ] || [ ! -r "${vars_override}" ]; then
            flr_die "OVMF variables override is not a readable regular file: ${vars_override}"
        fi
        FLR_FIRMWARE_MODE="pflash"
        FLR_FIRMWARE_CODE=${code_override}
        FLR_FIRMWARE_VARS_SOURCE=${vars_override}
        FLR_FIRMWARE_DESC="OVMF pflash override (non-secureboot)"
        return 0
    fi

    if [ -n "${vars_override}" ]; then
        flr_die "FLUORINEOS_OVMF_VARS requires FLUORINEOS_OVMF_CODE"
    fi

    if [ -n "${bios_override}" ]; then
        if [ ! -f "${bios_override}" ] || [ ! -r "${bios_override}" ]; then
            flr_die "OVMF combined firmware override is not a readable regular file: ${bios_override}"
        fi
        FLR_FIRMWARE_MODE="bios"
        FLR_FIRMWARE_BIOS=${bios_override}
        FLR_FIRMWARE_DESC="OVMF combined firmware override"
        return 0
    fi

    for code in \
        /usr/share/OVMF/OVMF_CODE_4M.fd \
        /usr/share/OVMF/OVMF_CODE.fd; do
        if [ ! -f "${code}" ] || [ ! -r "${code}" ]; then
            continue
        fi
        for candidate in \
            /usr/share/OVMF/OVMF_VARS_4M.fd \
            /usr/share/OVMF/OVMF_VARS.fd; do
            if [ -f "${candidate}" ] && [ -r "${candidate}" ]; then
                vars=${candidate}
                break
            fi
        done
        [ -n "${vars}" ] || continue

        FLR_FIRMWARE_MODE="pflash"
        FLR_FIRMWARE_CODE=${code}
        FLR_FIRMWARE_VARS_SOURCE=${vars}
        case "${code}" in
            *4M*)
                FLR_FIRMWARE_DESC="OVMF 4M (non-secureboot)"
                ;;
            *)
                FLR_FIRMWARE_DESC="OVMF pflash (non-secureboot)"
                ;;
        esac
        return 0
    done

    if [ -f /usr/share/ovmf/OVMF.fd ] && [ -r /usr/share/ovmf/OVMF.fd ]; then
        FLR_FIRMWARE_MODE="bios"
        FLR_FIRMWARE_BIOS="/usr/share/ovmf/OVMF.fd"
        FLR_FIRMWARE_DESC="OVMF.fd (combined firmware)"
        return 0
    fi

    flr_die "no UEFI firmware found; install ovmf or set FLUORINEOS_OVMF_CODE and FLUORINEOS_OVMF_VARS"
}

flr_prepare_firmware() {
    local vars_path=$1
    local force_copy=${2:-0}

    FLR_FIRMWARE_ARGS=()

    case "${FLR_FIRMWARE_MODE}" in
        pflash)
            mkdir -p -- "$(dirname -- "${vars_path}")" ||
                flr_die "cannot create firmware variable directory for ${vars_path}"
            if [ "${force_copy}" -eq 1 ] || [ ! -f "${vars_path}" ]; then
                if [ -f "${FLR_FIRMWARE_VARS_SOURCE}" ]; then
                    cp -- "${FLR_FIRMWARE_VARS_SOURCE}" "${vars_path}" ||
                        flr_die "cannot copy OVMF variables to ${vars_path}"
                else
                    : > "${vars_path}" ||
                        flr_die "cannot create OVMF variables at ${vars_path}"
                    truncate -s 540672 "${vars_path}" ||
                        flr_die "cannot size OVMF variables at ${vars_path}"
                fi
            fi
            chmod 0644 "${vars_path}" ||
                flr_die "cannot make OVMF variables readable: ${vars_path}"
            FLR_FIRMWARE_ARGS=(
                -drive "if=pflash,format=raw,readonly=on,file=${FLR_FIRMWARE_CODE}"
                -drive "if=pflash,format=raw,file=${vars_path}"
            )
            ;;
        bios)
            FLR_FIRMWARE_ARGS=(-bios "${FLR_FIRMWARE_BIOS}")
            ;;
        *)
            flr_die "firmware was not detected"
            ;;
    esac
}

flr_detect_kvm() {
    FLR_KVM_AVAILABLE=0
    FLR_KVM_REASON=""

    if [ ! -e /dev/kvm ]; then
        if flr_is_wsl; then
            FLR_KVM_REASON="/dev/kvm is not present in this WSL2 environment"
        else
            FLR_KVM_REASON="/dev/kvm is not present"
        fi
        return 0
    fi
    if [ ! -c /dev/kvm ]; then
        FLR_KVM_REASON="/dev/kvm is not a character device"
        return 0
    fi
    if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
        FLR_KVM_REASON="/dev/kvm is not readable and writable by $(id -un 2>/dev/null || printf 'the current user')"
        return 0
    fi

    FLR_KVM_AVAILABLE=1
}

flr_build_accel_args() {
    if [ "${FLR_KVM_AVAILABLE}" -eq 1 ]; then
        FLR_ACCEL="KVM"
        FLR_ACCEL_ARGS=(-accel kvm -cpu host)
    else
        FLR_ACCEL="TCG"
        FLR_ACCEL_ARGS=(-accel tcg)
    fi
}

flr_classify_environment() {
    if [ "${FLR_KVM_AVAILABLE}" -eq 1 ]; then
        FLR_ENV_CLASS="E2"
    else
        FLR_ENV_CLASS="E2-TCG"
    fi
}

flr_require_kvm() {
    if [ "${FLR_KVM_AVAILABLE}" -ne 1 ]; then
        flr_die "KVM is required but unavailable: ${FLR_KVM_REASON}"
    fi
}

flr_source_metadata() {
    FLR_SOURCE_COMMIT="unknown"
    FLR_SOURCE_DIRTY="unknown"
    FLR_SOURCE_BRANCH="unknown"
    FLR_REPO_VERSION="unknown"

    FLR_REPO_VERSION=$(flr_detect_version 2>/dev/null) ||
        FLR_REPO_VERSION="unknown"

    if command -v git >/dev/null 2>&1 && [ -d "${REPO_ROOT}/.git" ]; then
        FLR_SOURCE_COMMIT=$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null) ||
            FLR_SOURCE_COMMIT="unknown"
        FLR_SOURCE_BRANCH=$(git -C "${REPO_ROOT}" symbolic-ref --quiet --short HEAD 2>/dev/null) ||
            FLR_SOURCE_BRANCH="detached"
        if [ -n "$(git -C "${REPO_ROOT}" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
            FLR_SOURCE_DIRTY="yes"
        else
            FLR_SOURCE_DIRTY="no"
        fi
    fi
}

flr_detect_environment() {
    flr_detect_kvm
    flr_build_accel_args
    flr_detect_firmware
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

flr_build_gpu_args() {
    local vnc=${1:-}

    FLR_GPU_ARGS=()

    if [ -n "${vnc}" ]; then
        [[ "${vnc}" =~ ^[0-9]+$ ]] ||
            flr_die "FLUORINEOS_VNC must be numeric"
        FLR_GPU_ARGS=(-vga none -device virtio-vga -display none -vnc "127.0.2.0:${vnc}")
        FLR_GPU_DESC="virtio-vga over VNC 127.0.2.0:5900+${vnc}"
        FLR_GPU_MODE="vnc"
    elif flr_is_wsl; then
        FLR_GPU_ARGS=(-vga none -device virtio-vga -display gtk)
        FLR_GPU_DESC="virtio-vga without 3D acceleration (WSL2)"
        FLR_GPU_MODE="gtk-wsl"
    else
        FLR_GPU_ARGS=(-vga none -device virtio-vga-gl -display "gtk,gl=on")
        FLR_GPU_DESC="virtio-vga-gl with 3D acceleration"
        FLR_GPU_MODE="gtk-gl"
    fi
}

flr_build_serial_args() {
    local socket=${1:-}

    FLR_SERIAL_LOG="${FLR_EVIDENCE_DIR}/serial.log"
    FLR_SERIAL_ARGS=()

    if [ -n "${socket}" ]; then
        FLR_SERIAL_ARGS=(
            -chardev "socket,id=flrserial,path=${socket},server=on,wait=off,logfile=${FLR_SERIAL_LOG}"
            -serial "chardev:flrserial"
        )
    else
        FLR_SERIAL_ARGS=(-serial "file:${FLR_SERIAL_LOG}")
    fi
}

flr_validate_qcow2() {
    local path=$1
    local info=""

    flr_require_cmd qemu-img
    info=$(qemu-img info -- "${path}") ||
        flr_die "not a readable qcow2 image: ${path}"
    case "${info}" in
        *"file format: qcow2"*)
            ;;
        *)
            flr_die "disk image is not qcow2: ${path}"
            ;;
    esac
    if printf '%s\n' "${info}" | grep -qiE '^[[:space:]]*backing file:'; then
        flr_die "refusing qcow2 image with a backing file: ${path}"
    fi
}

flr_resolve_disk() {
    local requested=${1:-}
    local reuse=${2:-0}
    local resolved=""

    [ -n "${FLR_EVIDENCE_DIR}" ] || flr_die "evidence directory must be resolved before the disk"

    if [ -z "${requested}" ]; then
        requested="${FLR_EVIDENCE_DIR}/disk.qcow2"
    elif [[ "${requested}" != /* ]]; then
        requested="${FLR_EVIDENCE_DIR}/${requested}"
    fi

    case "${requested}" in
        /dev/*)
            flr_die "refusing block or device path as disk image: ${requested}"
            ;;
    esac
    if [ -L "${requested}" ]; then
        flr_die "refusing symlink as disk image: ${requested}"
    fi
    if [ -b "${requested}" ]; then
        flr_die "refusing block device as disk image: ${requested}"
    fi

    resolved=$(flr_realpath "${requested}") ||
        flr_die "cannot resolve disk image path: ${requested}"

    case "${resolved}" in
        "${FLR_EVIDENCE_DIR}"/*)
            ;;
        *)
            flr_die "disk image must be inside the evidence directory ${FLR_EVIDENCE_DIR}: ${resolved}"
            ;;
    esac
    case "${resolved}" in
        *,*)
            flr_die "disk image path must not contain a comma: ${resolved}"
            ;;
        *.qcow2)
            ;;
        *)
            flr_die "disk image must use the .qcow2 suffix: ${resolved}"
            ;;
    esac

    if [ -e "${resolved}" ]; then
        if [ ! -f "${resolved}" ]; then
            flr_die "disk image is not a regular file: ${resolved}"
        fi
        if [ ! -s "${resolved}" ]; then
            flr_die "disk image is empty: ${resolved}"
        fi
        if [ "${reuse}" -ne 1 ]; then
            flr_die "disk already exists: ${resolved}; pass --reuse-disk to reuse it"
        fi
        flr_validate_qcow2 "${resolved}"
        FLR_DISK_EXISTS=1
    else
        if [ "${reuse}" -eq 1 ]; then
            flr_die "reuse requested but disk does not exist: ${resolved}"
        fi
        FLR_DISK_EXISTS=0
    fi

    FLR_DISK_PATH=${resolved}
    FLR_DISK_REUSE=${reuse}
}

flr_resolve_vars() {
    local requested=${1:-}
    local resolved=""

    [ -n "${FLR_DISK_PATH}" ] || flr_die "disk path must be resolved before the UEFI variable store"

    if [ -z "${requested}" ]; then
        requested="${FLR_DISK_PATH%.qcow2}-vars.fd"
    elif [[ "${requested}" != /* ]]; then
        requested="${FLR_EVIDENCE_DIR}/${requested}"
    fi

    case "${requested}" in
        /dev/*)
            flr_die "refusing device path as UEFI variable store: ${requested}"
            ;;
    esac
    if [ -L "${requested}" ]; then
        flr_die "refusing symlink as UEFI variable store: ${requested}"
    fi
    if [ -b "${requested}" ]; then
        flr_die "refusing block device as UEFI variable store: ${requested}"
    fi

    resolved=$(flr_realpath "${requested}") ||
        flr_die "cannot resolve UEFI variable store path: ${requested}"

    case "${resolved}" in
        "${FLR_EVIDENCE_DIR}"/*)
            ;;
        *)
            flr_die "UEFI variable store must be inside the evidence directory ${FLR_EVIDENCE_DIR}: ${resolved}"
            ;;
    esac
    case "${resolved}" in
        *,*)
            flr_die "UEFI variable store path must not contain a comma: ${resolved}"
            ;;
        *.fd)
            ;;
        *)
            flr_die "UEFI variable store must use the .fd suffix: ${resolved}"
            ;;
    esac

    if [ -e "${resolved}" ]; then
        if [ ! -f "${resolved}" ]; then
            flr_die "UEFI variable store is not a regular file: ${resolved}"
        fi
        if [ ! -s "${resolved}" ]; then
            flr_die "UEFI variable store is empty: ${resolved}"
        fi
        FLR_VARS_EXISTS=1
    else
        FLR_VARS_EXISTS=0
    fi

    FLR_VARS_PATH=${resolved}
}

flr_print_environment() {
    printf 'Artifact:\n'
    if [ -n "${FLR_ISO_PATH}" ]; then
        printf '  ISO requested: %s\n' "${FLR_ISO_REQUESTED}"
        printf '  ISO resolved:  %s\n' "${FLR_ISO_PATH}"
        printf '  ISO size:      %s bytes\n' "${FLR_ISO_SIZE}"
        printf '  ISO SHA-256:   %s\n' "${FLR_ISO_SHA256}"
        if [ -n "${FLR_CHECKSUM_FILE}" ]; then
            printf '  Checksum:      %s (%s)\n' "${FLR_CHECKSUM_STATUS}" "${FLR_CHECKSUM_FILE}"
        else
            printf '  Checksum:      not supplied; computed digest recorded only\n'
        fi
    else
        printf '  ISO:           none (booting the installed disk)\n'
    fi

    if [ -n "${FLR_DISK_PATH}" ]; then
        if [ "${FLR_DISK_EXISTS}" -eq 1 ]; then
            printf '  Disk:          %s (existing, reuse)\n' "${FLR_DISK_PATH}"
        else
            printf '  Disk:          %s (new)\n' "${FLR_DISK_PATH}"
        fi
        printf '  UEFI vars:     %s (%s)\n' "${FLR_VARS_PATH}" \
            "$([ "${FLR_VARS_EXISTS}" -eq 1 ] && printf 'existing' || printf 'new')"
    fi

    printf 'Environment:\n'
    printf '  Acceleration:  %s\n' "${FLR_ACCEL}"
    if [ "${FLR_KVM_AVAILABLE}" -ne 1 ]; then
        printf '  KVM:           unavailable (%s)\n' "${FLR_KVM_REASON}"
    fi
    printf '  Test env:      %s\n' "${FLR_ENV_CLASS}"
    printf '  Firmware:      %s\n' "${FLR_FIRMWARE_DESC}"
    printf '  Display:       %s\n' "${FLR_GPU_DESC}"
    printf '  QEMU:          %s\n' "${FLR_QEMU_VERSION}"
    printf '  Serial log:    %s\n' "${FLR_SERIAL_LOG}"
    if [ -n "${FLR_SERIAL_SOCKET}" ]; then
        printf '  Serial socket: %s\n' "${FLR_SERIAL_SOCKET}"
    fi
    printf '  Evidence:      %s\n' "${FLR_EVIDENCE_DIR}"
    printf '  Source version: %s\n' "${FLR_REPO_VERSION}"
    printf '  Source branch: %s\n' "${FLR_SOURCE_BRANCH}"
    printf '  Source commit: %s (dirty: %s)\n' "${FLR_SOURCE_COMMIT}" "${FLR_SOURCE_DIRTY}"

    if [ "${FLR_KVM_AVAILABLE}" -ne 1 ]; then
        flr_warn "TCG does not satisfy TEST_PLAN E2; record this run as ${FLR_ENV_CLASS}, not E2"
    fi
}

flr_write_artifact_record() {
    local file="${FLR_EVIDENCE_DIR}/artifact.txt"

    {
        printf 'iso_requested=%s\n' "${FLR_ISO_REQUESTED:-none}"
        printf 'iso_resolved=%s\n' "${FLR_ISO_PATH:-none}"
        printf 'iso_size_bytes=%s\n' "${FLR_ISO_SIZE:-none}"
        printf 'iso_sha256=%s\n' "${FLR_ISO_SHA256:-none}"
        printf 'iso_version_from_name=%s\n' "${FLR_ISO_VERSION_FROM_NAME:-unknown}"
        printf 'iso_source=%s\n' "${FLR_ISO_SOURCE:-none}"
        printf 'checksum_file=%s\n' "${FLR_CHECKSUM_FILE:-none}"
        printf 'checksum_expected=%s\n' "${FLR_CHECKSUM_EXPECTED:-none}"
        printf 'checksum_status=%s\n' "${FLR_CHECKSUM_STATUS}"
        printf 'repo_version=%s\n' "${FLR_REPO_VERSION}"
        printf 'disk_path=%s\n' "${FLR_DISK_PATH:-none}"
        printf 'disk_reuse=%s\n' "${FLR_DISK_REUSE}"
        printf 'disk_size=%s\n' "${FLR_DISK_SIZE_SPEC:-none}"
        printf 'vars_path=%s\n' "${FLR_VARS_PATH:-none}"
        printf 'source_branch=%s\n' "${FLR_SOURCE_BRANCH}"
        printf 'source_commit=%s\n' "${FLR_SOURCE_COMMIT}"
        printf 'source_dirty=%s\n' "${FLR_SOURCE_DIRTY}"
        printf 'serial_log=%s\n' "${FLR_SERIAL_LOG}"
    } > "${file}" || flr_die "cannot write artifact record: ${file}"
}

flr_write_environment_record() {
    local memory=$1
    local cpus=$2
    local file="${FLR_EVIDENCE_DIR}/environment.txt"
    local timestamp=""
    local host=""
    local kernel=""

    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ) || timestamp="unknown"
    host=$(hostname 2>/dev/null || printf 'unknown')
    kernel=$(uname -r 2>/dev/null || printf 'unknown')

    {
        printf 'timestamp_utc=%s\n' "${timestamp}"
        printf 'hostname=%s\n' "${host}"
        printf 'kernel=%s\n' "${kernel}"
        printf 'wsl=%s\n' "${FLR_WSL}"
        printf 'kvm_available=%s\n' "${FLR_KVM_AVAILABLE}"
        printf 'kvm_reason=%s\n' "${FLR_KVM_REASON:-none}"
        printf 'acceleration=%s\n' "${FLR_ACCEL}"
        printf 'test_environment=%s\n' "${FLR_ENV_CLASS}"
        printf 'qemu_version=%s\n' "${FLR_QEMU_VERSION}"
        printf 'firmware_mode=%s\n' "${FLR_FIRMWARE_MODE}"
        printf 'firmware=%s\n' "${FLR_FIRMWARE_DESC}"
        printf 'display_mode=%s\n' "${FLR_GPU_MODE}"
        printf 'display=%s\n' "${FLR_GPU_DESC}"
        printf 'memory_mb=%s\n' "${memory}"
        printf 'cpus=%s\n' "${cpus}"
        printf 'serial_log=%s\n' "${FLR_SERIAL_LOG}"
        printf 'serial_socket=%s\n' "${FLR_SERIAL_SOCKET:-none}"
        printf 'evidence_dir=%s\n' "${FLR_EVIDENCE_DIR}"
        printf 'repo_version=%s\n' "${FLR_REPO_VERSION}"
        printf 'source_branch=%s\n' "${FLR_SOURCE_BRANCH}"
        printf 'source_commit=%s\n' "${FLR_SOURCE_COMMIT}"
        printf 'source_dirty=%s\n' "${FLR_SOURCE_DIRTY}"
    } > "${file}" || flr_die "cannot write environment record: ${file}"
}
