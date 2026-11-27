#!/usr/bin/env bash
set -euo pipefail

# Append one evidence-backed result to the local validation ledger.
# TEST_PLAN.md remains the canonical source of test IDs and procedures.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../.." && pwd)

TEST_ID=""
RESULT=""
EVIDENCE=""
NOTES=""
ENVIRONMENT=""
TIMESTAMP=""
LEDGER_PATH="${FLUORINEOS_RESULT_LEDGER:-${XDG_DATA_HOME:-${HOME:-/tmp}/.local/share}/fluorineos/validation/results.jsonl}"

usage() {
    cat <<'EOF'
Usage: scripts/validation/record-result.sh --test-id ID --result STATUS \
       --environment TEXT [--evidence PATH] [--notes TEXT] \
       [--timestamp UTC] [--ledger PATH]

Record one result in a local JSONL ledger. TEST_PLAN.md defines the tests.

Options:
  --test-id ID       Canonical test id, for example VER-01 or ISO-03.
  --result STATUS    PASS, FAIL, BLOCKED, NOT TESTED, or SKIP.
  --environment TEXT Test environment and runtime context. Required.
  --evidence PATH    Existing local evidence file or directory. Required for
                     PASS and FAIL, and rejected if it is inside the Git repo.
  --notes TEXT       Result notes. Required for BLOCKED and SKIP.
  --timestamp UTC    Override the UTC timestamp for reproducible fixtures.
  --ledger PATH      JSONL ledger path. Defaults to
                     $XDG_DATA_HOME/fluorineos/validation/results.jsonl or
                     ~/.local/share/fluorineos/validation/results.jsonl.
  -h, --help         Show this help.

The ledger is local evidence and must be outside the source repository.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 2
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

main() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --test-id)
                [ "$#" -ge 2 ] || die "option --test-id requires an argument"
                TEST_ID=$2
                shift 2
                ;;
            --result)
                [ "$#" -ge 2 ] || die "option --result requires an argument"
                RESULT=$2
                shift 2
                ;;
            --environment)
                [ "$#" -ge 2 ] || die "option --environment requires an argument"
                ENVIRONMENT=$2
                shift 2
                ;;
            --evidence)
                [ "$#" -ge 2 ] || die "option --evidence requires an argument"
                EVIDENCE=$2
                shift 2
                ;;
            --notes)
                [ "$#" -ge 2 ] || die "option --notes requires an argument"
                NOTES=$2
                shift 2
                ;;
            --timestamp)
                [ "$#" -ge 2 ] || die "option --timestamp requires an argument"
                TIMESTAMP=$2
                shift 2
                ;;
            --ledger)
                [ "$#" -ge 2 ] || die "option --ledger requires an argument"
                LEDGER_PATH=$2
                shift 2
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            --)
                shift
                [ "$#" -eq 0 ] || die "unexpected positional argument: $1"
                break
                ;;
            *)
                usage >&2
                die "unknown option: $1"
                ;;
        esac
    done

    command -v jq >/dev/null 2>&1 || die "jq not found in PATH"
    command -v realpath >/dev/null 2>&1 || die "realpath not found in PATH"

    [[ "${TEST_ID}" =~ ^[A-Z][A-Z0-9]*-[0-9]{2,3}$ ]] ||
        die "invalid test id: ${TEST_ID}"
    case "${RESULT}" in
        PASS | FAIL | BLOCKED | "NOT TESTED" | SKIP) ;;
        *) die "invalid result: ${RESULT}" ;;
    esac
    [ -n "${ENVIRONMENT}" ] || die "--environment is required"
    [ "${#ENVIRONMENT}" -le 200 ] || die "--environment is too long"

    case "${RESULT}" in
        PASS | FAIL)
            [ -n "${EVIDENCE}" ] || die "--evidence is required for ${RESULT}"
            ;;
        BLOCKED | SKIP)
            [ -n "${NOTES}" ] || die "--notes is required for ${RESULT}"
            ;;
    esac

    if [ -z "${TIMESTAMP}" ]; then
        TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ) || die "cannot read the current time"
    fi
    [[ "${TIMESTAMP}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
        die "invalid UTC timestamp: ${TIMESTAMP}"

    if [ -n "${EVIDENCE}" ]; then
        [ -e "${EVIDENCE}" ] || die "evidence path does not exist: ${EVIDENCE}"
        [ -r "${EVIDENCE}" ] || die "evidence path is not readable: ${EVIDENCE}"
        EVIDENCE=$(realpath -- "${EVIDENCE}") || die "cannot resolve evidence: ${EVIDENCE}"
        outside_repo "${EVIDENCE}" ||
            die "evidence must be outside the source repository: ${EVIDENCE}"
    fi

    [ -n "${LEDGER_PATH}" ] || die "ledger path is empty"
    outside_repo "${LEDGER_PATH}" ||
        die "ledger must be outside the source repository: ${LEDGER_PATH}"
    LEDGER_PATH=$(realpath -m -- "${LEDGER_PATH}") ||
        die "cannot resolve ledger path: ${LEDGER_PATH}"
    mkdir -p -- "$(dirname -- "${LEDGER_PATH}")" ||
        die "cannot create ledger directory: $(dirname -- "${LEDGER_PATH}")"
    [ ! -d "${LEDGER_PATH}" ] || die "ledger path is a directory: ${LEDGER_PATH}"

    local record=""
    record=$(jq -cn \
        --arg test_id "${TEST_ID}" \
        --arg result "${RESULT}" \
        --arg evidence "${EVIDENCE}" \
        --arg timestamp "${TIMESTAMP}" \
        --arg notes "${NOTES}" \
        --arg environment "${ENVIRONMENT}" \
        '{
            test_id: $test_id,
            result: $result,
            evidence: (if $evidence == "" then null else $evidence end),
            timestamp_utc: $timestamp,
            notes: $notes,
            environment: $environment
        }') || die "cannot serialize the result record"

    printf '%s\n' "${record}" >> "${LEDGER_PATH}" ||
        die "cannot append to ledger: ${LEDGER_PATH}"
    printf '%s\n' "${record}"
}

main "$@"
