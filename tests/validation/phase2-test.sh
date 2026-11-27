#!/usr/bin/env bash
set -uo pipefail

# Non-destructive Phase 2 validation tests.
# Uses temporary fixtures and a fake QEMU wrapper that exits immediately.

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
LIB_COMMON="${REPO}/scripts/lib/qemu-common.sh"
LIB_MANIFEST="${REPO}/scripts/lib/qemu-manifest.sh"
LIB_VERSION="${REPO}/scripts/lib/version-common.sh"
INSPECT="${REPO}/scripts/validation/inspect-artifact.sh"
RECORD="${REPO}/scripts/validation/record-result.sh"
LIVE="${REPO}/scripts/run-qemu-live.sh"
INSTALL="${REPO}/scripts/run-qemu-install.sh"

TMP=$(mktemp -d /tmp/flr-qemu-phase2.XXXXXX)
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
        tail -n 6 "${file}" | sed 's/^/      /'
    fi
}

expect_ok() {
    local name=$1
    shift
    if "$@" >"${TMP}/${name}.out" 2>&1; then
        ok "${name}"
    else
        bad "${name}"
        show_tail "${TMP}/${name}.out"
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
    if grep -Eqi -- "${needle}" "${file}" 2>/dev/null; then
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
    if grep -Eqi -- "${needle}" "${file}" 2>/dev/null; then
        bad "${name} (unexpected: ${needle})"
    else
        ok "${name}"
    fi
}

jq_true() {
    local name=$1
    local file=$2
    local filter=$3
    if jq -e "${filter}" "${file}" >/dev/null 2>&1; then
        ok "${name}"
    else
        bad "${name} (jq filter failed: ${filter})"
    fi
}

jq_slurp_true() {
    local name=$1
    local file=$2
    local filter=$3
    if jq -e -s "${filter}" "${file}" >/dev/null 2>&1; then
        ok "${name}"
    else
        bad "${name} (jq filter failed: ${filter})"
    fi
}

parser_expect() {
    local name=$1
    local expected=$2
    local actual=""
    shift 2
    if actual=$("$@" 2>/dev/null) && [ "${actual}" = "${expected}" ]; then
        ok "${name}"
    else
        bad "${name} (got '${actual}', expected '${expected}')"
    fi
}

parser_reject() {
    local name=$1
    shift
    if "$@" >/dev/null 2>&1; then
        bad "${name} (unexpected success)"
    else
        ok "${name}"
    fi
}

run_parser() {
    bash -c 'source "$1"; shift; "$@"' _ "${LIB_VERSION}" "$@"
}

make_root() {
    local root=$1

    mkdir -p "${root}/etc" \
        "${root}/usr/share/calamares/branding/fluorineos" \
        "${root}/var/lib/dpkg"
    cat > "${root}/etc/os-release" <<'EOF'
PRETTY_NAME="FluorineOS 0.4.0 (Trixie)"
NAME="FluorineOS"
VERSION="0.4.0"
VERSION_ID="0.4.0"
ID=fluorineos
EOF
    cat > "${root}/etc/issue" <<'EOF'
FluorineOS 0.4.0 \n \l
EOF
    cat > "${root}/usr/share/calamares/branding/fluorineos/branding.desc" <<'EOF'
componentName: fluorineos
strings:
  productName: FluorineOS
  version:            0.4.0
  shortVersion:       0.4.0
  versionedName:      FluorineOS 0.4.0
EOF
    cat > "${root}/var/lib/dpkg/status" <<'EOF'
Package: fluorine-desktop
Status: install ok installed
Priority: optional
Architecture: all
Version: 0.15.1
Description: fixture

Package: fluorine-artwork
Status: install ok installed
Priority: optional
Architecture: all
Version: 0.8.0
Description: fixture

Package: fluorine-keyring
Status: install ok installed
Priority: optional
Architecture: all
Version: 0.0.2
Description: fixture

Package: fluorine-extra
Status: install ok installed
Priority: optional
Architecture: all
Version: 1.2.3
Description: fixture
EOF
}

