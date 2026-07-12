# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased](https://github.com/jackielii/skhd.zig/compare/v0.1.11...HEAD)

## [0.1.11](https://github.com/jackielii/skhd.zig/compare/v0.1.10...v0.1.11) - 2026-07-12

### Fixed
- **Post-wake keyboard death where the device's IOKit registry ID did not change (mode-3 dead keyboard).** The 0.1.10 sleep-fix released and re-acquired the seize around every sleep transition; 0.1.9's DeviceNotify re-seized on re-enumeration. A third failure mode remained: after certain wake cycles the built-in keyboard's IOKit ID was unchanged — no re-enumeration event fired, the power-on path re-seized the same handle, yet keystrokes stopped flowing. The grabber now **verifies** the seize is live after every `kIOMessageSystemHasPoweredOn` by confirming event delivery; if the check times out it tears down and rebuilds the seize against the current device set. Closes the last documented dead-keyboard scenario without requiring a lid cycle or cord flip.
- **Fix #50.**

### Added
- **vhidd heartbeat watchdog — replaces the unreliable wake ready-probe.** A recurring heartbeat tests the vhidd transport on a short interval and declares it broken on the first missed reply, triggering the existing fail-open + reconnect path. The prior approach (a one-shot probe immediately after `kIOMessageSystemHasPoweredOn`) fired only at the moment of wake; if vhidd stalled seconds later there was no detection until the next key event failed. The heartbeat timer is re-armed in-place on each successful reply — no timer-object churn per heartbeat.
- **Master restore key — in-keyboard escape hatch for a dead grabber.** A configurable fn-key (observed without seizing, so it always reaches the OS) acts as a trigger: holding it for a short burst fires a full vhidd-connection + HID-seize teardown and rebuild — the same recovery as the lid-cycle + cord-flip sequence documented in `docs/`. The observer logs the full device set it holds at the observe stage so the chosen key is visible in the log. Provides a recovery path when SSH or a lid cycle is impractical.
- **Recovery documentation.** `docs/` gains a recovery ladder covering the full sequence for an unresponsive keyboard (lid cycle → cord flip → master restore key) and calls out `skhd --restart-service` as the first step when recovering over SSH.

### Changed
- **Power and battery diagnostics expanded (Debug/ReleaseSafe builds).** The grabber now logs every IOKit power-source transition (battery → AC and back, percentage changes) and every raw IOKit power message, including non-sleep transitions that were previously invisible. The restore-key observer also logs the devices it holds at startup. All new lines are compiled out of ReleaseFast so production logs stay quiet.

## [0.1.10](https://github.com/jackielii/skhd.zig/compare/v0.1.9...v0.1.10) - 2026-06-24

### Fixed
- **skhd-grabber no longer dead-keys the built-in keyboard across sleep (the remaining case).** 0.1.9 made the grabber re-seize when the keyboard *re-enumerates* on wake, but the keyboard could still come back dead with its IOKit registry id *unchanged* — so nothing re-enumerated, the re-enumeration watch correctly fired nothing, and re-seizing the same device in place couldn't revive it. Root cause: the grabber held its `IOHIDManager` seize *across* the sleep power transition, so when the keyboard powered down mid-sleep the seized connection went stale (on wake the device still reported present, but no events flowed). The grabber now **releases the seize before sleep and re-acquires a fresh one on wake** — it never holds the seize across the power transition (the same lifecycle Karabiner's grabber uses: devices are ungrabbable while the system is sleeping). On `kIOMessageSystemWillSleep` it tears down the seize and acks the sleep after a short delay so the release lands before the device loses power; on `kIOMessageSystemHasPoweredOn` it re-seizes against the now-healthy device. Validated across an 11-day soak with a single long-lived grabber process surviving multiple sleep cycles (including ~2-day and ~8-day suspends) with zero dead-keyboard recurrences.

### Added
- **`skhd --status` now reports both daemons' versions.** It prints the running `skhd` version and the running `skhd-grabber` version — the grabber's is queried live over IPC, so it reflects the actually-running daemon and surfaces an "agent updated but grabber not restarted" mismatch at a glance.

### Changed
- **`skhd-grabber --version` reports the real version** (it previously printed a hardcoded `skhd-grabber (D1 skeleton)` placeholder).
- **Grabber log timestamps and noise.** Every grabber log line is now prefixed with a local `[YYYY-MM-DD HH:MM:SS]` timestamp so events line up with `pmset -g log` across multi-day idle periods. Routine per-wake events (keyboard re-seizes, device enumeration changes) and informational startup lines were demoted to `info`, so a release build's log grows only on genuine anomalies — important for a daemon meant to run for months without a restart.

## [0.1.9](https://github.com/jackielii/skhd.zig/compare/v0.1.8...v0.1.9) - 2026-06-12

