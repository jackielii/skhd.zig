#!/bin/bash
# Wrap the skhd-grabber binary into a minimal .app bundle so macOS
# Tahoe shows it in System Settings → Privacy & Security and TCC keys
# the Input Monitoring grant on the bundle ID instead of the bare
# binary's path/cdhash. Without bundling, every rebuild changes the
# cdhash and forces re-approval.
#
# usage: make-grabber-app.sh <binary> <app-path> [bundle-id]
set -e

BINARY_PATH="${1:?usage: make-grabber-app.sh <binary> <app-path> [bundle-id]}"
APP_PATH="${2:?usage: make-grabber-app.sh <binary> <app-path> [bundle-id]}"
BUNDLE_ID="${3:-com.jackielii.skhd.grabber}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$REPO_ROOT/assets/Info.plist.grabber.template"
VERSION_FILE="$REPO_ROOT/VERSION"

if [ ! -f "$BINARY_PATH" ]; then
    echo "Error: binary not found at $BINARY_PATH" >&2
    exit 1
fi
if [ ! -f "$TEMPLATE" ]; then
    echo "Error: Info.plist template not found at $TEMPLATE" >&2
    exit 1
fi
if [ ! -f "$VERSION_FILE" ]; then
    echo "Error: VERSION file not found at $VERSION_FILE" >&2
    exit 1
fi

VERSION=$(tr -d '\n' < "$VERSION_FILE")

# Build the new bundle in a temp path, then swap it in atomically.
TMP_APP="${APP_PATH}.tmp"
rm -rf "$TMP_APP"
mkdir -p "$TMP_APP/Contents/MacOS"

sed -e "s/__VERSION__/${VERSION}/g" -e "s/__BUNDLE_ID__/${BUNDLE_ID}/g" \
    "$TEMPLATE" > "$TMP_APP/Contents/Info.plist"

# Inner binary is named skhd-grabber (matches CFBundleExecutable). The
# actual executable lives at Contents/MacOS/skhd-grabber and is what
# launchd / sudo invokes.
cp "$BINARY_PATH" "$TMP_APP/Contents/MacOS/skhd-grabber"
chmod 755 "$TMP_APP/Contents/MacOS/skhd-grabber"

rm -rf "$APP_PATH"
mv "$TMP_APP" "$APP_PATH"
echo "Bundle created at $APP_PATH"
