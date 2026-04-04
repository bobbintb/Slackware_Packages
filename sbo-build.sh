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
    sbopkg -d "${PACKAGE}" || die "sbopkg -d failed for '${PACKAGE}'"
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

# ── step 3b: parse the SlackBuild for the expected tarball name ────────────────
PRGNAM="$(grep -m1 -E '^PRGNAM=' "${SLACKBUILD_SCRIPT}" | cut -d= -f2 | tr -d '"' | tr -d "'" || true)"
PRGNAM="${PRGNAM:-${PACKAGE}}"

# Find the first tar line that extracts (contains 'x' in the flags)
_TAR_LINE="$(grep -m1 -E '^\s*tar -?[a-zA-Z]*x[a-zA-Z]*' "${SLACKBUILD_SCRIPT}")"
_TAR_LINENUM="$(grep -m1 -nE '^\s*tar -?[a-zA-Z]*x[a-zA-Z]*' "${SLACKBUILD_SCRIPT}" | cut -d: -f1)"

# Extract the filename token after $CWD/
_RAW_TARNAME="$(echo "${_TAR_LINE}" | grep -oE '\$\{?CWD\}?/\S+' | sed 's|.*CWD}*/||')"

# Extract variable names from the filename token and substitute each
SCRIPT_TARBALL="${_RAW_TARNAME}"
_VARS="$(echo "${_RAW_TARNAME}" | grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*\}?' | sed 's/[${}]//g')"
for _VAR in ${_VARS}; do
    _VAL="$(head -n "${_TAR_LINENUM}" "${SLACKBUILD_SCRIPT}" | \
        grep -E "^\s*${_VAR}=" | tail -n1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
    if [[ "${_VAL}" =~ ^\$\{[A-Za-z_][A-Za-z0-9_]*:-([^}]+)\}$ ]]; then
        _VAL="${BASH_REMATCH[1]}"
    fi
    SCRIPT_TARBALL="${SCRIPT_TARBALL//\$\{${_VAR}\}/${_VAL}}"
    SCRIPT_TARBALL="${SCRIPT_TARBALL//\$${_VAR}/${_VAL}}"
done

info "SlackBuild expects tarball: ${SCRIPT_TARBALL}"

# ── step 4: fetch source ───────────────────────────────────────────────────────
SRCDIR="$(mktemp -d /tmp/sbo-src.XXXXXX)"
trap 'rm -rf "${SRCDIR}"' EXIT

if [[ "${LOCAL_MODE}" == "true" ]]; then
    info "Local mode: Ensuring source tarball is present..."
    if [[ -f "${SBO_DIR}/${SCRIPT_TARBALL}" ]]; then
        cp "${SBO_DIR}/${SCRIPT_TARBALL}" "${SRCDIR}/"
    elif [[ -n "${GIT_URL}" ]]; then
        info "Source not found in workspace. Cloning from Git..."
        git clone --branch "${VERSION}" --recurse-submodules "${GIT_URL}" "${SRCDIR}/source" || \
        git clone --branch "v${VERSION}" --recurse-submodules "${GIT_URL}" "${SRCDIR}/source" || \
        die "git clone failed"
        tar -czf "${SRCDIR}/${SCRIPT_TARBALL}" -C "${SRCDIR}" source
    else
        die "Source tarball ${SCRIPT_TARBALL} not found in workspace and no GIT_URL provided."
    fi
else
    if [[ -n "${GIT_URL}" ]]; then
        git clone --branch "${VERSION}" --recurse-submodules "${GIT_URL}" "${SRCDIR}/source" || \
        git clone --branch "v${VERSION}" --recurse-submodules "${GIT_URL}" "${SRCDIR}/source" || \
        die "git clone failed"
        tar -czf "${SRCDIR}/${SCRIPT_TARBALL}" -C "${SRCDIR}" source
    else
        RAW_DOWNLOAD="$(grep -E '^DOWNLOAD(_x86_64)?=' "${INFO_FILE}" | grep -v 'UNSUPPORTED' | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
        NEW_URL="${RAW_DOWNLOAD//${OLD_VERSION}/${VERSION}}"
        curl -fL -o "${SRCDIR}/$(basename "${NEW_URL%% *}")" "${NEW_URL%% *}" || die "Download failed"
    fi
fi

# ── step 4b: rename source tarball to match what the SlackBuild expects ───────
_ACTUAL="$(find "${SRCDIR}" -maxdepth 1 \( -name "*.tar.*" -o -name "*.tgz" \) | head -n1)"
[[ -n "${_ACTUAL}" ]] || die "No source tarball found in ${SRCDIR}"
if [[ "$(basename "${_ACTUAL}")" != "${SCRIPT_TARBALL}" ]]; then
    info "Renaming $(basename "${_ACTUAL}") → ${SCRIPT_TARBALL}"
    mv "${_ACTUAL}" "${SRCDIR}/${SCRIPT_TARBALL}"
fi

# ── step 5: stage everything and build ────────────────────────────────────────
BUILD_DIR="$(mktemp -d /tmp/sbo-build-stage.XXXXXX)"
trap 'rm -rf "${SRCDIR}" "${BUILD_DIR}"' EXIT

cp -af "${SBO_DIR}/." "${BUILD_DIR}/"
cp -af "${SRCDIR}"/* "${BUILD_DIR}/"

chmod +x "${BUILD_DIR}/${PACKAGE}.SlackBuild"

info "Building '${PACKAGE}' version ${VERSION}..."
(
    cd "${BUILD_DIR}"
    VERSION="${VERSION}" bash "${PACKAGE}.SlackBuild"
)
