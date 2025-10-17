#!/bin/bash
set -e

# Configuration
BINARY_PATH="${1:-./zig-out/bin/skhd}"
CERT_NAME="${SKHD_CERT:-skhd-cert}"
BUNDLE_ID="com.jackielii.skhd"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "Code signing skhd binary..."

# Check if binary exists
if [ ! -f "$BINARY_PATH" ]; then
    echo -e "${RED}Error: Binary not found at $BINARY_PATH${NC}"
    echo "Build the project first: zig build"
    exit 1
fi

# Check if certificate exists
if ! security find-certificate -c "$CERT_NAME" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
    echo -e "${YELLOW}Certificate '$CERT_NAME' not found.${NC}"
    echo "Creating self-signed code signing certificate..."
    echo ""

    # Try to create the certificate programmatically
    # Note: This may prompt the user to allow keychain access
    TEMP_DIR=$(mktemp -d)
    TEMP_KEY="$TEMP_DIR/key.pem"
    TEMP_CERT="$TEMP_DIR/cert.pem"
    TEMP_P12="$TEMP_DIR/cert.p12"

    # Generate a private key
    openssl genrsa -out "$TEMP_KEY" 2048 2>/dev/null

    # Generate a self-signed certificate
    openssl req -new -x509 -key "$TEMP_KEY" -out "$TEMP_CERT" -days 3650 \
        -subj "/CN=$CERT_NAME/O=skhd Development/C=US" 2>/dev/null

    # Convert to PKCS12 format for import
    openssl pkcs12 -export -out "$TEMP_P12" -inkey "$TEMP_KEY" -in "$TEMP_CERT" \
        -passout pass: 2>/dev/null

    # Import into login keychain
    if security import "$TEMP_P12" -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign -T /usr/bin/security 2>/dev/null; then
        echo -e "${GREEN}✓ Certificate created successfully${NC}"

        # Set the certificate to always trust for code signing
        # Note: This may require admin password
        CERT_HASH=$(security find-certificate -c "$CERT_NAME" -Z ~/Library/Keychains/login.keychain-db | awk '/SHA-256/ {print $NF}')
        if [ -n "$CERT_HASH" ]; then
            security set-key-partition-list -S apple-tool:,apple: -k "" ~/Library/Keychains/login.keychain-db 2>/dev/null || true
            echo -e "${GREEN}✓ Certificate trust settings updated${NC}"
        fi
    else
        echo -e "${RED}Failed to import certificate programmatically.${NC}"
        echo ""
        echo -e "${YELLOW}Please create a code signing certificate manually:${NC}"
        echo "1. Open Keychain Access (in /Applications/Utilities/)"
        echo "2. Go to: Keychain Access > Certificate Assistant > Create a Certificate"
        echo "3. Name: $CERT_NAME"
        echo "4. Identity Type: Self-Signed Root"
        echo "5. Certificate Type: Code Signing"
        echo "6. Click 'Create'"
        echo ""
        echo "After creating the certificate, run this script again."
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    # Clean up temporary files
    rm -rf "$TEMP_DIR"
    echo ""
fi

# Sign the binary
echo "Signing binary: $BINARY_PATH"
codesign -f -s "$CERT_NAME" -i "$BUNDLE_ID" "$BINARY_PATH"

# Verify the signature
if codesign -v "$BINARY_PATH" 2>/dev/null; then
    echo -e "${GREEN}✓ Successfully signed $BINARY_PATH${NC}"
    echo ""
    echo "Signature details:"
    codesign -dv "$BINARY_PATH" 2>&1 | grep -E "Authority|Identifier|Signature"
else
    echo -e "${RED}✗ Signature verification failed${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}Code signing complete!${NC}"
echo "The binary is now signed with certificate '$CERT_NAME'"
echo ""
echo "Next steps:"
echo "1. Run skhd: $BINARY_PATH"
echo "2. Grant accessibility permissions in System Settings → Privacy & Security → Accessibility"
echo "3. The permissions should persist across rebuilds now"
