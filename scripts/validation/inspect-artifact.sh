#!/usr/bin/env bash
# shellcheck disable=SC2016
# jq filters are intentionally single-quoted so $variables are expanded by jq.
set -euo pipefail

# Read-only version inspector for FluorineOS ISO images and installed roots.
# It never boots an image, mounts a filesystem, creates a disk, or writes into
# the source repository. Extracted squashfs images are cached outside Git.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../.." && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/version-common.sh
source "${SCRIPT_DIR}/../lib/version-common.sh"

MODE=""
ISO_PATH=""
ROOT_PATH=""
SQUASHFS_OVERRIDE=""
CACHE_DIR="${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/fluorineos/validation"
EXPECTED_VERSION=""
EXPECTED_PACKAGES=""
MANIFEST_PATH=""
JSON_OUTPUT=0
ISO_SIZE=""
ISO_SHA256=""
ISO_VOLUME=""
ISO_APPLICATION=""
SQUASHFS=""
SQUASHFS_SOURCE=""
PACKAGES_FILE=""
PACKAGES_AVAILABLE=0
RESULT=""
REFERENCE_OVERRIDE=0

EXACT_JSONL=""
PACKAGE_JSONL=""
DISCREPANCY_JSONL=""
TMP_DIR=""
REPORT_JSON=""
HAS_FAIL=0
HAS_BLOCKED=0
MISSING_TOOLS=()
NOTES=()

REQUIRED_COMPONENTS=(fluorine-desktop fluorine-artwork fluorine-keyring)
declare -A PACKAGE_VERSIONS=()
declare -A PACKAGE_ADDED=()

usage() {
    cat <<'EOF'
Usage: scripts/validation/inspect-artifact.sh [options]

Inspect version sources without booting or modifying an artifact.

Modes (choose one):
  --iso PATH              Inspect a live ISO read-only.
  --root DIR              Inspect an already extracted filesystem root.
  --system                Inspect the running system.

Options:
  --expected-version V    Override the repository VERSION reference. Use the
                          version of the tagged artifact being inspected.
  --expected-packages F   Enforce exact versions in a file of
                          "package version" or "package = version" lines.
  --squashfs PATH         Use an already extracted squashfs instead of making
                          a cache copy from the ISO. Read-only.
  --cache-dir DIR         Cache directory for extracted squashfs images.
                          Must be outside the source repository.
  --manifest FILE         Merge the report into an existing validation manifest.
  --json                  Emit the full JSON report on stdout.
  -h, --help              Show this help.

Exit status:
  0 PASS      1 FAIL      2 BLOCKED or usage error

Component packages such as fluorine-desktop are versioned independently from
the operating system. They are recorded, not required to match the OS version,
unless --expected-packages lists them.
EOF
}

die_usage() {
    printf 'error: %s\n' "$*" >&2
    exit 2
}

note() {
    NOTES+=("$1")
}

have() {
    command -v "$1" >/dev/null 2>&1
}

tool_marked() {
    local candidate=$1
    local tool=""
    for tool in "${MISSING_TOOLS[@]}"; do
        [ "${tool}" != "${candidate}" ] || return 0
    done
    return 1
}

check_tool() {
    local tool=$1
    have "${tool}" && return 0
    tool_marked "${tool}" || MISSING_TOOLS+=("${tool}")
    return 1
}

outside_repo() {
    local path=$1
    local resolved=""
    local repo_real=""

    resolved=$(realpath -m -- "${path}") || return 1
    repo_real=$(realpath -m -- "${REPO_ROOT}") || return 1
    case "${resolved}/" in
        "${repo_real}/"*) return 1 ;;
        *) return 0 ;;
    esac
}

validate_outside_repo() {
    local path=$1
    local label=$2

    [ -n "${path}" ] || die_usage "${label} is empty"
    outside_repo "${path}" ||
        die_usage "${label} must be outside the source repository: ${path}"
}

