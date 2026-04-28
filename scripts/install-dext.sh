#!/bin/bash
# Download + install the pinned Karabiner-DriverKit-VirtualHIDDevice .pkg.
#
# usage: install-dext.sh <version> <url> <expected-sha256>
#
# Idempotent: re-running with the same version is a no-op once the dext
# is already installed at that version. The .pkg is cached under
# $ZIG_GLOBAL_CACHE_DIR (or ~/.cache/zig) so subsequent runs skip the
# download.
#
# Invoked by `zig build install-dext`. Pinned constants live in
# build.zig — bump there, not here.
set -euo pipefail

if [ $# -ne 3 ]; then
    echo "usage: $0 <version> <url> <expected-sha256>" >&2
    exit 2
fi

VERSION="$1"
URL="$2"
EXPECTED_SHA="$3"

CACHE_ROOT="${ZIG_GLOBAL_CACHE_DIR:-$HOME/.cache/zig}/karabiner-dext"
mkdir -p "$CACHE_ROOT"
PKG="$CACHE_ROOT/Karabiner-DriverKit-VirtualHIDDevice-${VERSION}.pkg"

if [ ! -f "$PKG" ]; then
    echo "Downloading Karabiner-DriverKit-VirtualHIDDevice ${VERSION}..."
    echo "  $URL → $PKG"
    curl -fsSL -o "$PKG" "$URL"
fi

ACTUAL_SHA=$(shasum -a 256 "$PKG" | awk '{print $1}')
if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
    echo "error: sha256 mismatch for $PKG" >&2
    echo "  expected: $EXPECTED_SHA" >&2
    echo "  got:      $ACTUAL_SHA" >&2
    # Drop the cached file so the next run fetches fresh — but don't
    # auto-retry here, in case the upstream release was retagged
    # legitimately and the user needs to bump the pinned hash.
    rm -f "$PKG"
    exit 1
fi

echo "Installing Karabiner-DriverKit-VirtualHIDDevice ${VERSION}..."
echo "  (sudo will prompt for your password — installer needs root to register the dext)"
sudo /usr/sbin/installer -pkg "$PKG" -target /

echo
echo "Done. macOS may now prompt to approve the system extension in"
echo "System Settings → Privacy & Security → Allow system software."
echo "Approve it, then run: skhd --install-service"
