#!/bin/bash
# Wrap the skhd binary into a minimal .app bundle so macOS Tahoe / Sequoia
# accept it for accessibility permission grants. The bundle structure also
# makes TCC entries bundle-ID-keyed (com.jackielii.skhd) instead of path-keyed,
# so permissions persist across `brew upgrade`.
set -e

BINARY_PATH="${1:?usage: make-app.sh <binary> <app-path> [bundle-id]}"
APP_PATH="${2:?usage: make-app.sh <binary> <app-path> [bundle-id]}"
BUNDLE_ID="${3:-com.jackielii.skhd}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$REPO_ROOT/assets/Info.plist.template"
LAUNCH_AGENT_PLIST="$REPO_ROOT/assets/LaunchAgent.plist"
VERSION_FILE="$REPO_ROOT/VERSION"

if [ ! -f "$BINARY_PATH" ]; then
    echo "Error: binary not found at $BINARY_PATH" >&2
    exit 1
fi
if [ ! -f "$TEMPLATE" ]; then
    echo "Error: Info.plist template not found at $TEMPLATE" >&2
    exit 1
fi
if [ ! -f "$LAUNCH_AGENT_PLIST" ]; then
    echo "Error: LaunchAgent.plist not found at $LAUNCH_AGENT_PLIST" >&2
    exit 1
fi
if [ ! -f "$VERSION_FILE" ]; then
    echo "Error: VERSION file not found at $VERSION_FILE" >&2
    exit 1
fi

VERSION=$(tr -d '\n' < "$VERSION_FILE")

# Build the new bundle in a temp path, then swap it in only after every step
# has succeeded. If any command above the swap fails, set -e aborts and the
# previously-installed $APP_PATH is left intact.
TMP_APP="${APP_PATH}.tmp"
rm -rf "$TMP_APP"
mkdir -p "$TMP_APP/Contents/MacOS"
mkdir -p "$TMP_APP/Contents/Library/LaunchAgents"

sed -e "s/__VERSION__/${VERSION}/g" -e "s/__BUNDLE_ID__/${BUNDLE_ID}/g" \
    "$TEMPLATE" > "$TMP_APP/Contents/Info.plist"
# SMAppService.agent(plistName:) reads its target launchd plist from the
# bundle's Contents/Library/LaunchAgents/<plistName>. Filename matches
# the bundle id so the runtime register call can find it by passing
# "${BUNDLE_ID}.plist".
cp "$LAUNCH_AGENT_PLIST" "$TMP_APP/Contents/Library/LaunchAgents/${BUNDLE_ID}.plist"
cp "$BINARY_PATH" "$TMP_APP/Contents/MacOS/skhd"
chmod 755 "$TMP_APP/Contents/MacOS/skhd"

rm -rf "$APP_PATH"
mv "$TMP_APP" "$APP_PATH"
echo "Bundle created at $APP_PATH"
