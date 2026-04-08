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

# ── defaults ───────────────────────────────────────────────────────────────────
SBO_ROOT="/var/lib/sbopkg"
export CMAKE_POLICY_VERSION_MINIMUM=3.5
LOCAL_MODE=false
PACKAGE=""
VERSION=""
GIT_URL="${GIT_URL:-}"
SBO_DIR=""
SRCDIR=""
BUILD_DIR=""

# ── functions ──────────────────────────────────────────────────────────────────

parse_args() {
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
}
step_1_locate_workspace() {

    # ── step 1: locate workspace OR download via sbopkg ───────────────────────────
    local WORKSPACE_SRC=""
    if [ -d "/__w/Slackware_Packages/Slackware_Packages/SlackBuilds/${PACKAGE}" ]; then
        WORKSPACE_SRC="/__w/Slackware_Packages/Slackware_Packages/SlackBuilds/${PACKAGE}"
    elif [ -d "/root/Slackware_Packages/SlackBuilds/${PACKAGE}" ]; then
        WORKSPACE_SRC="/root/Slackware_Packages/SlackBuilds/${PACKAGE}"
    fi

    DEST_DIR="${SBO_ROOT}/SBo/15.0/development/${PACKAGE}"

    if [[ -n "${WORKSPACE_SRC}" ]]; then
        info "========================================Local workspace detected at ${WORKSPACE_SRC}. Syncing to ${DEST_DIR}...========================================"
        mkdir -p "$(dirname "${DEST_DIR}")"
        cp -af "${WORKSPACE_SRC}/." "${DEST_DIR}/"
        
        SBO_DIR="${DEST_DIR}"
        LOCAL_MODE=true

        # Your intentional tar/gpg logic
        tar -czf ${PACKAGE}.tar.gz -C "$(dirname "${DEST_DIR}")" "${PACKAGE}"
        gpg --armor --detach-sign ${PACKAGE}.tar.gz
        mv ${PACKAGE}.tar.gz "${SBO_ROOT}/SBo/15.0/development/"
        mv ${PACKAGE}.tar.gz.asc "${SBO_ROOT}/SBo/15.0/development/"
    else
        info "========================================Workspace source not found. Falling back to sbopkg...========================================"
        command -v sbopkg &>/dev/null || die "sbopkg not found and no local workspace exists."
        sbopkg -d "${PACKAGE}" || die "sbopkg -d failed for '${PACKAGE}'"
        SBO_DIR="$(find "${SBO_ROOT}" -type d -name "${PACKAGE}" | head -n1)"
    fi
}

step_2_verify_directory() {
    # ── step 2: final directory verification ──────────────────────────────────────
    [[ -n "${SBO_DIR}" ]] || die "Cannot find SlackBuild directory for '${PACKAGE}'"
    SLACKBUILD_SCRIPT="${SBO_DIR}/${PACKAGE}.SlackBuild"
    [[ -f "${SLACKBUILD_SCRIPT}" ]] || die "No .SlackBuild script found at '${SLACKBUILD_SCRIPT}'"
}

step_3_resolve_version() {
    # ── step 3: resolve version ────────────────────────────────────────────────────
    INFO_FILE="${SBO_DIR}/${PACKAGE}.info"
    [[ -f "${INFO_FILE}" ]] || die "No .info file found"

    OLD_VERSION="$(grep -E '^VERSION=' "${INFO_FILE}" | cut -d= -f2 | tr -d '"' | tr -d "'")"

    if [[ -z "${VERSION}" ]]; then
        RAW_DOWNLOAD="$(grep -E '^DOWNLOAD(_x86_64)?=' "${INFO_FILE}" | grep -v 'UNSUPPORTED' | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
        FIRST_URL="${RAW_DOWNLOAD%% *}"
        if [[ "$FIRST_URL" == *"github.com"* ]]; then
            slug=$(echo "${FIRST_URL}" | grep -oP '(?<=github\.com/)[^/]+/[^/]+')
            tag=$(curl -fsSL "https://api.github.com/repos/${slug}/releases/latest" | grep -oP '"tag_name"\s*:\s*"\K[^"]+')
            VERSION="${tag#v}"
        elif [[ "${GIT_URL}" == *"github.com"* ]]; then
            slug=$(echo "${GIT_URL}" | grep -oP '(?<=github\.com/)[^/]+/[^/]+' | sed 's/\.git$//')
            tag=$(curl -fsSL "https://api.github.com/repos/${slug}/releases/latest" | grep -oP '"tag_name"\s*:\s*"\K[^"]+')
            VERSION="${tag#v}"
        else
            VERSION="${OLD_VERSION}"
            info ========================================"Using version from .info: ${VERSION}========================================"
        fi
    fi

    TARNAM="$(grep -oP '^TARNAM=\K\S+' "${SLACKBUILD_SCRIPT}" | tr -d '"' | tr -d "'" || true)"
    TARNAM="${TARNAM:-${PACKAGE}}"
}

