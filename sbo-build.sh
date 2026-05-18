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
BINARY_URL=""
BINARY_DEST="${BINARY_DEST:-/usr/bin}"
SBO_DIR=""
SRCDIR=""
BUILD_DIR=""
SCRIPT_DIR="$(dirname "$(realpath "$0")")"

# ── functions ──────────────────────────────────────────────────────────────────

parse_args() {
    while [[ ${1:-} == -* ]]; do
        case "$1" in
            -h|--help) usage ;;
            -d|--dir)  SBO_ROOT="${2:?--dir requires a path}"; shift ;;
            -b|--binary-url)  BINARY_URL="${2:?--binary-url requires a URL}"; shift ;;
            --binary-dest)    BINARY_DEST="${2:?--binary-dest requires a path}"; shift ;;
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
        local tag=""
        if [[ "$FIRST_URL" == *"github.com"* ]]; then
            slug=$(echo "${FIRST_URL}" | grep -oP '(?<=github\.com/)[^/]+/[^/]+' | sed 's/\.git$//')
            tag=$(curl -fsSL "https://api.github.com/repos/${slug}/releases/latest" | grep -oP '"tag_name"\s*:\s*"\K[^"]+') || true
        fi
        if [[ -z "${tag}" && "${GIT_URL}" == *"github.com"* ]]; then
            slug=$(echo "${GIT_URL}" | grep -oP '(?<=github\.com/)[^/]+/[^/]+' | sed 's/\.git$//')
            tag=$(curl -fsSL "https://api.github.com/repos/${slug}/releases/latest" | grep -oP '"tag_name"\s*:\s*"\K[^"]+') || true
        fi
        if [[ -z "${tag}" && "${BINARY_URL}" == *"github.com"* ]]; then
            slug=$(echo "${BINARY_URL}" | grep -oP '(?<=github\.com/)[^/]+/[^/]+' | sed 's/\.git$//')
            tag=$(curl -fsSL "https://api.github.com/repos/${slug}/releases/latest" | grep -oP '"tag_name"\s*:\s*"\K[^"]+') || true
        fi
        if [[ -n "${tag}" ]]; then
            VERSION="${tag#v}"
        else
            VERSION="${OLD_VERSION}"
            info "========================================Using version from .info: ${VERSION}========================================"
        fi
    fi

    TARNAM="$(grep -oP '^TARNAM=\K\S+' "${SLACKBUILD_SCRIPT}" | tr -d '"' | tr -d "'" || true)"
    TARNAM="${TARNAM:-${PACKAGE}}"
}

step_4_fetch_source() {
    # ── step 4: fetch source ───────────────────────────────────────────────────────

    SRCDIR="/tmp/SBo"
    mkdir -p "${SRCDIR}"

    # Binary mode: download pre-built binary directly, skip all source/git logic
    if [[ -n "${BINARY_URL}" ]]; then
        BINARY_URL="${BINARY_URL//\{VERSION\}/${VERSION}}"
        info "Binary URL provided. Downloading binary from ${BINARY_URL}..."
        curl -fL -J -O --output-dir "${SRCDIR}" "${BINARY_URL}" || die "Binary download failed"

        # Detect and extract archives by extension; delete archive after
        local DOWNLOADED
        DOWNLOADED="$(ls -t "${SRCDIR}" | head -n1)"
        local FILEPATH="${SRCDIR}/${DOWNLOADED}"
        case "${DOWNLOADED}" in
            *.tar.gz|*.tgz)       tar -xzf  "${FILEPATH}" -C "${SRCDIR}" && rm -f "${FILEPATH}" ;;
            *.tar.bz2|*.tbz2)     tar -xjf  "${FILEPATH}" -C "${SRCDIR}" && rm -f "${FILEPATH}" ;;
            *.tar.xz|*.txz)       tar -xJf  "${FILEPATH}" -C "${SRCDIR}" && rm -f "${FILEPATH}" ;;
            *.tar.zst)            tar --zstd -xf "${FILEPATH}" -C "${SRCDIR}" && rm -f "${FILEPATH}" ;;
            *.zip)                unzip -q   "${FILEPATH}" -d "${SRCDIR}"  && rm -f "${FILEPATH}" ;;
            *.7z)                 7z x       "${FILEPATH}" -o"${SRCDIR}"   && rm -f "${FILEPATH}" ;;
            *)  info "File does not appear to be an archive; treating as raw binary." ;;
        esac

        info "Binary successfully prepared in ${SRCDIR}"
        return
    fi

    # 1. Try Git first (if GIT_URL is provided)
    if [[ -n "${GIT_URL}" ]]; then
        info "Fetching source via Git clone..."
        git clone --branch "${VERSION}" --recurse-submodules "${GIT_URL}" "${SRCDIR}/source" || \
        git clone --branch "v${VERSION}" --recurse-submodules "${GIT_URL}" "${SRCDIR}/source" || \
        die "git clone failed"

        # Package the clone into the expected tarball format
        mv "${SRCDIR}/source" "${SRCDIR}/${PACKAGE}-${VERSION}"
        tar -czf "${SRCDIR}/${TARNAM}-${VERSION}.tar.gz" -C "${SRCDIR}" "${PACKAGE}-${VERSION}"
        rm -rf "${SRCDIR}/${PACKAGE}-${VERSION}"
    fi

    # 2. Try URL Fallback (if Git didn't run or failed to produce the file)
    if [[ ! -f "${SRCDIR}/${TARNAM}-${VERSION}.tar.gz" ]]; then
        info "Fetching source via URL..."
        
        # Extract URL from .info file
        RAW_DOWNLOAD="$(grep -E '^DOWNLOAD(_x86_64)?=' "${INFO_FILE}" | grep -v 'UNSUPPORTED' | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
        
        if [[ -n "${RAW_DOWNLOAD}" ]]; then
            # Handle potential version mismatches in the URL string
            NEW_URL="${RAW_DOWNLOAD//${OLD_VERSION}/${VERSION}}"
            
            # Download and force the output name to match our expected TARNAM
            curl -fL -o "${SRCDIR}/${TARNAM}-${VERSION}.tar.gz" "${NEW_URL%% *}" || die "Download failed"
        else
            die "Error: No Git URL provided and no Download URL found in ${INFO_FILE}"
        fi
    fi

    # 3. Final Integrity Check
    if [[ -f "${SRCDIR}/${TARNAM}-${VERSION}.tar.gz" ]]; then
        info "Source successfully prepared in ${SRCDIR}"
    else
        die "Source retrieval failed: File not found in ${SRCDIR}"
    fi
}