main() {
    local root="${TMP}/root"
    local root_mismatch="${TMP}/root-mismatch"
    local root_missing_issue="${TMP}/root-missing-issue"
    local root_missing_branding="${TMP}/root-missing-branding"
    local expected_ok="${TMP}/expected-ok.txt"
    local expected_bad="${TMP}/expected-bad.txt"
    local pvd="${TMP}/pvd.txt"
    local iso="${TMP}/fixture.iso"
    local manifest_case="${TMP}/manifest-case.sh"
    local evidence_a="${TMP}/manifest-a"
    local evidence_live="${TMP}/evidence-live"
    local manifest_a=""
    local manifest_b=""
    local manifest_b_out=""
    local manifest_live=""
    local sanitized=""
    local run_id=""
    local archive=""
    local ledger="${TMP}/ledger/results.jsonl"
    local fakebin="${TMP}/fakebin"
    local fakeiso="${TMP}/fakeiso"
    local fake_squashfs="${TMP}/fake-filesystem.squashfs"
    local fakeqemu="${TMP}/fakeqemu"
    local qemu_log="${TMP}/qemu-invocations.log"
    local tool=""
    local target=""

    mkdir -p "${fakebin}" "${fakeqemu}"
    for tool in bash jq awk grep sed head date mktemp dirname basename realpath stat cat \
        sha256sum rm rmdir mkdir touch sort tr cut cp unsquashfs; do
        target=$(command -v "${tool}" 2>/dev/null) || continue
        ln -s "${target}" "${fakebin}/${tool}" 2>/dev/null || true
    done

    mkdir -p "${fakeiso}"
    for tool in bash jq awk grep sed head date mktemp dirname basename realpath stat cat \
        sha256sum rm rmdir mkdir touch sort tr cut cp mv; do
        target=$(command -v "${tool}" 2>/dev/null) || continue
        ln -s "${target}" "${fakeiso}/${tool}" 2>/dev/null || true
    done
    printf 'fake squashfs fixture for phase 2 tests\n' > "${fake_squashfs}"
    cat > "${fakeiso}/xorriso" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
    *"-pvd_info"*)
        printf 'Volume Id    : FLUORINEOS_0_4_0\n'
        printf 'App Id       : FLUORINEOS 0.4.0\n'
        ;;
    *"-extract /live/filesystem.packages"*)
        for last; do :; done
        cp -- "${FIXTURE_PACKAGES:?}" "${last}"
        ;;
    *)
        exit 1
        ;;
esac
EOF
    chmod +x "${fakeiso}/xorriso"
    cat > "${fakeiso}/unsquashfs" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
path=${3:-}
case "${path}" in
    etc/os-release)
        cat -- "${FIXTURE_ROOT:?}/etc/os-release"
        ;;
    etc/issue)
        cat -- "${FIXTURE_ROOT:?}/etc/issue"
        ;;
    usr/share/calamares/branding/fluorineos/branding.desc)
        cat -- "${FIXTURE_ROOT:?}/usr/share/calamares/branding/fluorineos/branding.desc"
        ;;
    var/lib/dpkg/status)
        cat -- "${FIXTURE_ROOT:?}/var/lib/dpkg/status"
        ;;
    *)
        exit 1
        ;;
esac
EOF
    chmod +x "${fakeiso}/unsquashfs"

    printf 'synthetic iso fixture for phase 2 tests\n' > "${iso}"
    sha256sum "${iso}" > "${iso}.sha256"

    make_root "${root}"
    mkdir -p "${root_mismatch}" "${root_missing_issue}" "${root_missing_branding}"
    cp -a "${root}/." "${root_mismatch}/"
    cp -a "${root}/." "${root_missing_issue}/"
    cp -a "${root}/." "${root_missing_branding}/"
    printf 'FluorineOS 0.3.9 \\n \\l\n' > "${root_mismatch}/etc/issue"
    rm -f -- "${root_missing_issue}/etc/issue"
    rm -f -- "${root_missing_branding}/usr/share/calamares/branding/fluorineos/branding.desc"

    cat > "${expected_ok}" <<'EOF'
# Component versions recorded for this run.
fluorine-desktop 0.15.1
fluorine-artwork = 0.8.0
fluorine-keyring 0.0.2
EOF
    cat > "${expected_bad}" <<'EOF'
