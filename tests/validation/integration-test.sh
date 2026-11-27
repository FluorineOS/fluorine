#!/usr/bin/env bash
set -uo pipefail

# Static application-integration checks.
#
# Reads the desktop package in the sibling checkout and compares it with the
# decisions in docs/DESKTOP.md. Nothing here needs a session, a compositor, or
# the installed packages: the point is to catch a default handler that points at
# an application the image does not ship, a MIME map that lost its coverage, or
# a desktop entry that a validator would reject.
#
# Run: bash tests/validation/integration-test.sh

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
DOC="${REPO}/docs/DESKTOP.md"
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

DESKTOP=""
for candidate in "${REPO}/../fluorine-desktop" \
    "${REPO}/../../../fluorine-workspace/fluorine-desktop"; do
    if [ -r "${candidate}/mimeapps.list" ]; then
        DESKTOP="${candidate}"
        break
    fi
done

if [ -z "${DESKTOP}" ]; then
    printf 'SKIP  desktop checkout not present\n'
    exit 0
fi

MIME_SYSTEM="${DESKTOP}/mimeapps.list"
MIME_SKEL="${DESKTOP}/skel/.config/mimeapps.list"
CONTROL="${DESKTOP}/debian/control"

# The two copies are installed for different scopes and must not drift.
if diff -q "${MIME_SYSTEM}" "${MIME_SKEL}" >/dev/null 2>&1; then
    ok "system and skel mimeapps.list are identical"
else
    bad "system and skel mimeapps.list differ"
fi

# Every value must name one application, and no key may appear twice: a
# duplicated key silently loses the first association.
duplicates=$(grep -vE '^[[:space:]]*(#|\[|$)' "${MIME_SYSTEM}" 2>/dev/null |
    cut -d= -f1 | sort | uniq -d)
if [ -z "${duplicates}" ]; then
    ok "no MIME type is mapped twice"
else
    bad "types mapped twice: $(printf '%s' "${duplicates}" | tr '\n' ' ')"
fi

malformed=$(grep -vE '^[[:space:]]*(#|\[|$)' "${MIME_SYSTEM}" 2>/dev/null |
    grep -vE '^[A-Za-z0-9.+_/-]+=[A-Za-z0-9._+-]+\.desktop;$')
if [ -z "${malformed}" ]; then
    ok "every association is one desktop ID with a trailing semicolon"
else
    bad "malformed association: ${malformed%%$'\n'*}"
fi

# Only applications this image ships may be a default handler.
known_handler() {
    case "$1" in
        thunar.desktop | org.pwmt.zathura.desktop | swayimg.desktop | org.gnome.FileRoller.desktop | org.xfce.mousepad.desktop | mpv.desktop)
            return 0
            ;;
        *) return 1 ;;
    esac
}

unknown=""
while IFS= read -r id; do
    [ -n "${id}" ] || continue
    known_handler "${id}" || unknown="${unknown} ${id}"
done < <(grep -vE '^[[:space:]]*(#|\[|$)' "${MIME_SYSTEM}" 2>/dev/null |
    cut -d= -f2 | tr -d ';' | sort -u)

if [ -z "${unknown}" ]; then
    ok "every handler is an application the image installs"
else
    bad "unknown handler in mimeapps.list:${unknown}"
fi

# Coverage that was missing before this pass: each of these types is declared by
# the application it maps to.
for type in inode/directory application/pdf text/plain application/x-zerosize \
    image/png image/jpeg image/webp image/gif image/svg+xml \
    image/avif image/bmp image/tiff image/heif \
    application/zip application/x-tar application/x-compressed-tar \
    application/x-7z-compressed application/gzip application/x-xz \
    application/zstd application/vnd.rar \
    video/mp4 video/x-matroska video/webm video/quicktime video/ogg \
    audio/mpeg audio/flac audio/x-wav audio/mp4 audio/m4a audio/aac; do
    if grep -qF "${type}=" "${MIME_SYSTEM}" 2>/dev/null; then
        ok "default handler declared for ${type}"
    else
        bad "no default handler for ${type}"
    fi
done

# A URL scheme must not be pointed at the store: clicking a link has to stay a
# no-op until a browser is installed, not open a storefront.
if grep -qE '^x-scheme-handler/' "${MIME_SYSTEM}" 2>/dev/null; then
    bad "a URL scheme is mapped although no browser is installed"
else
    ok "no URL scheme is mapped to a non-browser"
fi

# Desktop entries: valid structure, one main category each.
CATEGORIES="${DESKTOP}/applications"
for entry in "${CATEGORIES}"/*.desktop; do
    name=$(basename "${entry}")
    for key in '^Type=Application$' '^Exec=' '^Icon=' '^Categories='; do
        if grep -qE "${key}" "${entry}" 2>/dev/null; then
            ok "${name} declares ${key#^}"
        else
            bad "${name} is missing ${key#^}"
        fi
    done

    mains=$(grep -m1 '^Categories=' "${entry}" 2>/dev/null | cut -d= -f2 |
        tr ';' '\n' | grep -cE '^(AudioVideo|Audio|Video|Development|Education|Game|Graphics|Network|Office|Science|Settings|System|Utility)$')
    if [ "${mains}" -eq 1 ]; then
        ok "${name} has exactly one main category"
    else
        bad "${name} has ${mains} main categories"
    fi
done

# An icon name that the theme does not ship falls back to a generic square.
ARTWORK=""
for candidate in "${REPO}/../fluorine-artwork" \
    "${REPO}/../../../fluorine-workspace/fluorine-artwork"; do
    if [ -d "${candidate}/icons/Fluorine" ]; then
        ARTWORK="${candidate}/icons/Fluorine"
        break
    fi
done

if [ -n "${ARTWORK}" ]; then
    while IFS= read -r icon; do
        [ -n "${icon}" ] || continue
        if find "${ARTWORK}" -name "${icon}.svg" | grep -q .; then
            ok "icon ${icon} exists in the Fluorine theme"
        else
            bad "icon ${icon} is not in the Fluorine theme"
        fi
    done < <(grep -h '^Icon=' "${CATEGORIES}"/*.desktop 2>/dev/null | cut -d= -f2 | sort -u)
else
    printf 'SKIP  icon checks (artwork checkout not present)\n'
fi

# The desktop package must declare what the session relies on.
for package in thunar zathura swayimg file-roller mousepad mpv \
    xdg-desktop-portal-hyprland xdg-desktop-portal-gtk; do
    if grep -qE "(^|[ ,])${package}([,]|$)" "${CONTROL}" 2>/dev/null; then
        ok "debian/control declares ${package}"
    else
        bad "debian/control does not declare ${package}"
    fi
done

# Documentation must exist and name the decisions.
if [ -r "${DOC}" ]; then
    ok "docs/DESKTOP.md exists"
else
    bad "docs/DESKTOP.md is missing"
fi
for needle in "Wayland" "Verification" "browser" "Secret Service" "MIME"; do
    if grep -q -- "${needle}" "${DOC}" 2>/dev/null; then
        ok "docs/DESKTOP.md covers: ${needle}"
    else
        bad "docs/DESKTOP.md does not mention: ${needle}"
    fi
done

printf '\nSummary: %d passed, %d failed\n' "${PASS}" "${FAIL}"

if [ "${FAIL}" -ne 0 ]; then
    exit 1
fi
