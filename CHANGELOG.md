# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.0.22] - 2026-04-26

### Fixed
- **Event tap survives runtime Accessibility revoke.** When Accessibility was toggled off while skhd was running, macOS sent `kCGEventTapDisabledByUserInput` and the in-place `CGEventTapEnable` retry silently failed — the tap stayed in the event chain as an active filter that couldn't forward events, leaving the keyboard unresponsive until skhd was killed. The tap is now detached on the disabled callback, and a 1 s `CFRunLoopTimer` watches for `AXIsProcessTrusted` to flip back and recreates the tap on re-grant. `EventTap.deinit` also cleans up when the tap is system-disabled, not just when `enabled()`.
- **`--status` no longer false-negatives in the first 30 s after daemon start.** `getEventTapHealth` scanned the daemon log for the `ACCESSIBILITY PERMISSIONS REQUIRED` marker, but SMAppService routes the daemon's stderr to `/dev/null`, so stale denial lines from previous runs dominated the tail. The log scan is now skipped when the log file is older than the running daemon, and reports `unknown` in that window instead.

### Changed
- **Daemon sources `PATH` from `$SHELL -ilc` at startup.** Hotkeys that exec `/opt/homebrew/bin/yabai`, `/opt/homebrew/bin/aerospace`, etc. previously failed under launchd's minimal `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`). The interactive-login shell is queried once at startup so command lookups match what the user sees in their terminal.

### Internal
- **`zig build install-local`** stages the local build into `/Applications/skhd.app` (the slot a brew install would occupy), re-signs with `skhd-cert`, and restarts the SMAppService daemon — for testing the packaged path without cutting a release.

## [0.0.21] - 2026-04-26

### Fixed
- **The actual root cause of "skhd doesn't always start after reboot" on macOS Tahoe.** Hand-installed LaunchAgents under `~/Library/LaunchAgents/` get registered with macOS's Background Tasks Manager (BTM, introduced in Sequoia, enforced in Tahoe) as `Type: legacy agent` with `Disposition: [enabled, disallowed, not notified]` — and BTM silently refuses to auto-load them at login until the user manually approves the agent in System Settings → General → Login Items & Extensions. The previous fixes (launchctl bootstrap migration, retry loops, plist paths) addressed real but secondary issues; BTM was the gatekeeper all along.

### Changed
- **`--install-service` now uses `SMAppService`** instead of writing to `~/Library/LaunchAgents/`. The bundled plist lives inside `skhd.app/Contents/Library/LaunchAgents/com.jackielii.skhd.plist` and registration goes through `SMAppService.agent(plistName:).register()`. BTM creates a proper managed entry (`Type: agent`, `Disposition: [enabled, allowed, notified]`) that auto-loads cleanly at every login.
- **`--uninstall-service`** now unregisters via SMAppService. Both install and uninstall also clean up any pre-0.0.21 hand-installed plist at `~/Library/LaunchAgents/com.jackielii.skhd.plist` so the legacy and new managed entries don't race.
- **`--status`** reads SMAppService registration state directly. Reports `Registration status: enabled` / `requires approval` / `not registered` so the user knows what BTM thinks.

### Migration
On upgrade from 0.0.20 or earlier, run `skhd --install-service` once (preferably from `/Applications/skhd.app/Contents/MacOS/skhd` so SMAppService treats `/Applications/skhd.app` as the registering bundle). The legacy `disallowed` BTM entry from previous versions is harmless after the new managed entry is in place but can be removed via System Settings → General → Login Items & Extensions if desired. See [docs/UPGRADING.md](docs/UPGRADING.md) for the full walkthrough.

## [0.0.20] - 2026-04-26

Local-development quality-of-life release. No runtime changes.

### Internal
- **`zig build run` now produces a signed dev `.app` bundle** at `zig-out/skhd-dev.app`, signed with a separate `skhd-dev-cert` and bundle ID `com.jackielii.skhd.dev`. On macOS Tahoe, an adhoc-signed bare binary cannot be granted Accessibility, so `zig build run` previously failed with permission errors during local debugging. The dev TCC slot is fully isolated from the prod entry (`com.jackielii.skhd` + `skhd-cert`) used by the Homebrew install, and re-signing every build keeps permissions stable across rebuilds. See [docs/CODE_SIGNING.md](docs/CODE_SIGNING.md#local-debug-workflow-zig-build-run).
- **First-run Accessibility popup.** `AXIsProcessTrustedWithOptions(prompt=true)` is now called before event tap setup so unknown bundles surface the macOS popup and System Settings deep-link, instead of failing silently after 10 retries.
- **`AccessibilityPermissionDenied` error message** prefers the `.app` bundle that actually contains the running binary over `/Applications/skhd.app`, so the displayed path matches what a grant would apply to.
- **`scripts/codesign.sh`** reads `SKHD_BUNDLE_ID` env var (defaults to `com.jackielii.skhd`).
- **`scripts/make-app.sh`** accepts an optional bundle ID as the third argument.

## [0.0.19] - 2026-04-26

Small follow-up to v0.0.18 fixing a reporting bug.

### Fixed
- **`--status` reported `Hotkeys functional: No` while the daemon was actually working.** The previous logic read the daemon log's tail looking for "Event tap created successfully" markers — but ReleaseFast (Homebrew's build mode) suppresses `log.info`, so the log stayed silent on success and old failure entries dominated. The daemon's event tap was active, only the status reporter was misled. Now uses process uptime via `sysctl(kern.proc.pid)` as the primary signal: a daemon alive for >30 s necessarily has a working event tap (otherwise launchd would have respawned it). Log tail kept as a fallback for very recent starts.
- **`AccessibilityPermissionDenied` error message wording.** Previously said macOS Tahoe's picker "only accepts `.app` bundles". The picker actually accepts bare binaries — they're just hidden from the visible Accessibility list, so users can't toggle them on. Updated message describes the actual behavior.

