#!/bin/bash
# sbo-build — Download a SlackBuild via sbopkg, then build it at a custom version.
#
# Usage: sbo-build <package> <version>
#   package  : exact SlackBuild name (e.g. "python3-requests")
#   version  : upstream version to fetch and build (e.g. "2.31.0")
#
# Requirements: sbopkg, curl/wget, standard build tools (makepkg, etc.)

set -euo pipefail

# ── helpers ────────────────────────────────────────────────────────────────────
die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">>> $*"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") <package> <version>

  package   SlackBuild package name   (e.g. python3-requests)
  version   Upstream version to build (e.g. 2.31.0)

Options:
  -h, --help    Show this help and exit
  -d, --dir     Override SlackBuilds tree root (default: /var/lib/sbopkg)
EOF
    exit 0
}

# ── defaults ───────────────────────────────────────────────────────────────────
SBO_ROOT="/var/lib/sbopkg"          # where sbopkg stores the SlackBuilds tree

# ── argument parsing ───────────────────────────────────────────────────────────
while [[ ${1:-} == -* ]]; do
    case "$1" in
        -h|--help) usage ;;
        -d|--dir)  SBO_ROOT="${2:?--dir requires a path}"; shift ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

[[ $# -eq 2 ]] || usage

PACKAGE="$1"
VERSION="$2"

# ── sanity checks ──────────────────────────────────────────────────────────────
command -v sbopkg &>/dev/null || die "sbopkg not found in PATH"

# ── step 1: download / sync the SlackBuild via sbopkg ─────────────────────────
info "Downloading SlackBuild for '${PACKAGE}' via sbopkg …"
sbopkg -d "${PACKAGE}" || die "sbopkg -d failed for '${PACKAGE}'"

# ── step 2: locate the .SlackBuild directory ───────────────────────────────────
SBO_DIR="$(find "${SBO_ROOT}" -type d -name "${PACKAGE}" | head -n1)"
[[ -n "${SBO_DIR}" ]] || die "Cannot find SlackBuild directory for '${PACKAGE}' under ${SBO_ROOT}"
info "Found SlackBuild at: ${SBO_DIR}"

SLACKBUILD_SCRIPT="${SBO_DIR}/${PACKAGE}.SlackBuild"
[[ -f "${SLACKBUILD_SCRIPT}" ]] || die "No .SlackBuild script found at '${SLACKBUILD_SCRIPT}'"

# ── step 3: read the download URL from the .info file and patch the version ────
INFO_FILE="${SBO_DIR}/${PACKAGE}.info"
[[ -f "${INFO_FILE}" ]] || die "No .info file found at '${INFO_FILE}'"

# Read fields without sourcing (which would clobber this script's $VERSION)
OLD_VERSION="$(grep -E '^VERSION=' "${INFO_FILE}" | cut -d= -f2 | tr -d '"' | tr -d "'")"
[[ -n "${OLD_VERSION}" ]] || die "Could not parse VERSION from '${INFO_FILE}'"

# Determine the right DOWNLOAD field for this architecture
ARCH="$(uname -m)"
RAW_DOWNLOAD=""
if [[ "${ARCH}" == "x86_64" ]]; then
    RAW_DOWNLOAD="$(grep -E '^DOWNLOAD_x86_64=' "${INFO_FILE}" | cut -d= -f2- | tr -d '"' | tr -d "'")"
fi
# Fall back to the generic DOWNLOAD field if arch-specific is empty or UNSUPPORTED
if [[ -z "${RAW_DOWNLOAD}" || "${RAW_DOWNLOAD}" == "UNSUPPORTED" ]]; then
    RAW_DOWNLOAD="$(grep -E '^DOWNLOAD=' "${INFO_FILE}" | cut -d= -f2- | tr -d '"' | tr -d "'")"
fi
[[ -n "${RAW_DOWNLOAD}" && "${RAW_DOWNLOAD}" != "UNSUPPORTED" ]] \
    || die "No supported DOWNLOAD URL found in '${INFO_FILE}' for arch '${ARCH}'"

# Substitute the old version with the requested version in every URL
NEW_DOWNLOADS=""
for url in ${RAW_DOWNLOAD}; do
    NEW_DOWNLOADS+=" ${url//${OLD_VERSION}/${VERSION}}"
done
NEW_DOWNLOADS="${NEW_DOWNLOADS# }"   # trim leading space

info "Old version : ${OLD_VERSION}"
info "New version : ${VERSION}"
info "Arch        : ${ARCH}"
info "Download URL(s): ${NEW_DOWNLOADS}"

# ── step 4: download the source archive(s) ────────────────────────────────────
SRCDIR="$(mktemp -d /tmp/sbo-build.XXXXXX)"
trap 'rm -rf "${SRCDIR}"' EXIT

for url in ${NEW_DOWNLOADS}; do
    info "Fetching: ${url}"
    if command -v curl &>/dev/null; then
        curl -fL --progress-bar -o "${SRCDIR}/$(basename "${url}")" "${url}" \
            || die "Download failed: ${url}"
    elif command -v wget &>/dev/null; then
        wget -q --show-progress -P "${SRCDIR}" "${url}" \
            || die "Download failed: ${url}"
    else
        die "Neither curl nor wget found — cannot download source"
    fi
done

# ── step 5: stage everything and build ────────────────────────────────────────
# Copy the SlackBuild directory into a writable temp area so we don't touch
# the sbopkg-managed tree.
BUILD_DIR="$(mktemp -d /tmp/sbo-build-stage.XXXXXX)"
trap 'rm -rf "${SRCDIR}" "${BUILD_DIR}"' EXIT

cp -r "${SBO_DIR}/." "${BUILD_DIR}/"
cp "${SRCDIR}"/* "${BUILD_DIR}/"

chmod +x "${BUILD_DIR}/${PACKAGE}.SlackBuild"

info "Building '${PACKAGE}' version ${VERSION} …"
(
    cd "${BUILD_DIR}"
    # Pass the new VERSION into the SlackBuild script via the environment.
    # Most SlackBuilds honour an externally-set VERSION variable.
    VERSION="${VERSION}" bash "${PACKAGE}.SlackBuild"
)

info "Build complete. Check /tmp or \$OUTPUT for the resulting .txz / .tgz package."
