#!/usr/bin/env bash
set -euo pipefail

# Build, verify, and publish a FluorineOS Debian package.
#
# Usage: scripts/publish-deb.sh <package>
#
#   scripts/publish-deb.sh --help
#
#   <package>   One of fluorine-desktop, fluorine-artwork, or fluorine-keyring.
#
# The script must run inside WSL or on a native Linux host: it uses rsync,
# dpkg-buildpackage, lintian, and reprepro, and it builds on ext4 under
# /home/gowth/build-tmp. Building on /mnt/c is not supported because the
# Windows filesystem layer breaks file modes and slows dpkg.
#
# Order of operations:
#   1. Copy the package source tree to an ext4 build directory.
#   2. Normalize debian/ file modes, then build a binary-only package.
#   3. Run lintian and stop if it reports errors.
#   4. Replace older builds of the same package in config/packages.chroot.
#   5. Import the package into the apt-repo working copy and sync the index back.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(dirname -- "$SCRIPT_DIR")

WORKSPACE_DIR=${WORKSPACE_DIR:-/mnt/c/Users/gowth/fluorine-workspace}
BUILD_ROOT=${BUILD_ROOT:-/home/gowth/build-tmp}
APT_REPO=${APT_REPO:-$WORKSPACE_DIR/apt-repo}
PACKAGES_DIR=${PACKAGES_DIR:-$REPO_ROOT/config/packages.chroot}
SUITE=${SUITE:-trixie}

ALLOWED_PACKAGES=(
    fluorine-desktop
    fluorine-artwork
    fluorine-keyring
)

usage() {
    cat <<'EOF'
Usage: scripts/publish-deb.sh <package>

Build, verify, and publish a FluorineOS Debian package.

Packages:
  fluorine-desktop   Desktop session, Hyprland configuration, and flr-* helpers
  fluorine-artwork   Wallpapers, Plymouth theme, toolkits, and Calamares branding
  fluorine-keyring   APT archive signing key

Steps:
  1. Copy the source tree to $BUILD_ROOT/<package> on ext4
  2. Normalize debian/ file modes
  3. dpkg-buildpackage -us -uc -b
  4. lintian on the resulting .deb
  5. Replace older versions in config/packages.chroot
  6. reprepro includedeb into the apt-repo working copy, then sync back

Environment:
  WORKSPACE_DIR   Companion repository container (default /mnt/c/Users/gowth/fluorine-workspace)
  BUILD_ROOT      ext4 build directory (default /home/gowth/build-tmp)
  APT_REPO        APT archive checkout (default $WORKSPACE_DIR/apt-repo)
  PACKAGES_DIR    Offline bundle directory (default config/packages.chroot)
  SUITE           APT suite to publish into (default trixie)

Options:
  -h, --help      Show this help and exit.
EOF
}

die() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

step() {
    printf '\n==> %s\n' "$1"
}