### Internal
- **Release pipeline robustness.** Validate that the git tag is annotated before reading its message; force-fetch tag objects post-checkout; fall back to `CHANGELOG.md` if the tag annotation is missing. v0.0.18 initially shipped with a release body containing a random commit message because `actions/checkout@v4`'s `fetch-tags: true` doesn't reliably fetch annotated tag objects.

## [0.0.18] - 2026-04-26

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

## [0.0.17] - 2025-12-08

### Added
- **Media key support** - Added support for media keys as forward/remap targets (#28)
  - Supported media keys: `play`, `pause`, `next`, `previous`, `fast`, `rewind`, `brightness_up`, `brightness_down`, `illumination_up`, `illumination_down`, `sound_up`, `sound_down`, `mute`
  - Example: `cmd - p | play` forwards Cmd+P to the play/pause media key

## [0.0.16] - 2025-11-30

### Fixed
- **CFString null pointer crash** - Fixed crash during keyboard layout initialization on certain keyboard layouts (#19, #20)
  - Added null check for `CFStringCreateWithCharacters` which can return NULL for some keycodes
  - skhd now gracefully skips problematic keycodes and continues initialization

## [0.0.15] - 2025-10-17

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

## [0.0.13] - 2025-08-27

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

## [0.0.12] - 2025-07-15

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

## [0.0.11] - 2025-07-13

### Changed
- Optimized command execution by using null-terminated strings throughout, eliminating runtime allocations in exec.zig
- Refactored Hotkey API to have separate methods for each action type (add_process_command, add_process_forward, add_process_unbound)

### Fixed
- Fixed benchmark to use new Hotkey API methods

## [0.0.10] - 2025-07-08

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

## [0.0.9] - 2025-07-07

### Fixed

- A subtle but critical bug only happens in release mode due to how memory allocation works with aggressive allocators like `smp_allocator` or `c_allocator`. This bug caused HashMaps to silently point to different objects after destroying an object that was still referenced in the map. This has been fixed by using a array list to track the hotkeys instead of a HashMap, which avoids this issue entirely.

### Added
- Improved duplicate hotkey detection with better error reporting

### Internal
- Added issue template for better bug reporting
- Updated CI workflow configuration
- Include build mode in version string output

## [0.0.8] - 2025-07-06

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

## [0.0.7] - 2025-07-05

### Fixed
- **Accessibility permission check reliability** - Replaced unreliable event tap creation with `AXIsProcessTrusted()` API
- `--status` command now correctly reports accessibility permission state
- Fixed issue where permissions showed as "not granted" even when properly configured

### Changed
- Permission checking now uses the official macOS API for more accurate results

## [0.0.6] - 2025-07-04

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

## [0.0.5] - 2025-07-02

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

## [0.0.4] - 2025-07-02

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

## [0.0.3] - 2025-07-01

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

## [0.0.2] - 2025-07-01

### Fixed
- Support for uppercase option names (.SHELL, .BLACKLIST) in configuration files
- Improved error reporting to show parse errors with line numbers during initialization
- Parser now properly handles comma-separated lists in .define directives
- Exit with proper error when config file is not a regular file (e.g., /dev/null)
- Fixed release workflow permissions for uploading artifacts
- Simplified release workflow to build natively for each architecture

## [0.0.1] - 2025-07-01

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

[Unreleased]: https://github.com/jackielii/skhd.zig/compare/v0.0.22...HEAD
[0.0.22]: https://github.com/jackielii/skhd.zig/compare/v0.0.21...v0.0.22
[0.0.21]: https://github.com/jackielii/skhd.zig/compare/v0.0.20...v0.0.21
[0.0.20]: https://github.com/jackielii/skhd.zig/compare/v0.0.19...v0.0.20
[0.0.19]: https://github.com/jackielii/skhd.zig/compare/v0.0.18...v0.0.19
[0.0.18]: https://github.com/jackielii/skhd.zig/compare/v0.0.17...v0.0.18
[0.0.17]: https://github.com/jackielii/skhd.zig/compare/v0.0.16...v0.0.17
[0.0.16]: https://github.com/jackielii/skhd.zig/compare/v0.0.15...v0.0.16
[0.0.15]: https://github.com/jackielii/skhd.zig/compare/v0.0.13...v0.0.15
[0.0.13]: https://github.com/jackielii/skhd.zig/compare/v0.0.12...v0.0.13
[0.0.12]: https://github.com/jackielii/skhd.zig/compare/v0.0.11...v0.0.12
[0.0.11]: https://github.com/jackielii/skhd.zig/compare/v0.0.10...v0.0.11
[0.0.10]: https://github.com/jackielii/skhd.zig/compare/v0.0.9...v0.0.10
[0.0.9]: https://github.com/jackielii/skhd.zig/compare/v0.0.8...v0.0.9
[0.0.8]: https://github.com/jackielii/skhd.zig/compare/v0.0.7...v0.0.8
[0.0.7]: https://github.com/jackielii/skhd.zig/compare/v0.0.6...v0.0.7
[0.0.6]: https://github.com/jackielii/skhd.zig/compare/v0.0.5...v0.0.6
[0.0.5]: https://github.com/jackielii/skhd.zig/compare/v0.0.4...v0.0.5
[0.0.4]: https://github.com/jackielii/skhd.zig/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/jackielii/skhd.zig/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/jackielii/skhd.zig/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/jackielii/skhd.zig/releases/tag/v0.0.1