fluorine-desktop 0.8.0
EOF
    cat > "${pvd}" <<'EOF'
Volume Id    : FLUORINEOS_0_4_0
App Id       : FLUORINEOS 0.4.0
EOF

    # Version parsers.
    parser_expect parse-os-release-version 0.4.0 \
        run_parser flr_version_from_os_release "${root}/etc/os-release" VERSION
    parser_expect parse-os-release-id 0.4.0 \
        run_parser flr_version_from_os_release "${root}/etc/os-release" VERSION_ID
    parser_expect parse-issue 0.4.0 \
        run_parser flr_version_from_issue "${root}/etc/issue"
    parser_expect parse-iso-volume 0.4.0 \
        run_parser flr_version_from_iso_volume FLUORINEOS_0_4_0
    parser_expect parse-iso-application 0.4.0 \
        run_parser flr_version_from_iso_application 'FLUORINEOS 0.4.0'
    parser_expect parse-branding-version 0.4.0 \
        run_parser flr_version_from_branding \
        "${root}/usr/share/calamares/branding/fluorineos/branding.desc" version
    parser_expect parse-branding-short-version 0.4.0 \
        run_parser flr_version_from_branding \
        "${root}/usr/share/calamares/branding/fluorineos/branding.desc" shortVersion
    parser_expect parse-package-line 0.15.1 \
        run_parser flr_version_from_package_line $'fluorine-desktop\t0.15.1' fluorine-desktop
    parser_expect parse-expected-file 0.15.1 \
        run_parser flr_expected_version_from_file "${expected_ok}" fluorine-desktop
    parser_expect parse-pvd-field FLUORINEOS_0_4_0 \
        run_parser flr_pvd_field "${pvd}" 'Volume Id'
    parser_reject parse-missing-file \
        run_parser flr_version_from_os_release "${TMP}/no-such-file" VERSION
    parser_reject parse-invalid-volume \
        run_parser flr_version_from_iso_volume FLUORINEOS_LATEST
    parser_reject parse-expected-missing \
        run_parser flr_expected_version_from_file "${expected_ok}" fluorine-missing
    parser_reject parse-invalid-issue \
        run_parser flr_version_from_issue "${root_mismatch}/etc/os-release"

    # The inspector uses dpkg-query for filesystem-root mode and the tab-separated
    # inventory for ISO mode; both parsers are exercised here.
    cat > "${TMP}/packages.tsv" <<'EOF'
