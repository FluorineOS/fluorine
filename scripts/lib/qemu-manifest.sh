#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2016
# JSON validation manifest for FluorineOS QEMU runs.
# jq filters are intentionally single-quoted so $name is expanded by jq.
# This file is sourced after qemu-common.sh. It has no load-time side effects.

FLR_MANIFEST_PATH=""
FLR_MANIFEST_ACTIVE=0
FLR_RUN_ID=""

if ! declare -F flr_manifest_die >/dev/null 2>&1; then
    flr_manifest_die() {
        printf 'error: %s\n' "$*" >&2
        exit 1
    }
fi

flr_manifest_utc() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

flr_manifest_run_id() {
    local version=${FLR_REPO_VERSION:-unknown}

    [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || version="unknown"
    printf '%s-%s-%s\n' \
        "${version}" "$(date -u +%Y%m%dT%H%M%SZ)" "$$"
}

# Print a JSON array of command-line arguments with sensitive values removed.
flr_manifest_sanitize_args() {
    local arg=""
    local name=""
    local json='[]'
    local redact_next=0
    local -a sanitized=()

    for arg in "$@"; do
        if [ "${redact_next}" -eq 1 ]; then
            sanitized+=("[REDACTED]")
            redact_next=0
            continue
        fi

        case "${arg}" in
            -*)
                name=${arg%%=*}
                name=${name#--}
                name=${name#-}
                case "${name,,}" in
                    *password* | *passwd* | *secret* | *token* | *credential* | \
                        *api-key* | *apikey* | *access-key* | *private-key* | *auth-key*)
                        case "${arg}" in
                            *=*)
                                sanitized+=("${arg%%=*}=[REDACTED]")
                                ;;
                            *)
                                sanitized+=("${arg}")
                                redact_next=1
                                ;;
                        esac
                        continue
                        ;;
                esac
                ;;
        esac

        sanitized+=("${arg}")
    done

    for arg in "${sanitized[@]}"; do
        json=$(jq -cn --argjson current "${json}" --arg value "${arg}" \
            '$current + [$value]') ||
            flr_manifest_die "cannot serialize command-line options"
    done

    printf '%s\n' "${json}"
}

flr_manifest_apply() {
    local filter=$1
    local now=""
    local tmp=""

    shift
    [ -f "${FLR_MANIFEST_PATH}" ] ||
        flr_manifest_die "manifest does not exist: ${FLR_MANIFEST_PATH}"
    now=$(flr_manifest_utc) || flr_manifest_die "cannot read the current time"

    tmp="${FLR_MANIFEST_PATH}.tmp.$$"
    if ! jq --arg now "${now}" "$@" "${filter}" "${FLR_MANIFEST_PATH}" > "${tmp}"; then
        rm -f -- "${tmp}"
        flr_manifest_die "cannot update manifest: ${FLR_MANIFEST_PATH}"
    fi
    mv -f -- "${tmp}" "${FLR_MANIFEST_PATH}" ||
        flr_manifest_die "cannot replace manifest: ${FLR_MANIFEST_PATH}"
}

