#!/bin/bash
set -e

# Configuration
TARGET_PATH="${1:-./zig-out/bin/skhd}"
CERT_NAME="${SKHD_CERT:-skhd-cert}"
BUNDLE_ID="${SKHD_BUNDLE_ID:-com.jackielii.skhd}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "Code signing skhd..."

# Resolve target: accept either a bare Mach-O binary or a .app bundle.
if [ -d "$TARGET_PATH" ] && [[ "$TARGET_PATH" == *.app ]]; then
    APP_PATH="$TARGET_PATH"
    INNER_BINARY="$APP_PATH/Contents/MacOS/skhd"
    if [ ! -f "$INNER_BINARY" ]; then
        echo -e "${RED}Error: $APP_PATH does not contain Contents/MacOS/skhd${NC}"
        exit 1
    fi
elif [ -f "$TARGET_PATH" ]; then
    APP_PATH=""
    INNER_BINARY="$TARGET_PATH"
else
    echo -e "${RED}Error: $TARGET_PATH not found (expected a binary or a .app bundle)${NC}"
    echo "Build the project first: zig build (or zig build app)"
    exit 1
fi

# Check if certificate exists
if ! security find-certificate -c "$CERT_NAME" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
    echo -e "${YELLOW}Certificate '$CERT_NAME' not found.${NC}"
    echo "Creating self-signed code signing certificate..."
    echo ""

    TEMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TEMP_DIR"' EXIT
    TEMP_KEY="$TEMP_DIR/key.pem"
    TEMP_CERT="$TEMP_DIR/cert.pem"
    TEMP_P12="$TEMP_DIR/cert.p12"
    TEMP_CONFIG="$TEMP_DIR/openssl.cnf"

    # Generate openssl config that marks the cert as critical for codeSigning EKU.
    # Without the codeSigning EKU, `security find-identity -p codesigning` filters
    # the cert out and codesign cannot use it.
    cat > "$TEMP_CONFIG" <<EOF
[req]
distinguished_name = req_dn
prompt = no
x509_extensions = v3_ca

[req_dn]
CN = $CERT_NAME
O = skhd Development
C = US

[v3_ca]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

    openssl genrsa -out "$TEMP_KEY" 2048 2>/dev/null

    openssl req -new -x509 -key "$TEMP_KEY" -out "$TEMP_CERT" -days 3650 \
        -config "$TEMP_CONFIG" 2>/dev/null

    # macOS `security import` rejects empty-password p12 files produced by
    # OpenSSL 3+ ("MAC verification failed during PKCS12 import"). Use a
    # throwaway password and pass it to both export and import. The cert
    # itself isn't password-protected once in the keychain.
    P12_PASS="skhd-cert-import"

    # OpenSSL 3+ uses a stronger PKCS12 MAC by default that older `security`
    # tools can't read. -legacy falls back to the algorithm macOS understands.
    openssl pkcs12 -export -legacy -out "$TEMP_P12" -inkey "$TEMP_KEY" -in "$TEMP_CERT" \
        -passout "pass:$P12_PASS" 2>/dev/null

    if security import "$TEMP_P12" -k ~/Library/Keychains/login.keychain-db -P "$P12_PASS" \
        -T /usr/bin/codesign -T /usr/bin/security >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Certificate created successfully${NC}"
        # Allow codesign to use the key without prompting on every invocation.
        security set-key-partition-list -S apple-tool:,apple: -k "" \
            ~/Library/Keychains/login.keychain-db >/dev/null 2>&1 || true
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
        exit 1
    fi
    echo ""
fi

if [ -n "$APP_PATH" ]; then
    # Sign inner-out: Mach-O first, then the bundle.
    echo "Signing inner binary: $INNER_BINARY"
    codesign -f -s "$CERT_NAME" -i "$BUNDLE_ID" "$INNER_BINARY"
    echo "Signing bundle: $APP_PATH"
    codesign -f -s "$CERT_NAME" -i "$BUNDLE_ID" "$APP_PATH"
    VERIFY_TARGET="$APP_PATH"
else
    echo "Signing binary: $INNER_BINARY"
    codesign -f -s "$CERT_NAME" -i "$BUNDLE_ID" "$INNER_BINARY"
    VERIFY_TARGET="$INNER_BINARY"
fi

if codesign -v "$VERIFY_TARGET" 2>/dev/null; then
    echo -e "${GREEN}✓ Successfully signed $VERIFY_TARGET${NC}"
    echo ""
    echo "Signature details:"
    codesign -dv --verbose=2 "$VERIFY_TARGET" 2>&1 | grep -E "Authority|Identifier|Signature|Format"
else
    echo -e "${RED}✗ Signature verification failed${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}Code signing complete!${NC}"
if [ -n "$APP_PATH" ]; then
    echo "The bundle is now signed with certificate '$CERT_NAME'"
    echo ""
    echo "Next steps:"
    echo "1. Add $APP_PATH in System Settings → Privacy & Security → Accessibility"
    echo "2. Toggle the entry on"
    echo "3. Run: skhd --install-service && skhd --start-service"
else
    echo "The binary is now signed with certificate '$CERT_NAME'"
    echo ""
    echo "Next steps:"
    echo "1. Run skhd: $INNER_BINARY"
    echo "2. Grant accessibility permissions in System Settings → Privacy & Security → Accessibility"
    echo "3. The permissions should persist across rebuilds now"
fi
