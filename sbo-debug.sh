#!/bin/bash
set -euo pipefail

# --- Configuration ---
SBO_ROOT="/var/lib/sbopkg"

# --- Argument Parsing ---
PACKAGE="${1:?Usage: $0 <package> [version]}"
VERSION="${2:-}"

# --- Step 1: Sync / Download ---
if [ -d "/__w/Slackware_Packages/Slackware_Packages/SlackBuilds/${PACKAGE}" ]; then
    echo ">>> Local workspace detected. Syncing..."
    DEST_DIR="${SBO_ROOT}/SBo/15.0/development/${PACKAGE}"
    mkdir -p "$(dirname "$DEST_DIR")"
    cp -af "/__w/Slackware_Packages/Slackware_Packages/SlackBuilds/${PACKAGE}/." "$DEST_DIR/"
    SBO_DIR="$DEST_DIR"
else
    echo ">>> Workspace not found. Falling back to sbopkg..."
    # FIX: Pass -e and -d as separate, unquoted tokens
    sbopkg -b -e continue -d "${PACKAGE}"
    SBO_DIR="$(find "${SBO_ROOT}" -type d -name "${PACKAGE}" | head -n1)"
fi

# --- Step 2: Validation ---
if [[ -z "${SBO_DIR}" || ! -f "${SBO_DIR}/${PACKAGE}.SlackBuild" ]]; then
    echo "ERROR: SlackBuild for ${PACKAGE} not found."
    exit 1
fi

echo "---------------------------------------------------------"
echo " VALIDATION SUCCESSFUL"
echo " Package:  ${PACKAGE}"
echo " Path:     ${SBO_DIR}"
echo " Build:    ${PACKAGE}.SlackBuild"
echo "---------------------------------------------------------"

# --- Step 3: Stop ---
echo "TEST MODE: Skipping actual build execution."
exit 0
