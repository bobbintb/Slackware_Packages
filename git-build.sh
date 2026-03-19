#!/bin/bash
# sbo-git-build — Download a SlackBuild via sbopkg, clone a git repo as the
#                 source, then build using the SlackBuild script.
#
# Usage: sbo-git-build <package> <git-repo-url>
#   package      : exact SlackBuild name (e.g. "bcc")
#   git-repo-url : git repository to clone as the build source

set -euo pipefail

# ── helpers ────────────────────────────────────────────────────────────────────
die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">>> $*"; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <package> <git-repo-url>

  package       SlackBuild package name   (e.g. bcc)
  git-repo-url  Git repository to use as the build source

Options:
  -h, --help    Show this help and exit
  -d, --dir     Override SlackBuilds tree root (default: /var/lib/sbopkg)
EOF
    exit 0
}

# ── defaults ───────────────────────────────────────────────────────────────────
SBO_ROOT="/var/lib/sbopkg"

# ── argument parsing ───────────────────────────────────────────────────────────
while [[ ${1:-} == -* ]]; do
    case "$1" in
        -h|--help) usage ;;
        -d|--dir)  SBO_ROOT="${2:?--dir requires a path}"; shift ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

[[ $# -ge 2 ]] || usage

PACKAGE="$1"
GIT_REPO="$2"

# ── sanity checks ──────────────────────────────────────────────────────────────
command -v sbopkg &>/dev/null || die "sbopkg not found in PATH"
command -v git    &>/dev/null || die "git not found in PATH"
command -v expect &>/dev/null || die "expect not found in PATH"

# ── step 1: download / sync the SlackBuild via sbopkg ─────────────────────────
info "Downloading SlackBuild for '${PACKAGE}' via sbopkg ..."
expect -c "
    spawn sbopkg -d \"${PACKAGE}\"
    expect -re {Yes|yes|Y\|y}
    send \"y\r\"
    expect eof
" || die "sbopkg -d failed for '${PACKAGE}'"

# ── step 2: locate the .SlackBuild directory ───────────────────────────────────
SBO_DIR="$(find "${SBO_ROOT}" -type d -name "${PACKAGE}" | head -n1)"
[[ -n "${SBO_DIR}" ]] || die "Cannot find SlackBuild directory for '${PACKAGE}' under ${SBO_ROOT}"
info "Found SlackBuild at: ${SBO_DIR}"

SLACKBUILD_SCRIPT="${SBO_DIR}/${PACKAGE}.SlackBuild"
[[ -f "${SLACKBUILD_SCRIPT}" ]] || die "No .SlackBuild script found at '${SLACKBUILD_SCRIPT}'"

# ── step 3: read the version from the .info file ──────────────────────────────
INFO_FILE="${SBO_DIR}/${PACKAGE}.info"
[[ -f "${INFO_FILE}" ]] || die "No .info file found at '${INFO_FILE}'"

VERSION="$(grep -E '^VERSION=' "${INFO_FILE}" | cut -d= -f2 | tr -d '"' | tr -d "'")"
[[ -n "${VERSION}" ]] || die "Could not parse VERSION from '${INFO_FILE}'"
info "SlackBuild version: ${VERSION}"

# ── step 4: clone the git repo ────────────────────────────────────────────────
SRCDIR="$(mktemp -d /tmp/sbo-git-build.XXXXXX)"
trap 'rm -rf "${SRCDIR}"' EXIT

info "Cloning ${GIT_REPO} ..."
git clone --depth=1 "${GIT_REPO}" "${SRCDIR}/${PACKAGE}"

# ── step 5: stage everything and build ────────────────────────────────────────
BUILD_DIR="$(mktemp -d /tmp/sbo-git-build-stage.XXXXXX)"
trap 'rm -rf "${SRCDIR}" "${BUILD_DIR}"' EXIT

cp -r "${SBO_DIR}/." "${BUILD_DIR}/"
cp -r "${SRCDIR}/${PACKAGE}" "${BUILD_DIR}/"

chmod +x "${BUILD_DIR}/${PACKAGE}.SlackBuild"

info "Building '${PACKAGE}' version ${VERSION} ..."
(
    cd "${BUILD_DIR}"
    VERSION="${VERSION}" bash "${PACKAGE}.SlackBuild"
)

info "Build complete. Check /tmp or \$OUTPUT for the resulting .txz / .tgz package."
