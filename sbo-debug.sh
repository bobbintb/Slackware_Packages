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

    # Your intentional tar/gpg logic
    tar -czf ${PACKAGE}.tar.gz -C "$(dirname "${DEST_DIR}")" "${PACKAGE}"
    gpg --armor --detach-sign ${PACKAGE}.tar.gz
    mv ${PACKAGE}.tar.gz "${SBO_ROOT}/SBo/15.0/development/"
    mv ${PACKAGE}.tar.gz.asc "${SBO_ROOT}/SBo/15.0/development/"
else
    info "Workspace source not found. Falling back to sbopkg..."
    command -v sbopkg &>/dev/null || die "sbopkg not found and no local workspace exists."
    
    # FIX: Using -p (permanent) and answering 'y' via printf to avoid flooding stdin.
    # We use -k to skip GPG errors and -p to run as a non-interactive process.
    printf "y\ny\n" | sbopkg -p -k -d "${PACKAGE}" || die "sbopkg -d failed for '${PACKAGE}'"
    
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
        tag=$(curl -fsSL "https://api.github.com/repos/${slug}/releases/latest" | grep -oP '"tag_name"\s*:\s*"\K[^"]+')
        VERSION="${tag#v}"
    elif [[ "${GIT_URL}" == *"github.com"* ]]; then
        slug=$(echo "${GIT_URL}" | grep -oP '(?<=github\.com/)[^/]+/[^/]+' | sed 's/\.git$//')
        tag=$(curl -fsSL "https://api.github.com/repos/${slug}/releases/latest" | grep -oP '"tag_name"\s*:\s*"\K[^"]+')
        VERSION="${tag#v}"
    else
        VERSION="${OLD_VERSION}"
        info "Using version from .info: ${VERSION}"
    fi
fi

TARNAM="$(grep -oP '^TARNAM=\K\S+' "${SLACKBUILD_SCRIPT}" | tr -d '"' | tr -d "'" || true)"
TARNAM="${TARNAM:-${PACKAGE}}"

# ── step 4: fetch source ───────────────────────────────────────────────────────
SRCDIR="$(mktemp -d /tmp/sbo-src.XXXXXX)"
