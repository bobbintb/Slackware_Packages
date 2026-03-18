#!/bin/bash

set -e

NAME="$1"
GIT_REPO="$2"

if [[ -z "$NAME" || -z "$GIT_REPO" ]]; then
    echo "Usage: $0 <package-name> <git-repo-url>"
    exit 1
fi

# Download build files from sbopkg
echo "Downloading build files for $NAME..."
sbopkg -d "$NAME"

# Find where sbopkg put the build files
SBO_DIR=$(find /var/lib/sbopkg -type d -name "$NAME" 2>/dev/null | head -1)
if [[ -z "$SBO_DIR" ]]; then
    echo "Error: Could not find sbopkg build directory for $NAME"
    exit 1
fi

# Clone the git repo into a temp directory
WORK_DIR=$(mktemp -d)
echo "Cloning $GIT_REPO into $WORK_DIR..."
git clone "$GIT_REPO" "$WORK_DIR/$NAME"

# Copy the SlackBuild and supporting files from sbopkg over the cloned source
echo "Copying build files from sbopkg..."
cp "$SBO_DIR"/*.SlackBuild "$WORK_DIR/$NAME/"
cp "$SBO_DIR"/*.info "$WORK_DIR/$NAME/" 2>/dev/null || true
cp "$SBO_DIR"/slack-desc "$WORK_DIR/$NAME/" 2>/dev/null || true
cp "$SBO_DIR"/doinst.sh "$WORK_DIR/$NAME/" 2>/dev/null || true

# Build
echo "Building $NAME..."
cd "$WORK_DIR/$NAME"
chmod +x "$NAME.SlackBuild"
./"$NAME.SlackBuild"

echo "Done. Package should be in /tmp."
