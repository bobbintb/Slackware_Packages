#!/bin/bash
# sbo-build — Build a SlackBuild from a local workspace or sbopkg.
set -euo pipefail
trap 'echo "TRAP: exit $? at line $LINENO" >&2' ERR

# ── helpers ────────────────────────────────────────────────────────────────────
die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">>> $*"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <package> [version]
EOF
    exit 0
}

# ── setup & global variables ──────────────────────────────────────────────────
SBO_ROOT="/var/lib/sbopkg"
export CMAKE_POLICY_VERSION_MINIMUM=3.5
LOCAL_MODE=false
SBO_DIR=""
SRCDIR=""
BUILD_DIR=""

# ── functions ──────────────────────────────────────────────────────────────────

parse_arguments() {
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
}

locate_source_directory() {
    # Check for local workspace paths
    local wp1="/__w/Slackware_Packages/Slackware_Packages/SlackBuilds/${PACKAGE}"
    local wp2="/root/Slackware_Packages/SlackBuilds/${PACKAGE}"
    local workspace_src=""

    if [ -d "$wp1" ]; then workspace_src="$wp1";
    elif [ -d "$wp2" ]; then workspace_src="$wp2"; fi

    local dest_dir="${SBO_ROOT}/SBo/15.0/development/${PACKAGE}"

    if [[ -n "${workspace_src}" ]]; then
        info "Local workspace detected at ${workspace_src}. Syncing to ${dest_dir}..."
        mkdir -p "$(dirname "${dest_dir}")"
        cp -af "${workspace_src}/." "${dest_dir}/"
        
        SBO_DIR="${dest_dir}"
        LOCAL_MODE=true

        # Perform signing logic
        tar -czf "${PACKAGE}.tar.gz" -C "$(dirname "${dest_dir}")" "${PACKAGE}"
        gpg --armor --detach-sign "${PACKAGE}.tar.gz"
        mv "${PACKAGE}.tar.gz" "${SBO_ROOT}/SBo/15.0/development/"
        mv "${PACKAGE}.tar.gz.asc" "${SBO_ROOT}/SBo/15.0/development/"
    else
        info "Workspace source not found. Falling back to sbopkg..."
        command -v sbopkg &>/dev/null || die "sbopkg not found and no local workspace exists."
        info "This is where sbopkg is ran"
        SBO_DIR="$(find "${SBO_ROOT}" -type d -name "${PACKAGE}" | head -n1)"
    fi

    [[ -n "${SBO_DIR}" ]] || die "Cannot find SlackBuild directory for '${PACKAGE}'"
}