# flr_manifest_init <launcher> <memory_mb> <cpus> <options_json> <stage>...
flr_manifest_init() {
    local launcher=$1
    local memory=$2
    local cpus=$3
    local options_json=$4
    local stages_json='{}'
    local stage=""
    local started=""
    local archive=""
    local previous_run=""
    local iso_size_json="null"
    local kvm_available="false"
    local wsl="false"
    local disk_reuse="false"
    local disk_exists="false"
    local kvm_reason_json="null"

    shift 4

    [ -n "${FLR_EVIDENCE_DIR:-}" ] ||
        flr_manifest_die "evidence directory must be resolved before the manifest"
    [ -d "${FLR_EVIDENCE_DIR}" ] ||
        flr_manifest_die "evidence directory does not exist: ${FLR_EVIDENCE_DIR}"
    command -v jq >/dev/null 2>&1 ||
        flr_manifest_die "jq not found in PATH; the manifest requires jq"

    [[ "${memory}" =~ ^[0-9]+$ ]] ||
        flr_manifest_die "invalid memory allocation: ${memory}"
    [[ "${cpus}" =~ ^[0-9]+$ ]] ||
        flr_manifest_die "invalid CPU allocation: ${cpus}"
    printf '%s' "${options_json}" | jq -e 'type == "array"' >/dev/null 2>&1 ||
        flr_manifest_die "command-line options must be a JSON array"

    case "${FLR_ISO_SOURCE:-none}" in
        explicit | environment | discovered | none) ;;
        *) flr_manifest_die "invalid ISO source: ${FLR_ISO_SOURCE:-}" ;;
    esac

    for stage in "$@"; do
        [[ "${stage}" =~ ^[a-z][a-z0-9-]*$ ]] ||
            flr_manifest_die "invalid validation stage name: ${stage}"
        stages_json=$(jq -cn --argjson current "${stages_json}" --arg name "${stage}" \
            '$current + {($name): "PENDING"}') ||
            flr_manifest_die "cannot build the stage list"
    done
    [ "${stages_json}" != "{}" ] || stages_json='{}'

    [ -n "${FLR_ISO_SIZE:-}" ] && iso_size_json=${FLR_ISO_SIZE}
    [ "${FLR_KVM_AVAILABLE:-0}" -eq 1 ] && kvm_available="true"
    [ "${FLR_WSL:-0}" -eq 1 ] && wsl="true"
    [ "${FLR_DISK_REUSE:-0}" -eq 1 ] && disk_reuse="true"
    [ "${FLR_DISK_EXISTS:-0}" -eq 1 ] && disk_exists="true"
    if [ -n "${FLR_KVM_REASON:-}" ]; then
        kvm_reason_json=$(jq -cn --arg value "${FLR_KVM_REASON}" '$value') ||
            flr_manifest_die "cannot serialize the KVM status"
    fi

    FLR_RUN_ID=$(flr_manifest_run_id) ||
        flr_manifest_die "cannot build a validation run id"
    FLR_MANIFEST_PATH="${FLR_EVIDENCE_DIR}/manifest.json"
    started=$(flr_manifest_utc) || flr_manifest_die "cannot read the current time"

    # Preserve an earlier run in a reused evidence directory before replacing
    # manifest.json. The archived copy keeps the original run id.
    if [ -e "${FLR_MANIFEST_PATH}" ]; then
        previous_run=$(jq -r '.run_id // "unknown"' "${FLR_MANIFEST_PATH}" 2>/dev/null) ||
            previous_run="unknown"
        archive="${FLR_EVIDENCE_DIR}/manifest-${previous_run}.json"
        [ ! -e "${archive}" ] ||
            flr_manifest_die "manifest archive already exists: ${archive}"
        cp -p -- "${FLR_MANIFEST_PATH}" "${archive}" ||
            flr_manifest_die "cannot archive the previous manifest: ${archive}"
        printf 'Previous manifest archived to %s\n' "${archive}"
    fi

    if ! jq -n \
        --arg schema "fluorineos.validation.manifest/1" \
        --arg run_id "${FLR_RUN_ID}" \
        --arg started "${started}" \
        --arg launcher "${launcher}" \
        --arg evidence "${FLR_EVIDENCE_DIR}" \
        --argjson options "${options_json}" \
        --arg iso_path "${FLR_ISO_PATH:-}" \
        --arg iso_name "$([ -n "${FLR_ISO_PATH:-}" ] && basename -- "${FLR_ISO_PATH}")" \
        --arg iso_size "${iso_size_json}" \
        --arg iso_sha256 "${FLR_ISO_SHA256:-}" \
        --arg checksum_file "${FLR_CHECKSUM_FILE:-}" \
        --arg checksum_status "${FLR_CHECKSUM_STATUS:-not-supplied}" \
        --arg iso_source "${FLR_ISO_SOURCE:-none}" \
        --arg version_from_name "${FLR_ISO_VERSION_FROM_NAME:-}" \
        --arg git_commit "${FLR_SOURCE_COMMIT:-unknown}" \
        --arg git_branch "${FLR_SOURCE_BRANCH:-unknown}" \
        --arg dirty "${FLR_SOURCE_DIRTY:-unknown}" \
        --arg repo_version "${FLR_REPO_VERSION:-unknown}" \
        --arg qemu_version "${FLR_QEMU_VERSION:-unknown}" \
        --arg acceleration "${FLR_ACCEL:-unknown}" \
        --arg classification "${FLR_ENV_CLASS:-unknown}" \
        --argjson kvm_available "${kvm_available}" \
        --argjson kvm_reason "${kvm_reason_json}" \
        --arg firmware_mode "${FLR_FIRMWARE_MODE:-unknown}" \
        --arg firmware "${FLR_FIRMWARE_DESC:-unknown}" \
        --arg display_mode "${FLR_GPU_MODE:-unknown}" \
        --arg display "${FLR_GPU_DESC:-unknown}" \
        --argjson memory "${memory}" \
        --argjson cpus "${cpus}" \
        --argjson wsl "${wsl}" \
        --arg disk_path "${FLR_DISK_PATH:-}" \
        --arg disk_size "${FLR_DISK_SIZE_SPEC:-}" \
        --argjson disk_reuse "${disk_reuse}" \
        --argjson disk_exists "${disk_exists}" \
        --arg vars_path "${FLR_VARS_PATH:-}" \
        --argjson stages "${stages_json}" \
        '{
            schema: $schema,
            run_id: $run_id,
            started_utc: $started,
            updated_utc: $started,
            finished_utc: null,
            status: "running",
            exit_code: null,
            launcher: $launcher,
            evidence_dir: $evidence,
            options: $options,
            artifact: {
                iso_path: (if $iso_path == "" then null else $iso_path end),
                iso_name: (if $iso_name == "" then null else $iso_name end),
                iso_size_bytes: (if $iso_size == "null" or $iso_size == "" then null else ($iso_size | tonumber) end),
                iso_sha256: (if $iso_sha256 == "" then null else $iso_sha256 end),
                checksum_file: (if $checksum_file == "" then null else $checksum_file end),
                checksum_status: $checksum_status,
                iso_source: $iso_source,
                version_from_name: (if $version_from_name == "" then null else $version_from_name end)
            },
            source: {
                git_commit: $git_commit,
                git_branch: $git_branch,
                worktree_dirty: $dirty,
                version_file: $repo_version
            },
            environment: {
                qemu_version: $qemu_version,
                acceleration: $acceleration,
                classification: $classification,
                kvm_available: $kvm_available,
                kvm_reason: $kvm_reason,
                firmware_mode: $firmware_mode,
                firmware: $firmware,
                display_mode: $display_mode,
                display: $display,
                memory_mb: $memory,
                cpus: $cpus,
                wsl: $wsl
            },
            disk: (if $disk_path == "" then null else {
                path: $disk_path,
                size: (if $disk_size == "" then null else $disk_size end),
                reuse: $disk_reuse,
                exists: $disk_exists,
                vars_path: (if $vars_path == "" then null else $vars_path end)
            } end),
            stages: $stages,
            stage_details: {},
            version_report: null
        }' > "${FLR_MANIFEST_PATH}.tmp.$$"; then
        rm -f -- "${FLR_MANIFEST_PATH}.tmp.$$"
        flr_manifest_die "cannot write manifest: ${FLR_MANIFEST_PATH}"
    fi

    mv -f -- "${FLR_MANIFEST_PATH}.tmp.$$" "${FLR_MANIFEST_PATH}" ||
        flr_manifest_die "cannot install manifest: ${FLR_MANIFEST_PATH}"
    FLR_MANIFEST_ACTIVE=1
}

