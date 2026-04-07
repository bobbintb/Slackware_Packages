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
    elif [ -d "./SlackBuilds/${PACKAGE}" ]; then
        WORKSPACE_SRC="./SlackBuilds/${PACKAGE}"
    fi

    DEST_DIR="${SBO_ROOT}/SBo/15.0/development/${PACKAGE}"

    if [[ -n "${WORKSPACE_SRC}" ]]; then
        info "Local workspace detected at ${WORKSPACE_SRC}. Syncing to ${DEST_DIR}..."
        mkdir -p "$(dirname "${DEST_DIR}")"
        cp -af "${WORKSPACE_SRC}/." "${DEST_DIR}/"
        
        SBO_DIR="${DEST_DIR}"
        LOCAL_MODE=true

        # Your intentional tar/gpg logic
        tar -czf "${PACKAGE}.tar.gz" -C "$(dirname "${DEST_DIR}")" "${PACKAGE}"
        gpg --armor --detach-sign "${PACKAGE}.tar.gz"
        mv "${PACKAGE}.tar.gz" "${SBO_ROOT}/SBo/15.0/development/"
        mv "${PACKAGE}.tar.gz.asc" "${SBO_ROOT}/SBo/15.0/development/"
    else
        info "Workspace source not found. Falling back to sbopkg..."
        command -v sbopkg &>/dev/null || die "sbopkg not found and no local workspace exists."
        info "This is where sbopkg is ran"
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
        VERSION="${OLD_VERSION}"
        info "Using version from .info: ${VERSION}"

        RAW_DOWNLOAD="$(grep -E '^DOWNLOAD(_x86_64)?=' "${INFO_FILE}" | grep -v 'UNSUPPORTED' | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
        FIRST_URL="${RAW_DOWNLOAD%% *}"
        if [[ "$FIRST_URL" == *"github.com"* ]]; then
            slug=$(echo "${FIRST_URL}" | grep -oP '(?<=github\.com/)[^/]+/[^/]+')
            tag=$(curl -fsSL "https://api.github.com/repos/${slug}/releases/latest" | grep -oP '"tag_name"\s*:\s*"\K[^"]+')
            if [[ -n "${tag:-}" ]]; then
                VERSION="${tag#v}"
                info "Detected GitHub release, updating version to: ${VERSION}"
            fi
        elif [[ "${GIT_URL}" == *"github.com"* ]]; then
            slug=$(echo "${GIT_URL}" | grep -oP '(?<=github\.com/)[^/]+/[^/]+' | sed 's/\.git$//')
            tag=$(curl -fsSL "https://api.github.com/repos/${slug}/releases/latest" | grep -oP '"tag_name"\s*:\s*"\K[^"]+')
            if [[ -n "${tag:-}" ]]; then
                VERSION="${tag#v}"
                info "Detected GitHub URL, updating version to: ${VERSION}"
            fi
        fi
    fi

    TARNAM="$(grep -oP '^TARNAM=\K\S+' "${SLACKBUILD_SCRIPT}" | tr -d '"' | tr -d "'" || true)"
    TARNAM="${TARNAM:-${PACKAGE}}"
}

step_4_fetch_source() {
    # ── step 4: fetch source ───────────────────────────────────────────────────────
    # We now stage everything in a temporary directory that acts as the "CWD" 
    # for the SlackBuild script.
    BUILD_DIR="$(mktemp -d /tmp/sbo-stage.XXXXXX)"
    trap 'rm -rf "${BUILD_DIR}"' EXIT

    # Copy the SlackBuild, info, slack-desc, etc. to the stage
    cp -af "${SBO_DIR}/." "${BUILD_DIR}/"

    if [[ "${LOCAL_MODE}" == "true" ]]; then
        info "Local mode: Ensuring source tarball is present..."
        # Check if tarball already exists in the workspace
        if [[ -f "${SBO_DIR}/${TARNAM}-${VERSION}.tar.gz" ]]; then
            cp "${SBO_DIR}/${TARNAM}-${VERSION}.tar.gz" "${BUILD_DIR}/"
        elif [[ -f "${SBO_DIR}/${TARNAM}.tar.gz" ]]; then
            cp "${SBO_DIR}/${TARNAM}.tar.gz" "${BUILD_DIR}/"
        elif [[ -n "${GIT_URL}" ]]; then
            info "Source not found. Cloning and creating tarball..."
            git clone --branch "${VERSION}" --recurse-submodules "${GIT_URL}" "${BUILD_DIR}/${PACKAGE}" || \
            git clone --branch "v${VERSION}" --recurse-submodules "${GIT_URL}" "${BUILD_DIR}/${PACKAGE}" || \
            die "git clone failed"
            
            # Create the tarball in the BUILD_DIR so the SlackBuild sees it
            tar -czf "${BUILD_DIR}/${TARNAM}.tar.gz" -C "${BUILD_DIR}" "${PACKAGE}"
            rm -rf "${BUILD_DIR}/${PACKAGE}"
        else
            die "Source tarball ${TARNAM} not found and no GIT_URL provided."
        fi
    else
        if [[ -n "${GIT_URL}" ]]; then
            git clone --branch "${VERSION}" --recurse-submodules "${GIT_URL}" "${BUILD_DIR}/${PACKAGE}" || \
            git clone --branch "v${VERSION}" --recurse-submodules "${GIT_URL}" "${BUILD_DIR}/${PACKAGE}" || \
            die "git clone failed"
            tar -czf "${BUILD_DIR}/${TARNAM}.tar.gz" -C "${BUILD_DIR}" "${PACKAGE}"
            rm -rf "${BUILD_DIR}/${PACKAGE}"
        else
            RAW_DOWNLOAD="$(grep -E '^DOWNLOAD(_x86_64)?=' "${INFO_FILE}" | grep -v 'UNSUPPORTED' | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
            NEW_URL="${RAW_DOWNLOAD//${OLD_VERSION}/${VERSION}}"
            curl -fL -o "${BUILD_DIR}/$(basename "${NEW_URL%% *}")" "${NEW_URL%% *}" || die "Download failed"
        fi
    fi
}

step_5_stage_and_build() {
    # ── step 5: stage everything and build ────────────────────────────────────────
    # Source is already staged in BUILD_DIR by step 4.
    
    chmod +x "${BUILD_DIR}/${PACKAGE}.SlackBuild"

    info "Building '${PACKAGE}' version ${VERSION}..."
    (
        cd "${BUILD_DIR}"
        # SlackBuilds use CWD=$(pwd) to find the tarball; we are now in that directory.
        VERSION="${VERSION}" bash "${PACKAGE}.SlackBuild"
    )
}

# ── main execution ─────────────────────────────────────────────────────────────

parse_args "$@"

info "=========================BEGIN========================="

step_1_locate_workspace
step_2_verify_directory
step_3_resolve_version
step_4_fetch_source
step_5_stage_and_build

info "=========================END========================="
