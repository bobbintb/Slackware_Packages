#!/bin/bash
# sbo-build — Download a SlackBuild via sbopkg, then build it at the latest
#             GitHub release version (or a specific version if supplied).
#
# Usage: sbo-build <package> [version]
#   package  : exact SlackBuild name (e.g. "bpftrace")
#   version  : upstream version to build (optional; auto-detected from GitHub)
#
# Requirements: sbopkg, curl, standard build tools

set -euo pipefail

# ── helpers ────────────────────────────────────────────────────────────────────
die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">>> $*"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <package> [version]

  package   SlackBuild package name            (e.g. bpftrace)
  version   Upstream version to build          (optional; auto-detected from GitHub)

Options:
  -h, --help    Show this help and exit
  -d, --dir     Override SlackBuilds tree root (default: /var/lib/sbopkg)

When no version is given the script reads the DOWNLOAD URL from the package's
.info file, extracts the GitHub owner/repo, and queries the GitHub releases API
for the latest published release tag.
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

[[ $# -ge 1 ]] || usage

PACKAGE="$1"
VERSION="${2:-}"   # may be empty — will be resolved from GitHub below

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

# ── step 3b: auto-detect latest GitHub version if none was supplied ────────────
# Extract the GitHub owner/repo slug from the first download URL.
# Handles both:
#   https://github.com/OWNER/REPO/archive/...
#   https://github.com/OWNER/REPO/releases/download/...
github_latest_version() {
    local url="$1"
    local slug api_url tag

    slug="$(echo "${url}" | grep -oP '(?<=github\.com/)[^/]+/[^/]+')"
    [[ -n "${slug}" ]] || die "Cannot extract GitHub owner/repo from URL: ${url}"

    api_url="https://api.github.com/repos/${slug}/releases/latest"
    info "Querying GitHub API: ${api_url}"

    tag="$(curl -fsSL "${api_url}" \
        -H "Accept: application/vnd.github+json" \
        | grep -oP '"tag_name"\s*:\s*"\K[^"]+')"
    [[ -n "${tag}" ]] || die "GitHub API returned no tag for '${slug}'. The repo may have no releases — supply a version manually."

    # Strip a leading 'v' to get a plain version number (e.g. v0.25.0 → 0.25.0)
    LATEST_VERSION="${tag#v}"
}

if [[ -z "${VERSION}" ]]; then
    # Use the first URL in the download list to find the GitHub repo
    FIRST_URL="${RAW_DOWNLOAD%% *}"
    if echo "${FIRST_URL}" | grep -q 'github\.com'; then
        github_latest_version "${FIRST_URL}"
        VERSION="${LATEST_VERSION}"
        info "Auto-detected latest version: ${VERSION}"
    else
        die "No version supplied and the download URL is not on GitHub. Please pass the desired version as the second argument."
    fi
fi

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