resolve_version() {
    local info_file="${SBO_DIR}/${PACKAGE}.info"
    [[ -f "${info_file}" ]] || die "No .info file found at ${info_file}"

    local old_version
    old_version=$(grep -E '^VERSION=' "${info_file}" | cut -d= -f2 | tr -d '"' | tr -d "'")

    if [[ -z "${VERSION}" ]]; then
        local raw_download
        raw_download=$(grep -E '^DOWNLOAD(_x86_64)?=' "${info_file}" | grep -v 'UNSUPPORTED' | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'")
        local first_url="${raw_download%% *}"

        if [[ "$first_url" == *"github.com"* ]]; then
            local slug
            slug=$(echo "${first_url}" | grep -oP '(?<=github\.com/)[^/]+/[^/]+')
            local tag
            tag=$(curl -fsSL "https://api.github.com/repos/${slug}/releases/latest" | grep -oP '"tag_name"\s*:\s*"\K[^"]+')
            VERSION="${tag#v}"
        elif [[ "${GIT_URL}" == *"github.com"* ]]; then
            local slug
            slug=$(echo "${GIT_URL}" | grep -oP '(?<=github\.com/)[^/]+/[^/]+' | sed 's/\.git$//')
            local tag
            tag=$(curl -fsSL "https://api.github.com/repos/${slug}/releases/latest" | grep -oP '"tag_name"\s*:\s*"\K[^"]+')
            VERSION="${tag#v}"
        else
            VERSION="${old_version}"
            info "Using version from .info: ${VERSION}"
        fi
    fi

    # Determine TARNAM for source fetching
    local slackbuild_script="${SBO_DIR}/${PACKAGE}.SlackBuild"
    TARNAM=$(grep -oP '^TARNAM=\K\S+' "${slackbuild_script}" | tr -d '"' | tr -d "'" || true)
    TARNAM="${TARNAM:-${PACKAGE}}"
    OLD_VERSION_VAL="$old_version" # Store for URL replacement later
}

fetch_source() {
    SRCDIR="$(mktemp -d /tmp/sbo-src.XXXXXX)"
    # Update trap to include SRCDIR
    trap 'rm -rf "${SRCDIR}"' EXIT

    if [[ "${LOCAL_MODE}" == "true" ]]; then
        info "Local mode: Ensuring source tarball is present..."
        if [[ -f "${SBO_DIR}/${TARNAM}-${VERSION}.tar.gz" ]]; then
            cp "${SBO_DIR}/${TARNAM}-${VERSION}.tar.gz" "${SRCDIR}/"
        elif [[ -n "${GIT_URL}" ]]; then
            info "Source not found in workspace. Cloning from Git..."
            git clone --branch "${VERSION}" --recurse-submodules "${GIT_URL}" "${SRCDIR}/source" || \
            git clone --branch "v${VERSION}" --recurse-submodules "${GIT_URL}" "${SRCDIR}/source" || \
            die "git clone failed"
            mv "${SRCDIR}/source" "${SRCDIR}/${PACKAGE}-${VERSION}"
            tar -czf "${SRCDIR}/${TARNAM}-${VERSION}.tar.gz" -C "${SRCDIR}" "${PACKAGE}-${VERSION}"
        else
            die "Source tarball ${TARNAM}-${VERSION}.tar.gz not found and no GIT_URL provided."
        fi
    else
        if [[ -n "${GIT_URL}" ]]; then
            git clone --branch "${VERSION}" --recurse-submodules "${GIT_URL}" "${SRCDIR}/source" || \
            git clone --branch "v${VERSION}" --recurse-submodules "${GIT_URL}" "${SRCDIR}/source" || \
            die "git clone failed"
            mv "${SRCDIR}/source" "${SRCDIR}/${PACKAGE}-${VERSION}"
            tar -czf "${SRCDIR}/${TARNAM}-${VERSION}.tar.gz" -C "${SRCDIR}" "${PACKAGE}-${VERSION}"
        else
            local info_file="${SBO_DIR}/${PACKAGE}.info"
            local raw_download
            raw_download=$(grep -E '^DOWNLOAD(_x86_64)?=' "${info_file}" | grep -v 'UNSUPPORTED' | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'")
            local new_url="${raw_download//${OLD_VERSION_VAL}/${VERSION}}"
            curl -fL -o "${SRCDIR}/$(basename "${new_url%% *}")" "${new_url%% *}" || die "Download failed"
        fi
    fi
}

run_build() {
    BUILD_DIR="$(mktemp -d /tmp/sbo-build-stage.XXXXXX)"
    # Update trap to clean up everything
    trap 'rm -rf "${SRCDIR}" "${BUILD_DIR}"' EXIT

    cp -af "${SBO_DIR}/." "${BUILD_DIR}/"
    cp -af "${SRCDIR}"/* "${BUILD_DIR}/"

    local sb_script="${BUILD_DIR}/${PACKAGE}.SlackBuild"
    [[ -f "${sb_script}" ]] || die "No .SlackBuild script found at '${sb_script}'"
    chmod +x "${sb_script}"

    info "Building '${PACKAGE}' version ${VERSION}..."
    (
        cd "${BUILD_DIR}"
        VERSION="${VERSION}" bash "${PACKAGE}.SlackBuild"
    )
}

# ── main ───────────────────────────────────────────────────────────────────────

main() {
    parse_arguments "$@"
    
    info "=========================BEGIN========================="
    
    locate_source_directory
    resolve_version
    fetch_source
    run_build

    info "=========================END========================="
}

# Launch
main "$@"