fluorine-desktop	0.15.1
fluorine-artwork	0.8.0
fluorine-keyring	0.0.2
EOF
    parser_expect parse-packages-inventory 0.15.1 \
        run_parser flr_version_from_packages_file "${TMP}/packages.tsv" fluorine-desktop
    parser_expect parse-dpkg-status 0.0.2 \
        run_parser flr_version_from_dpkg_status "${root}/var/lib/dpkg/status" fluorine-keyring

    # Inspector: PASS, expected package enforcement, FAIL cases, BLOCKED cases.
    expect_status 0 inspect-root-pass \
        bash "${INSPECT}" --root "${root}" --expected-version 0.4.0 --json
    jq_true inspect-root-result-pass "${TMP}/inspect-root-pass.out" '.result == "PASS"'
    jq_true inspect-root-no-discrepancies "${TMP}/inspect-root-pass.out" \
        '(.discrepancies | length) == 0'
    jq_true inspect-root-independent-recorded "${TMP}/inspect-root-pass.out" \
        '[.independent_packages[] | select(.package == "fluorine-desktop" and .version == "0.15.1" and .status == "RECORDED")] | length == 1'
    jq_true inspect-root-extra-recorded "${TMP}/inspect-root-pass.out" \
        '[.independent_packages[] | select(.package == "fluorine-extra" and .version == "1.2.3")] | length == 1'

    expect_status 0 inspect-expected-packages-pass \
        bash "${INSPECT}" --root "${root}" --expected-version 0.4.0 \
        --expected-packages "${expected_ok}" --json
    jq_true inspect-expected-status-match "${TMP}/inspect-expected-packages-pass.out" \
        '[.independent_packages[] | select(.package == "fluorine-desktop" and .status == "MATCH")] | length == 1'

    expect_status 1 inspect-expected-mismatch \
        bash "${INSPECT}" --root "${root}" --expected-version 0.4.0 \
        --expected-packages "${expected_bad}" --json
    jq_true inspect-expected-mismatch-result "${TMP}/inspect-expected-mismatch.out" \
        '.result == "FAIL"'
    jq_true inspect-expected-mismatch-detail "${TMP}/inspect-expected-mismatch.out" \
        '[.discrepancies[] | select(.id == "package:fluorine-desktop" and .expected == "0.8.0")] | length == 1'

    expect_status 1 inspect-issue-mismatch \
        bash "${INSPECT}" --root "${root_mismatch}" --expected-version 0.4.0 --json
    jq_true inspect-issue-mismatch-detail "${TMP}/inspect-issue-mismatch.out" \
        '[.discrepancies[] | select(.id == "issue" and .status == "MISMATCH")] | length == 1'

    expect_status 1 inspect-issue-missing \
        bash "${INSPECT}" --root "${root_missing_issue}" --expected-version 0.4.0 --json
    jq_true inspect-issue-missing-detail "${TMP}/inspect-issue-missing.out" \
        '[.exact_sources[] | select(.id == "issue" and .status == "MISSING")] | length == 1'

    expect_status 1 inspect-branding-missing \
        bash "${INSPECT}" --root "${root_missing_branding}" --expected-version 0.4.0 --json
    jq_true inspect-branding-missing-version "${TMP}/inspect-branding-missing.out" \
        '[.exact_sources[] | select(.id == "branding-version" and .status == "MISSING")] | length == 1'
    jq_true inspect-branding-missing-short "${TMP}/inspect-branding-missing.out" \
        '[.exact_sources[] | select(.id == "branding-short-version" and .status == "MISSING")] | length == 1'

    expect_status 2 inspect-no-mode bash "${INSPECT}" --json
    expect_status 2 inspect-two-modes \
        bash "${INSPECT}" --root "${root}" --iso "${iso}" --json
    expect_status 2 inspect-squashfs-root \
        bash "${INSPECT}" --root "${root}" --squashfs "${iso}" --json

    expect_status 0 inspect-iso-squashfs-pass \
        env PATH="${fakeiso}:${PATH}" FIXTURE_ROOT="${root}" \
        FIXTURE_PACKAGES="${TMP}/packages.tsv" \
        bash "${INSPECT}" --iso "${iso}" --squashfs "${fake_squashfs}" \
        --cache-dir "${TMP}/cache" --expected-version 0.4.0 --json
    jq_true inspect-iso-result-pass "${TMP}/inspect-iso-squashfs-pass.out" \
        '.result == "PASS"'
    jq_true inspect-iso-os-release-match "${TMP}/inspect-iso-squashfs-pass.out" \
        '[.exact_sources[] | select(.id == "os-release-version" and .status == "MATCH" and .source == "squashfs:etc/os-release")] | length == 1'
    jq_true inspect-iso-issue-match "${TMP}/inspect-iso-squashfs-pass.out" \
        '[.exact_sources[] | select(.id == "issue" and .status == "MATCH" and .source == "squashfs:etc/issue")] | length == 1'
    jq_true inspect-iso-branding-match "${TMP}/inspect-iso-squashfs-pass.out" \
        '[.exact_sources[] | select(.id == "branding-version" and .status == "MATCH")] | length == 1'
    jq_true inspect-iso-no-discrepancies "${TMP}/inspect-iso-squashfs-pass.out" \
        '(.discrepancies | length) == 0'

    expect_status 2 inspect-missing-dpkg-query \
        env PATH="${fakebin}" bash "${INSPECT}" --root "${root}" \
        --expected-version 0.4.0 --json
    jq_true inspect-missing-dpkg-result "${TMP}/inspect-missing-dpkg-query.out" \
        '.result == "BLOCKED"'
    jq_true inspect-missing-dpkg-tool "${TMP}/inspect-missing-dpkg-query.out" \
        '(.missing_tools | index("dpkg-query")) != null'

    expect_status 2 inspect-missing-xorriso \
        env PATH="${fakebin}" bash "${INSPECT}" --iso "${iso}" \
        --expected-version 0.4.0 --json
    jq_true inspect-missing-xorriso-result "${TMP}/inspect-missing-xorriso.out" \
        '.result == "BLOCKED"'
    jq_true inspect-missing-xorriso-tool "${TMP}/inspect-missing-xorriso.out" \
        '(.missing_tools | index("xorriso")) != null'

    cat > "${TMP}/version-report.json" <<'EOF'
{"schema":"fixture","result":"PASS"}
EOF

    cat > "${manifest_case}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
