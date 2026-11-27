#!/usr/bin/env bash
# shellcheck disable=SC2034
# Version parsing helpers shared by the FluorineOS validation tooling.
# This file is sourced. It must not execute anything at load time.

# Return 0 when the value is a bare MAJOR.MINOR.PATCH version.
flr_semver_valid() {
    [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# Print VERSION (or VERSION_ID) from an os-release file.
# The value must be a bare version; a decorated value is rejected so callers
# never compare a partial match.
flr_version_from_os_release() {
    local file=$1
    local key=${2:-VERSION}
    local line=""
    local value=""

    [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    [ -f "${file}" ] && [ -r "${file}" ] || return 1

    line=$(grep -m1 -E -- "^[[:space:]]*${key}=" "${file}" 2>/dev/null) ||
        return 1
    value=${line#*=}
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    case "${value}" in
        \"*\") value=${value#\"}; value=${value%\"} ;;
        \'*\') value=${value#\'}; value=${value%\'} ;;
    esac

    flr_semver_valid "${value}" || return 1
    printf '%s\n' "${value}"
}

# Print the version from the first line of /etc/issue.
flr_version_from_issue() {
    local file=$1
    local line=""

    [ -f "${file}" ] && [ -r "${file}" ] || return 1
    line=$(head -n 1 -- "${file}" 2>/dev/null) || return 1
    line=${line%$'\r'}

    if [[ "${line}" =~ ^[Ff][Ll][Uu][Oo][Rr][Ii][Nn][Ee][Oo][Ss][[:space:]]+([0-9]+\.[0-9]+\.[0-9]+)([[:space:]]|$) ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    return 1
}

# Decode FLUORINEOS_MAJOR_MINOR_PATCH from an ISO volume label.
flr_version_from_iso_volume() {
    local volume=${1:-}
    local upper=${volume^^}

    [[ "${upper}" =~ ^FLUORINEOS_([0-9]+)_([0-9]+)_([0-9]+)$ ]] || return 1
    printf '%s.%s.%s\n' \
        "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

# Print the version from the ISO application id "FluorineOS <version>".
flr_version_from_iso_application() {
    local application=${1:-}

    if [[ "${application}" =~ ^[Ff][Ll][Uu][Oo][Rr][Ii][Nn][Ee][Oo][Ss][[:space:]]+([0-9]+\.[0-9]+\.[0-9]+)[[:space:]]*$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    return 1
}

# Print a version key from a Calamares branding descriptor.
# Defaults to "version"; "shortVersion" is also supported.
flr_version_from_branding() {
    local file=$1
    local key=${2:-version}
    local line=""
    local value=""

    [[ "${key}" =~ ^[A-Za-z][A-Za-z0-9]*$ ]] || return 1
    [ -f "${file}" ] && [ -r "${file}" ] || return 1

    line=$(grep -m1 -E -- "^[[:space:]]*${key}:[[:space:]]*" "${file}" 2>/dev/null) ||
        return 1
    value=${line#*:}
    value=${value%%#*}
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    case "${value}" in
        \"*\") value=${value#\"}; value=${value%\"} ;;
        \'*\') value=${value#\'}; value=${value%\'} ;;
    esac

    flr_semver_valid "${value}" || return 1
    printf '%s\n' "${value}"
}

# Print the version from one "package<TAB>version" line.
flr_version_from_package_line() {
    local line=$1
    local package=$2
    local version=""

    [[ "${package}" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || return 1
    [[ "${line}" == "${package}"$'\t'* ]] || return 1

    version=${line#*$'\t'}
    version=${version%%$'\t'*}
    flr_semver_valid "${version}" || return 1
    printf '%s\n' "${version}"
}

# Print the version of a package from a tab-separated package inventory.
flr_version_from_packages_file() {
    local file=$1
    local package=$2
    local line=""
    local version=""

    [ -f "${file}" ] && [ -r "${file}" ] || return 1

    while IFS= read -r line || [ -n "${line}" ]; do
        line=${line%$'\r'}
        if version=$(flr_version_from_package_line "${line}" "${package}"); then
            printf '%s\n' "${version}"
            return 0
        fi
    done < "${file}"

    return 1
}

# Print the version of a package from a dpkg status database.
flr_version_from_dpkg_status() {
    local file=$1
    local package=$2
    local version=""

    [[ "${package}" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || return 1
    [ -f "${file}" ] && [ -r "${file}" ] || return 1

    version=$(awk -v wanted="${package}" '
        BEGIN { RS = ""; FS = "\n" }
        {
            name = ""
            value = ""
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^Package: /) {
                    name = substr($i, 10)
                } else if ($i ~ /^Version: /) {
                    value = substr($i, 10)
                }
            }
            if (name == wanted && value != "") {
                print value
                exit
            }
        }
    ' "${file}") || return 1

    flr_semver_valid "${version}" || return 1
    printf '%s\n' "${version}"
}

# Print an expected version from a file of "package version" or
# "package = version" lines. Blank lines and # comments are ignored.
flr_expected_version_from_file() {
    local file=$1
    local package=$2
    local line=""
    local name=""
    local version=""

    [[ "${package}" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || return 1
    [ -f "${file}" ] && [ -r "${file}" ] || return 1

    while IFS= read -r line || [ -n "${line}" ]; do
        line=${line%$'\r'}
        line=${line%%#*}
        line=${line#"${line%%[![:space:]]*}"}
        line=${line%"${line##*[![:space:]]}"}
        [ -n "${line}" ] || continue

        line=${line/=/ }
        read -r name version _ <<< "${line}"
        if [ "${name}" = "${package}" ]; then
            flr_semver_valid "${version}" || return 1
            printf '%s\n' "${version}"
            return 0
        fi
    done < "${file}"

    return 1
}

# Print the package names listed in an expected-packages file.
flr_expected_package_names() {
    local file=$1
    local line=""
    local name=""

    [ -f "${file}" ] && [ -r "${file}" ] || return 1

    while IFS= read -r line || [ -n "${line}" ]; do
        line=${line%$'\r'}
        line=${line%%#*}
        line=${line#"${line%%[![:space:]]*}"}
        line=${line%"${line##*[![:space:]]}"}
        [ -n "${line}" ] || continue
        line=${line/=/ }
        read -r name _ <<< "${line}"
        [[ "${name}" =~ ^[a-z0-9][a-z0-9+.-]+$ ]] || continue
        printf '%s\n' "${name}"
    done < "${file}" | sort -u
}

# Print one field from xorriso -pvd_info output, for example "Volume Id".
flr_pvd_field() {
    local file=$1
    local field=$2

    case "${field}" in
        '' | *[!A-Za-z\ ]*) return 1 ;;
    esac
    [ -f "${file}" ] && [ -r "${file}" ] || return 1

    awk -v key="${field}" '
        $0 ~ "^" key "[[:space:]]*:" {
            sub(/^[^:]*:[[:space:]]*/, "")
            print
            exit
        }
    ' "${file}"
}
