#!/bin/bash
# sbo-build — Download a SlackBuild via sbopkg, then build it.
# Supports GitHub API auto-detection OR direct Git cloning via $GIT_URL.
#
# Usage: sbo-build <package> [version]
# Env Vars: GIT_URL (optional)

set -euo pipefail

# ── helpers ────────────────────────────────────────────────────────────────────
die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">>> $*"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <package> [version]

  package    SlackBuild package name            (e.g. bpftrace)
  version    Upstream version to build          (optional)

Options:
  -h, --help    Show this help and exit
  -d, --dir     Override SlackBuilds tree root (default: /var/lib/sbopkg)

If GIT_URL is set in the environment, the script clones that repo instead of
using the download link in the .info file.
EOF
    exit 0
}

# ── defaults ───────────────────────────────────────────────────────────────────
SBO_ROOT="/var/lib/sbopkg"
export CMAKE_POLICY_VERSION_MINIMUM=3.5

# ── argument parsing ───────────────────────────────────────────────────────────
while [[ ${1:-} == -* ]]; do
    case "$1" in
        -h|--help) usage ;;
        -d|--dir)  SBO_ROOT="${2:?--dir requires a path}"; shift ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

[[ $# -ge 1 ]] || usage

PACKAGE="$1"
VERSION="${2:-}"
GIT_URL="${GIT_URL:-}"

# ── sanity checks ──────────────────────────────────────────────────────────────
command -v sbopkg &>/dev/null || die "sbopkg not found in PATH"

# ── step 1: download / sync the SlackBuild via sbopkg ─────────────────────────
info "Downloading SlackBuild for '${PACKAGE}' via sbopkg …"
sbopkg -d "${PACKAGE}" || die "sbopkg -d failed for '${PACKAGE}'"

# ── step 2: locate the .SlackBuild directory ───────────────────────────────────
SBO_DIR="$(find "${SBO_ROOT}" -type d -name "${PACKAGE}" | head -n1)"
[[ -n "${SBO_DIR}" ]] || die "Cannot find SlackBuild directory for '${PACKAGE}'"

SLACKBUILD_SCRIPT="${SBO_DIR}/${PACKAGE}.SlackBuild"
[[ -f "${SLACKBUILD_SCRIPT}" ]] || die "No .SlackBuild script found at '${SLACKBUILD_SCRIPT}'"

# ── step 3: resolve version ────────────────────────────────────────────────────
INFO_FILE="${SBO_DIR}/${PACKAGE}.info"
[[ -f "${INFO_FILE}" ]] || die "No .info file found"

OLD_VERSION="$(grep -E '^VERSION=' "${INFO_FILE}" | cut -d= -f2 | tr -d '"' | tr -d "'")"

if [[ -z "${VERSION}" ]]; then
    # First try the DOWNLOAD= URL in the .info file
    RAW_DOWNLOAD="$(grep -E '^DOWNLOAD=' "${INFO_FILE}" | cut -d= -f2- | tr -d '"' | tr -d "'")"
    FIRST_URL="${RAW_DOWNLOAD%% *}"
    if [[ "$FIRST_URL" == *"github.com"* ]]; then
        slug=$(echo "${FIRST_URL}" | grep -oP '(?<=github\.com/)[^/]+/[^/]+')
        tag=$(curl -fsSL "https://api.github.com/repos/${slug}/releases/latest" | grep -oP '"tag_name"\s*:\s*"\K[^"]+')
        VERSION="${tag#v}"
        info "Auto-detected latest version from .info URL: ${VERSION}"
    elif [[ "${GIT_URL}" == *"github.com"* ]]; then
        # Fall back to querying the GIT_URL repo via the GitHub API
        slug=$(echo "${GIT_URL}" | grep -oP '(?<=github\.com/)[^/]+/[^/]+' | sed 's/\.git$//')
        tag=$(curl -fsSL "https://api.github.com/repos/${slug}/releases/latest" | grep -oP '"tag_name"\s*:\s*"\K[^"]+')
        VERSION="${tag#v}"
        info "Auto-detected latest version from GIT_URL: ${VERSION}"
    else
        die "No version supplied and no GitHub URL found in .info or GIT_URL"
    fi
fi

# Read TARNAM from the SlackBuild if present, otherwise fall back to PACKAGE name
TARNAM="$(grep -oP '^TARNAM=\K\S+' "${SLACKBUILD_SCRIPT}" | tr -d '"' | tr -d "'" || true)"
TARNAM="${TARNAM:-${PACKAGE}}"

# ── step 4: fetch source ───────────────────────────────────────────────────────
SRCDIR="$(mktemp -d /tmp/sbo-src.XXXXXX)"
trap 'rm -rf "${SRCDIR}"' EXIT

if [[ -n "${GIT_URL}" ]]; then
    # --- GIT PATH ---
    info "Git URL detected: ${GIT_URL}. Cloning source at version ${VERSION}..."

    git clone --depth 1 --branch "${VERSION}" "${GIT_URL}" "${SRCDIR}/source" || \
    git clone --depth 1 --branch "v${VERSION}" "${GIT_URL}" "${SRCDIR}/source" || \
    die "git clone failed for '${GIT_URL}' at version '${VERSION}' (tried both '${VERSION}' and 'v${VERSION}')"

    # Create a tarball named after TARNAM, with a top-level directory named
    # after PACKAGE — because SlackBuilds do "tar xvf $TARNAM.tar.gz" then "cd $PRGNAM"
    info "Packaging git source into tarball for the SlackBuild..."
    mv "${SRCDIR}/source" "${SRCDIR}/${PACKAGE}"
    tar -czf "${SRCDIR}/${TARNAM}.tar.gz" -C "${SRCDIR}" "${PACKAGE}"
    rm -rf "${SRCDIR}/${PACKAGE}"

else
    # --- STANDARD DOWNLOAD PATH ---
    RAW_DOWNLOAD="$(grep -E '^DOWNLOAD=' "${INFO_FILE}" | cut -d= -f2- | tr -d '"' | tr -d "'")"
    NEW_URL="${RAW_DOWNLOAD//${OLD_VERSION}/${VERSION}}"

    info "Fetching source from: ${NEW_URL}"
    curl -fL -o "${SRCDIR}/$(basename "${NEW_URL%% *}")" "${NEW_URL%% *}" || die "Download failed"
fi

# ── step 5: stage everything and build ────────────────────────────────────────
BUILD_DIR="$(mktemp -d /tmp/sbo-build-stage.XXXXXX)"
trap 'rm -rf "${SRCDIR}" "${BUILD_DIR}"' EXIT

cp -r "${SBO_DIR}/." "${BUILD_DIR}/"
cp "${SRCDIR}"/* "${BUILD_DIR}/"

chmod +x "${BUILD_DIR}/${PACKAGE}.SlackBuild"

info "Building '${PACKAGE}' version ${VERSION} …"
(
    cd "${BUILD_DIR}"
    VERSION="${VERSION}" bash "${PACKAGE}.SlackBuild"
)

info "Build complete. Check /tmp or \$OUTPUT for the package."
