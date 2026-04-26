#!/bin/bash
# Install the local skhd build into /Applications/skhd.app (the slot a brew
# install would occupy) and restart the SMAppService daemon. Lets you test
# the packaged path — real bundle ID, real launchd registration, real TCC
# slot — without cutting a release.
#
# First install on a fresh box requires a one-time accessibility re-grant
# because the local skhd-cert keypair differs from CI's; subsequent installs
# reuse the same local cert so the TCC entry stays valid.
#
# usage: install-local.sh <built-binary>
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_BINARY="${1:?usage: install-local.sh <built-binary>}"

PROD_LABEL="com.jackielii.skhd"
DOMAIN="gui/$(id -u)"

# Prefer /Applications/skhd.app (the symlink brew creates); fall back to the
# brew opt dir. The OS dereferences the symlink for cp / codesign so we don't
# need to resolve it manually.
APP_PATH="/Applications/skhd.app"
if [ ! -d "$APP_PATH" ]; then
    APP_PATH="/opt/homebrew/opt/skhd-zig/skhd.app"
fi
if [ ! -d "$APP_PATH" ]; then
    echo "Error: prod skhd.app not found at /Applications or brew opt path" >&2
    echo "Install once via 'brew install jackielii/tap/skhd-zig' before using install-local." >&2
    exit 1
fi

INNER_DST="$APP_PATH/Contents/MacOS/skhd"
PROD_PLIST="$APP_PATH/Contents/Library/LaunchAgents/${PROD_LABEL}.plist"

if [ ! -f "$SRC_BINARY" ]; then
    echo "Error: built binary not found at $SRC_BINARY" >&2
    exit 1
fi
if [ ! -f "$PROD_PLIST" ]; then
    echo "Error: prod LaunchAgent plist not found at $PROD_PLIST" >&2
    exit 1
fi

echo "Prod app:    $APP_PATH"
echo "Replacing:   $INNER_DST"

# KeepAlive would respawn the old binary mid-write, so unload first.
was_loaded=0
if launchctl print "$DOMAIN/$PROD_LABEL" >/dev/null 2>&1; then
    was_loaded=1
    echo "Stopping prod service..."
    launchctl bootout "$DOMAIN/$PROD_LABEL" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        launchctl print "$DOMAIN/$PROD_LABEL" >/dev/null 2>&1 || break
        sleep 0.2
    done
fi

cp "$SRC_BINARY" "$INNER_DST"
chmod 755 "$INNER_DST"

echo "Signing with skhd-cert (prod bundle id)..."
SKHD_CERT="skhd-cert" SKHD_BUNDLE_ID="$PROD_LABEL" \
    bash "$REPO_ROOT/scripts/codesign.sh" "$APP_PATH" >/dev/null

echo "Starting prod service..."
if launchctl bootstrap "$DOMAIN" "$PROD_PLIST" 2>/dev/null; then
    :
elif [ "$was_loaded" = "1" ] && launchctl kickstart -k "$DOMAIN/$PROD_LABEL" 2>/dev/null; then
    :
else
    echo "Warning: launchctl bootstrap failed — run 'skhd --start-service' to recover." >&2
fi

echo
echo "Deployed locally-built skhd → $APP_PATH"
echo "If hotkeys stop working, the local skhd-cert is fresh and differs from"
echo "the cert TCC has on file. Open System Settings → Privacy & Security →"
echo "Accessibility and toggle skhd off and back on (one-time re-grant)."
