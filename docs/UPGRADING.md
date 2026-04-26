# Upgrading to skhd.zig 0.0.18 (macOS Tahoe compatibility)

Version 0.0.18 ships with a wholesale rework of how skhd integrates with macOS, in response to a series of issues that surfaced on macOS 26 (Tahoe). If you are upgrading from 0.0.17 or earlier, please read the **Required actions** section before installing.

## What changed and why

| Area | Before | After |
|---|---|---|
| Distribution layout | bare Mach-O at `bin/skhd` | `.app` bundle (`skhd.app/Contents/MacOS/skhd`) with bare-binary symlink kept for CLI use |
| TCC entries | path-keyed (`/opt/homebrew/Cellar/.../bin/skhd`) | bundle-ID-keyed (`com.jackielii.skhd`) |
| LaunchAgent commands | `launchctl load -w` / `unload -w` | `launchctl bootstrap` / `bootout` (no persistent disable flag) |
| Plist `ProgramArguments` | version-pinned Cellar path | stable `/opt/homebrew/opt/skhd-zig/...` symlink |
| Plist log path | `/tmp/skhd_$USER.log` (wiped at boot) | `~/Library/Logs/skhd.log` |
| Plist `ThrottleInterval` | 30 s | 10 s |
| `CGEventTapCreate` failures | exit immediately, wait full throttle, repeat | retry up to 10× at 500 ms before giving up |

The combined effect: the daemon comes up reliably after a cold reboot, accessibility permissions persist across `brew upgrade` and rebuilds, and a previous `--stop-service` no longer prevents auto-load on the next login.

## Required actions

These steps assume you installed the previous version via Homebrew. The order matters.

### 1. Stop the old service

```bash
skhd --stop-service
```

### 2. Upgrade

```bash
brew upgrade jackielii/tap/skhd-zig
```

The new formula installs `skhd.app` to `<prefix>/skhd.app`, symlinks the CLI into `bin/skhd`, and creates `/Applications/skhd.app` so macOS Settings can find it.

### 3. Clear the legacy disable flag (if you ever ran the old `--stop-service`)

The old `unload -w` set a flag in launchd's persistent disable list. The new `--start-service` clears it automatically, but it's worth confirming it's gone:

```bash
launchctl print-disabled gui/$(id -u) | grep com.jackielii.skhd
# Expect: "com.jackielii.skhd" => enabled
```

If it shows `disabled`, run:
```bash
launchctl enable gui/$(id -u)/com.jackielii.skhd
```

### 4. Drop stale TCC entries from previous installs

The path-keyed accessibility entries from previous Cellar versions will silently shadow the new bundle-ID entry until removed:

```bash
sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "DELETE FROM access WHERE client LIKE '%skhd-zig%' AND client_type=1;"
```

This deletes only path-keyed (`client_type=1`) rows. The new bundle-ID-keyed (`client_type=0`) entry created when you grant in step 6 below is left untouched on future runs.

### 5. Install the new LaunchAgent plist

```bash
skhd --install-service
```

The plist now points at `/opt/homebrew/opt/skhd-zig/skhd.app/Contents/MacOS/skhd` (stable across `brew upgrade`).

### 6. Grant Accessibility for `skhd.app`

1. Open **System Settings → Privacy & Security → Accessibility**
2. Click `+`, navigate to `/Applications/skhd.app`, add it
3. Toggle the entry on

You will only need to do this once. The bundle-ID-keyed TCC entry now persists across rebuilds and Homebrew upgrades.

### 7. Start

```bash
skhd --start-service
```

Watch the log at `~/Library/Logs/skhd.log`. You should see:

```
info(skhd): Starting event tap
info(skhd): Event tap created successfully. skhd is now running.
```

Or if the daemon hits the early-boot `WindowServer` race once or twice, the new retry loop handles it:
```
warning(event_tap): Event tap creation failed (attempt 1/10), retrying in 500ms...
info(event_tap): Event tap created on attempt 2/10
```

## Notes for source builds

If you build from source rather than installing via Homebrew:

```bash
zig build sign-app                          # produces a signed zig-out/skhd.app
ln -sfn "$(pwd)/zig-out/skhd.app" /Applications/skhd.app
/Applications/skhd.app/Contents/MacOS/skhd --install-service
/Applications/skhd.app/Contents/MacOS/skhd --start-service
```

`zig build` (without `app`) still produces the bare binary at `zig-out/bin/skhd` for quick development iteration — it just won't be visible in the Accessibility picker.

## Troubleshooting

If anything goes sideways, see [docs/CODE_SIGNING.md](CODE_SIGNING.md) — the troubleshooting section there covers stale TCC entries, picker rejections, the misleading `--status` output, and signing problems.