CASE_EVIDENCE_DIR=${FLR_EVIDENCE_DIR:-}
CASE_ISO_PATH=${FLR_ISO_PATH:-}
source "$1"
source "$2"
FLR_EVIDENCE_DIR=${CASE_EVIDENCE_DIR:?}
FLR_ISO_PATH=${CASE_ISO_PATH:?}
FLR_ISO_REQUESTED=${FLR_ISO_PATH}
FLR_ISO_SIZE=1234
FLR_ISO_SHA256=abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789
FLR_ISO_VERSION_FROM_NAME=0.4.0
FLR_ISO_SOURCE=explicit
FLR_CHECKSUM_STATUS=verified
FLR_CHECKSUM_FILE=""
FLR_SOURCE_COMMIT=deadbeef
FLR_SOURCE_BRANCH=main
FLR_SOURCE_DIRTY=yes
FLR_REPO_VERSION=0.4.0
FLR_QEMU_VERSION="QEMU emulator version 10.0.13 (fixture)"
FLR_ACCEL=TCG
FLR_ENV_CLASS=E2-TCG
FLR_KVM_AVAILABLE=0
FLR_KVM_REASON="no /dev/kvm"
FLR_FIRMWARE_MODE=pflash
FLR_FIRMWARE_DESC="OVMF 4M (non-secureboot)"
FLR_GPU_MODE=gtk-wsl
FLR_GPU_DESC="virtio-vga without 3D acceleration (WSL2)"
FLR_WSL=1
FLR_DISK_PATH=""
FLR_VARS_PATH=""
mkdir -p "${FLR_EVIDENCE_DIR}"
shift 2
report=$1
shift
options=$(flr_manifest_sanitize_args "$@")
flr_manifest_init "run-qemu-live.sh" 4096 4 "${options}" \
    preflight version qemu boot