require_tools() {
    local missing=()
    local tool

    for tool in rsync dpkg-buildpackage lintian reprepro dpkg-parsechangelog find; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing+=("$tool")
        fi
    done

    if ((${#missing[@]} > 0)); then
        die "missing tools: ${missing[*]}. Install them before publishing."
    fi
}

resolve_package() {
    local candidate=$1
    local allowed

    for allowed in "${ALLOWED_PACKAGES[@]}"; do
        if [[ "$candidate" == "$allowed" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    die "unknown package '$candidate'. Expected one of: ${ALLOWED_PACKAGES[*]}"
}

source_tree() {
    local package=$1
    local tree=$WORKSPACE_DIR/$package

    [[ -d "$tree" ]] || die "package source not found: $tree"
    [[ -f "$tree/debian/control" ]] || die "missing debian/control in $tree"
    [[ -f "$tree/debian/changelog" ]] || die "missing debian/changelog in $tree"

    printf '%s\n' "$tree"
}

copy_source() {
    local tree=$1
    local destination=$2

    printf 'syncing %s -> %s\n' "$tree" "$destination"
    rsync -a \
        --exclude='.git/' \
        --exclude='*.deb' \
        --exclude='*.changes' \
        --exclude='*.buildinfo' \
        --exclude='debian/.debhelper/' \
        --exclude='debian/files' \
        --exclude='debian/tmp/' \
        --exclude='debian/*.substvars' \
        --exclude='debian/debhelper-build-stamp' \
        "$tree"/ "$destination"/
}

normalize_modes() {
    local build_dir=$1
    local script

    # Everything defaults to a regular data file, then the few paths that must
    # be executable are restored explicitly. This mirrors what git cannot carry
    # through a Windows checkout.
    find "$build_dir" -type f -exec chmod 0644 {} +

    if [[ -f "$build_dir/debian/rules" ]]; then
        chmod 0755 "$build_dir/debian/rules"
    fi

    for script in preinst postinst prerm postrm config; do
        if [[ -f "$build_dir/debian/$script" ]]; then
            chmod 0755 "$build_dir/debian/$script"
        fi
    done

    if [[ -d "$build_dir/bin" ]]; then
        find "$build_dir/bin" -maxdepth 1 -type f -exec chmod 0755 {} +
    fi
}

build_package() {
    local build_dir=$1
    local log_file=$2

    printf 'building in %s\n' "$build_dir"
    if ! (cd "$build_dir" && dpkg-buildpackage -us -uc -b) >"$log_file" 2>&1; then
        tail -20 "$log_file" >&2
        die "dpkg-buildpackage failed; full log at $log_file"
    fi
    printf 'build log: %s\n' "$log_file"
}

lint_package() {
    local deb=$1

    printf 'running lintian on %s\n' "$(basename -- "$deb")"
    if ! lintian --tag-display-limit 0 "$deb"; then
        die "lintian reported errors for $(basename -- "$deb")"
    fi
}

replace_bundled_copies() {
    local package=$1
    local deb=$2
    local new_name
    local existing

    new_name=$(basename -- "$deb")
    mkdir -p "$PACKAGES_DIR"

    while IFS= read -r existing; do
        [[ -n "$existing" ]] || continue
        printf 'removing superseded bundle: %s\n' "$(basename -- "$existing")"
        rm -f -- "$existing"
    done < <(find "$PACKAGES_DIR" -maxdepth 1 -type f -name "${package}_*.deb" ! -name "$new_name")

    cp -f -- "$deb" "$PACKAGES_DIR"/
    printf 'bundled: %s\n' "$PACKAGES_DIR/$new_name"
}

publish_to_archive() {
    local deb=$1
    local staging=$BUILD_ROOT/apt-repo-publish
    local directory

    [[ -d "$APT_REPO/conf" ]] || die "no reprepro configuration in $APT_REPO/conf"

    # reprepro writes its database and indices in place, so the import runs on a
    # staging copy under ext4 and only the published directories are copied back.
    rm -rf -- "$staging"
    mkdir -p "$staging"
    rsync -a --exclude='.git/' "$APT_REPO"/ "$staging"/

    reprepro -b "$staging" includedeb "$SUITE" "$deb"

    for directory in dists pool db; do
        if [[ -d "$staging/$directory" ]]; then
            rsync -a --delete "$staging/$directory"/ "$APT_REPO/$directory"/
        fi
    done

    printf 'published to %s (suite %s)\n' "$APT_REPO" "$SUITE"
}

main() {
    if [[ $# -eq 0 ]]; then
        usage >&2
        exit 1
    fi

    case "$1" in
        -h | --help)
            usage
            return 0
            ;;
    esac

    if [[ $# -gt 1 ]]; then
        die "expected exactly one package argument, got $#"
    fi

    local package
    local tree
    local build_dir
    local version
    local deb
    local started

    package=$(resolve_package "$1")
    require_tools
    tree=$(source_tree "$package")

    build_dir=$BUILD_ROOT/$package
    started=$(date +%Y%m%d-%H%M%S)

    step "Preparing $package on ext4"
    mkdir -p "$BUILD_ROOT"
    rm -rf -- "$build_dir"
    mkdir -p "$build_dir"
    copy_source "$tree" "$build_dir"
    normalize_modes "$build_dir"

    version=$(cd "$build_dir" && dpkg-parsechangelog -SVersion)

    step "Building $package $version"
    build_package "$build_dir" "$BUILD_ROOT/$package-$started.log"

    deb=$BUILD_ROOT/${package}_${version}_all.deb
    [[ -f "$deb" ]] || die "expected package not found: $deb"
    printf 'artifact: %s (%s)\n' "$deb" "$(du -h -- "$deb" | cut -f1)"

    step "Verifying $package"
    lint_package "$deb"
    dpkg-deb -I "$deb" | sed -n '/^ Package:/p; /^ Version:/p; /^ Architecture:/p'

    step "Updating the offline bundle"
    replace_bundled_copies "$package" "$deb"

    step "Publishing to the APT archive"
    publish_to_archive "$deb"

    printf '\nDone: %s %s\n' "$package" "$version"
}

main "$@"