cleanup() {
    local file=""
    [ -n "${TMP_DIR}" ] || return 0
    for file in "${TMP_DIR}"/*; do
        if [ -f "${file}" ]; then
            rm -f -- "${file}"
        fi
    done
    rmdir -- "${TMP_DIR}" 2>/dev/null || true
}

jq_append() {
    local file=$1
    shift
    jq -cn "$@" >> "${file}"
}

add_discrepancy() {
    local id=$1
    local source=$2
    local status=$3
    local expected=$4
    local actual=$5
    local reason=$6

    jq_append "${DISCREPANCY_JSONL}" \
        --arg id "${id}" \
        --arg source "${source}" \
        --arg status "${status}" \
        --arg expected "${expected}" \
        --arg actual "${actual}" \
        --arg reason "${reason}" \
        '{id: $id, source: $source, status: $status,
          expected: $expected, actual: $actual, reason: $reason}'
}

# record_exact <id> <label> <source> <actual> <status> [reason] [raw]
record_exact() {
    local id=$1
    local label=$2
    local source=$3
    local actual=$4
    local status=$5
    local reason=${6:-}
    local raw=${7:-}

    case "${status}" in
        MATCH)
            ;;
        UNVERIFIABLE)
            HAS_BLOCKED=1
            add_discrepancy "${id}" "${source}" "${status}" \
                "${EXPECTED_VERSION:-unavailable}" "${actual:-unavailable}" \
                "${reason:-source could not be verified}"
            ;;
        *)
            HAS_FAIL=1
            add_discrepancy "${id}" "${source}" "${status}" \
                "${EXPECTED_VERSION:-unavailable}" "${actual:-unavailable}" \
                "${reason:-source does not match the reference}"
            ;;
    esac

    jq_append "${EXACT_JSONL}" \
        --arg id "${id}" \
        --arg label "${label}" \
        --arg source "${source}" \
        --arg expected "${EXPECTED_VERSION}" \
        --arg actual "${actual}" \
        --arg status "${status}" \
        --arg reason "${reason}" \
        --arg raw "${raw}" \
        '{id: $id, label: $label, source: $source,
          expected: (if $expected == "" then null else $expected end),
          actual: (if $actual == "" then null else $actual end),
          status: $status, reason: $reason,
          raw: (if $raw == "" then null else $raw end)}'
}

record_parsed_source() {
    local id=$1
    local label=$2
    local source=$3
    local raw=$4
    local parser=$5
    local parser_arg=${6:-}
    local actual=""
    local status=""

    [ -n "${raw}" ] || {
        record_exact "${id}" "${label}" "${source}" "" MISSING \
            "version source is absent"
        return 0
    }
    if [ -z "${EXPECTED_VERSION}" ]; then
        record_exact "${id}" "${label}" "${source}" "" UNVERIFIABLE \
            "reference version is unavailable" "${raw}"
        return 0
    fi

    if [ -n "${parser_arg}" ]; then
        actual=$("${parser}" "${raw}" "${parser_arg}" 2>/dev/null) || actual=""
    else
        actual=$("${parser}" "${raw}" 2>/dev/null) || actual=""
    fi

    if [ -z "${actual}" ]; then
        status="INVALID"
    elif [ "${actual}" = "${EXPECTED_VERSION}" ]; then
        status="MATCH"
    else
        status="MISMATCH"
    fi
    record_exact "${id}" "${label}" "${source}" "${actual}" "${status}" \
        "" "${raw}"
}

# record_file_source <id> <label> <file> <parser> [parser_arg] [display_source]
# The optional display_source keeps virtual ISO/squashfs paths in the report
# while the parser still reads the real extracted file.
record_file_source() {
    local id=$1
    local label=$2
    local file=$3
    local parser=$4
    local parser_arg=${5:-}
    local display_source=${6:-${file}}

    if [ ! -f "${file}" ] || [ ! -r "${file}" ]; then
        record_exact "${id}" "${label}" "${display_source}" "" MISSING \
            "version source file is absent"
        return 0
    fi
    if [ -z "${EXPECTED_VERSION}" ]; then
        record_exact "${id}" "${label}" "${display_source}" "" UNVERIFIABLE \
            "reference version is unavailable"
        return 0
    fi

    local actual=""
    if [ -n "${parser_arg}" ]; then
        actual=$("${parser}" "${file}" "${parser_arg}" 2>/dev/null) || actual=""
    else
        actual=$("${parser}" "${file}" 2>/dev/null) || actual=""
    fi

    local status=""
    if [ -z "${actual}" ]; then
        status="INVALID"
    elif [ "${actual}" = "${EXPECTED_VERSION}" ]; then
        status="MATCH"
    else
        status="MISMATCH"
    fi
    record_exact "${id}" "${label}" "${display_source}" "${actual}" "${status}"
}

add_package() {
    local name=$1
    local version=$2
    local status=$3
    local expected=$4
    local required="false"

    case "${name}" in
        fluorine-desktop | fluorine-artwork | fluorine-keyring) required="true" ;;
    esac
    [[ -n "${PACKAGE_ADDED[$name]:-}" ]] || PACKAGE_ADDED[$name]=1

    case "${status}" in
        MISMATCH | MISSING)
            HAS_FAIL=1
            add_discrepancy "package:${name}" "${name}" "${status}" \
                "${expected:-required}" "${version:-missing}" \
                "component package version does not satisfy the recorded expectation"
            ;;
        UNVERIFIABLE)
            HAS_BLOCKED=1
            add_discrepancy "package:${name}" "${name}" "${status}" \
                "${expected:-unknown}" "unknown" \
                "component package version could not be read"
            ;;
    esac

    jq_append "${PACKAGE_JSONL}" \
        --arg name "${name}" \
        --arg version "${version}" \
        --arg status "${status}" \
        --arg expected "${expected}" \
        --argjson required "${required}" \
        '{package: $name,
          version: (if $version == "" then null else $version end),
          expected: (if $expected == "" then null else $expected end),
          status: $status, relationship: "independent", required: $required}'
}

load_packages() {
    local name=""
    local version=""

    PACKAGE_VERSIONS=()
    while IFS=$'\t' read -r name version || [ -n "${name}" ]; do
        [ -n "${name}" ] || continue
        case "${name}" in
            fluorine-*) PACKAGE_VERSIONS[$name]=${version} ;;
        esac
    done < "${PACKAGES_FILE}"
}

check_packages() {
    local name=""
    local version=""
    local expected=""
    local status=""
    local sorted_names=""

    if [ "${PACKAGES_AVAILABLE}" -ne 1 ]; then
        for name in "${REQUIRED_COMPONENTS[@]}"; do
            add_package "${name}" "" UNVERIFIABLE ""
        done
        if [ -n "${EXPECTED_PACKAGES}" ]; then
            while IFS= read -r name; do
                [ -n "${name}" ] || continue
                [ -z "${PACKAGE_ADDED[$name]:-}" ] ||
                    add_package "${name}" "" UNVERIFIABLE ""
            done < <(flr_expected_package_names "${EXPECTED_PACKAGES}")
        fi
        return 0
    fi

    load_packages
    sorted_names=$(printf '%s\n' "${!PACKAGE_VERSIONS[@]}" | sort -u)
    while IFS= read -r name; do
        [ -n "${name}" ] || continue
        version=${PACKAGE_VERSIONS[$name]}
        expected=""
        status="RECORDED"
        if [ -n "${EXPECTED_PACKAGES}" ]; then
            expected=$(flr_expected_version_from_file "${EXPECTED_PACKAGES}" "${name}" 2>/dev/null) || expected=""
            if [ -n "${expected}" ] && [ "${version}" != "${expected}" ]; then
                status="MISMATCH"
            elif [ -n "${expected}" ]; then
                status="MATCH"
            fi
        fi
        add_package "${name}" "${version}" "${status}" "${expected}"
    done <<< "${sorted_names}"

    for name in "${REQUIRED_COMPONENTS[@]}"; do
        if [ -z "${PACKAGE_ADDED[$name]:-}" ]; then
            add_package "${name}" "" MISSING ""
        fi
    done

    if [ -n "${EXPECTED_PACKAGES}" ]; then
        while IFS= read -r name; do
            [ -n "${name}" ] || continue
            if [ -z "${PACKAGE_ADDED[$name]:-}" ]; then
                add_package "${name}" "" MISSING ""
            fi
        done < <(flr_expected_package_names "${EXPECTED_PACKAGES}")
    fi
}

read_reference() {
    local repo_version_file="${REPO_ROOT}/VERSION"
    local value=""

    if [ -n "${EXPECTED_VERSION}" ]; then
        flr_semver_valid "${EXPECTED_VERSION}" ||
            die_usage "invalid --expected-version: ${EXPECTED_VERSION}"
        REFERENCE_OVERRIDE=1
        return 0
    fi

    REFERENCE_OVERRIDE=0
    if [ -f "${repo_version_file}" ] && [ -r "${repo_version_file}" ]; then
        value=$(tr -d '[:space:]' < "${repo_version_file}") || value=""
    fi
    if flr_semver_valid "${value}"; then
        EXPECTED_VERSION=${value}
    else
        note "repository VERSION is missing or invalid; version comparisons are unverifiable"
        HAS_BLOCKED=1
    fi
}

read_iso_sources() {
    local volume=""
    local application=""
    local key=""
    local cache_file=""
    local part=""
    local source_path=""
    local dest=""
    local status=""

    check_tool unsquashfs || true
    if check_tool xorriso; then
        if xorriso -indev "${ISO_PATH}" -pvd_info \
            > "${TMP_DIR}/pvd.txt" 2> "${TMP_DIR}/pvd.err"; then
            volume=$(flr_pvd_field "${TMP_DIR}/pvd.txt" "Volume Id" 2>/dev/null) || volume=""
            application=$(flr_pvd_field "${TMP_DIR}/pvd.txt" "App Id" 2>/dev/null) || application=""
            ISO_VOLUME=${volume}
            ISO_APPLICATION=${application}
            record_parsed_source "iso-volume" "ISO volume label" \
                "ISO PVD:Volume Id" "${volume}" flr_version_from_iso_volume
            record_parsed_source "iso-application" "ISO application id" \
                "ISO PVD:App Id" "${application}" flr_version_from_iso_application
        else
            note "xorriso could not read the ISO PVD; see xorriso-stderr in the report"
            cp -f -- "${TMP_DIR}/pvd.err" "${TMP_DIR}/note-xorriso-pvd.txt" 2>/dev/null || true
            record_exact "iso-volume" "ISO volume label" "ISO PVD:Volume Id" \
                "" UNVERIFIABLE "xorriso could not read the PVD"
            record_exact "iso-application" "ISO application id" "ISO PVD:App Id" \
                "" UNVERIFIABLE "xorriso could not read the PVD"
        fi
    else
        record_exact "iso-volume" "ISO volume label" "ISO PVD:Volume Id" \
            "" UNVERIFIABLE "xorriso is not installed"
        record_exact "iso-application" "ISO application id" "ISO PVD:App Id" \
            "" UNVERIFIABLE "xorriso is not installed"
    fi

    if have xorriso; then
        if xorriso -indev "${ISO_PATH}" -osirrox on \
            -extract /live/filesystem.packages "${TMP_DIR}/packages.tsv" \
            > "${TMP_DIR}/packages-extract.log" 2>&1; then
            PACKAGES_FILE="${TMP_DIR}/packages.tsv"
            PACKAGES_AVAILABLE=1
        else
            note "the ISO has no readable /live/filesystem.packages inventory"
        fi
    fi

    if [ -n "${SQUASHFS_OVERRIDE}" ]; then
        if [ -f "${SQUASHFS_OVERRIDE}" ] && [ -r "${SQUASHFS_OVERRIDE}" ] &&
            [ -s "${SQUASHFS_OVERRIDE}" ]; then
            SQUASHFS=$(realpath -- "${SQUASHFS_OVERRIDE}") || SQUASHFS=""
            SQUASHFS_SOURCE="explicit"
        else
            die_usage "squashfs file is not a readable non-empty regular file: ${SQUASHFS_OVERRIDE}"
        fi
    elif check_tool xorriso && check_tool unsquashfs; then
        validate_outside_repo "${CACHE_DIR}" "cache directory"
        mkdir -p -- "${CACHE_DIR}" ||
            die_usage "cannot create cache directory: ${CACHE_DIR}"
        if [ -n "${ISO_SHA256}" ]; then
            key=${ISO_SHA256}
        else
            key="$(basename -- "${ISO_PATH}")-${ISO_SIZE}"
        fi
        cache_file="${CACHE_DIR}/${key}-filesystem.squashfs"
        if [ -s "${cache_file}" ]; then
            SQUASHFS=${cache_file}
            SQUASHFS_SOURCE="cache"
            note "reusing cached squashfs: ${cache_file}"
        else
            part="${cache_file}.part.$$"
            if xorriso -indev "${ISO_PATH}" -osirrox on \
                -extract /live/filesystem.squashfs "${part}" \
                > "${TMP_DIR}/squashfs-extract.log" 2>&1 &&
                [ -s "${part}" ]; then
                if mv -f -- "${part}" "${cache_file}"; then
                    SQUASHFS=${cache_file}
                    SQUASHFS_SOURCE="extracted"
                else
                    note "cannot move extracted squashfs into the cache: ${cache_file}"
                fi
            else
                note "xorriso could not extract /live/filesystem.squashfs from the ISO"
            fi
        fi
    fi

    if [ -z "${SQUASHFS}" ] && [ "${PACKAGES_AVAILABLE}" -ne 1 ] &&
        [ -n "${ISO_SHA256}" ]; then
        note "package inventory and squashfs are both unavailable"
    fi

    if [ -n "${SQUASHFS}" ]; then
        for source_path in \
            "etc/os-release:os-release" \
            "etc/issue:issue" \
            "usr/share/calamares/branding/fluorineos/branding.desc:branding"; do
            dest=${source_path#*:}
            source_path=${source_path%%:*}
            case "${dest}" in
                os-release)
                    id="os-release-version"
                    label="/etc/os-release VERSION"
                    parser=flr_version_from_os_release
                    parser_arg="VERSION"
                    ;;
                issue)
                    id="issue"
                    label="/etc/issue"
                    parser=flr_version_from_issue
                    parser_arg=""
                    ;;
                branding)
                    id="branding-version"
                    label="Calamares branding version"
                    parser=flr_version_from_branding
                    parser_arg="version"
                    ;;
            esac
            if unsquashfs -cat "${SQUASHFS}" "${source_path}" \
                > "${TMP_DIR}/${dest}" 2> "${TMP_DIR}/${dest}.err"; then
                :
            else
                : > "${TMP_DIR}/${dest}"
            fi
            if [ -s "${TMP_DIR}/${dest}" ]; then
                record_file_source "${id}" "${label}" \
                    "${TMP_DIR}/${dest}" "${parser}" "${parser_arg}" \
                    "squashfs:${source_path}"
            else
                status="MISSING"
                if ! have unsquashfs; then
                    status="UNVERIFIABLE"
                fi
                record_exact "${id}" "${label}" "squashfs:${source_path}" \
                    "" "${status}" "${source_path} is absent or unreadable in the squashfs"
            fi
        done

        if [ -s "${TMP_DIR}/os-release" ]; then
            record_file_source "os-release-id" "/etc/os-release VERSION_ID" \
                "${TMP_DIR}/os-release" flr_version_from_os_release "VERSION_ID" \
                "squashfs:etc/os-release"
        else
            record_exact "os-release-id" "/etc/os-release VERSION_ID" \
                "squashfs:etc/os-release" "" MISSING \
                "os-release is absent or unreadable in the squashfs"
        fi

        if [ -s "${TMP_DIR}/branding" ]; then
            record_file_source "branding-short-version" \
                "Calamares branding shortVersion" \
                "${TMP_DIR}/branding" flr_version_from_branding "shortVersion" \
                "squashfs:usr/share/calamares/branding/fluorineos/branding.desc"
        else
            record_exact "branding-short-version" \
                "Calamares branding shortVersion" \
                "squashfs:usr/share/calamares/branding/fluorineos/branding.desc" \
                "" MISSING "branding.desc is absent or unreadable"
        fi
    else
        for id_label in \
            "os-release-version:/etc/os-release VERSION" \
            "os-release-id:/etc/os-release VERSION_ID" \
            "issue:/etc/issue" \
            "branding-version:Calamares branding version" \
            "branding-short-version:Calamares branding shortVersion"; do
            id=${id_label%%:*}
            label=${id_label#*:}
            record_exact "${id}" "${label}" "squashfs" "" UNVERIFIABLE \
                "squashfs could not be read"
        done
    fi

    if [ "${PACKAGES_AVAILABLE}" -ne 1 ] && [ -n "${SQUASHFS}" ] &&
        have unsquashfs; then
        if unsquashfs -cat "${SQUASHFS}" var/lib/dpkg/status \
            > "${TMP_DIR}/dpkg-status" 2> "${TMP_DIR}/dpkg-status.err" &&
            [ -s "${TMP_DIR}/dpkg-status" ]; then
            awk '
                BEGIN { RS = ""; FS = "\n" }
                {
                    name = ""
                    version = ""
                    for (i = 1; i <= NF; i++) {
                        if ($i ~ /^Package: /) {
                            name = substr($i, 10)
                        } else if ($i ~ /^Version: /) {
                            version = substr($i, 10)
                        }
                    }
                    if (name != "" && version != "") {
                        print name "\t" version
                    }
                }
            ' "${TMP_DIR}/dpkg-status" > "${TMP_DIR}/packages.tsv"
            PACKAGES_FILE="${TMP_DIR}/packages.tsv"
            PACKAGES_AVAILABLE=1
            note "package versions recovered from the squashfs dpkg status file"
        fi
    fi
}

read_root_sources() {
    local branding="${ROOT_PATH}/usr/share/calamares/branding/fluorineos/branding.desc"

    record_file_source "os-release-version" "/etc/os-release VERSION" \
        "${ROOT_PATH}/etc/os-release" flr_version_from_os_release "VERSION"
    record_file_source "os-release-id" "/etc/os-release VERSION_ID" \
        "${ROOT_PATH}/etc/os-release" flr_version_from_os_release "VERSION_ID"
    record_file_source "issue" "/etc/issue" \
        "${ROOT_PATH}/etc/issue" flr_version_from_issue
    record_file_source "branding-version" "Calamares branding version" \
        "${branding}" flr_version_from_branding "version"
    record_file_source "branding-short-version" "Calamares branding shortVersion" \
        "${branding}" flr_version_from_branding "shortVersion"
}

read_system_sources() {
    ROOT_PATH="/"
    read_root_sources
}

read_root_packages() {
    local status_file="${ROOT_PATH}/var/lib/dpkg/status"

    if ! check_tool dpkg-query; then
        note "dpkg-query is not installed; component package versions are unverifiable"
        return 0
    fi
    if [ ! -f "${status_file}" ] || [ ! -r "${status_file}" ]; then
        note "the dpkg status database is absent: ${status_file}"
        return 0
    fi

    if dpkg-query --admindir="${ROOT_PATH}/var/lib/dpkg" -W \
        -f='${Package}\t${Version}\n' > "${TMP_DIR}/packages.tsv" \
        2> "${TMP_DIR}/dpkg-query.err"; then
        PACKAGES_FILE="${TMP_DIR}/packages.tsv"
        PACKAGES_AVAILABLE=1
    else
        note "dpkg-query could not read the package database; see dpkg-query-stderr in the report"
    fi
}

json_array_from_names() {
    local json='[]'
    local value=""

    for value in "$@"; do
        json=$(jq -cn --argjson current "${json}" --arg value "${value}" \
            '$current + [$value]') || json='[]'
    done
    printf '%s' "${json}"
}

write_report() {
    local generated=""
    local missing_json=""
    local note_json=""
    local mode_value=${MODE}
    local artifact_path=${ISO_PATH}
    local artifact_name=""
    local size_value="null"
    local sha_value=""
    local root_value=""
    local override_json="false"

    generated=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    [ -n "${ISO_PATH}" ] && artifact_name=$(basename -- "${ISO_PATH}")
    [ -n "${ISO_SIZE}" ] && size_value=${ISO_SIZE}
    [ -n "${ISO_SHA256}" ] && sha_value=${ISO_SHA256}
    [ "${MODE}" != "iso" ] && root_value=${ROOT_PATH}
    [ "${REFERENCE_OVERRIDE:-0}" -eq 1 ] && override_json="true"

    missing_json=$(json_array_from_names "${MISSING_TOOLS[@]}")
    note_json='[]'
    local note=""
    for note in "${NOTES[@]}"; do
        note_json=$(jq -cn --argjson current "${note_json}" --arg value "${note}" \
            '$current + [$value]')
    done

    if [ "${HAS_FAIL}" -eq 1 ]; then
        RESULT="FAIL"
    elif [ "${HAS_BLOCKED}" -eq 1 ]; then
        RESULT="BLOCKED"
    else
        RESULT="PASS"
    fi

    jq -n \
        --arg schema "fluorineos.version-report/1" \
        --arg generated "${generated}" \
        --arg mode "${mode_value}" \
        --arg path "${artifact_path}" \
        --arg name "${artifact_name}" \
        --arg size "${size_value}" \
        --arg sha "${sha_value}" \
        --arg volume "${ISO_VOLUME}" \
        --arg application "${ISO_APPLICATION}" \
        --arg root "${root_value}" \
        --arg squashfs "${SQUASHFS}" \
        --arg squashfs_source "${SQUASHFS_SOURCE}" \
        --arg cache "${CACHE_DIR}" \
        --arg reference "${EXPECTED_VERSION}" \
        --argjson override "${override_json}" \
        --arg result "${RESULT}" \
        --argjson missing_tools "${missing_json}" \
        --argjson notes "${note_json}" \
        --slurpfile exact "${EXACT_JSONL}" \
        --slurpfile packages "${PACKAGE_JSONL}" \
        --slurpfile discrepancies "${DISCREPANCY_JSONL}" \
        '{
            schema: $schema,
            generated_utc: $generated,
            mode: $mode,
            artifact: {
                iso_path: (if $path == "" then null else $path end),
                iso_name: (if $name == "" then null else $name end),
                iso_size_bytes: (if $size == "null" or $size == "" then null else ($size | tonumber) end),
                iso_sha256: (if $sha == "" then null else $sha end),
                iso_volume: (if $volume == "" then null else $volume end),
                iso_application: (if $application == "" then null else $application end),
                root: (if $root == "" then null else $root end),
                squashfs: (if $squashfs == "" then null else $squashfs end),
                squashfs_source: (if $squashfs_source == "" then null else $squashfs_source end),
                cache_dir: (if $mode == "iso" then $cache else null end)
            },
            reference: {
                version: (if $reference == "" then null else $reference end),
                override: $override,
                source: (if $override then "--expected-version" else "repository VERSION" end)
            },
            result: $result,
            exact_sources: $exact,
            independent_packages: $packages,
            discrepancies: $discrepancies,
            missing_tools: $missing_tools,
            notes: $notes
        }' > "${REPORT_JSON}"
}

merge_manifest() {
    local tmp="${MANIFEST_PATH}.tmp.$$"
    local now=""

    [ -f "${MANIFEST_PATH}" ] ||
        die_usage "manifest does not exist: ${MANIFEST_PATH}"
    validate_outside_repo "${MANIFEST_PATH}" "manifest"
    jq -e 'type == "object"' "${MANIFEST_PATH}" >/dev/null 2>&1 ||
        die_usage "manifest is not a JSON object: ${MANIFEST_PATH}"
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    if ! jq --slurpfile report "${REPORT_JSON}" --arg now "${now}" \
        '.version_report = $report[0]
         | .stages.version = $report[0].result
         | .stage_details.version = ($report[0].result + " from inspect-artifact.sh")
         | .updated_utc = $now' \
        "${MANIFEST_PATH}" > "${tmp}"; then
        rm -f -- "${tmp}"
        die_usage "cannot merge the version report into ${MANIFEST_PATH}"
    fi
    mv -f -- "${tmp}" "${MANIFEST_PATH}" ||
        die_usage "cannot replace the manifest: ${MANIFEST_PATH}"
}

print_human_report() {
    local status=""
    local label=""
    local actual=""
    local raw=""
    local name=""
    local version=""
    local expected=""
    local detail=""
    local tool=""

    printf 'FluorineOS artifact version report\n'
    printf 'Mode:           %s\n' "${MODE}"
    if [ "${MODE}" = "iso" ]; then
        printf 'Artifact:       %s\n' "${ISO_PATH}"
        printf 'Size (bytes):   %s\n' "${ISO_SIZE}"
        printf 'SHA-256:        %s\n' "${ISO_SHA256:-not computed}"
        printf 'Squashfs:       %s\n' "${SQUASHFS:-unavailable}"
    else
        printf 'Root:           %s\n' "${ROOT_PATH}"
    fi
    printf 'Reference:      %s (%s)\n' \
        "${EXPECTED_VERSION:-unavailable}" \
        "$([ "${REFERENCE_OVERRIDE:-0}" -eq 1 ] && printf '%s' '--expected-version' || printf '%s' 'repository VERSION')"
    printf 'Result:         %s\n' "${RESULT}"
    printf '\nExact version sources:\n'
    while IFS=$'\t' read -r status label actual raw; do
        if [ -n "${raw}" ] && [ "${raw}" != "${actual}" ]; then
            printf '  %-14s %-36s %s (%s)\n' "${status}" "${label}" "${actual}" "${raw}"
        else
            printf '  %-14s %-36s %s\n' "${status}" "${label}" "${actual}"
        fi
    done < <(jq -r '.exact_sources[] | [.status, .label, (.actual // ""), (.raw // "")] | @tsv' "${REPORT_JSON}")

    printf '\nIndependent component packages:\n'
    while IFS=$'\t' read -r name version status expected; do
        if [ -n "${expected}" ]; then
            printf '  %-14s %-26s %s (expected %s)\n' "${status}" "${name}" "${version}" "${expected}"
        else
            printf '  %-14s %-26s %s\n' "${status}" "${name}" "${version}"
        fi
    done < <(jq -r '.independent_packages[] | [.status, .package, (.version // ""), (.expected // "")] | @tsv' "${REPORT_JSON}")

    if [ "${#MISSING_TOOLS[@]}" -gt 0 ]; then
        printf '\nMissing tools:  '
        for tool in "${MISSING_TOOLS[@]}"; do
            printf '%s ' "${tool}"
        done
        printf '\n'
    fi

    while IFS= read -r detail; do
        [ -n "${detail}" ] && printf 'Note:           %s\n' "${detail}"
    done < <(jq -r '.notes[]' "${REPORT_JSON}")

    while IFS=$'\t' read -r label status expected actual reason; do
        printf 'Discrepancy:    %s [%s] expected=%s actual=%s: %s\n' \
            "${label}" "${status}" "${expected}" "${actual}" "${reason}"
    done < <(jq -r '.discrepancies[] | [.source, .status, .expected, .actual, .reason] | @tsv' "${REPORT_JSON}")
}

main() {
    local mode_count=0

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --iso)
                [ "$#" -ge 2 ] || die_usage "option --iso requires an argument"
                ISO_PATH=$2
                MODE="iso"
                shift 2
                ;;
            --root)
                [ "$#" -ge 2 ] || die_usage "option --root requires an argument"
                ROOT_PATH=$2
                MODE="root"
                shift 2
                ;;
            --system)
                MODE="system"
                shift
                ;;
            --expected-version)
                [ "$#" -ge 2 ] || die_usage "option --expected-version requires an argument"
                EXPECTED_VERSION=$2
                shift 2
                ;;
            --expected-packages)
                [ "$#" -ge 2 ] || die_usage "option --expected-packages requires an argument"
                EXPECTED_PACKAGES=$2
                shift 2
                ;;
            --squashfs)
                [ "$#" -ge 2 ] || die_usage "option --squashfs requires an argument"
                SQUASHFS_OVERRIDE=$2
                shift 2
                ;;
            --cache-dir)
                [ "$#" -ge 2 ] || die_usage "option --cache-dir requires an argument"
                CACHE_DIR=$2
                shift 2
                ;;
            --manifest)
                [ "$#" -ge 2 ] || die_usage "option --manifest requires an argument"
                MANIFEST_PATH=$2
                shift 2
                ;;
            --json)
                JSON_OUTPUT=1
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            --)
                shift
                [ "$#" -eq 0 ] || die_usage "unexpected positional argument: $1"
                break
                ;;
            *)
                usage >&2
                die_usage "unknown option: $1"
                ;;
        esac
    done

    [ "${MODE}" != "" ] || die_usage "choose exactly one of --iso, --root, or --system"
    [ "${MODE}" != "system" ] || mode_count=$((mode_count + 1))
    [ -z "${ISO_PATH}" ] || mode_count=$((mode_count + 1))
    [ -z "${ROOT_PATH}" ] || mode_count=$((mode_count + 1))
    [ "${mode_count}" -eq 1 ] || die_usage "choose exactly one of --iso, --root, or --system"

    have jq || die_usage "jq not found in PATH; the inspector requires jq"

    TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/flr-inspect.XXXXXX") ||
        die_usage "cannot create a temporary directory"
    trap cleanup EXIT
    EXACT_JSONL="${TMP_DIR}/exact.jsonl"
    PACKAGE_JSONL="${TMP_DIR}/packages.jsonl"
    DISCREPANCY_JSONL="${TMP_DIR}/discrepancies.jsonl"
    NOTE_JSONL="${TMP_DIR}/notes.jsonl"
    REPORT_JSON="${TMP_DIR}/report.json"
    : > "${EXACT_JSONL}"
    : > "${PACKAGE_JSONL}"
    : > "${DISCREPANCY_JSONL}"
    : > "${NOTE_JSONL}"

    if [ -n "${EXPECTED_PACKAGES}" ]; then
        if [ ! -f "${EXPECTED_PACKAGES}" ] || [ ! -r "${EXPECTED_PACKAGES}" ]; then
            die_usage "expected-packages file is not readable: ${EXPECTED_PACKAGES}"
        fi
        EXPECTED_PACKAGES=$(realpath -- "${EXPECTED_PACKAGES}") ||
            die_usage "cannot resolve expected-packages file: ${EXPECTED_PACKAGES}"
    fi
    if [ -n "${SQUASHFS_OVERRIDE}" ] && [ "${MODE}" != "iso" ]; then
        die_usage "--squashfs is only valid with --iso"
    fi

    read_reference

    if [ "${MODE}" = "iso" ]; then
        [ -n "${ISO_PATH}" ] || die_usage "ISO path is empty"
        case "${ISO_PATH}" in
            /dev/*) die_usage "refusing device path as ISO: ${ISO_PATH}" ;;
        esac
        [ -e "${ISO_PATH}" ] || die_usage "ISO not found: ${ISO_PATH}"
        if [ ! -f "${ISO_PATH}" ] || [ -b "${ISO_PATH}" ]; then
            die_usage "ISO is not a regular file: ${ISO_PATH}"
        fi
        [ -r "${ISO_PATH}" ] || die_usage "ISO is not readable: ${ISO_PATH}"
        ISO_PATH=$(realpath -- "${ISO_PATH}") ||
            die_usage "cannot resolve ISO path: ${ISO_PATH}"
        [ -s "${ISO_PATH}" ] || die_usage "ISO is empty: ${ISO_PATH}"
        ISO_SIZE=$(stat -c %s -- "${ISO_PATH}") || ISO_SIZE=""
        if have sha256sum; then
            ISO_SHA256=$(sha256sum -- "${ISO_PATH}" | awk '{print $1}') || ISO_SHA256=""
            [[ "${ISO_SHA256}" =~ ^[0-9a-fA-F]{64}$ ]] || ISO_SHA256=""
        else
            note "sha256sum is not installed; the ISO digest is not recorded"
        fi
        read_iso_sources
    else
        if [ "${MODE}" = "root" ]; then
            [ -d "${ROOT_PATH}" ] || die_usage "root is not a directory: ${ROOT_PATH}"
            ROOT_PATH=$(realpath -- "${ROOT_PATH}") ||
                die_usage "cannot resolve root directory: ${ROOT_PATH}"
        fi
        read_root_sources
        read_root_packages
    fi

    check_packages
    write_report

    if [ -n "${MANIFEST_PATH}" ]; then
        merge_manifest
    fi

    if [ "${JSON_OUTPUT}" -eq 1 ]; then
        cat -- "${REPORT_JSON}"
    else
        print_human_report
    fi

    case "${RESULT}" in
        PASS) exit 0 ;;
        FAIL) exit 1 ;;
        BLOCKED) exit 2 ;;
    esac
}

main "$@"