flr_manifest_stage preflight PASS "fixture preflight"
flr_manifest_merge_report "${report}"
flr_manifest_finalize "${FINALIZE_CODE:-0}"
printf '%s\n' "${FLR_MANIFEST_PATH}"
EOF
    chmod +x "${manifest_case}"

    sanitized=$(bash -c 'source "$1"; shift; flr_manifest_sanitize_args "$@"' \
        _ "${LIB_MANIFEST}" --iso /tmp/x.iso --password hunter2 \
        --token=sekrit --normal value)
    if [ "${sanitized}" = '["--iso","/tmp/x.iso","--password","[REDACTED]","--token=[REDACTED]","--normal","value"]' ]; then
        ok sanitize-args
    else
        bad "sanitize-args (got ${sanitized})"
    fi

    manifest_a=$(FLR_EVIDENCE_DIR="${evidence_a}" FLR_ISO_PATH="${iso}" \
        bash "${manifest_case}" "${LIB_COMMON}" "${LIB_MANIFEST}" \
        "${TMP}/version-report.json" \
        --iso "${iso}" --password hunter2 --token=sekrit --normal value 2>"${TMP}/manifest-a.err") ||
        manifest_a=""
    if [ -n "${manifest_a}" ] && [ -f "${manifest_a}" ]; then
        ok manifest-init
    else
        bad manifest-init
        show_tail "${TMP}/manifest-a.err"
    fi
    jq_true manifest-schema "${manifest_a}" '.schema == "fluorineos.validation.manifest/1"'
    jq_true manifest-artifact "${manifest_a}" \
        '.artifact.iso_size_bytes == 1234 and .artifact.iso_source == "explicit" and .artifact.checksum_status == "verified"'
    jq_true manifest-source "${manifest_a}" \
        '.source.git_branch == "main" and .source.version_file == "0.4.0" and .source.worktree_dirty == "yes"'
    jq_true manifest-environment "${manifest_a}" \
        '.environment.classification == "E2-TCG" and .environment.memory_mb == 4096 and .environment.cpus == 4'
    jq_true manifest-stages "${manifest_a}" \
        '.stages.preflight == "PASS" and .stages.version == "PASS" and .stages.qemu == "PENDING"'
    jq_true manifest-report "${manifest_a}" '.version_report.result == "PASS"'
    jq_true manifest-finalized "${manifest_a}" \
        '.status == "completed" and .exit_code == 0 and .finished_utc != null'
    not_contains manifest-redaction "${manifest_a}" 'hunter2|sekrit'
    run_id=$(jq -r '.run_id' "${manifest_a}")
    if [[ "${run_id}" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]]; then
        ok manifest-run-id
    else
        bad "manifest-run-id (got ${run_id})"
    fi

    manifest_b_out="${TMP}/manifest-b.out"
    if FLR_EVIDENCE_DIR="${evidence_a}" FLR_ISO_PATH="${iso}" FINALIZE_CODE=130 \
        bash "${manifest_case}" "${LIB_COMMON}" "${LIB_MANIFEST}" \
        "${TMP}/version-report.json" --iso "${iso}" \
        >"${manifest_b_out}" 2>"${TMP}/manifest-b.err"; then
        manifest_b=$(tail -n 1 "${manifest_b_out}")
    else
        manifest_b=""
    fi
    if [ -n "${manifest_b}" ] && [ -f "${manifest_b}" ]; then
        ok manifest-reuse
    else
        bad manifest-reuse
        show_tail "${TMP}/manifest-b.err"
    fi
    jq_true manifest-aborted "${manifest_b}" \
        '.status == "aborted" and .exit_code == 130'
    archive="${evidence_a}/manifest-${run_id}.json"
    if [ -f "${archive}" ]; then
        ok manifest-archives-previous
    else
        bad manifest-archives-previous
    fi

    # Fake QEMU launcher lifecycle: no VM is booted, no disk is created.
    cat > "${fakeqemu}/qemu-system-x86_64" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
    printf 'QEMU emulator version 10.0.13 (fake phase 2 wrapper)\n'
    exit 0
