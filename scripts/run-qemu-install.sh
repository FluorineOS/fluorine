#!/usr/bin/env bash
set -euo pipefail

# Exercise the Calamares installer against a throwaway 25 GB disk.
#
# Usage: scripts/run-qemu-install.sh [--boot-disk]
#
#   --boot-disk  Boot the installed disk instead of the ISO, so you can verify
#                the finished system after Calamares completes.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(dirname -- "${SCRIPT_DIR}")
DISK_IMAGE="${REPO_ROOT}/test-disk.qcow2"
VARS_IMAGE="${REPO_ROOT}/test-vars.fd"
DISK_SIZE="25G"
MEMORY=4096
CPUS=4
SERIAL_SOCKET="${TMPDIR:-/tmp}/fluorineos-serial.sock"

BOOT_DISK=0
FIRMWARE_ARGS=()

usage() {
    cat <<'EOF'
Usage: scripts/run-qemu-install.sh [--boot-disk]

Creates test-disk.qcow2 (25 GB) when missing and boots the ISO with UEFI
firmware so Calamares can install onto it.

Options:
  --boot-disk   Boot from test-disk.qcow2 instead of the installer ISO.
  -h, --help    Show this help.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

is_wsl() {
    grep -qi microsoft /proc/version 2>/dev/null
}

find_iso() {
    local candidate

    for candidate in \
        "${REPO_ROOT}/FluorineOS-0.1.0-amd64.iso" \
        "${REPO_ROOT}/FluorineOS-0.1.0-amd64.hybrid.iso" \
        "${REPO_ROOT}/live-image-amd64.hybrid.iso"; do
        if [ -f "${candidate}" ]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

ensure_disk() {
    if [ -f "${DISK_IMAGE}" ]; then
        printf 'Reusing existing disk: %s\n' "${DISK_IMAGE}"
        return
    fi

    command -v qemu-img >/dev/null 2>&1 || die "qemu-img not found; install qemu-utils"
    qemu-img create -f qcow2 "${DISK_IMAGE}" "${DISK_SIZE}"
}

build_firmware_args() {
    if [ -f /usr/share/OVMF/OVMF_CODE_4M.fd ] && [ -f /usr/share/OVMF/OVMF_VARS_4M.fd ]; then
        if [ ! -f "${VARS_IMAGE}" ]; then
            cp -- /usr/share/OVMF/OVMF_VARS_4M.fd "${VARS_IMAGE}"
        fi
        FIRMWARE_ARGS=(
            -drive "if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd"
            -drive "if=pflash,format=raw,file=${VARS_IMAGE}"
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
    local boot_args

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --boot-disk)
                BOOT_DISK=1
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

    command -v qemu-system-x86_64 >/dev/null 2>&1 ||
        die "qemu-system-x86_64 not found; install qemu-system-x86"

    ensure_disk
    iso=$(find_iso) || die "no ISO found in ${REPO_ROOT}; build the image first"

    if [ "${BOOT_DISK}" -eq 1 ]; then
        boot_args=(-boot c)
        printf 'Booting the installed disk\n'
    else
        boot_args=(-cdrom "${iso}" -boot d)
        printf 'Booting the installer from %s\n' "${iso}"
    fi

    if [ -w /dev/kvm ]; then
        accel_args=(-enable-kvm -cpu host)
        printf 'Acceleration: KVM\n'
    else
        accel_args=(-accel tcg)
        printf 'Acceleration: TCG (software emulation)\n'
    fi

    if [ -n "${FLUORINEOS_VNC:-}" ]; then
        # Headless viewing path. QEMU serves the framebuffer on
        # 127.0.1.0:5900+N; bridge it to a browser with
        # websockify 6080 127.0.1.0:5900+N and /usr/share/novnc.
        gpu_args=(-vga none -device virtio-vga -display none -vnc "127.0.1.0:${FLUORINEOS_VNC}")
        printf 'Display: virtio-vga over VNC 127.0.1.0:590%s\n' "${FLUORINEOS_VNC}"
    elif is_wsl; then
        # WSLg's D3D12 Mesa path crashes with gl=on, so stay on the 2D device.
        gpu_args=(-vga none -device virtio-vga -display gtk)
        printf 'Display: virtio-vga without 3D acceleration (WSL2)\n'
    else
        gpu_args=(-vga none -device virtio-vga-gl -display "gtk,gl=on")
        printf 'Display: virtio-vga-gl with 3D acceleration\n'
    fi

    build_firmware_args

    qemu-system-x86_64 \
        -machine q35 \
        "${accel_args[@]}" \
        -m "${MEMORY}" \
        -smp "${CPUS}" \
        "${FIRMWARE_ARGS[@]}" \
        "${gpu_args[@]}" \
        "${boot_args[@]}" \
        -drive "file=${DISK_IMAGE},format=qcow2,if=virtio" \
        -netdev user,id=net0 \
        -device virtio-net-pci,netdev=net0 \
        -chardev "socket,id=flrserial,path=${SERIAL_SOCKET},server=on,wait=off" \
        -serial chardev:flrserial
}

main "$@"
