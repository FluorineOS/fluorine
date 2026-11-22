#!/usr/bin/env bash
set -euo pipefail

# Boot the FluorineOS live image in QEMU with UEFI firmware.
#
# Usage: scripts/run-qemu-live.sh [--export-win]
#
#   --export-win  Copy the ISO into the Windows user's Downloads folder before
#                 booting. Only meaningful when the image is built under WSL2.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(dirname -- "${SCRIPT_DIR}")
WINDOWS_ISO_NAME="FluorineOS-0.0.1-amd64.iso"
MEMORY=4096
CPUS=4

EXPORT_WIN=0
VARS_COPY=""
FIRMWARE_ARGS=()

usage() {
    cat <<'EOF'
Usage: scripts/run-qemu-live.sh [--export-win]

Boots the FluorineOS live ISO in QEMU with UEFI firmware.

Options:
  --export-win   Copy the ISO to the Windows Downloads folder first.
  -h, --help     Show this help.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [ -n "${VARS_COPY}" ] && [ -f "${VARS_COPY}" ]; then
        rm -f -- "${VARS_COPY}"
    fi
}

trap cleanup EXIT

is_wsl() {
    grep -qi microsoft /proc/version 2>/dev/null
}

find_iso() {
    local candidate

    for candidate in \
        "${REPO_ROOT}/FluorineOS-0.0.1-amd64.hybrid.iso" \
        "${REPO_ROOT}/live-image-amd64.hybrid.iso"; do
        if [ -f "${candidate}" ]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

require_qemu() {
    command -v qemu-system-x86_64 >/dev/null 2>&1 ||
        die "qemu-system-x86_64 not found; install qemu-system-x86"
}

export_to_windows() {
    local iso=$1
    local cmd="/mnt/c/Windows/System32/cmd.exe"
    local profile
    local downloads

    [ -x "${cmd}" ] || die "cmd.exe not found; --export-win requires WSL2"
    command -v wslpath >/dev/null 2>&1 || die "wslpath not found; --export-win requires WSL2"

    profile=$("${cmd}" /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r')
    [ -n "${profile}" ] || die "could not resolve the Windows user profile"

    downloads=$(wslpath -u "${profile}")/Downloads
    mkdir -p -- "${downloads}"
    cp -- "${iso}" "${downloads}/${WINDOWS_ISO_NAME}"
    printf 'Exported ISO to %s\n' "${downloads}/${WINDOWS_ISO_NAME}"
}

build_firmware_args() {
    if [ -f /usr/share/OVMF/OVMF_CODE_4M.fd ] && [ -f /usr/share/OVMF/OVMF_VARS_4M.fd ]; then
        VARS_COPY=$(mktemp --suffix=-OVMF_VARS.fd)
        cp -- /usr/share/OVMF/OVMF_VARS_4M.fd "${VARS_COPY}"
        FIRMWARE_ARGS=(
            -drive "if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd"
            -drive "if=pflash,format=raw,file=${VARS_COPY}"
        )
    elif [ -f /usr/share/ovmf/OVMF.fd ]; then
        FIRMWARE_ARGS=(-bios /usr/share/ovmf/OVMF.fd)
    else
        die "no UEFI firmware found; install ovmf"
    fi
}

main() {
    local iso
    local accel_args
    local gpu_args

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --export-win)
                EXPORT_WIN=1
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                usage >&2
                die "unknown option: $1"
                ;;
        esac
        shift
    done

    require_qemu
    iso=$(find_iso) || die "no ISO found in ${REPO_ROOT}; build the image first"

    if [ "${EXPORT_WIN}" -eq 1 ]; then
        export_to_windows "${iso}"
    fi

    if [ -w /dev/kvm ]; then
        accel_args=(-enable-kvm -cpu host)
        printf 'Acceleration: KVM\n'
    else
        accel_args=(-accel tcg)
        printf 'Acceleration: TCG (software emulation)\n'
    fi

    if is_wsl; then
        # WSLg's D3D12 Mesa path crashes with gl=on, so stay on the 2D device.
        gpu_args=(-vga none -device virtio-vga -display gtk)
        printf 'Display: virtio-vga without 3D acceleration (WSL2)\n'
    else
        gpu_args=(-vga none -device virtio-vga-gl -display "gtk,gl=on")
        printf 'Display: virtio-vga-gl with 3D acceleration\n'
    fi

    build_firmware_args

    printf 'Booting %s\n' "${iso}"

    qemu-system-x86_64 \
        -machine q35 \
        "${accel_args[@]}" \
        -m "${MEMORY}" \
        -smp "${CPUS}" \
        "${FIRMWARE_ARGS[@]}" \
        "${gpu_args[@]}" \
        -cdrom "${iso}" \
        -boot d \
        -netdev user,id=net0 \
        -device virtio-net-pci,netdev=net0
}

main "$@"