step_4_fetch_source() {
    # ── step 4: fetch source ───────────────────────────────────────────────────────
    
    # Creates Temp Storage: Use a fixed directory instead of a random one
    SRCDIR="/tmp/SBo"
    mkdir -p "${SRCDIR}"
    # Note: Removed 'trap' so the folder persists for the build step
    
    # Prioritizes Local Tarballs: Only happens if LOCAL_MODE is true
    if [[ "${LOCAL_MODE}" == "true" && -f "${SBO_DIR}/${TARNAM}-${VERSION}.tar.gz" ]]; then
        cp "${SBO_DIR}/${TARNAM}-${VERSION}.tar.gz" "${SRCDIR}/"
    fi

    # Clones via Git: If no tarball was found and a Git URL is provided, clone and compress
    if [[ ! -f "${SRCDIR}/${TARNAM}-${VERSION}.tar.gz" && -n "${GIT_URL}" ]]; then
        git clone --branch "${VERSION}" --recurse-submodules "${GIT_URL}" "${SRCDIR}/source" || \
        git clone --branch "v${VERSION}" --recurse-submodules "${GIT_URL}" "${SRCDIR}/source" || \
        die "git clone failed"

        mv "${SRCDIR}/source" "${SRCDIR}/${PACKAGE}-${VERSION}"
        tar -czf "${SRCDIR}/${TARNAM}-${VERSION}.tar.gz" -C "${SRCDIR}" "${PACKAGE}-${VERSION}"
        # Cleanup cloned source folder to keep /tmp/SBo clean
        rm -rf "${SRCDIR}/${PACKAGE}-${VERSION}"
    fi

    # Dynamic URL Fallback: Only runs if still missing, NOT in local mode, and no Git URL worked
    if [[ ! -f "${SRCDIR}/${TARNAM}-${VERSION}.tar.gz" && "${LOCAL_MODE}" != "true" ]]; then
        RAW_DOWNLOAD="$(grep -E '^DOWNLOAD(_x86_64)?=' "${INFO_FILE}" | grep -v 'UNSUPPORTED' | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
        NEW_URL="${RAW_DOWNLOAD//${OLD_VERSION}/${VERSION}}"
        curl -fL -o "${SRCDIR}/$(basename "${NEW_URL%% *}")" "${NEW_URL%% *}" || die "Download failed"
    fi

    # Ensures Integrity: Final check to make sure the tarball exists in /tmp/SBo
    local FINAL_TARBALL="${SRCDIR}/${TARNAM}-${VERSION}.tar.gz"
    if [[ -f "${FINAL_TARBALL}" ]]; then
        info "Source prepared: $(basename "${FINAL_TARBALL}") located at ${FINAL_TARBALL}"
    else
        die "Source retrieval failed: No tarball found or generated in ${SRCDIR}"
    fi
}

step_5_stage_and_build() {
    # ── step 5: stage everything and build ────────────────────────────────────────
    BUILD_DIR="$(mktemp -d /tmp/sbo-build-stage.XXXXXX)"
    info "======================================== BUILD_DIR =  '${BUILD_DIR}' ========================================"
    info "======================================== SBO_DIR = '${SBO_DIR}' ========================================"
    info "======================================== SRCDIR =  '${SRCDIR}' ========================================"

    # trap 'rm -rf "${SRCDIR}" "${BUILD_DIR}"' EXIT

    cp -af "${SBO_DIR}/." "${BUILD_DIR}/"
    cp -af "${SRCDIR}"/* "${BUILD_DIR}/"

    chmod +x "${BUILD_DIR}/${PACKAGE}.SlackBuild"

    info "========================================Building '${PACKAGE}' version ${VERSION}...========================================"
    (
        cd "${BUILD_DIR}"
        VERSION="${VERSION}" bash "${PACKAGE}.SlackBuild"
    )
}

# ── main execution ─────────────────────────────────────────────────────────────

parse_args "$@"

info ========================================BEGIN========================================

step_1_locate_workspace
step_2_verify_directory
step_3_resolve_version
step_4_fetch_source
step_5_stage_and_build

info ========================================END========================================