### Fixed
- **Release builds no longer crash on Intel Macs (#46).** Signed x86_64 release binaries died at startup with SIGILL/SIGBUS in whatever function happened to sit first in the text section (`Keycodes.init`, `Parser.init`). Root cause is upstream [ziglang/zig#23704](https://github.com/ziglang/zig/issues/23704): Zig's MachO linker emits zero headerpad on x86_64, so Apple's `codesign` silently writes its `LC_CODE_SIGNATURE` load command over the first bytes of `__TEXT,__text`, corrupting the first function's prologue (arm64 was unaffected because Zig already reserves an ad-hoc signature load command there; unsigned binaries ran fine, and Debug builds escaped by layout luck). Both `skhd` and `skhd-grabber` now reserve `0x1000` of headerpad — the same amount Apple's clang/ld64 leaves — so signing no longer touches code. Verified by diffing `__text` across a `codesign` run: previously the prologue bytes were replaced by the signature load command, now they're untouched. Thanks @UnixMonky for the patient round-trips that pinned this down!
- **skhd-grabber recovers the keyboard after DarkWake/hibernate.** The 0.1.7 sleep/wake fix re-seized on the system power-on notification, but a DarkWake or hibernate cycle re-enumerates the keyboard *without* sending power-on, so the grabber kept holding a dead device and the built-in keyboard came back unresponsive. The grabber now watches the keyboard's IOService directly (`IOServiceAddMatchingNotification`, `kIOFirstMatch` + `kIOTerminated`, in the new `src/grabber/DeviceNotify.zig`) and re-seizes whenever the device re-appears — event-driven, no polling, the same approach Karabiner's grabber uses. This replaces the power-notification path (`PowerNotify.zig` is gone). Reproduced via scheduled DarkWake and validated across a real hibernate cycle.

## [0.1.8](https://github.com/jackielii/skhd.zig/compare/v0.1.7...v0.1.8) - 2026-06-07

### Fixed
- **Built-in keyboard remaps no longer leak onto external keyboards (#47).** The `(0,0)` built-in `.device` alias matched on keyboard usage alone, so the grabber seized every connected keyboard and a `[device builtin]` remap could intermittently fire on an external one. The match is now scoped to the internal-bus transport (FIFO/SPI), capturing only the built-in keyboard. Thanks @ingara!
- **`skhd --status` reports hotkey health reliably.** It used to print `Unknown` for ~30s after start and on installed builds, because it guessed from process uptime and log scraping; it now reads the event tap's live state directly via `CGGetEventTapList`.

### Added
- **`skhd --status` shows skhd-grabber health when your config needs it** — required (and for which device), installed, running, and IPC reachable — for configs with tap-hold (`.remap` block-form) rules. Other configs stay quiet.

## [0.1.7](https://github.com/jackielii/skhd.zig/compare/v0.1.6...v0.1.7) - 2026-05-29

### Added
- **Intel (x86_64) Macs install via Homebrew again.** The release pipeline already cross-compiled an `skhd-x86_64-macos.tar.gz` from the arm64 runner, but the Homebrew cask was arm64-only — so `brew install jackielii/tap/skhd-zig` refused to install on Intel. `Casks/skhd-zig.rb` is now dual-arch: an `arch arm: "arm64", intel: "x86_64"` stanza drives `skhd-#{arch}-macos.tar.gz`, with per-arch `sha256 arm:/intel:` checksums, and the `depends_on arch: :arm64` restriction is dropped. release.yml's `update-homebrew` job now rewrites both checksum lines on each release (anchored on the 64-hex value so the `arch` stanza's `arm:`/`intel:` keys are left alone).

### Fixed
- **Built-in keyboards with no IOKit VendorID/ProductID now match correctly (#45).** Some Macs (e.g. M3 Max MacBook Pro, `Mac15,10`) drive the built-in keyboard over Apple's FIFO transport, which exposes no `VendorID`/`ProductID` in the IOKit registry. The three matching paths each mishandled this: `IOHIDManager` matching with `{VendorID:0, ProductID:0}` requires the properties to *exist*, so the seize (`HidSeize`) and presence check (`DeviceCheck`) matched zero devices, while `hidutil`'s `--matching '{"VendorID":0,"ProductID":0}'` treated 0/0 as a wildcard and applied the `UserKeyMapping` to *every* connected keyboard. Now: for a 0/0 alias, `HidSeize.setMatches` and `DeviceCheck.isPresent` omit the VID/PID keys (the Generic Desktop / Keyboard usage filter keeps the match to keyboards) and confirm at least one matched device genuinely lacks a `VendorID` (the Karabiner VHIDD, which *does* carry one, is excluded — and un-seized after open to avoid a feedback loop); `Hidutil.buildMatching` scopes 0/0 to `{Built-In:1, PrimaryUsagePage:1, PrimaryUsage:6}` so only the internal keyboard is touched. All three paths now key on `PrimaryUsagePage`/`PrimaryUsage` so they agree on the device set, `--list-devices` shows VID-less keyboards as `vendor: 0x0, product: 0x0` instead of skipping them, and a partial-zero alias (one ID zero, one not) now warns loudly.
- **Layer-hold + modifier-hold chord no longer occasionally drops the layer.** Holding space (→ `fn_layer`, layer rule) and caps_lock (→ `lctrl`, modifier rule with `permissive_hold`) and tapping a nested key — e.g. `space + caps - h` expected to resolve through the agent's `fn_layer < ctrl - h | ctrl - left` mapping — would intermittently land bare `ctrl-h` at the OS instead. The two rules ran as independent FSMs in the grabber; caps's `permissive_hold` fires on `h↑` and emitted `ctrl + h` to vhidd before space's 200ms timer ever pushed the layer, so the agent saw the chord without the layer context. The fix adds a dispatch-level arbitration hook (`TapHold.arbitration_hook`) invoked from `doHoldCommit`. When a non-layer slot is about to commit, dispatch forces any peer slot still pending on a layer rule to push its layer first; the layer's buffered events are split so the committing slot's own buffer flush covers shared nested keys without double-emitting them, while any prefix the layer alone witnessed (events that arrived before the modifier started pending) is replayed under the layer before the modifier-down lands. The tap path and single-rule timer-fire paths are untouched; modifier-tap roll-over behavior is unchanged.
- **skhd-grabber no longer dead-keys the built-in keyboard after sleep/wake.** After the lid was closed for several minutes, the built-in keyboard could come back dead on wake: the grabber's `IOHIDManager` held device references that deep sleep silently invalidated and never re-enumerated, so it sat in its run loop receiving no input while the keyboard stayed seized — the grabber process looked healthy (CFRunLoop parked in `mach_msg`, IPC + vhidd sockets connected) but no keystrokes flowed. The grabber now registers for system power notifications (`IORegisterForSystemPower`, in the new `src/grabber/PowerNotify.zig`) and, on `kIOMessageSystemHasPoweredOn`, re-runs `applyLatestRules` — the same path an agent re-apply takes — tearing down and rebuilding the vhidd connection and the HID seize against the post-wake device set. Verified against a real 17-minute clamshell sleep. Diagnostic logging for this path (and new device matched/removed logging in `HidSeize.zig`) is `info`-level, so it is compiled out of the ReleaseFast release and does not accumulate on users' machines; build ReleaseSafe to trace it.

## [0.1.6](https://github.com/jackielii/skhd.zig/compare/v0.1.4...v0.1.6) - 2026-05-24

### Added
- **`NSMicrophoneUsageDescription` in the app bundle Info.plist.** Lets hotkeys that shell out to audio-recording tools (voice-transcription commands, etc.) trigger the microphone TCC prompt instead of being silently denied. The string surfaces in System Settings → Privacy & Security → Microphone as "Allow skhd to launch hotkeys that record audio, such as voice transcription commands."

## [0.1.4](https://github.com/jackielii/skhd.zig/compare/v0.1.3...v0.1.4) - 2026-05-23

> First release distributed as a Homebrew **cask** (replacing the formula). `brew install jackielii/tap/skhd-zig` now installs `skhd.app` directly into `/Applications`, which the formula required users to do manually via `ln -sfn`.

### Added
- **`--list-devices` prints connected HID keyboards as paste-ready `.device` blocks.** Authors of `.remap` / `.taphold` rules previously had to grep `hidutil list` (hundreds of SMC sensor rows alongside the actual keyboards) and copy VendorID/ProductID by hand. The new flag enumerates devices via `IOHIDManager` with a `DeviceUsagePage:1 / DeviceUsage:6` match dict, dedupes on `(vendor, product)` since IOKit returns one entry per HID interface (e.g. HHKB exposing both Keyboard and Consumer Control), slugifies the product name into a default alias, and prints a copy-paste-ready `.device` block per device. A footnote flags that mouse receivers advertising a keyboard usage (Logitech Unifying et al.) will also show up — they really do present that usage, so filtering them would be a heuristic that hides legitimate config targets.

### Changed
- **Homebrew distribution switched from formula to cask.** The cask installs the signed `skhd.app` bundle into `/Applications`, runs `xattr -dr com.apple.quarantine` in `postflight` to clear Gatekeeper's quarantine flag on the self-signed binary, and surfaces the CLI on `PATH` via the cask's `binary` stanza pointing at `skhd.app/Contents/MacOS/skhd`. Uninstall stops the user LaunchAgent via `launchctl`. release.yml's `update-homebrew` job seds `Casks/skhd-zig.rb`'s `version` + `sha256` lines (the cask's `url` interpolates `#{version}` so no URL rewrite is needed); the arm64-only cask drops the x86_64 sed steps from the previous formula bump.

### Fixed
- **skhd-grabber no longer dead-keys the keyboard when the Karabiner vhidd transport drops.** Two compounding gaps were leaving the keyboard seized while every re-injection failed:
  1. `isTransportError`'s allowlist was too narrow (`SendFailed` / `ShortWrite` only). `ConnectionResetByPeer`, `BrokenPipe`, `Unexpected` — exactly the errors the OS surfaces when the Karabiner daemon resets the socket — fell through to the "no-op" branch, so `markVhiddBroken` was never called and the seize was never released. Classification is now flipped: any post error means the pipe is dead. Only our-side logic bugs (`PayloadTooLarge`, `TooManyKeys`) are excluded — a reconnect can't fix a malformed report.
  2. `applyLatestRules`'s `teardownSeize` ran AFTER the (blocking, up-to-5s) vhidd lazy-connect. On a fresh apply with a stale seize and a dead vhidd, the old seize was held for the full 5s timeout. `teardownSeize` now runs before the vhidd connect so the physical keyboard is never seized while we're blocked (re)connecting.

  Net effect: any vhidd failure now reliably triggers fail-open + reconnect (matching v0.1.3's recovery contract for the case where the socket simply resets rather than the daemon process exiting).

## [0.1.3](https://github.com/jackielii/skhd.zig/compare/v0.1.2...v0.1.3) - 2026-05-16

### Fixed
- **skhd-grabber no longer dead-keys the keyboard when the Karabiner vhidd_server connection breaks.** Before: the grabber kept the keyboard `IOHIDDeviceOpen(seize)`-d while every `postKeyboardReport` returned `SendFailed`, so real keystrokes were silently dropped — keyboard appeared dead until reboot. Now: on transport failure, the grabber latches a `vhidd_broken` flag, schedules a one-shot `CFRunLoopTimer`, and from that callback (running between runloop sources, not inside the IOHIDManager value callback) tears down seize so keys fall through to the OS, closes the dead client, and reconnects via the existing `applyLatestRules` lazy-connect path. Backoff progresses 1s → 2s → 5s → 10s capped, matching Karabiner-Elements' 1s reconnect baseline. Triggered by Karabiner daemon restart, dext deactivation, or vhidd server crash.
- **`IOHIDSetModifierLockState failed: 0xE00002C2` log spam.** This call fails permanently (`kIOReturnNotPermitted`) when the binary isn't signed with a real Apple Developer ID. One broken-grabber session produced ~5500 of these lines in `/var/log/skhd-grabber.log`. Now latched after the first failure with a "suppressing further attempts" hint, then becomes a no-op.

## [0.1.2](https://github.com/jackielii/skhd.zig/compare/v0.1.1...v0.1.2) - 2026-05-09

### Fixed
- **`brew upgrade` now actually restarts the service.** The Homebrew formula gained a `post_install` hook that runs `skhd --start-service` after every install/upgrade. Without this, an upgrade left the user-level legacy plist at `~/Library/LaunchAgents/com.jackielii.skhd.plist` (from any pre-0.0.21 install) shadowing the SMAppService registration on Tahoe — same `Label`, two definitions, and launchd refused to spawn either with `EX_CONFIG` (`108: Invalid path: Contents/MacOS/skhd`). The post_install hook chains through `installService → cleanupLegacyInstall → registerWithBTM`, so the orphan plist gets booted out and removed and BTM rebinds to the current Cellar bundle path automatically.
- **Daemon self-heals stale TCC grants after binary swaps.** Every `brew upgrade` rebuilds the binary, the cdHash changes, and TCC silently invalidates the Input Monitoring grant — System Settings still shows the entry as granted, `IOHIDCheckAccess` returns denied, and key events never reach the tap. Previously launchd respawned the agent every 10s with the giant "ACCESSIBILITY PERMISSIONS REQUIRED" wall of text in the log on every cycle until the user noticed and ran the two `tccutil reset` commands by hand. The agent now detects this case (event tap creation fails AND `IOHIDCheckAccess == denied` AND we're launchd-managed) and runs `tccutil reset ListenEvent / Accessibility com.jackielii.skhd` itself, then logs a single short "go re-toggle in Settings" message and exits. A marker file at `~/Library/Caches/com.jackielii.skhd/tcc_auto_reset_at` rate-limits this to once per 10 minutes so subsequent throttled respawns don't keep wiping the grant out from under the user before they get a chance to re-grant.

## [0.1.1](https://github.com/jackielii/skhd.zig/compare/v0.1.0...v0.1.1) - 2026-05-05

### Added
- **`--start-service` is now the canonical "make sure skhd is set up and running" entry point.** Idempotent and safe to re-run; same flow as `--install-service` — registers the agent with BTM, then smart-prompts to install skhd-grabber via sudo if your config has `.remap` / `.taphold` / `fn_layer` rules and a target device is connected. Single command users reach for whether installing fresh, recovering from a stopped agent, or re-running after a `brew upgrade`.

### Fixed
- **`--install-grabber` could leave the system in a half-broken state with no diagnostic.** Three layered issues conspired: `runLaunchctl` discarded launchctl's stderr/stdout so the actual error was never seen; `main.zig` swallowed grabber CLI errors with `catch std.process.exit(1)`, dropping the error name; and the `bootout`-then-`bootstrap` sequence had no delay between calls — macOS's `bootout` is async, so a follow-up `bootstrap` issued immediately can race the prior teardown and fail with EIO. Fixes:
  - `runLaunchctl` prints stderr/stdout when launchctl exits non-zero.
  - Grabber CLI commands (`--install-grabber`, `--install-dext`, `--uninstall-grabber`, `--grabber-status`, `--grabber-test-rule`) print the error name before exit-1.
  - New `bootstrapService` helper: bootout → 300ms sleep → bootstrap (with one 800ms-delayed retry on failure) → enable → kickstart. Shared between `installGrabber` and `installVhiddDaemon`.
  - After the launchctl chain, `installGrabber` verifies `launchctl print system/<label>` succeeds and aborts with `error.GrabberRegistrationFailed` if not — catches the silent-failure mode where the plist is on disk but the service isn't registered.

## [0.1.0](https://github.com/jackielii/skhd.zig/compare/v0.0.24...v0.1.0) - 2026-05-04

> Major release introducing **skhd-grabber** — a system daemon that handles caps_lock-class tap-hold rules through HID seize, enabling QMK-style keyboard remapping that the user-session-level event tap can't reach. The wire format between agent and grabber and the new `.remap` / `.taphold` / `.device` directives are now considered stable.

### Added
- **`.remap` / `.taphold` / `.device` directives** for QMK-style keyboard remapping. Two paths depending on what the rule needs:
  - **Colon-form `.remap key : key`** — drives `hidutil`'s `UserKeyMapping` table directly. Works for non-conflicting remaps (e.g. swap `caps_lock` → `escape`); doesn't need the grabber. Original mappings are saved on startup and restored on shutdown so the keyboard isn't left remapped when skhd exits.
  - **Block-form `.remap { ... }` and `.taphold key : tap, hold, ...`** — handled by skhd-grabber, which seizes the keyboard at the IOKit/HID level via Karabiner-DriverKit and rewrites events before they reach the OS event chain. Required for caps_lock-class rules (the kernel layer above `hidutil` silently drops `caps_lock → modifier` mappings on Tahoe), modifier-as-hold rules, and any rule that needs to distinguish tap vs hold by timing.
  - **`.device "alias" vendor=0xVVVV product=0xPPPP`** scopes rules to a specific keyboard. A config shared between a laptop and an external keyboard targets only the relevant device.
  - **Layer holds** — `key : tap, hold: <mode>` switches skhd into a temporary mode for the duration of the hold and back when released. Push IPC from grabber → agent so layer modes activate on the agent's run loop.
- **`skhd-grabber`** — system daemon (LaunchDaemon, root) for the HID-seize path. Installed via `sudo skhd --install-grabber`. Communicates with the agent over a Unix socket at `/var/run/skhd/grabber.sock`. Per-uid rule filtering tracks the active console user so fast-user-switching does the right thing. The agent forwards rules on every config load (and re-forwards on hot-reload + auto-reconnect after a grabber restart).
- **`skhd --install-dext`** — downloads the pinned Karabiner-DriverKit-VirtualHIDDevice `.pkg` (URL + SHA-256 verified in-process via `std.crypto`), runs `installer -pkg`, self-elevates via `sudo` if not root. Cached at `~/.cache/skhd/` (or `/tmp/` under root) so re-runs skip the download. Runs entirely from the binary — no external scripts needed, so brew users get the same code path as `zig build install-dext`.
- **`skhd --install-service` auto-installs the dext** when grabber is needed and the dext is missing. Brew install becomes one command:
  ```
  brew install jackielii/tap/skhd-zig
  skhd --install-service     # registers agent, installs dext if missing, registers grabber
  ```
- **`HID daemon` line in `skhd --status`** — surfaces the four-state probe (`not_installed` / `plist_unregistered` / `stopped` / `running`) plus the installed dext version, with state-specific remediation. Catches the broken-launchd-registration case where the dext is loaded but `launchctl print system/<label>` returns "could not find service" (kickstart can't recover; needs a `.pkg` reinstall).
- **`Input Monitoring` line in `skhd --status`** — calls `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` directly. Catches the silent cdHash-mismatch case (#36) where the grant looks granted in System Settings but TCC's stored csreq is anchored to a stale cdHash from a previous build, so key-down events are silently dropped before reaching skhd's event tap. Includes the `tccutil reset ListenEvent com.jackielii.skhd` workaround.
- **Karabiner-Elements conflict warning** — `--status` and `--install-grabber` flag when `karabiner_grabber` is running, since both daemons compete for HID seize.
- **Bundle-shared TCC for skhd-grabber** — the grabber runs from inside `skhd.app/Contents/MacOS/skhd-grabber` instead of being copied to `/usr/local/libexec/`. Both binaries are signed with `-i com.jackielii.skhd`, so a single Input Monitoring grant on skhd.app covers both processes via TCC's bundle keying. No more separate "add the grabber binary path to Input Monitoring" step.
- **Auto VHIDD daemon launchd registration** — `--install-dext` writes the LaunchDaemon plist for `org.pqrs.service.daemon.Karabiner-VirtualHIDDevice-Daemon` after the `.pkg` installer runs. Without this, the daemon never registers with launchd on machines without Karabiner-Elements (which historically provided the launchd entry via SMAppService). Coexistence-aware: skipped when launchd already has the label registered.
- **Interactive Input Monitoring auto-prompt** — `--install-service` calls `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` after a successful grabber install, popping the system IM dialog while the user is at a terminal. Same UX as the Accessibility auto-pop; no manual System Settings navigation.
- **`--uninstall-service` post-uninstall hints** — surfaces follow-up cleanup commands (skhd-grabber, VHIDD daemon, pqrs uninstaller) when those pieces are still on disk so users don't forget the sudo step.

### Changed
- **Karabiner DriverKit version is pinned** in `build.zig` (currently v6.14.0). `--status` and `--install-grabber` compare the installed version against the pinned major; same major is treated as wire-compatible (pqrs follows SemVer), older major refuses to proceed with a remediation pointer to `zig build install-dext`, newer major proceeds with an "untested" advisory. Bump procedure documented inline above the constants.
- **`scripts/install-dext.sh` removed** in favor of the in-binary `--install-dext` subcommand. Removes shell duplication and means the dev path (`zig build install-dext`) and brew path (`skhd --install-dext`) share the same code.
- **`scripts/install-grabber.sh` and `scripts/uninstall-grabber.sh` removed** — install/uninstall logic moved into Zig (`grabber_cli.zig`) with the LaunchDaemon plist embedded via `@embedFile`. Works from any cwd (a brew bundle without a checked-out repo can still install). Uninstall also tears down the VHIDD daemon's launchd registration if `--install-dext` put it there.
- **`make-app.sh` bundles `skhd-grabber` into `skhd.app/Contents/MacOS/`** — release tarballs and `zig build install-local` ship both binaries inside the bundle. `codesign.sh` signs both inner Mach-Os with the bundle ID so the bundle's seal stays valid.

### Fixed
- **`Hotkeys functional` false negative in `--status`** — the log-tail scan now anchors on the current daemon's `(PID N)` start marker so stale `ACCESSIBILITY PERMISSIONS REQUIRED` lines from prior crashed instances no longer poison the read. Returns `Unknown` instead of `Denied` when the marker isn't in the read window yet.

### Internal
- **Toolchain upgraded to Zig 0.16.** `std.Io` is plumbed through `Skhd` / `Mappings` / `Hotload` / `Parser` / `CarbonEvent` / `TrackingAllocator` as a struct field set at init, and through `service` / `grabber_cli` per call. `main()` takes `std.process.Init` so gpa, io, arena, and args come from the runtime. File I/O moves to `std.Io.Dir` / `std.Io.File`, process spawning to `std.process.spawn(io, ...)` / `std.process.run(gpa, io, ...)`, unix sockets to `std.Io.net.UnixAddress`. Format methods adopt the new `(self, w: *std.Io.Writer)` signature.
- **`mappings.tapholds` / `mappings.remaps` / `mappings.device_aliases`** — parser and runtime data for the new directives.
- **`grabber_protocol`** — shared module defining the agent ↔ grabber wire format. Versioned (`protocol_version`) so handshake mismatches surface clearly. Currently v2.
- **Daemon refactored around `CFRunLoop`-driven IPC listener** so the agent can react to grabber pushes (layer-hold mode changes) without polling.
- **`Hidutil.zig`** — parses + merges existing `UserKeyMapping` so colon-form `.remap` doesn't clobber whatever System Settings → Modifier Keys (or other tooling) already set. Restores on shutdown.
- **Test surface expanded** to cover `RuleSet` parsing, the IPC framing, `KbState` / `TapHold` state machines, and the new HID-daemon version compat helpers.

## [0.0.24](https://github.com/jackielii/skhd.zig/compare/v0.0.23...v0.0.24) - 2026-04-28

### Fixed
- **v0.0.23 binaries refused to launch on macOS 15.x** with `You can't use this version of the application 'skhd' with this version of macOS.` (#35). Without an explicit `os_version_min`, Zig stamps the Mach-O's `LC_BUILD_VERSION minos` with the build host's OS version, and the `macos-latest` CI runner is now Tahoe 26 — so the binary's minimum-OS field jumped past Sequoia. `build.zig` now pins `os_version_min` to 13.0 (matching `Info.plist`'s `LSMinimumSystemVersion` and the SMAppService floor); setting `os_version_min` flips Zig out of native-SDK mode, so the build also probes `xcrun` once and threads the SDK's framework / include / lib paths into every artifact.
- **`PATH` inheritance under SMAppService now works for users without `SHELL` set, and fails loudly when it doesn't.** v0.0.22's `$SHELL -ilc` approach silently returned the launchd minimal `PATH` in several real cases: `SHELL` was unset under launchd, or `-i` triggered shell-specific weirdness with no controlling tty (zsh `compinit` warnings, fish prompt probes, rc files assuming a tty). `detectLoginShell` now prefers `$SHELL` and falls back to `getpwuid(getuid()).pw_shell` — the same Open Directory source `login(1)` uses, so it resolves even when launchd doesn't set `SHELL`. `capturePath` uses shell-specific argv: fish runs `-c 'string join : $PATH'` (fish's `PATH` is a list and `config.fish`/`conf.d` are always sourced), bash/zsh run `-lc 'printenv PATH'` (`-l` sources `~/.zprofile` / `~/.bash_profile` where Homebrew's `shellenv` lives, dropping `-i` avoids the interactive-init noise). Every failure path now logs at `warn` so the breakdown appears in `~/Library/Logs/skhd.log` instead of being invisible, and the final inherited PATH is logged so users can see what skhd actually resolved.

### Added
- **`.path` directive for explicit PATH additions.** Escape hatch for the cases where shell-inherited `PATH` isn't enough — mostly version-manager shims (mise/asdf/nvm) which only land in `PATH` via shell hooks that `-lc` doesn't always trigger, and any directory the user wants resolved before system tools of the same name. Single-entry and list forms (matching `.shell` / `.blacklist` style):
  ```
  .path "/opt/homebrew/bin"
  .path [
      "$HOME/.local/share/mise/shims"
      "~/bin"
  ]
  ```
  `~` and `$HOME` expand at parse time; no arbitrary `$VAR` because parse-time env can differ from command-exec-time env. Entries are prepended to `PATH` after the shell-inherited `PATH` is resolved (declaration order preserved), so explicit user paths take precedence.

### Changed
- **x86_64 prebuilt releases are back, paused since v0.0.19.** Instead of spinning up a `macos-13` Intel runner (slow queue, on GitHub's deprecation timeline), the arm64 runner cross-compiles via `-Dtarget=x86_64-macos.13.0`. The macOS SDK is universal so x86_64 stubs are present, and `codesign` on arm64 signs x86_64 Mach-Os fine.

### Internal
- **Portable `BOOL` marshalling in `sm_app_service.zig` for x86_64.** Apple's `objc.h` gates `BOOL` on `__OBJC_BOOL_IS_BOOL`, which Clang only sets for arm64-darwin — so `c.BOOL` translates to Zig `bool` on arm64 but to `i8` on x86_64, and the existing `if (!ok)` only typechecked on arm64. The `objc_msgSend` return is now declared `u8` (both archs return `BOOL` in the low byte regardless of C-level typedef) with explicit `!= 0` comparisons. Unblocks the cross-compile.

## [0.0.23](https://github.com/jackielii/skhd.zig/compare/v0.0.22...v0.0.23) - 2026-04-26

### Fixed
- **Event tap now actually detaches on Accessibility revoke.** v0.0.22 relied on `kCGEventTapDisabledByUserInput` firing when Accessibility was toggled off at runtime, but the callback isn't actually fired in that case — the OS just stops delivering events to the tap, leaving the keyboard captured with no signal `keyHandler` could react to. The one-shot recovery timer is replaced with an always-on 1 s `CFRunLoopTimer` that reconciles the tap with `AXIsProcessTrusted` in both directions: detach proactively on revoke, recreate on re-grant. `AXIsProcessTrusted` is cached at the OS level and runs in ~µs, so the poll has no measurable overhead and the keydown / `NX_SYSDEFINED` hot path is untouched.
- **Daemon log lines actually reach `~/Library/Logs/skhd.log`.** SMAppService's bundled `LaunchAgent.plist` sets no `StandardErrorPath`, so stderr went to `/dev/null` and every `log.err` / `log.info` from the daemon was silently dropped. Stderr is now redirected to the log file when the process is launchd-managed (detected by `XPC_SERVICE_NAME != "0"` — the variable is set to the placeholder `"0"` for normal user-shell processes, so a plain null-check matched everything). Foreground `-V` runs and `zig build`-spawned subprocesses keep stderr at the terminal/pipe.
- **`std_options.log_level` floored at `.warn`** so the session-start marker (`=== skhd <ver> started at <iso ts> (PID N) ===`) survives ReleaseFast builds, which would otherwise filter everything below `.err`.

### Changed
- **Foreground runs use silent `AXIsProcessTrusted` instead of `AXIsProcessTrustedWithOptions(prompt: true)`.** The TCC dialog popped on every `zig build run` / `zig build alloc` iteration was noise, and on Tahoe TCC mis-displays the path when self-signed dev/prod bundles share a `com.jackielii.skhd*` prefix. The daemon install path still prompts on first install.

### Internal
- **`zig build alloc` is routed through the dev `.app` + sign chain** so the alloc binary inherits the dev TCC slot. A bare Mach-O can't be granted Accessibility on Tahoe, so the previous setup couldn't actually run end-to-end.

## [0.0.22](https://github.com/jackielii/skhd.zig/compare/v0.0.21...v0.0.22) - 2026-04-26

### Fixed
- **Event tap survives runtime Accessibility revoke.** When Accessibility was toggled off while skhd was running, macOS sent `kCGEventTapDisabledByUserInput` and the in-place `CGEventTapEnable` retry silently failed — the tap stayed in the event chain as an active filter that couldn't forward events, leaving the keyboard unresponsive until skhd was killed. The tap is now detached on the disabled callback, and a 1 s `CFRunLoopTimer` watches for `AXIsProcessTrusted` to flip back and recreates the tap on re-grant. `EventTap.deinit` also cleans up when the tap is system-disabled, not just when `enabled()`.
- **`--status` no longer false-negatives in the first 30 s after daemon start.** `getEventTapHealth` scanned the daemon log for the `ACCESSIBILITY PERMISSIONS REQUIRED` marker, but SMAppService routes the daemon's stderr to `/dev/null`, so stale denial lines from previous runs dominated the tail. The log scan is now skipped when the log file is older than the running daemon, and reports `unknown` in that window instead.

### Changed
- **Daemon sources `PATH` from `$SHELL -ilc` at startup.** Hotkeys that exec `/opt/homebrew/bin/yabai`, `/opt/homebrew/bin/aerospace`, etc. previously failed under launchd's minimal `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`). The interactive-login shell is queried once at startup so command lookups match what the user sees in their terminal.

### Internal
- **`zig build install-local`** stages the local build into the brew-installed bundle in place (preferring `/Applications/skhd.app` if you've manually symlinked it there, otherwise `/opt/homebrew/opt/skhd-zig/skhd.app`), re-signs with `skhd-cert`, and restarts the SMAppService daemon — for testing the packaged path without cutting a release.

## [0.0.21](https://github.com/jackielii/skhd.zig/compare/v0.0.20...v0.0.21) - 2026-04-26

### Fixed
- **The actual root cause of "skhd doesn't always start after reboot" on macOS Tahoe.** Hand-installed LaunchAgents under `~/Library/LaunchAgents/` get registered with macOS's Background Tasks Manager (BTM, introduced in Sequoia, enforced in Tahoe) as `Type: legacy agent` with `Disposition: [enabled, disallowed, not notified]` — and BTM silently refuses to auto-load them at login until the user manually approves the agent in System Settings → General → Login Items & Extensions. The previous fixes (launchctl bootstrap migration, retry loops, plist paths) addressed real but secondary issues; BTM was the gatekeeper all along.

### Changed
- **`--install-service` now uses `SMAppService`** instead of writing to `~/Library/LaunchAgents/`. The bundled plist lives inside `skhd.app/Contents/Library/LaunchAgents/com.jackielii.skhd.plist` and registration goes through `SMAppService.agent(plistName:).register()`. BTM creates a proper managed entry (`Type: agent`, `Disposition: [enabled, allowed, notified]`) that auto-loads cleanly at every login.
- **`--uninstall-service`** now unregisters via SMAppService. Both install and uninstall also clean up any pre-0.0.21 hand-installed plist at `~/Library/LaunchAgents/com.jackielii.skhd.plist` so the legacy and new managed entries don't race.
- **`--status`** reads SMAppService registration state directly. Reports `Registration status: enabled` / `requires approval` / `not registered` so the user knows what BTM thinks.

### Migration
On upgrade from 0.0.20 or earlier, run `skhd --install-service` once. The brew-installed `skhd` shim is a symlink into the bundle, so SMAppService gets the right calling bundle automatically; if you're running a source build, invoke the inner binary directly (`<path-to>/skhd.app/Contents/MacOS/skhd --install-service`). The legacy `disallowed` BTM entry from previous versions is harmless after the new managed entry is in place but can be removed via System Settings → General → Login Items & Extensions if desired. See [docs/UPGRADING.md](docs/UPGRADING.md) for the full walkthrough.

## [0.0.20](https://github.com/jackielii/skhd.zig/compare/v0.0.19...v0.0.20) - 2026-04-26

Local-development quality-of-life release. No runtime changes.

### Internal
- **`zig build run` now produces a signed dev `.app` bundle** at `zig-out/skhd-dev.app`, signed with a separate `skhd-dev-cert` and bundle ID `com.jackielii.skhd.dev`. On macOS Tahoe, an adhoc-signed bare binary cannot be granted Accessibility, so `zig build run` previously failed with permission errors during local debugging. The dev TCC slot is fully isolated from the prod entry (`com.jackielii.skhd` + `skhd-cert`) used by the Homebrew install, and re-signing every build keeps permissions stable across rebuilds. See [docs/CODE_SIGNING.md](docs/CODE_SIGNING.md#local-debug-workflow-zig-build-run).
- **First-run Accessibility popup.** `AXIsProcessTrustedWithOptions(prompt=true)` is now called before event tap setup so unknown bundles surface the macOS popup and System Settings deep-link, instead of failing silently after 10 retries.
- **`AccessibilityPermissionDenied` error message** prefers the `.app` bundle that actually contains the running binary over `/Applications/skhd.app`, so the displayed path matches what a grant would apply to.
- **`scripts/codesign.sh`** reads `SKHD_BUNDLE_ID` env var (defaults to `com.jackielii.skhd`).
- **`scripts/make-app.sh`** accepts an optional bundle ID as the third argument.

## [0.0.19](https://github.com/jackielii/skhd.zig/compare/v0.0.18...v0.0.19) - 2026-04-26

Small follow-up to v0.0.18 fixing a reporting bug.

### Fixed
- **`--status` reported `Hotkeys functional: No` while the daemon was actually working.** The previous logic read the daemon log's tail looking for "Event tap created successfully" markers — but ReleaseFast (Homebrew's build mode) suppresses `log.info`, so the log stayed silent on success and old failure entries dominated. The daemon's event tap was active, only the status reporter was misled. Now uses process uptime via `sysctl(kern.proc.pid)` as the primary signal: a daemon alive for >30 s necessarily has a working event tap (otherwise launchd would have respawned it). Log tail kept as a fallback for very recent starts.
- **`AccessibilityPermissionDenied` error message wording.** Previously said macOS Tahoe's picker "only accepts `.app` bundles". The picker actually accepts bare binaries — they're just hidden from the visible Accessibility list, so users can't toggle them on. Updated message describes the actual behavior.

### Internal
- **Release pipeline robustness.** Validate that the git tag is annotated before reading its message; force-fetch tag objects post-checkout; fall back to `CHANGELOG.md` if the tag annotation is missing. v0.0.18 initially shipped with a release body containing a random commit message because `actions/checkout@v4`'s `fetch-tags: true` doesn't reliably fetch annotated tag objects.

## [0.0.18](https://github.com/jackielii/skhd.zig/compare/v0.0.17...v0.0.18) - 2026-04-26

### macOS Tahoe (26) compatibility

This release reworks distribution and service management for macOS 26 (Tahoe). See [docs/UPGRADING.md](docs/UPGRADING.md) for the one-time setup users on 0.0.17 or earlier need to perform after upgrading.

### Added
- **`.app` bundle distribution** — skhd now ships as `skhd.app` instead of a bare Mach-O. TCC accessibility entries are keyed by bundle ID (`com.jackielii.skhd`) instead of by file path, so permissions persist across rebuilds and `brew upgrade`.
- **`zig build app` / `zig build sign-app`** — build steps for producing and signing the `.app` bundle locally.
- **Daemon health in `--status`** — now reports `Daemon running` (from `launchctl list`) and `Hotkeys functional` (from log file tail), instead of the misleading `AXIsProcessTrusted` check on the CLI process.
- **[docs/UPGRADING.md](docs/UPGRADING.md)** — step-by-step guide for users moving from 0.0.17 to 0.0.18.

### Changed
- **Logs moved to `~/Library/Logs/skhd.log`** (was `/tmp/skhd_$USER.log`). The previous path was wiped at every boot, hiding boot-time failures.
- **Service management uses `launchctl bootstrap` / `bootout`** instead of legacy `load -w` / `unload -w`. `--stop-service` no longer leaves the agent in a persistently-disabled state across reboots.
- **Plist `ProgramArguments`** points at the stable `/opt/homebrew/opt/skhd-zig/skhd.app/Contents/MacOS/skhd` symlink instead of a version-pinned Cellar path.
- **Plist `ThrottleInterval`** lowered from 30 s to 10 s for faster recovery from boot-time failures.
- **`AccessibilityPermissionDenied` error message** now points at the `.app` bundle path (which Tahoe's picker accepts) instead of the inner binary.

### Removed
- **Intel (x86_64) prebuilt releases paused.** Apple Silicon only as of v0.0.18. Intel users can still build from source via `zig build sign-app`. Re-enable hooks documented in `.github/workflows/release.yml` and `Formula/skhd-zig.rb` (kept commented for easy restoration).
- **Homebrew `brew services` integration.** Replaced by skhd's own `--install-service`, which produces a properly Tahoe-tuned launchd plist (retry loop, log path, ThrottleInterval, bundle-aware ProgramArguments). Migrate with `brew services stop skhd-zig 2>/dev/null && skhd --install-service && skhd --start-service`. The two agents would race for the event tap if both were enabled.

### Fixed
- **Boot-time `CGEventTapCreate` race** — added a 10-attempt retry loop with 500 ms backoff. The daemon used to exit and wait the full `ThrottleInterval` when WindowServer/TCC weren't ready immediately at login.
- **`scripts/codesign.sh` cert auto-creation** — fixed empty-password p12 import rejection on macOS Tahoe + OpenSSL 3.6, and the missing `extendedKeyUsage = codeSigning` that hid the cert from `find-identity -p codesigning`.
- **Homebrew formula auto-bump regex** — replaced the buggy `[0-9.(-preview)]\+` character class with `v[0-9.]+(-[A-Za-z0-9]+)?` so pre-release tags (`v0.0.18-preview`, `v0.0.19-rc1`) update correctly.

## [0.0.17](https://github.com/jackielii/skhd.zig/compare/v0.0.16...v0.0.17) - 2025-12-08

### Added
- **Media key support** - Added support for media keys as forward/remap targets (#28)
  - Supported media keys: `play`, `pause`, `next`, `previous`, `fast`, `rewind`, `brightness_up`, `brightness_down`, `illumination_up`, `illumination_down`, `sound_up`, `sound_down`, `mute`
  - Example: `cmd - p | play` forwards Cmd+P to the play/pause media key

## [0.0.16](https://github.com/jackielii/skhd.zig/compare/v0.0.15...v0.0.16) - 2025-11-30

### Fixed
- **CFString null pointer crash** - Fixed crash during keyboard layout initialization on certain keyboard layouts (#19, #20)
  - Added null check for `CFStringCreateWithCharacters` which can return NULL for some keycodes
  - skhd now gracefully skips problematic keycodes and continues initialization

## [0.0.15](https://github.com/jackielii/skhd.zig/compare/v0.0.13...v0.0.15) - 2025-10-17

### Added
- **Code signing support for macOS 15+** - Accessibility permissions now persist across builds (#15)
  - Added `Info.plist` with bundle identifier for stable TCC identity
  - Added `zig build sign` command for local development signing
  - Release binaries are now automatically signed
  - See `docs/CODE_SIGNING.md` for setup instructions

### Fixed
- **Missing F16-F20 keycodes** - Added support for F16-F20 function keys in observe mode (#14)
  - These keys were already usable in configs but showed as "unknown" in `-o` mode
  - Note: F21-F24 cannot be supported as they are not defined in macOS's HIToolbox framework
- **Homebrew release artifact URL** - Fixed regex to handle preview tags in release URLs
  - Thanks to @tdjordan for the contribution (#17)

### Changed
- Removed unused `Info.plist` file from assets directory

## [0.0.13](https://github.com/jackielii/skhd.zig/compare/v0.0.12...v0.0.13) - 2025-08-27

### Added
- **Support for backtick (`) special character** - Added backtick to the list of recognized special characters in the tokenizer
  - Enables hotkey bindings with the backtick key
  - Thanks to @danielfalbo for the contribution (#8)

### Fixed
- **Duplicate keycode from layout** - Fixed issue where keycodes could be duplicated when retrieved from keyboard layout
- **ZBench vendor dependency** - Fixed vendor import for zbench benchmarking library

### Changed
- **Improved error messages** - Enhanced parser error reporting with contextual information
  - Added helpful error messages for invalid hex keycodes with examples
  - Improved duplicate command detection with specific context about conflicts
  - Added suggestions for common mistakes (e.g., "Did you forget to declare it with '::mode'?")
  - Better error reporting for file loading, blacklist, and shell configuration failures
- **Duplicate command handling** - Allow identical duplicate commands in process groups
  - This enables more flexible configuration with overlapping process groups
  - Duplicate detection still prevents conflicting commands for the same process
- **Build optimization** - Only build all targets on main branch to speed up development builds
- **Code improvements** - Various internal refactoring and simplifications
  - Simplified activation equality check
  - Use Zig field syntax for cleaner code
  - Added error sets for type safety in Hotkey methods

## [0.0.12](https://github.com/jackielii/skhd.zig/compare/v0.0.11...v0.0.12) - 2025-07-15

### Added
- **Mode activation with optional command execution** - Enhanced mode switching with command execution support
  - New syntax: `keysym ; mode : command` executes command when switching to mode
  - Process-specific mode activation in process lists (e.g., `"terminal" ; vim_mode`)
  - Process group mode activation (e.g., `@browsers ; browser_mode`)
  - Comprehensive test coverage for all activation scenarios
- Added `activation` variant to `ProcessCommand` enum for proper mode activation tracking

### Changed
- Refactored command parsing to eliminate code duplication with helper function `parse_command`
- Removed redundant `flags.activate` field from `ModifierFlag` 
- Updated SYNTAX.md and README.md with comprehensive mode activation documentation

### Fixed
- Fixed mode activation implementation to use dedicated enum variant instead of borrowing command enum
- Improved error handling for empty commands followed by references

## [0.0.11](https://github.com/jackielii/skhd.zig/compare/v0.0.10...v0.0.11) - 2025-07-13

### Changed
- Optimized command execution by using null-terminated strings throughout, eliminating runtime allocations in exec.zig
- Refactored Hotkey API to have separate methods for each action type (add_process_command, add_process_forward, add_process_unbound)

### Fixed
- Fixed benchmark to use new Hotkey API methods

## [0.0.10](https://github.com/jackielii/skhd.zig/compare/v0.0.9...v0.0.10) - 2025-07-08

### Fixed
- **Critical bug fix**: Capture mode now respects passthrough and unbound actions
  - Previously, capture mode would consume all keys including those explicitly marked as passthrough (`->`) or unbound (`~`)
  - Now these keys are properly passed through to applications even in capture mode

### Added
- Support for unbound action syntax: `<keysym> ~`
  - Keys marked as unbound are not captured and pass through to applications
  - Compatible with all existing features (modes, process lists, etc.)
- Added `--message` flag to release script for custom tag messages

### Changed
- Refactored hotkey processing to use `HotkeyResult` enum instead of boolean return
  - Clearer distinction between consumed, passthrough, and not_found states
  - Eliminated code duplication between `handleKeyDown` and `handleSystemKey`

### Internal
- Added comprehensive tests for capture mode behavior with passthrough and unbound actions
- Extracted common hotkey result handling into `handleHotkeyResult` helper function
- Updated SYNTAX.md documentation to include unbound action syntax

## [0.0.9](https://github.com/jackielii/skhd.zig/compare/v0.0.8...v0.0.9) - 2025-07-07

### Fixed

- A subtle but critical bug only happens in release mode due to how memory allocation works with aggressive allocators like `smp_allocator` or `c_allocator`. This bug caused HashMaps to silently point to different objects after destroying an object that was still referenced in the map. This has been fixed by using a array list to track the hotkeys instead of a HashMap, which avoids this issue entirely.

### Added
- Improved duplicate hotkey detection with better error reporting

### Internal
- Added issue template for better bug reporting
- Updated CI workflow configuration
- Include build mode in version string output

## [0.0.8](https://github.com/jackielii/skhd.zig/compare/v0.0.7...v0.0.8) - 2025-07-06

### Changed
- **Major performance improvement**: Achieved allocation-free event loop
  - Replaced dynamic allocation for process names with fixed-size buffer
  - Zero allocations during runtime after initialization
  - Event loop is now completely allocation-free in release builds
- Refactored hotkey implementation for simplicity and performance
  - Removed HotkeyArrayHashMap and HotkeyMultiArrayList (740+ lines removed)
  - Consolidated hotkey functionality in Hotkey.zig
- Enhanced test coverage with comprehensive duplicate detection tests
- CarbonEvent now uses a pre-allocated buffer for process names to avoid runtime allocations
- Moved VERSION file from src/VERSION to root directory for better visibility
- Code cleanup and formatting improvements across multiple modules

### Fixed
- Fixed cleanup logic when sending SIGINT to the process
- Fixed memory leaks in Hotkey.zig and improved memory management
- **Duplicate definition detection**: Now reports errors instead of silently overwriting duplicate entries in config
- Fixed CI/CD release workflow by replacing deprecated upload-release-asset action with gh CLI

### Internal
- Added TrackingAllocator for monitoring memory allocations during development
- Created new exec.zig module for command execution
- Improved error handling in Parser, Mappings, and Keycodes modules

## [0.0.7](https://github.com/jackielii/skhd.zig/compare/v0.0.6...v0.0.7) - 2025-07-05

### Fixed
- **Accessibility permission check reliability** - Replaced unreliable event tap creation with `AXIsProcessTrusted()` API
- `--status` command now correctly reports accessibility permission state
- Fixed issue where permissions showed as "not granted" even when properly configured

### Changed
- Permission checking now uses the official macOS API for more accurate results

## [0.0.6](https://github.com/jackielii/skhd.zig/compare/v0.0.5...v0.0.6) - 2025-07-04

### Added
- **Command definitions feature** with `.define` directive for reusable command templates
  - Support for placeholders (`{{1}}`, `{{2}}`, etc.) in command templates
  - Reference commands with `@command_name("arg1", "arg2")` syntax
  - Reduces configuration duplication and improves maintainability
- Enhanced error handling for command definition parsing with clear error messages

### Changed
- Refactored tokenizer to clean up token text representation
- Optimized command definition storage by moving it directly to Parser
- Updated documentation to include command definition examples

### Fixed
- Command definition parsing now properly handles escaped characters in templates
- Improved error reporting for invalid placeholder syntax

## [0.0.5](https://github.com/jackielii/skhd.zig/compare/v0.0.4...v0.0.5) - 2025-07-02

### Changed
- Improved service mode execution to always use fork/exec for better reliability
- Refactored hotkey storage to use MultiArrayList for better memory layout and performance
- Updated README to explicitly mention key remapping/forwarding feature

### Added
- MIT License file
- Integrated Homebrew tap update directly into release workflow

### Fixed
- Import statement cleanup for better code organization
- GitHub Actions workflow now directly triggers Homebrew tap updates

## [0.0.4](https://github.com/jackielii/skhd.zig/compare/v0.0.3...v0.0.4) - 2025-07-02

### Added
- Comprehensive execution tracer with `-P/--profile` flag for performance analysis
- Benchmark suite using zBench for hot path optimization
- Carbon event handler for efficient app switching notifications

### Changed
- **Major performance optimization**: Cache process name lookups (25μs → 21ns)
- **Eliminated double hotkey lookup**: Combined into single `processHotkey` function (169ns → 83ns)
- CPU usage reduced from ~1.2% to ~0.5% (matching original skhd)

### Fixed
- High CPU usage compared to original skhd implementation
- Unnecessary system calls in hot path

## [0.0.3](https://github.com/jackielii/skhd.zig/compare/v0.0.2...v0.0.3) - 2025-07-01

### Added
- `--start-service` now automatically installs/updates the service plist to ensure it uses the current binary
- `--status` command to check service installation status, running state, and accessibility permissions
- Clear startup message in service mode to confirm skhd is running
- Improved accessibility permission error message with troubleshooting steps for when permissions are "stuck"

### Changed
- Service mode now only logs errors and startup messages, reducing log verbosity
- Removed unnecessary stdout/stderr syncing in logger for better performance

### Fixed
- Service management commands now provide better error messages and guidance
- Homebrew service integration now works more reliably with proper binary path updates

## [0.0.2](https://github.com/jackielii/skhd.zig/compare/v0.0.1...v0.0.2) - 2025-07-01

### Fixed
- Support for uppercase option names (.SHELL, .BLACKLIST) in configuration files
- Improved error reporting to show parse errors with line numbers during initialization
- Parser now properly handles comma-separated lists in .define directives
- Exit with proper error when config file is not a regular file (e.g., /dev/null)
- Fixed release workflow permissions for uploading artifacts
- Simplified release workflow to build natively for each architecture

## [0.0.1](https://github.com/jackielii/skhd.zig/releases/tag/v0.0.1) - 2025-07-01

### Added
- Initial release of skhd.zig - a complete Zig port of skhd
- Full compatibility with original skhd configuration format
- Core features:
  - Event tap creation and keyboard event handling
  - Hotkey mapping with modifier support (cmd, alt, ctrl, shift)
  - Left/right modifier distinction (lcmd, rcmd, etc.)
  - Modal system with mode switching and capture modes
  - Process-specific hotkey bindings
  - Key forwarding/remapping
  - Blacklist support for applications
  - Shell command execution
  - Configuration file loading with `.load` directive
  - Custom shell support with `.shell` directive
- Command-line interface:
  - `-c/--config` - Specify config file
  - `-o/--observe` - Observe mode for testing keys
  - `-V/--verbose` - Verbose output
  - `-k/--key` - Synthesize keypress
  - `-t/--text` - Synthesize text
  - `-r/--reload` - Reload configuration
  - `-h/--no-hotload` - Disable hot reloading
  - `-v/--version` - Show version
- Service management:
  - `--install-service` - Install launchd service
  - `--uninstall-service` - Remove launchd service
  - `--start-service` - Start service
  - `--restart-service` - Restart service
  - `--stop-service` - Stop service
- Enhanced features:
  - **Process group variables** (New!) - Define reusable process groups with `.define` directive
  - Improved error reporting with line numbers and file paths
  - Unicode character handling in process names
  - Fixed key repeating issue with event forwarding
  - Comprehensive test suite
  - CI/CD workflow with GitHub Actions

### Fixed
- Key repeating issue when forwarding events to applications
- Unicode invisible character handling in process names
- Modifier matching logic to properly handle general vs specific modifiers
- Memory management and hot reload stability

### Performance
- Optimized hot path to minimize allocations during key events
- Efficient HashMap-based hotkey lookup
- Stack-based buffers for process name retrieval
