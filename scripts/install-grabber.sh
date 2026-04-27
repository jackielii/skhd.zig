#!/bin/bash
# Install skhd-grabber as a system LaunchDaemon.
#
# usage: install-grabber.sh <built-binary>
#
# Requires sudo: copies the binary to /usr/local/libexec, writes a
# plist to /Library/LaunchDaemons, and bootstraps the daemon into the
# system domain. Re-runs are idempotent (bootout first, then bootstrap).
#
# This script is invoked by `skhd --install-grabber`, which forwards
# the path of the locally-built binary as $1.
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_BINARY="${1:?usage: install-grabber.sh <built-binary>}"

LABEL="com.jackielii.skhd.grabber"
INSTALL_BIN="/usr/local/libexec/skhd-grabber"
INSTALL_PLIST="/Library/LaunchDaemons/${LABEL}.plist"
TEMPLATE_PLIST="${REPO_ROOT}/scripts/${LABEL}.plist"

if [ "$EUID" -ne 0 ]; then
    echo "error: must run as root (sudo skhd --install-grabber)" >&2
    exit 1
fi

if [ ! -f "$SRC_BINARY" ]; then
    echo "error: built binary not found at $SRC_BINARY" >&2
    echo "       run 'zig build' first" >&2
    exit 1
fi

if [ ! -f "$TEMPLATE_PLIST" ]; then
    echo "error: plist template not found at $TEMPLATE_PLIST" >&2
    exit 1
fi

echo "Installing $SRC_BINARY → $INSTALL_BIN"
mkdir -p "$(dirname "$INSTALL_BIN")"
cp "$SRC_BINARY" "$INSTALL_BIN"
chown root:wheel "$INSTALL_BIN"
chmod 0755 "$INSTALL_BIN"

echo "Installing plist → $INSTALL_PLIST"
cp "$TEMPLATE_PLIST" "$INSTALL_PLIST"
chown root:wheel "$INSTALL_PLIST"
chmod 0644 "$INSTALL_PLIST"

# bootout any prior incarnation so bootstrap doesn't trip on
# "Bootstrap failed: already loaded".
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    echo "Stopping previous instance..."
    launchctl bootout system "$INSTALL_PLIST" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
        launchctl print "system/$LABEL" >/dev/null 2>&1 || break
        sleep 0.3
    done
fi

echo "Loading daemon..."
launchctl bootstrap system "$INSTALL_PLIST"
launchctl enable "system/$LABEL" 2>/dev/null || true
launchctl kickstart -k "system/$LABEL" 2>/dev/null || true

# Brief pause for the daemon to bind its socket so --grabber-status
# right after install reports "running" instead of "socket absent".
sleep 0.4

echo
echo "Done. Daemon status:"
launchctl print "system/$LABEL" 2>/dev/null | head -20 || true
echo
echo "Logs: /var/log/skhd-grabber.log"
echo "Socket: /var/run/skhd/grabber.sock"
