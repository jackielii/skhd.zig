#!/bin/bash
# Wrap the skhd binary into a minimal .app bundle so macOS Tahoe / Sequoia
# accept it for accessibility permission grants. The bundle structure also
# makes TCC entries bundle-ID-keyed (com.jackielii.skhd) instead of path-keyed,
# so permissions persist across `brew upgrade`.
set -e

BINARY_PATH="${1:?usage: make-app.sh <binary> <app-path>}"
APP_PATH="${2:?usage: make-app.sh <binary> <app-path>}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$REPO_ROOT/assets/Info.plist.template"
VERSION_FILE="$REPO_ROOT/VERSION"

if [ ! -f "$BINARY_PATH" ]; then
    echo "Error: binary not found at $BINARY_PATH" >&2
    exit 1
fi
if [ ! -f "$TEMPLATE" ]; then
    echo "Error: Info.plist template not found at $TEMPLATE" >&2
    exit 1
fi

VERSION=$(tr -d '\n' < "$VERSION_FILE")

# Build the bundle next to a temp path then move into place atomically so a
# failed signing run does not leave a half-written bundle.
TMP_APP="${APP_PATH}.tmp"
rm -rf "$TMP_APP" "$APP_PATH"
mkdir -p "$TMP_APP/Contents/MacOS"

sed "s/__VERSION__/${VERSION}/g" "$TEMPLATE" > "$TMP_APP/Contents/Info.plist"
cp "$BINARY_PATH" "$TMP_APP/Contents/MacOS/skhd"
chmod 755 "$TMP_APP/Contents/MacOS/skhd"

mv "$TMP_APP" "$APP_PATH"
echo "Bundle created at $APP_PATH"