# flr_manifest_stage <name> <status> [detail]
flr_manifest_stage() {
    local name=$1
    local status=$2
    local detail=${3:-}

    [[ "${name}" =~ ^[a-z][a-z0-9-]*$ ]] ||
        flr_manifest_die "invalid validation stage name: ${name}"
    case "${status}" in
        PENDING | RUNNING | PASS | FAIL | BLOCKED | SKIP | ABORTED) ;;
        *) flr_manifest_die "invalid validation stage status: ${status}" ;;
    esac
    [ "${FLR_MANIFEST_ACTIVE:-0}" -eq 1 ] ||
        flr_manifest_die "manifest is not active"

    if [ "$#" -ge 3 ]; then
        flr_manifest_apply \
            '.stages[$name] = $status | .stage_details[$name] = $detail | .updated_utc = $now' \
            --arg name "${name}" --arg status "${status}" --arg detail "${detail}"
    else
        flr_manifest_apply \
            '.stages[$name] = $status | .updated_utc = $now' \
            --arg name "${name}" --arg status "${status}"
    fi
}

# Merge a version inspector report into version_report and the version stage.
flr_manifest_merge_report() {
    local report=$1
    local stage_status=""

    [ -f "${report}" ] ||
        flr_manifest_die "version report does not exist: ${report}"
    stage_status=$(jq -r '.result // "BLOCKED"' "${report}" 2>/dev/null) ||
        flr_manifest_die "cannot read the version report result: ${report}"
    case "${stage_status}" in
        PASS | FAIL | BLOCKED) ;;
        *) flr_manifest_die "invalid version report result: ${stage_status}" ;;
    esac
    [ "${FLR_MANIFEST_ACTIVE:-0}" -eq 1 ] ||
        flr_manifest_die "manifest is not active"

    flr_manifest_apply \
        '.version_report = $report[0] | .stages.version = $report[0].result | .stage_details.version = ($report[0].result + " from inspect-artifact.sh") | .updated_utc = $now' \
        --slurpfile report "${report}"
}

