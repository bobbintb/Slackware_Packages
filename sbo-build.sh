#!/bin/bash
# sbo-build — Build a SlackBuild from a local workspace or sbopkg.
set -euo pipefail

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

# ── resolve TARNAM: check TARNAM, SRCNAM, then PRGNAM, fallback to PACKAGE ────
TARNAM="$(grep -oP '^(TARNAM|SRCNAM|PRGNAM)=\K\S+' "${SLACKBUILD_SCRIPT}" | head -n1 | tr -d '"' | tr -d "'" || true)"
TARNAM="${TARNAM:-${PACKAGE}}"

# ── step 4: fetch source ───────────────────────────────────────────────────────
SRCDIR="$(mktemp -d /tmp/sbo-src.XXXXXX)"
trap 'rm -rf "${SRCDIR}"' EXIT

inspect_tarball() {
    local tarball_path="$1"
    # Capture full listing to avoid SIGPIPE killing tar under pipefail.
    local tarball_listing
    tarball_listing="$(tar -tzf "${tarball_path}")"
    EXTRACTED_DIR="$(echo "${tarball_listing}" | head -n1 | cut -d/ -f1)"
    [[ -n "${EXTRACTED_DIR}" ]] || die "Could not determine extracted directory from tarball: ${tarball_path}"
    info "Tarball extracts to top-level directory: '${EXTRACTED_DIR}'"
}

# git_clone: wraps git clone so a failing first attempt doesn't kill the script.
# pipefail is disabled for the duration because git --recurse-submodules spawns
# child processes that write to pipes internally and can trigger SIGPIPE (141).
git_clone() {
    local branch="$1" dest="$2"
    set +o pipefail
    git clone --branch "${branch}" --recurse-submodules "${GIT_URL}" "${dest}"
    local rc=$?
    set -o pipefail
    return $rc
}

STAGED_TARBALL=""

if [[ "${LOCAL_MODE}" == "true" ]]; then
    info "Local mode: Ensuring source tarball is present..."
    if [[ -f "${SBO_DIR}/${TARNAM}-${VERSION}.tar.gz" ]]; then
        cp "${SBO_DIR}/${TARNAM}-${VERSION}.tar.gz" "${SRCDIR}/"
        STAGED_TARBALL="${SRCDIR}/${TARNAM}-${VERSION}.tar.gz"
        inspect_tarball "${STAGED_TARBALL}"
    elif [[ -n "${GIT_URL}" ]]; then
        info "Source not found in workspace. Cloning from Git..."
        git_clone "${VERSION}" "${SRCDIR}/source" \
            || git_clone "v${VERSION}" "${SRCDIR}/source" \
            || die "git clone failed for both '${VERSION}' and 'v${VERSION}'"
        mv "${SRCDIR}/source" "${SRCDIR}/${PACKAGE}-${VERSION}"
        tar -czf "${SRCDIR}/${TARNAM}-${VERSION}.tar.gz" -C "${SRCDIR}" "${PACKAGE}-${VERSION}"
        STAGED_TARBALL="${SRCDIR}/${TARNAM}-${VERSION}.tar.gz"
        inspect_tarball "${STAGED_TARBALL}"
    else
        die "Source tarball ${TARNAM}-${VERSION}.tar.gz not found in workspace and no GIT_URL provided."
    fi
else
    if [[ -n "${GIT_URL}" ]]; then
        git_clone "${VERSION}" "${SRCDIR}/source" \
            || git_clone "v${VERSION}" "${SRCDIR}/source" \
            || die "git clone failed for both '${VERSION}' and 'v${VERSION}'"
        mv "${SRCDIR}/source" "${SRCDIR}/${PACKAGE}-${VERSION}"
        tar -czf "${SRCDIR}/${TARNAM}-${VERSION}.tar.gz" -C "${SRCDIR}" "${PACKAGE}-${VERSION}"
        STAGED_TARBALL="${SRCDIR}/${TARNAM}-${VERSION}.tar.gz"
        inspect_tarball "${STAGED_TARBALL}"
    else
        RAW_DOWNLOAD="$(grep -E '^DOWNLOAD(_x86_64)?=' "${INFO_FILE}" | grep -v 'UNSUPPORTED' | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
        NEW_URL="${RAW_DOWNLOAD//${OLD_VERSION}/${VERSION}}"
        TARBALL_NAME="$(basename "${NEW_URL%% *}")"

        info "Verifying download URL resolves before fetching..."
        curl --head --silent --fail "${NEW_URL%% *}" > /dev/null \
            || die "Substituted download URL does not resolve: ${NEW_URL%% *}"

        curl -fL -o "${SRCDIR}/${TARBALL_NAME}" "${NEW_URL%% *}" || die "Download failed"
        STAGED_TARBALL="${SRCDIR}/${TARBALL_NAME}"
        inspect_tarball "${STAGED_TARBALL}"
    fi
fi

# ── step 5: stage everything and build ────────────────────────────────────────
BUILD_DIR="$(mktemp -d /tmp/sbo-build-stage.XXXXXX)"
trap 'rm -rf "${SRCDIR}" "${BUILD_DIR}"' EXIT

cp -af "${SBO_DIR}/." "${BUILD_DIR}/"
cp -af "${SRCDIR}"/* "${BUILD_DIR}/"

# If the tarball's top-level directory name doesn't match TARNAM-VERSION,
# the SlackBuild will extract it fine but may cd into the wrong path.
# We rename the top-level directory inside the tarball to match what the
# SlackBuild expects: ${TARNAM}-${VERSION}.
EXPECTED_TARBALL_DIR="${TARNAM}-${VERSION}"
if [[ "${EXTRACTED_DIR}" != "${EXPECTED_TARBALL_DIR}" ]]; then
    info "Renaming tarball top-level '${EXTRACTED_DIR}' to '${EXPECTED_TARBALL_DIR}'..."
    STAGED_TARBALL_IN_BUILD="${BUILD_DIR}/$(basename "${STAGED_TARBALL}")"
    [[ -f "${STAGED_TARBALL_IN_BUILD}" ]] || die "Staged tarball not found in build dir: ${STAGED_TARBALL_IN_BUILD}"
    tar -xzf "${STAGED_TARBALL_IN_BUILD}" -C "${BUILD_DIR}"
    mv "${BUILD_DIR}/${EXTRACTED_DIR}" "${BUILD_DIR}/${EXPECTED_TARBALL_DIR}"
    # Repack the tarball with the corrected directory name so the SlackBuild's
    # own tar extraction also gets the right name.
    tar -czf "${STAGED_TARBALL_IN_BUILD}" -C "${BUILD_DIR}" "${EXPECTED_TARBALL_DIR}"
    rm -rf "${BUILD_DIR:?}/${EXPECTED_TARBALL_DIR}"
fi

chmod +x "${BUILD_DIR}/${PACKAGE}.SlackBuild"

info "Building '${PACKAGE}' version ${VERSION}..."
(
    cd "${BUILD_DIR}"
    VERSION="${VERSION}" bash "${PACKAGE}.SlackBuild"
)