step_5_stage_and_build() {
    # ── step 5: stage everything and build ────────────────────────────────────────
    BUILD_DIR="$(mktemp -d /tmp/sbo-build-stage.XXXXXX)"

    # 1. Copy the SlackBuild script and metadata files (from Step 1)
    cp -af "${SBO_DIR}/." "${BUILD_DIR}/"

    # 2. Copy the actual source/binary (from Step 4)
    # We use -f to overwrite any "wrapper" tarballs from Step 1 with the real source
    cp -af "${SRCDIR}"/* "${BUILD_DIR}/"

    # Binary mode: use binary.SlackBuild from the script's own directory
    if [[ -n "${BINARY_URL}" ]]; then
        local BINARY_SLACKBUILD="${SCRIPT_DIR}/binary.SlackBuild"
        [[ -f "${BINARY_SLACKBUILD}" ]] || die "binary.SlackBuild not found at '${BINARY_SLACKBUILD}'"
        cp -f "${BINARY_SLACKBUILD}" "${BUILD_DIR}/binary.SlackBuild"
        chmod +x "${BUILD_DIR}/binary.SlackBuild"

        info "========================================Building '${PACKAGE}' version ${VERSION} from binary...========================================"

        (
            cd "${BUILD_DIR}"
            PRGNAM="${PACKAGE}" VERSION="${VERSION}" BINARY_DEST="${BINARY_DEST}" bash binary.SlackBuild
        )
        return
    fi

    # 3. FIX: Handle Naming Mismatch (The bpftool fix)
    # If the script expects 'package.tar.gz' but we have 'package-version.tar.gz',
    # we create a symlink so the SlackBuild finds the right file.
    local VERSIONED_TARBALL="${TARNAM}-${VERSION}.tar.gz"
    local GENERIC_TARBALL="${PACKAGE}.tar.gz"

    if [[ -f "${BUILD_DIR}/${VERSIONED_TARBALL}" && ! -f "${BUILD_DIR}/${GENERIC_TARBALL}" ]]; then
        ln -sf "${VERSIONED_TARBALL}" "${BUILD_DIR}/${GENERIC_TARBALL}"
    elif [[ -f "${BUILD_DIR}/${VERSIONED_TARBALL}" && "${VERSIONED_TARBALL}" != "${GENERIC_TARBALL}" ]]; then
        # Force the generic name to point to our freshly fetched source
        ln -sf "${VERSIONED_TARBALL}" "${BUILD_DIR}/${GENERIC_TARBALL}"
    fi

    chmod +x "${BUILD_DIR}/${PACKAGE}.SlackBuild"

    info "========================================Building '${PACKAGE}' version ${VERSION}...========================================"
    
    (
        cd "${BUILD_DIR}"
        # Run the build. We pass VERSION explicitly in case the script relies on it.
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
