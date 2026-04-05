#!/bin/bash
# sbo-debug.sh — Validation-only version of sbo-build.
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
LOCAL_MODE=false

# ── step 1: locate workspace OR download via sbopkg ───────────────────────────
if [ -d "/__w/Slackware_Packages/Slackware_Packages/SlackBuilds/${PACKAGE}" ]; then
    WORKSPACE_SRC="/__w/Slackware_Packages/Slackware_Packages/SlackBuilds/${PACKAGE}"
elif [ -d "/root/Slackware_Packages/SlackBuilds/${PACKAGE}" ]; then
    WORKSPACE_SRC="/root/Slackware_Packages/SlackBuilds/${PACKAGE}"
else
    WORKSPACE_SRC=""
fi

DEST_DIR="${SBO_ROOT}/SBo/15.0/development/${PACKAGE}"

if [[ -n "${WORKSPACE_SRC}" ]]; then
    info "Local workspace detected at ${WORKSPACE_SRC}. Syncing to ${DEST_DIR}..."
    mkdir -p "$(dirname "${DEST_DIR}")"
    cp -af "${WORKSPACE_SRC}/." "${DEST_DIR}/"
    
    SBO_DIR="${DEST_DIR}"
    LOCAL_MODE=true

    tar -czf ${PACKAGE}.tar.gz -C "$(dirname "${DEST_DIR}")" "${PACKAGE}"
    gpg --batch --yes --armor --detach-sign ${PACKAGE}.tar.gz
    mv ${PACKAGE}.tar.gz "${SBO_ROOT}/SBo/15.0/development/"
    mv ${PACKAGE}.tar.gz.asc "${SBO_ROOT}/SBo/15.0/development/"
else
    info "Workspace source not found. Falling back to sbopkg..."
    command -v sbopkg &>/dev/null || die "sbopkg not found and no local workspace exists."
    
    # FIX: Cleaned up flag syntax for sbopkg batch mode
    sbopkg -b -e continue -d "${PACKAGE}" || die "sbopkg -d failed for '${PACKAGE}'"
    
    SBO_DIR="$(find "${SBO_ROOT}" -type d -name "${PACKAGE}" | head -n1)"
fi

# ── step 2: final directory verification ──────────────────────────────────────
[[ -n "${SBO_DIR}" ]] || die "Cannot find SlackBuild directory for '${PACKAGE}'"
SLACKBUILD_SCRIPT="${SBO_DIR}/${PACKAGE}.SlackBuild"
[[ -f "${SLACKBUILD_SCRIPT}" ]] || die "No .SlackBuild script found at '${SLACKBUILD_SCRIPT}'"

# ── step 3: resolve version ────────────────────────────────────────────────────
INFO_FILE="${SBO_DIR}/${PACKAGE}.info"
[[ -f "${INFO_FILE}" ]] || die "No .info file found"

OLD_VERSION="$(grep -E '^VERSION=' "${INFO_FILE}" | cut -d= -f2 | tr -d '"' | tr -d "'")"

if [[ -z "${VERSION}" ]]; then
    RAW_DOWNLOAD="$(grep -E '^DOWNLOAD(_x86_64)?=' "${INFO_FILE}" | grep -v 'UNSUPPORTED' | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
    FIRST_URL="${RAW_DOWNLOAD%% *}"
    
    if [[ "$FIRST_URL" == *"github.com"* ]]; then
        slug=$(echo "${FIRST_URL}" | grep -oP '(?<=github\.com/)[^/]+/[^/]+')
        # Use GITHUB_TOKEN if available to avoid rate limits
        AUTH_HEADER=""
        [[ -n "${GITHUB_TOKEN:-}" ]] && AUTH_HEADER="-H \"Authorization: token ${GITHUB_TOKEN}\""
        
        tag=$(eval curl -fsSL "${AUTH_HEADER}" "https://api.github.com/repos/${slug}/releases/latest" | grep -oP '"tag_name"\s*:\s*"\K[^"]+' || echo "")
        if [[ -n "$tag" ]]; then
             VERSION="${tag#v}"
        else
             VERSION="${OLD_VERSION}"
        fi
    else
        VERSION="${OLD_VERSION}"
    fi
fi

TARNAM="$(grep -oP '^TARNAM=\K\S+' "${SLACKBUILD_SCRIPT}" | tr -d '"' | tr -d "'" || true)"
TARNAM="${TARNAM:-${PACKAGE}}"

# ── step 4: fetch source ───────────────────────────────────────────────────────
SRCDIR="$(mktemp -d /tmp/sbo-src.XXXXXX)"
trap 'rm -rf "${SRCDIR}"' EXIT

if [[ "${LOCAL_MODE}" == "true" ]]; then
    info "Local mode: Ensuring source tarball is present..."
    if [[ -f "${SBO_DIR}/${TARNAM}-${VERSION}.tar.gz" ]]; then
        cp "${SBO_DIR}/${TARNAM}-${VERSION}.tar.gz" "${SRCDIR}/"
    elif [[ -n "${GIT_URL}" ]]; then
        info "Source not found in workspace. Cloning from Git..."
        # Try version with and without 'v' prefix
        git clone --branch "${VERSION}" --recurse-submodules "${GIT_URL}" "${SRCDIR}/source" || \
        git clone --branch "v${VERSION}" --recurse-submodules "${GIT_URL}" "${SRCDIR}/source" || \
        die "git clone failed"
        mv "${SRCDIR}/source" "${SRCDIR}/${PACKAGE}-${VERSION}"
        tar -czf "${SRCDIR}/${TARNAM}-${VERSION}.tar.gz" -C "${SRCDIR}" "${PACKAGE}-${VERSION}"
    fi
else
    # Only try downloading if we aren't using a local workspace
    RAW_DOWNLOAD="$(grep -E '^DOWNLOAD(_x86_64)?=' "${INFO_FILE}" | grep -v 'UNSUPPORTED' | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
    NEW_URL="${RAW_DOWNLOAD//${OLD_VERSION}/${VERSION}}"
    if [[ -n "${NEW_URL}" ]]; then
        curl -fL -o "${SRCDIR}/$(basename "${NEW_URL%% *}")" "${NEW_URL%% *}" || info "Download failed - continuing validation"
    fi
fi

# ── step 5: staging ──────────────────────────────────────────────────────────
BUILD_DIR="$(mktemp -d /tmp/sbo-build-stage.XXXXXX)"
trap 'rm -rf "${SRCDIR}" "${BUILD_DIR}"' EXIT

cp -af "${SBO_DIR}/." "${BUILD_DIR}/"
cp -af "${SRCDIR}"/* "${BUILD_DIR}/" 2>/dev/null || true

chmod +x "${BUILD_DIR}/${PACKAGE}.SlackBuild"

# ── step 6: validation output ──────────────────────────────────────────────────
echo "--- VALIDATION COMPLETE ---"
echo "Package:          ${PACKAGE}"
echo "Version:          ${VERSION}"
echo "SBo Directory:    ${SBO_DIR}"
echo "Staging Dir:      ${BUILD_DIR}"
echo "Source Tarball:   ${TARNAM}-${VERSION}.tar.gz"
echo "---------------------------"
