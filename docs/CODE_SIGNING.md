# Code Signing for Accessibility Permissions

## Why Code Signing is Required

Starting with macOS 15 (Sequoia) and especially macOS 26 (Tahoe) released in September 2025, **code signing with a stable identity is required** for accessibility permissions to persist across builds.

### The Problem

- **macOS TCC (Transparency, Consent, and Control)** uses code signatures to track accessibility permissions
- Adhoc signatures (Zig's default) cause macOS to treat each build as a "different" binary
- **CVE-2025-43312**: Unsigned services are now blocked from launching on Intel Macs
- This results in constant permission resets and "ACCESSIBILITY PERMISSIONS REQUIRED" warnings

### The Solution

Use a **self-signed code signing certificate** with a stable identity (bundle identifier: `com.jackielii.skhd`) to ensure TCC recognizes the binary across rebuilds.

## Setting Up Code Signing

### 1. Create a Self-Signed Certificate (One-Time Setup)

```bash
# Open Keychain Access
open "/Applications/Utilities/Keychain Access.app"
```

Then in Keychain Access:
1. Menu: **Keychain Access** → **Certificate Assistant** → **Create a Certificate**
2. Name: `skhd-cert`
3. Identity Type: **Self-Signed Root**
4. Certificate Type: **Code Signing**
5. Click **Create**

### 2. Build and Sign

```bash
# Build the project
zig build

# Sign the binary
zig build sign

# Alternatively, use the script directly:
./scripts/codesign.sh ./zig-out/bin/skhd
```

### 3. Grant Accessibility Permissions

1. Run skhd: `./zig-out/bin/skhd`
2. Go to: **System Settings** → **Privacy & Security** → **Accessibility**
3. Enable the checkbox next to `skhd`
4. Restart skhd

### 4. Done!

Permissions will now **persist across rebuilds** as long as you sign each new build with the same certificate.

## Verifying Code Signature

Check the signature status:

```bash
codesign -dv ./zig-out/bin/skhd
```

Expected output with proper signing:
```
Executable=/path/to/skhd
Identifier=com.jackielii.skhd
Format=Mach-O thin (arm64)
CodeDirectory v=20400 size=XXXX flags=0x0(none) hashes=XXX+0 location=embedded
Signature size=XXXX
Authority=skhd-cert
Signed Time=...
Info.plist=not bound
TeamIdentifier=not set
```

Key differences from adhoc signature:
- `Authority=skhd-cert` (not "adhoc")
- `Identifier=com.jackielii.skhd` (stable bundle ID)

## CI/CD Compatibility

Code signing is **optional** for CI environments:
- Builds will succeed without signing
- GitHub Actions and other CI systems don't need certificates
- Local development requires signing for accessibility permissions to persist

## Homebrew Installation

For users installing via Homebrew:
1. The formula will attempt to create a certificate and sign the binary automatically
2. Users will be prompted to grant accessibility permissions once
3. Permissions will persist across Homebrew updates

## Troubleshooting

### "codesign wants to sign using key in your keychain"

This is normal - click **Always Allow** to avoid repeated prompts.

### Permissions still reset after signing

1. Verify the signature: `codesign -dv ./zig-out/bin/skhd`
2. Check that `Authority=skhd-cert` (not "adhoc")
3. Check that `Identifier=com.jackielii.skhd` is present
4. Remove old accessibility permissions and re-add
5. Ensure you're signing with the same certificate each time

### Certificate not found when running `zig build sign`

1. Verify certificate exists: `security find-identity -v -p codesigning`
2. If not found, create it manually using Keychain Access (see step 1 above)
3. The script will provide detailed instructions if the certificate is missing

## References

- [Issue #15: Accessibility permission fails on macOS 26](https://github.com/jackielii/skhd.zig/issues/15)
- [Apple TN2206: macOS Code Signing In Depth](https://developer.apple.com/library/archive/technotes/tn2206/)
- [macOS 26 (Tahoe) Release Notes](https://developer.apple.com/documentation/macos-release-notes/macos-26-release-notes)
