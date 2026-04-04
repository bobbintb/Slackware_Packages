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

# ── step 3b: resolve the expected tarball name ────────────────────────────────
PRGNAM="${PACKAGE}"

echo "DEBUG script path: ${SLACKBUILD_SCRIPT}"
echo "DEBUG file exists: $(test -f "${SLACKBUILD_SCRIPT}" && echo yes || echo no)"

_TAR_LINE="$(grep -m1 -E '^\s*tar -?[a-zA-Z]*x[a-zA-Z]*' "${SLACKBUILD_SCRIPT}" || true)"
_TAR_LINENUM="$(grep -m1 -nE '^\s*tar -?[a-zA-Z]*x[a-zA-Z]*' "${SLACKBUILD_SCRIPT}" | cut -d: -f1 || echo "")"

echo "DEBUG grep result: ${_TAR_LINE}"
echo "DEBUG exit code: $?"

SCRIPT_TARBALL=""
if [[ -n "${_TAR_LINE}" ]]; then
    _RAW_TARNAME="$(echo "${_TAR_LINE}" | grep -oE '\$\{?CWD\}?/\S+' | sed 's|.*CWD}*/||' || true)"
    
    if [[ -n "${_RAW_TARNAME}" ]]; then
        SCRIPT_TARBALL="${_RAW_TARNAME}"
        _VARS="$(echo "${_RAW_TARNAME}" | grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*\}?' | sed 's/[${}]//g')"
        for _VAR in ${_VARS}; do
            if [[ "${_VAR}" == "PRGNAM" ]]; then
                _VAL="${PRGNAM}"
            else
                _VAL="$(head -n "${_TAR_LINENUM}" "${SLACKBUILD_SCRIPT}" | \
                    grep -E "^\s*${_VAR}=" | tail -n1 | cut -d= -f2- | tr -d '"' | tr -d "'" || true)"
            fi
            
            [[ "${_VAL}" =~ ^\$\{[A-Za-z_][A-Za-z0-9_]*:-([^}]+)\}$ ]] && _VAL="${BASH_REMATCH[1]}"
            SCRIPT_TARBALL="${SCRIPT_TARBALL//\$\{${_VAR}\}/${_VAL}}"
            SCRIPT_TARBALL="${SCRIPT_TARBALL//\$${_VAR}/${_VAL}}"
        done
        info "SlackBuild expects tarball: ${SCRIPT_TARBALL}"
    fi
fi

# ── step 4: fetch source ───────────────────────────────────────────────────────
SRCDIR="$(mktemp -d /tmp/sbo-src.XXXXXX)"
trap 'rm -rf "${SRCDIR}"' EXIT

if [[ "${LOCAL_MODE}" == "true" ]]; then
    if [[ -n "${SCRIPT_TARBALL}" && -f "${SBO_DIR}/${SCRIPT_TARBALL}" ]]; then
        cp "${SBO_DIR}/${SCRIPT_TARBALL}" "${SRCDIR}/"
    elif [[ -n "${GIT_URL}" ]]; then
        info "Cloning into ${SRCDIR}/${PRGNAM}..."
        git clone --branch "${VERSION}" --recurse-submodules "${GIT_URL}" "${SRCDIR}/${PRGNAM}" || \
        git clone --branch "v${VERSION}" --recurse-submodules "${GIT_URL}" "${SRCDIR}/${PRGNAM}" || \
        die "git clone failed"
        [[ -n "${SCRIPT_TARBALL}" ]] && tar -czf "${SRCDIR}/${SCRIPT_TARBALL}" -C "${SRCDIR}" "${PRGNAM}"
    else
        [[ -n "${SCRIPT_TARBALL}" ]] && die "Source tarball ${SCRIPT_TARBALL} not found and no GIT_URL provided."
    fi
else
    if [[ -n "${GIT_URL}" ]]; then
        info "Cloning into ${SRCDIR}/${PRGNAM}..."
        git clone --branch "${VERSION}" --recurse-submodules "${GIT_URL}" "${SRCDIR}/${PRGNAM}" || \
        git clone --branch "v${VERSION}" --recurse-submodules "${GIT_URL}" "${SRCDIR}/${PRGNAM}" || \
        die "git clone failed"
        [[ -n "${SCRIPT_TARBALL}" ]] && tar -czf "${SRCDIR}/${SCRIPT_TARBALL}" -C "${SRCDIR}" "${PRGNAM}"
    else
        RAW_DOWNLOAD="$(grep -E '^DOWNLOAD(_x86_64)?=' "${INFO_FILE}" | grep -v 'UNSUPPORTED' | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
        NEW_URL="${RAW_DOWNLOAD//${OLD_VERSION}/${VERSION}}"
        curl -fL -o "${SRCDIR}/$(basename "${NEW_URL%% *}")" "${NEW_URL%% *}" || die "Download failed"
    fi
fi

# ── step 4b: rename source tarball ────────────────────────────────────────────
if [[ -n "${SCRIPT_TARBALL}" ]]; then
    _ACTUAL="$(find "${SRCDIR}" -maxdepth 1 \( -name "*.tar.*" -o -name "*.tgz" \) | head -n1 || true)"
    if [[ -n "${_ACTUAL}" && "$(basename "${_ACTUAL}")" != "${SCRIPT_TARBALL}" ]]; then
        info "Renaming $(basename "${_ACTUAL}") → ${SCRIPT_TARBALL}"
        mv "${_ACTUAL}" "${SRCDIR}/${SCRIPT_TARBALL}"
    fi
fi

# ── step 5: stage everything and build ────────────────────────────────────────
BUILD_DIR="$(mktemp -d /tmp/sbo-build-stage.XXXXXX)"
trap 'rm -rf "${SRCDIR}" "${BUILD_DIR}"' EXIT

cp -af "${SBO_DIR}/." "${BUILD_DIR}/"
cp -af "${SRCDIR}"/* "${BUILD_DIR}/" || true

chmod +x "${BUILD_DIR}/${PACKAGE}.SlackBuild"

info "Building '${PACKAGE}' version ${VERSION}..."
(
    cd "${BUILD_DIR}"
    VERSION="${VERSION}" bash "${PACKAGE}.SlackBuild"
)
