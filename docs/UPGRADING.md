# Upgrading to skhd.zig 0.0.21 (macOS Tahoe compatibility)

> **0.0.21 fixes the actual root cause of "skhd doesn't start on reboot".** The 0.0.18 rework was correct on packaging and signing but missed the gatekeeper: macOS Background Tasks Manager (BTM) silently marked any hand-installed LaunchAgent as `disallowed`. 0.0.21 switches to `SMAppService`, which gets a proper `[enabled, allowed, notified]` BTM entry that auto-loads at every login.
>
> If you upgraded to 0.0.18–0.0.20 and skhd still doesn't always start after reboot, **0.0.21 is the fix you want**.

## Migrating from 0.0.20 → 0.0.21

```bash
brew upgrade skhd-zig

# Re-register via SMAppService. The `skhd` shim brew puts on PATH is a
# symlink into the bundle's inner binary, so SMAppService still sees the
# correct calling bundle and BTM gets a clean managed entry:
skhd --install-service

# Verify
skhd --status
# Expect: Registration status: enabled
#         Daemon running: Yes (PID …)
#         Hotkeys functional: Yes (event tap active)
```

That's it. Your accessibility grant carries over (TCC entry is bundle-ID-keyed, the cert hasn't changed), and BTM now has a proper managed entry that auto-loads on every reboot.

The old `disallowed` legacy BTM entry from previous versions is harmless once the new managed entry is in place — but you can clean it up via System Settings → General → Login Items & Extensions if you like.

## What `brew upgrade` does for you (post-0.1.1)

The formula's `post_install` hook now runs `skhd --start-service` automatically after every install and upgrade. That means:

- **Legacy `~/Library/LaunchAgents/com.jackielii.skhd.plist` gets booted out and deleted.** If you ever installed a pre-0.0.21 version, this orphan plist shadowed the SMAppService registration on Tahoe — same `Label`, two definitions, launchd refused to spawn either (`EX_CONFIG`, `108: Invalid path: Contents/MacOS/skhd`). It's now cleaned up on every upgrade.
- **SMAppService rebinds to the current Cellar bundle path.** The previous version's binding pointed at the now-deleted `Cellar/<old-version>/skhd.app`; the post_install re-registration picks up the new path.
- **The daemon still self-heals the cdHash/TCC mismatch** on the first event-tap attempt after the new binary spawns (see the section below). You may still need to re-toggle the Accessibility entry in System Settings once per upgrade — the daemon will print a single short instruction line in the log when this happens, instead of the previous wall of text repeated every 10 seconds.

If something looks wrong after a `brew upgrade`, the canonical recovery is still one command:

```bash
skhd --start-service   # idempotent — same as what post_install just ran
skhd --status          # verify
```

## If keys stop working after `brew upgrade` (macOS Tahoe)

On macOS 15+ (Tahoe), TCC stores Input Monitoring grants with a **csreq anchored to the binary's cdHash** rather than the signing cert root. Every rebuild produces a new cdHash, so a brew upgrade silently invalidates the grant — the System Settings entry still shows as **granted**, but no events flow into the daemon.

Symptoms:
- `skhd --status` shows the daemon running, but hotkeys don't fire.
- System Settings → Privacy & Security → Accessibility (and/or Input Monitoring) shows skhd as enabled.
- `~/Library/Logs/skhd.log` shows the event tap was created but no key activity.

**Since 0.1.2 the daemon does this automatically** when it's launchd-managed: on the first event-tap creation failure it calls `tccutil reset` itself, writes a marker at `~/Library/Caches/com.jackielii.skhd/tcc_auto_reset_at` to avoid reset loops on subsequent respawns, and emits a single short "go re-toggle in Settings" line in the log. You only need to perform step 2 below.

If you're on an older release or the auto-reset failed, the manual fix is:

```bash
# 1. Drop the stale grants so macOS will store a fresh, cert-root-anchored csreq
tccutil reset ListenEvent com.jackielii.skhd
tccutil reset Accessibility com.jackielii.skhd
skhd --restart-service

# 2. Re-toggle the entry in System Settings → Privacy & Security → Accessibility
#    (or accept the prompt if one appears). The first hotkey press triggers the
#    Input Monitoring prompt — approve it.
```

This issue recurs on every brew upgrade until Apple loosens the anchor policy; `skhd --status` includes the same fix in its remediation output when the tap is detected as denied.

## Migrating from 0.0.17 or earlier (the original Tahoe rework)

Version 0.0.18 introduced the `.app` bundle structure and `~/Library/Logs/skhd.log`. If you're coming from 0.0.17 or earlier you also need to perform the steps below before the SMAppService re-register above.

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

The new formula installs `skhd.app` to `<prefix>/skhd.app` (e.g. `/opt/homebrew/opt/skhd-zig/skhd.app`) and symlinks the CLI into `bin/skhd`. macOS will prompt for Accessibility on first launch via the popup deep-link — no manual `+`/navigate step in System Settings.

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

`skhd --install-service` triggers the macOS Accessibility prompt with a deep-link to the right pane. In the dialog, click **Open System Settings** and toggle the **skhd** entry on — no manual `+`/navigate step needed.

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
