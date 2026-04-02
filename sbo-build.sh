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

# ── step 4: resolve TARNAM by sourcing SlackBuild vars in a subshell ──────────
# Run in a subshell so nothing can affect the current shell's state.
# We source only simple scalar assignments, skipping command substitutions,
# backticks, and comments, then print the resolved TARNAM.
TARNAM="$(bash 2>/dev/null <<SUBSHELL
$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "${SLACKBUILD_SCRIPT}" \
    | grep -vE '^\s*#' \
    | grep -vE '=\s*\$\(' \
    | grep -vE '=\s*\`' \
    || true)
VERSION="${VERSION}"
echo "\${TARNAM:-\${SRCNAM:-\${PRGNAM:-}}}"
SUBSHELL
)"
TARNAM="${TARNAM:-${PACKAGE}}"
info "Resolved TARNAM='${TARNAM}' VERSION='${VERSION}'"

# ── step 5: fetch source ───────────────────────────────────────────────────────
SRCDIR="$(mktemp -d /tmp/sbo-src.XXXXXX)"
trap 'rm -rf "${SRCDIR}"' EXIT

# git_clone: clones without --recurse-submodules to avoid SIGPIPE from git's
# internal inter-process pipes when handling large submodule trees.
# Submodules are initialised separately afterward.
# All output is captured so the Actions log pipe cannot cause SIGPIPE.
# Success is verified by checking .git exists, not by exit code.
git_clone() {
    local branch="$1" dest="$2" log
    log="$(mktemp /tmp/git-clone-XXXXXX.log)"
    set +eo pipefail
    git -c advice.detachedHead=false clone \
        --branch "${branch}" \
        "${GIT_URL}" "${dest}" \
        >"${log}" 2>&1
    set -eo pipefail
    if [[ -d "${dest}/.git" ]]; then
        rm -f "${log}"
        return 0
    fi
    rm -f "${log}"
    return 1
}

# git_submodules: initialises submodules separately from the clone.
# Kept as its own step so SIGPIPE from submodule pack operations
# doesn't affect the parent clone, and failures are clearly attributable.
git_submodules() {
    local dest="$1" log
    log="$(mktemp /tmp/git-submodule-XXXXXX.log)"
    set +eo pipefail
    git -C "${dest}" submodule update --init --recursive \
        >"${log}" 2>&1
    local rc=$?
    set -eo pipefail
    rm -f "${log}"
    return $rc
}

# do_git_clone: tries bare version then v-prefixed, then inits submodules.
do_git_clone() {
    local dest="$1"
    git_clone "${VERSION}" "${dest}" \
        || git_clone "v${VERSION}" "${dest}" \
        || die "git clone failed: could not find branch '${VERSION}' or 'v${VERSION}' in ${GIT_URL}"
    git_submodules "${dest}" \
        || die "git submodule update failed for ${GIT_URL}"
}

STAGED_TARBALL=""

if [[ "${LOCAL_MODE}" == "true" ]]; then
    info "Local mode: Ensuring source tarball is present..."
    if [[ -f "${SBO_DIR}/${TARNAM}-${VERSION}.tar.gz" ]]; then
        cp "${SBO_DIR}/${TARNAM}-${VERSION}.tar.gz" "${SRCDIR}/"
        STAGED_TARBALL="${SRCDIR}/${TARNAM}-${VERSION}.tar.gz"
    elif [[ -n "${GIT_URL}" ]]; then
        info "Source not found in workspace. Cloning from Git..."
        do_git_clone "${SRCDIR}/source"
        mv "${SRCDIR}/source" "${SRCDIR}/${TARNAM}-${VERSION}"
        tar -czf "${SRCDIR}/${TARNAM}-${VERSION}.tar.gz" -C "${SRCDIR}" "${TARNAM}-${VERSION}"
        STAGED_TARBALL="${SRCDIR}/${TARNAM}-${VERSION}.tar.gz"
    else
        die "Source tarball ${TARNAM}-${VERSION}.tar.gz not found in workspace and no GIT_URL provided."
    fi
else
    if [[ -n "${GIT_URL}" ]]; then
        do_git_clone "${SRCDIR}/source"
        mv "${SRCDIR}/source" "${SRCDIR}/${TARNAM}-${VERSION}"
        tar -czf "${SRCDIR}/${TARNAM}-${VERSION}.tar.gz" -C "${SRCDIR}" "${TARNAM}-${VERSION}"
        STAGED_TARBALL="${SRCDIR}/${TARNAM}-${VERSION}.tar.gz"
    else
        RAW_DOWNLOAD="$(grep -E '^DOWNLOAD(_x86_64)?=' "${INFO_FILE}" | grep -v 'UNSUPPORTED' | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
        NEW_URL="${RAW_DOWNLOAD//${OLD_VERSION}/${VERSION}}"
        TARBALL_NAME="$(basename "${NEW_URL%% *}")"

        info "Verifying download URL resolves before fetching..."
        curl --head --silent --fail "${NEW_URL%% *}" > /dev/null \
            || die "Substituted download URL does not resolve: ${NEW_URL%% *}"

        curl -fL -o "${SRCDIR}/${TARBALL_NAME}" "${NEW_URL%% *}" || die "Download failed"
        STAGED_TARBALL="${SRCDIR}/${TARBALL_NAME}"
    fi
fi

# ── diagnostic: show tarball name and its actual top-level directory ───────────
TARBALL_TOPLEVEL="$(tar -tzf "${STAGED_TARBALL}" | head -n1 | cut -d/ -f1)"
info "Staged tarball : $(basename "${STAGED_TARBALL}")"
info "Top-level dir  : ${TARBALL_TOPLEVEL}"

# ── step 6: stage everything and build ────────────────────────────────────────
BUILD_DIR="$(mktemp -d /tmp/sbo-build-stage.XXXXXX)"
trap 'rm -rf "${SRCDIR}" "${BUILD_DIR}"' EXIT

cp -af "${SBO_DIR}/." "${BUILD_DIR}/"
cp -af "${SRCDIR}"/* "${BUILD_DIR}/"

info "Build dir contents:"
ls -1 "${BUILD_DIR}"

chmod +x "${BUILD_DIR}/${PACKAGE}.SlackBuild"

info "Building '${PACKAGE}' version ${VERSION}..."
(
    cd "${BUILD_DIR}"
    VERSION="${VERSION}" bash "${PACKAGE}.SlackBuild"
)
