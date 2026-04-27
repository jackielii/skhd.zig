#!/bin/bash
# Uninstall the skhd-grabber LaunchDaemon.
#
# usage: uninstall-grabber.sh
#
# Requires sudo: stops the daemon, removes the plist and binary.
# Karabiner-DriverKit-VirtualHIDDevice (the dext) is NOT removed —
# users who want to uninstall that should do it via pqrs.org's
# uninstaller (Karabiner-Elements may also depend on it).
set -e

LABEL="com.jackielii.skhd.grabber"
INSTALL_BIN="/usr/local/libexec/skhd-grabber"
INSTALL_PLIST="/Library/LaunchDaemons/${LABEL}.plist"
SOCKET_DIR="/var/run/skhd"

if [ "$EUID" -ne 0 ]; then
    echo "error: must run as root (sudo skhd --uninstall-grabber)" >&2
    exit 1
fi

if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    echo "Stopping daemon..."
    launchctl bootout system "$INSTALL_PLIST" 2>/dev/null || true
fi

if [ -f "$INSTALL_PLIST" ]; then
    echo "Removing plist..."
    rm -f "$INSTALL_PLIST"
fi

if [ -f "$INSTALL_BIN" ]; then
    echo "Removing binary..."
    rm -f "$INSTALL_BIN"
fi

# Best-effort cleanup of the socket dir; harmless if it doesn't exist.
if [ -d "$SOCKET_DIR" ]; then
    rm -f "$SOCKET_DIR/grabber.sock"
    rmdir "$SOCKET_DIR" 2>/dev/null || true
fi

echo "Done. (Karabiner DriverKit dext was not touched.)"
