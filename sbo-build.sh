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

# ── step 3: Resolve Version & Source ──────────────────────────────────────────
INFO_FILE="${SBO_DIR}/${PACKAGE}.info"
[[ -f "${INFO_FILE}" ]] || die "No .info file found"

OLD_VERSION="$(grep -E '^VERSION=' "${INFO_FILE}" | cut -d= -f2 | tr -d '"' | tr -d "'")"

# Logic for Git vs Standard Download
SRCDIR="$(mktemp -d /tmp/sbo-src.XXXXXX)"
trap 'rm -rf "${SRCDIR}"' EXIT

if [[ -n "${GIT_URL}" ]]; then
    # --- GIT CLONE PATH ---
    info "Git URL detected: ${GIT_URL}. Cloning source..."
    
    if [[ -n "${VERSION}" ]]; then
        git clone --depth 1 --branch "${VERSION}" "${GIT_URL}" "${SRCDIR}/source" || \
        git clone --depth 1 "${GIT_URL}" "${SRCDIR}/source"
    else
        git clone --depth 1 "${GIT_URL}" "${SRCDIR}/source"
        # If no version was provided, use the short commit hash
        VERSION=$(git -C "${SRCDIR}/source" rev-parse --short HEAD)
    fi

    # Create a tarball because .SlackBuild scripts expect a file to extract
    info "Packaging git source into tarball for the SlackBuild..."
    tar -czf "${SRCDIR}/${PACKAGE}-${VERSION}.tar.gz" -C "${SRCDIR}/source" .
    rm -rf "${SRCDIR}/source"

else
    # --- STANDARD DOWNLOAD PATH ---
    # Extract GitHub info if VERSION is missing
    if [[ -z "${VERSION}" ]]; then
        RAW_DOWNLOAD="$(grep -E '^DOWNLOAD=' "${INFO_FILE}" | cut -d= -f2- | tr -d '"' | tr -d "'")"
        FIRST_URL="${RAW_DOWNLOAD%% *}"
        if [[ "$FIRST_URL" == *"github.com"* ]]; then
            slug=$(echo "${FIRST_URL}" | grep -oP '(?<=github\.com/)[^/]+/[^/]+')
            tag=$(curl -fsSL "https://api.github.com/repos/${slug}/releases/latest" | grep -oP '"tag_name"\s*:\s*"\K[^"]+')
            VERSION="${tag#v}"
        else
            die "No version supplied and no GitHub URL found in .info"
        fi
    fi

    # Download logic (Summary: replaces OLD_VERSION with NEW in URLs and curls them)
    # [Simplified for brevity but retains original logic]
    RAW_DOWNLOAD="$(grep -E '^DOWNLOAD=' "${INFO_FILE}" | cut -d= -f2- | tr -d '"' | tr -d "'")"
    NEW_URL="${RAW_DOWNLOAD//${OLD_VERSION}/${VERSION}}"
    
    info "Fetching source from: ${NEW_URL}"
    curl -fL -o "${SRCDIR}/$(basename ${NEW_URL%% *})" "${NEW_URL%% *}" || die "Download failed"
fi

# ── step 4: stage everything and build ────────────────────────────────────────
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
