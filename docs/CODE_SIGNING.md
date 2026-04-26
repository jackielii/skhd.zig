# Code Signing & .app Bundle for Accessibility Permissions

## Why Both Are Required

Starting with macOS 15 (Sequoia) and especially macOS 26 (Tahoe) released in September 2025, **two things are required for accessibility permissions to behave well**:

1. **Code signing with a stable identity** — so TCC (Transparency, Consent, Control) recognizes the binary across rebuilds.
2. **An `.app` bundle wrapper** — so the System Settings → Accessibility picker accepts the binary, and so TCC keys the entry by bundle identifier (`com.jackielii.skhd`) instead of by file path.

### What goes wrong without these

- **Without a stable signature** (Zig's default adhoc signing): every rebuild looks like a "different" binary to TCC, permissions reset, you keep seeing "ACCESSIBILITY PERMISSIONS REQUIRED".
- **Without the `.app` bundle** (bare Mach-O): on macOS Tahoe the Accessibility `+` picker silently rejects the binary; the entry never appears in the list. TCC entries that *do* get created are path-based (`client_type=1`) and break on `brew upgrade` because the Cellar version path changes.
- **CVE-2025-43312**: Unsigned services are now blocked from launching on Intel Macs.

### The Solution

Use a **self-signed code signing certificate** (`skhd-cert`) with a stable bundle identifier (`com.jackielii.skhd`), AND wrap the binary in an `.app` bundle. The combination produces TCC entries keyed by bundle ID that survive both rebuilds and Homebrew version upgrades.

## Setting Up Code Signing

### 1. Create a Self-Signed Certificate (One-Time Setup)

`zig build sign` will try to create the cert automatically via `openssl` + `security import`. If that fails (e.g. on some keychain configurations), create it by hand in Keychain Access:

```bash
open "/Applications/Utilities/Keychain Access.app"
```

Then:
1. Menu: **Keychain Access** → **Certificate Assistant** → **Create a Certificate**
2. Name: `skhd-cert`
3. Identity Type: **Self-Signed Root**
4. Certificate Type: **Code Signing**
5. Click **Create**

### 2. Build, Bundle, and Sign

```bash
# Build the bare binary (development iteration)
zig build

# Build skhd.app + sign both the inner Mach-O and the bundle
zig build sign-app

# Equivalent to:
zig build app                          # produces zig-out/skhd.app
./scripts/codesign.sh zig-out/skhd.app # signs both layers
```

### 3. Grant Accessibility Permissions

1. Move or symlink the bundle into `/Applications` (Tahoe's picker prefers paths there):
   ```bash
   ln -sfn "$(pwd)/zig-out/skhd.app" /Applications/skhd.app
   ```
2. Open: **System Settings** → **Privacy & Security** → **Accessibility**
3. Enable the checkbox next to `skhd`
4. Restart skhd

### 4. Done!

Permissions will now **persist across rebuilds** as long as you sign each new build with the same certificate.

## Local Debug Workflow (`zig build run`)

`zig build run` does not run the bare binary at `zig-out/bin/skhd` — on Tahoe, an adhoc-signed bare binary cannot be granted accessibility. Instead it builds and signs a **separate dev bundle** so debug runs have their own TCC slot:

| | Path | Bundle ID | Cert |
|---|---|---|---|
| Prod (`sign-app`) | `zig-out/skhd.app` | `com.jackielii.skhd` | `skhd-cert` |
| Dev (`run`) | `zig-out/skhd-dev.app` | `com.jackielii.skhd.dev` | `skhd-dev-cert` |

The dev cert is auto-created on first `zig build run`. One-time setup: add `zig-out/skhd-dev.app` in **System Settings → Privacy & Security → Accessibility** and toggle it on. Permissions persist across rebuilds because every `zig build run` re-signs with the same `skhd-dev-cert`.

The two bundles never overlap, so debugging never disturbs the prod TCC entry that the Homebrew-installed daemon relies on. If you want to debug without the prod daemon also receiving keypresses, stop it first: `skhd --stop-service`.

To override the dev cert/bundle ID, set `SKHD_CERT` and `SKHD_BUNDLE_ID` before invoking `scripts/codesign.sh` directly.

## Verifying Code Signature

```bash
codesign -dv --verbose=2 ./zig-out/skhd.app
```

Expected output with proper signing:
```
Executable=/path/to/zig-out/skhd.app/Contents/MacOS/skhd
Identifier=com.jackielii.skhd
Format=app bundle with Mach-O thin (arm64)
Authority=skhd-cert
Signed Time=...
TeamIdentifier=not set
Sealed Resources version=2 ...
```

Key things to confirm:
- `Format=app bundle with Mach-O thin (arm64)` — proves the bundle layer is signed, not just the inner binary
- `Authority=skhd-cert` (not "adhoc")
- `Identifier=com.jackielii.skhd` (stable bundle ID)

You can also verify TCC has bundle-ID-keyed entries (rather than path-keyed):
```bash
sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT service, client, client_type FROM access WHERE client='com.jackielii.skhd';"
```
Look for rows with `client_type=0` (bundle ID) — those are the entries that survive rebuilds and `brew upgrade`.

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

### Permissions stop working after replacing the binary in-place

If you `cp` a freshly-built binary on top of an existing path (e.g. into `/opt/homebrew/Cellar/skhd-zig/<ver>/...`), TCC may invalidate the previously-granted entry because the on-disk code signature stops matching the stored requirement (`csreq`). The entry stays in the table with `auth_value=2` but the daemon reports "not granted".

Two ways to recover:

1. **Use the .app bundle approach** (recommended): bundle-ID-keyed TCC entries (`client_type=0`) survive in-place replacements as long as the new binary keeps the same `Identifier` (`com.jackielii.skhd`) and signing certificate. This is why `zig build sign-app` is the right local workflow.

2. **Drop and re-grant**: if you have a stale path-keyed entry blocking re-add, delete it directly:
   ```bash
   sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
     "DELETE FROM access WHERE client LIKE '%skhd%' AND client_type=1;"
   ```
   Then restart skhd and grant fresh.

### "skhd doesn't appear in the Accessibility list"

On macOS Tahoe the Accessibility picker silently rejects bare Mach-O binaries. You need the `.app` bundle. Build with `zig build sign-app`, symlink it into `/Applications`, and add `/Applications/skhd.app` (not the inner binary) in System Settings.

### `--status` says "Not granted" even though the daemon works

`AXIsProcessTrusted()` checks the *responsible* process, which for terminal-launched commands is the terminal, not skhd. The launchd-spawned daemon is the one whose permissions matter — check `launchctl list | grep com.jackielii.skhd` for a non-zero PID, and the log at `~/Library/Logs/skhd.log` for `Event tap created successfully`.

### Permissions still reset after signing

1. Verify the signature: `codesign -dv --verbose=2 ./zig-out/skhd.app`
2. Check that `Authority=skhd-cert` (not "adhoc")
3. Check that `Format=app bundle with Mach-O thin (...)` — bundle layer is signed
4. Check that `Identifier=com.jackielii.skhd` is present
5. Remove old accessibility entries (especially path-keyed ones) and re-add
6. Ensure you're signing with the same certificate each time

### Certificate not found when running `zig build sign`

1. Verify certificate exists: `security find-identity -v -p codesigning`
2. If not found, create it manually using Keychain Access (see step 1 above)
3. The script will provide detailed instructions if the certificate is missing

## References

- [Issue #15: Accessibility permission fails on macOS 26](https://github.com/jackielii/skhd.zig/issues/15)
- [Apple TN2206: macOS Code Signing In Depth](https://developer.apple.com/library/archive/technotes/tn2206/)
- [macOS 26 (Tahoe) Release Notes](https://developer.apple.com/documentation/macos-release-notes/macos-26-release-notes)