fi
printf '%s\n' "$*" >> "${QEMU_LOG:?}"
exit 0
EOF
    chmod +x "${fakeqemu}/qemu-system-x86_64"

    expect_ok launcher-live-dry-run-no-manifest \
        bash "${LIVE}" --iso "${iso}" --sha256-file "${iso}.sha256" \
        --evidence-dir "${TMP}/evidence-dry" --dry-run
    if [ ! -e "${TMP}/evidence-dry/manifest.json" ]; then
        ok launcher-dry-run-no-manifest
    else
        bad launcher-dry-run-no-manifest
    fi

    expect_ok launcher-install-dry-run-no-manifest \
        bash "${INSTALL}" --iso "${iso}" --sha256-file "${iso}.sha256" \
        --evidence-dir "${TMP}/evidence-install-dry" --disk disk.qcow2 --dry-run
    if [ ! -e "${TMP}/evidence-install-dry/manifest.json" ]; then
        ok launcher-install-dry-run-no-manifest
    else
        bad launcher-install-dry-run-no-manifest
    fi

    expect_ok launcher-live-manifest \
        env QEMU_LOG="${qemu_log}" PATH="${fakeqemu}:${PATH}" \
        bash "${LIVE}" --iso "${iso}" --sha256-file "${iso}.sha256" \
        --evidence-dir "${evidence_live}" --serial-socket "${TMP}/phase2.sock"
    manifest_live="${evidence_live}/manifest.json"
    if [ -f "${manifest_live}" ]; then
        ok launcher-manifest-exists
    else
        bad launcher-manifest-exists
    fi
    jq_true launcher-manifest-source "${manifest_live}" \
        '.artifact.iso_source == "explicit" and .launcher == "run-qemu-live.sh"'
    jq_true launcher-manifest-runtime "${manifest_live}" \
        '.source.version_file == "0.4.0" and .environment.classification == "E2-TCG"'
    jq_true launcher-manifest-stages "${manifest_live}" \
        '.stages.preflight == "PASS" and .stages.qemu == "PASS" and .stages.version == "PENDING"'
    jq_true launcher-manifest-finalized "${manifest_live}" \
        '.status == "completed" and .exit_code == 0'
    contains launcher-manifest-options "${manifest_live}" --iso
    contains launcher-artifact-source "${evidence_live}/artifact.txt" 'iso_source=explicit'
    if [ -f "${qemu_log}" ] && grep -q -- '-cdrom' "${qemu_log}"; then
        ok launcher-called-fake-qemu
    else
        bad launcher-called-fake-qemu
    fi
    if [ ! -e "${evidence_live}/disk.qcow2" ]; then
        ok launcher-created-no-disk
    else
        bad launcher-created-no-disk
    fi

    # Result ledger.
    expect_ok ledger-pass \
        bash "${RECORD}" --test-id VER-01 --result PASS --environment 'E1 static inspection' \
        --evidence "${root}/etc/issue" --notes 'fixture pass' \
        --timestamp 2026-11-26T12:00:00Z --ledger "${ledger}"
    if [ -f "${ledger}" ]; then
        ok ledger-created
    else
        bad ledger-created
    fi
    if [ "$(wc -l < "${ledger}")" -eq 1 ]; then
        ok ledger-one-line
    else
        bad ledger-one-line
    fi
    jq_true ledger-fields "${ledger}" \
        '.test_id == "VER-01" and .result == "PASS" and .timestamp_utc == "2026-11-26T12:00:00Z" and .environment == "E1 static inspection"'
    jq_true ledger-evidence "${ledger}" \
        '(.evidence | endswith("/etc/issue"))'

    expect_ok ledger-skip \
        bash "${RECORD}" --test-id ISO-03 --result SKIP --environment 'E2 QEMU live' \
        --notes 'deliberately skipped in this fixture run' \
        --timestamp 2026-11-26T12:01:00Z --ledger "${ledger}"
    if [ "$(wc -l < "${ledger}")" -eq 2 ]; then
        ok ledger-appended
    else
        bad ledger-appended
    fi
    jq_slurp_true ledger-skip-evidence-null "${ledger}" \
        '[.[] | select(.test_id == "ISO-03" and .result == "SKIP" and .evidence == null)] | length == 1'

    expect_status 2 ledger-invalid-result \
        bash "${RECORD}" --test-id VER-01 --result MAYBE --environment E1 --ledger "${ledger}"
    expect_status 2 ledger-pass-no-evidence \
        bash "${RECORD}" --test-id VER-01 --result PASS --environment E1 --ledger "${ledger}"
    expect_status 2 ledger-missing-evidence \
        bash "${RECORD}" --test-id VER-01 --result FAIL --environment E1 \
        --evidence "${TMP}/no-evidence.txt" --ledger "${ledger}"
    expect_status 2 ledger-repo-evidence \
        bash "${RECORD}" --test-id VER-01 --result PASS --environment E1 \
        --evidence "${REPO}/TEST_PLAN.md" --ledger "${ledger}"
    expect_status 2 ledger-repo-ledger \
        bash "${RECORD}" --test-id VER-01 --result PASS --environment E1 \
        --evidence "${root}/etc/issue" --ledger "${REPO}/results.jsonl"
    expect_status 2 ledger-blocked-no-notes \
        bash "${RECORD}" --test-id VER-01 --result BLOCKED --environment E1 --ledger "${ledger}"
    expect_status 2 ledger-na-result \
        bash "${RECORD}" --test-id VER-01 --result N/A --environment E1 --ledger "${ledger}"
    expect_ok ledger-not-tested \
        bash "${RECORD}" --test-id VER-01 --result 'NOT TESTED' --environment E1 \
        --timestamp 2026-11-26T12:02:00Z --ledger "${ledger}"
    jq_slurp_true ledger-not-tested-recorded "${ledger}" \
        '[.[] | select(.result == "NOT TESTED" and .evidence == null)] | length == 1'

    printf '\nSummary: %s passed, %s failed\n' "${PASS}" "${FAIL}"
    printf 'Fixtures: %s\n' "${TMP}"
    [ "${FAIL}" -eq 0 ]
}

main "$@"