# flr_manifest_finalize [exit_code]
# Runs from an EXIT trap, so failures are reported without changing the exit
# status of the process that is already terminating.
flr_manifest_finalize() {
    local code=${1:-0}
    local status="completed"
    local now=""
    local tmp=""

    [ "${FLR_MANIFEST_ACTIVE:-0}" -eq 1 ] || return 0
    [ -f "${FLR_MANIFEST_PATH}" ] || {
        printf 'warning: manifest disappeared before finalization: %s\n' \
            "${FLR_MANIFEST_PATH}" >&2
        FLR_MANIFEST_ACTIVE=0
        return 0
    }

    if [ "${code}" -ne 0 ]; then
        case "${code}" in
            130 | 143) status="aborted" ;;
            *) status="failed" ;;
        esac
    fi

    now=$(flr_manifest_utc) || now=""
    tmp="${FLR_MANIFEST_PATH}.tmp.$$"
    if ! jq --arg now "${now}" --arg status "${status}" --arg code "${code}" \
        '.status = $status | .exit_code = ($code | tonumber) | .finished_utc = $now | .updated_utc = $now' \
        "${FLR_MANIFEST_PATH}" > "${tmp}"; then
        rm -f -- "${tmp}"
        printf 'warning: cannot finalize manifest: %s\n' "${FLR_MANIFEST_PATH}" >&2
        FLR_MANIFEST_ACTIVE=0
        return 1
    fi
    if ! mv -f -- "${tmp}" "${FLR_MANIFEST_PATH}"; then
        printf 'warning: cannot replace manifest: %s\n' "${FLR_MANIFEST_PATH}" >&2
        FLR_MANIFEST_ACTIVE=0
        return 1
    fi
    FLR_MANIFEST_ACTIVE=0
}
