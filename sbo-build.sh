step_4_fetch_source() {
    # Creates Temp Storage: Initializes a secure temporary directory (SRCDIR)
    SRCDIR="$(mktemp -d /tmp/sbo-src.XXXXXX)"
    trap 'rm -rf "${SRCDIR}"' EXIT

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
    fi

    # Dynamic URL Fallback: Only runs if still missing, NOT in local mode, and no Git URL worked
    if [[ ! -f "${SRCDIR}/${TARNAM}-${VERSION}.tar.gz" && "${LOCAL_MODE}" != "true" ]]; then
        RAW_DOWNLOAD="$(grep -E '^DOWNLOAD(_x86_64)?=' "${INFO_FILE}" | grep -v 'UNSUPPORTED' | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
        NEW_URL="${RAW_DOWNLOAD//${OLD_VERSION}/${VERSION}}"
        curl -fL -o "${SRCDIR}/$(basename "${NEW_URL%% *}")" "${NEW_URL%% *}" || die "Download failed"
    fi

    # Ensures Integrity: Final check to make sure we actually got the source
    local FINAL_TARBALL="${SRCDIR}/${TARNAM}-${VERSION}.tar.gz"
    if [[ -f "${FINAL_TARBALL}" ]]; then
        info "Source prepared: $(basename "${FINAL_TARBALL}") located at ${FINAL_TARBALL}"
    else
        die "Source retrieval failed: No tarball found or generated."
    fi
}
