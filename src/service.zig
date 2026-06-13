const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig");
const c_mod = c;
const sm = @import("sm_app_service.zig");
const grabber_cli = @import("grabber_cli.zig");
const log = std.log.scoped(.service);

// Import C functions
extern "c" fn getpid() c_int;
extern "c" fn getuid() c_uint;

/// Bundle ID of the agent the daemon registers itself as. Must match the
/// CFBundleIdentifier embedded in skhd.app/Contents/Info.plist *and* the
/// filename of the bundled launchd plist
/// (skhd.app/Contents/Library/LaunchAgents/<this>.plist).
const BUNDLE_ID = "com.jackielii.skhd";
const LAUNCH_AGENT_PLIST_NAME: [*:0]const u8 = BUNDLE_ID ++ ".plist";

/// Check if the current process has accessibility permissions
pub fn hasAccessibilityPermissions() bool {
    // Use the official macOS API to check accessibility permissions
    // AXIsProcessTrusted() is the recommended way to check if the current
    // process has been granted accessibility permissions by the user
    return c.AXIsProcessTrusted() != 0;
}

/// Three-valued result of `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`.
/// `unknown` means the user has never been prompted (first run); `denied`
/// can mean either explicitly denied OR — the case worth surfacing — that
/// TCC's stored csreq is anchored on a stale cdHash (every brew upgrade
/// or rebuild produces a new cdHash, silently invalidating the grant
/// without losing the System Settings check mark).
pub const InputMonitoringAccess = enum { granted, denied, unknown };

/// Query whether the running process has Input Monitoring
/// (kTCCServiceListenEvent) granted. CGEvent taps that listen for keyDown
/// require this in addition to Accessibility — without it, the tap is
/// created (Accessibility-only check) but key-down events are silently
/// dropped before reaching the callback. This catches the cdHash-mismatch
/// case that the existing Accessibility / log-tail signals miss entirely.
pub fn checkInputMonitoringAccess() InputMonitoringAccess {
    return switch (c_mod.IOHIDCheckAccess(c_mod.kIOHIDRequestTypeListenEvent)) {
        c_mod.kIOHIDAccessTypeGranted => .granted,
        c_mod.kIOHIDAccessTypeDenied => .denied,
        else => .unknown,
    };
}

/// Trigger the Input Monitoring approval dialog for this bundle. Same
/// auto-pop UX as `promptForAccessibility` — first call shows the system
/// prompt; subsequent calls just return the current grant state. Used to
/// extend the bundle-keyed IM grant to skhd-grabber: when the daemon and
/// the agent are both signed with `com.jackielii.skhd` and the daemon
/// runs from inside skhd.app, granting the dialog covers both processes.
pub fn promptForInputMonitoring() bool {
    return c_mod.IOHIDRequestAccess(c_mod.kIOHIDRequestTypeListenEvent) != 0;
}

/// Like hasAccessibilityPermissions() but uses the prompting variant. The
/// first time an unknown bundle calls this, macOS pops the "X would like to
/// control this computer" dialog and opens System Settings → Accessibility.
/// Subsequent calls (granted or denied) just return without prompting.
/// CGEventTap creation itself never prompts, so we have to call this
/// explicitly to surface the popup.
pub fn promptForAccessibility() bool {
    const keys = [_]?*const anyopaque{@ptrCast(c.kAXTrustedCheckOptionPrompt)};
    const values = [_]?*const anyopaque{@ptrCast(c.kCFBooleanTrue)};
    const opts = c.CFDictionaryCreate(
        null,
        @ptrCast(@constCast(&keys)),
        @ptrCast(@constCast(&values)),
        1,
        &c.kCFCopyStringDictionaryKeyCallBacks,
        &c.kCFTypeDictionaryValueCallBacks,
    );
    defer if (opts != null) c.CFRelease(opts);
    return c.AXIsProcessTrustedWithOptions(opts) != 0;
}

/// Outcome of `tryAutoResetStaleTcc` — drives the wording the daemon
/// shows to the user (and whether it speaks at all). Distinct
/// `skipped_*` reasons exist so the caller can print the right next-step
/// instructions instead of a generic "something went wrong".
pub const TccAutoResetResult = enum {
    /// We just dropped the stale grants. User must re-toggle the entry
    /// in System Settings; launchd will recover on the next respawn.
    reset_now,
    /// We already auto-reset within `tcc_auto_reset_window_secs`. Don't
    /// reset again — the previous reset's "go re-grant" instruction is
    /// still the actionable step.
    skipped_recent,
    /// Not reached for "real" denials. Returned when IOHIDCheckAccess
    /// reports access is granted or unknown — i.e. the cdHash-mismatch
    /// signature isn't present, so we shouldn't touch the grant.
    skipped_access_ok,
    /// Foreground / non-daemon invocation. Auto-resetting from a
    /// foreground run would surprise users running `zig build run` to
    /// debug something unrelated.
    skipped_not_daemon,
    /// `/usr/bin/tccutil` errored or the marker write failed. Caller
    /// falls back to the long manual-fix block.
    failed,
};

/// 10-minute cooldown between auto-resets. Long enough that the user
/// has time to navigate to System Settings → Privacy & Security and
/// re-toggle the entry without us nuking the grant out from under them
/// on the next launchd respawn (10s `ThrottleInterval`); short enough
/// that a *second* binary swap (e.g. the next brew upgrade) can heal
/// itself without the user clearing any state.
const tcc_auto_reset_window_secs: i64 = 10 * 60;

/// `tccutil reset Accessibility` + `reset ListenEvent` for our bundle,
/// with a marker file gate to prevent reset loops on every respawn.
///
/// The cdHash-anchored TCC bug (every brew upgrade / rebuild silently
/// invalidates the Input Monitoring grant on macOS Tahoe — System
/// Settings still shows it as on, but key events are dropped before
/// reaching the tap) used to manifest as launchd respawning the daemon
/// every 10s in a loop, each spawn producing the same "ACCESSIBILITY
/// PERMISSIONS REQUIRED" wall of text. The user is supposed to read
/// that text and run two `tccutil` commands by hand. Most don't —
/// they just see "skhd stopped working after `brew upgrade`".
///
/// This helper closes the loop: when `IOHIDCheckAccess` says
/// `denied` *and* we're a daemon (so the user isn't manually iterating
/// in foreground), we run the two `tccutil reset` commands ourselves
/// and write a marker file. Subsequent respawns within the window see
/// the marker and skip — they just print a short "still waiting for
/// you to re-grant" line and exit, instead of resetting again.
pub fn tryAutoResetStaleTcc(
    allocator: std.mem.Allocator,
    io: std.Io,
    is_daemon: bool,
) TccAutoResetResult {
    if (!is_daemon) return .skipped_not_daemon;
    if (checkInputMonitoringAccess() != .denied) return .skipped_access_ok;

    const home = @import("utils.zig").getenv("HOME") orelse return .failed;
    const cache_dir = std.fmt.allocPrint(
        allocator,
        "{s}/Library/Caches/" ++ BUNDLE_ID,
        .{home},
    ) catch return .failed;
    defer allocator.free(cache_dir);
    const marker_path = std.fmt.allocPrint(
        allocator,
        "{s}/tcc_auto_reset_at",
        .{cache_dir},
    ) catch return .failed;
    defer allocator.free(marker_path);

    const now_ns = std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds;
    const now_secs: i64 = @intCast(@divTrunc(now_ns, std.time.ns_per_s));

    // Marker present + within cooldown → don't reset again. The
    // previous reset's instruction ("go re-grant in Settings") is
    // still the actionable step.
    var marker_buf: [32]u8 = undefined;
    if (std.Io.Dir.cwd().readFile(io, marker_path, &marker_buf)) |slice| {
        const trimmed = std.mem.trim(u8, slice, " \t\n\r");
        if (std.fmt.parseInt(i64, trimmed, 10)) |last_reset| {
            if (now_secs - last_reset < tcc_auto_reset_window_secs) {
                return .skipped_recent;
            }
        } else |_| {}
    } else |_| {}

    std.Io.Dir.createDirAbsolute(io, cache_dir, .fromMode(0o755)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return .failed,
    };

    // Order matters: ListenEvent first so the IM prompt is what fires
    // on the next respawn (the one users miss most often, because
    // Accessibility's prompt is more familiar). Both must succeed for
    // the heal to be meaningful — if only one resets, the daemon
    // still can't capture events.
    if (!runTccutilReset(allocator, io, "ListenEvent")) return .failed;
    if (!runTccutilReset(allocator, io, "Accessibility")) return .failed;

    var ts_buf: [32]u8 = undefined;
    const ts_str = std.fmt.bufPrint(&ts_buf, "{d}\n", .{now_secs}) catch return .failed;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker_path, .data = ts_str }) catch return .failed;

    return .reset_now;
}

/// `/usr/bin/tccutil reset <service> com.jackielii.skhd`. Returns true
/// on exit code 0. Logs a warning on failure but doesn't propagate the
/// error — partial success is still a meaningful state for the caller
/// (e.g. service typo, system tccutil missing, sandboxed environment).
fn runTccutilReset(allocator: std.mem.Allocator, io: std.Io, service: []const u8) bool {
    const argv = [_][]const u8{ "/usr/bin/tccutil", "reset", service, BUNDLE_ID };
    const result = std.process.run(allocator, io, .{ .argv = &argv }) catch |err| {
        log.warn("tccutil reset {s} {s} failed to spawn: {s}", .{ service, BUNDLE_ID, @errorName(err) });
        return false;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const exit_code: u32 = switch (result.term) {
        .exited => |code| code,
        else => 255,
    };
    if (exit_code != 0) {
        const err_msg = std.mem.trim(u8, result.stderr, " \t\n\r");
        log.warn("tccutil reset {s} {s} exited {d}: {s}", .{ service, BUNDLE_ID, exit_code, err_msg });
        return false;
    }
    return true;
}

/// PID file management
pub fn writePidFile(allocator: std.mem.Allocator, io: std.Io) !void {
    const username = @import("utils.zig").getenv("USER") orelse "unknown";
    const pid_path = try std.fmt.allocPrint(allocator, "/tmp/skhd_{s}.pid", .{username});
    defer allocator.free(pid_path);

    const pid = @as(i32, @intCast(getpid()));
    const pid_str = try std.fmt.allocPrint(allocator, "{d}\n", .{pid});
    defer allocator.free(pid_str);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = pid_path, .data = pid_str });
}

pub fn removePidFile(allocator: std.mem.Allocator, io: std.Io) void {
    const username = @import("utils.zig").getenv("USER") orelse "unknown";
    const pid_path = std.fmt.allocPrint(allocator, "/tmp/skhd_{s}.pid", .{username}) catch return;
    defer allocator.free(pid_path);
    std.Io.Dir.deleteFileAbsolute(io, pid_path) catch {};
}

pub fn readPidFile(allocator: std.mem.Allocator, io: std.Io) !?i32 {
    const username = @import("utils.zig").getenv("USER") orelse "unknown";
    const pid_path = try std.fmt.allocPrint(allocator, "/tmp/skhd_{s}.pid", .{username});
    defer allocator.free(pid_path);

    var content_buf: [256]u8 = undefined;
    const slice = std.Io.Dir.cwd().readFile(io, pid_path, &content_buf) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return error.ReadFailed,
    };
    const trimmed = std.mem.trim(u8, slice, " \n\r\t");
    return std.fmt.parseInt(i32, trimmed, 10) catch null;
}

/// Check if a process with given PID is running
pub fn isProcessRunning(pid: i32) bool {
    // On macOS/Unix, sending signal 0 probes existence: returns 0 on
    // success, -1 with EPERM if the process exists but we can't signal,
    // -1 with ESRCH if it doesn't exist.
    // signal 0 is the "test for existence" probe; cast through the
    // SIG enum which has no zero variant.
    const rc = std.c.kill(pid, @enumFromInt(0));
    if (rc == 0) return true;
    return std.c.errno(rc) == .PERM;
}

/// Pick a path to recommend in error messages for the System Settings →
/// Accessibility picker. Tahoe's picker only accepts `.app` bundles, and TCC
/// keys entries by the running process's signature — so we prefer the `.app`
/// that actually contains the running binary, since that's the one a grant
/// would apply to. Only fall back to `/Applications/skhd.app` when the running
/// process is bare (e.g. cellar binary), in which case adding the prod bundle
/// is the right pointer for the install.
pub fn resolveBundlePath(allocator: std.mem.Allocator, io: std.Io, exe_path: []const u8) ![]const u8 {
    const marker = ".app/Contents/MacOS/";
    if (std.mem.indexOf(u8, exe_path, marker)) |idx| {
        return allocator.dupe(u8, exe_path[0 .. idx + 4]); // keep ".app"
    }

    const apps_path = "/Applications/skhd.app";
    if (std.Io.Dir.accessAbsolute(io, apps_path, .{})) |_| {
        return allocator.dupe(u8, apps_path);
    } else |_| {}

    return allocator.dupe(u8, exe_path);
}

/// Resolve a Homebrew Cellar path (e.g. /opt/homebrew/Cellar/skhd-zig/0.0.15/bin/skhd)
/// to its stable opt symlink (/opt/homebrew/opt/skhd-zig/bin/skhd) so the plist
/// keeps working across `brew upgrade` + `brew cleanup`. Returns the input
/// unchanged when no stable equivalent exists.
pub fn resolveStableExePath(allocator: std.mem.Allocator, io: std.Io, exe_path: []const u8) ![]const u8 {
    const cellar_marker = "/Cellar/";
    const idx = std.mem.indexOf(u8, exe_path, cellar_marker) orelse {
        return allocator.dupe(u8, exe_path);
    };

    const prefix = exe_path[0..idx];
    const after_cellar = exe_path[idx + cellar_marker.len ..];

    const formula_end = std.mem.indexOfScalar(u8, after_cellar, '/') orelse {
        return allocator.dupe(u8, exe_path);
    };
    const formula = after_cellar[0..formula_end];

    const after_formula = after_cellar[formula_end + 1 ..];
    const version_end = std.mem.indexOfScalar(u8, after_formula, '/') orelse {
        return allocator.dupe(u8, exe_path);
    };
    const rest = after_formula[version_end + 1 ..];

    const candidate = try std.fmt.allocPrint(allocator, "{s}/opt/{s}/{s}", .{ prefix, formula, rest });
    errdefer allocator.free(candidate);

    std.Io.Dir.accessAbsolute(io, candidate, .{}) catch {
        allocator.free(candidate);
        return allocator.dupe(u8, exe_path);
    };
    return candidate;
}

pub fn getServicePath(allocator: std.mem.Allocator) ![]const u8 {
    const home = @import("utils.zig").getenv("HOME") orelse return error.NoHomeDirectory;
    return std.fmt.allocPrint(allocator, "{s}/Library/LaunchAgents/com.jackielii.skhd.plist", .{home});
}


/// Register the bundled LaunchAgent with macOS Background Tasks Manager via
/// SMAppService and clean up any pre-0.0.21 plist installed at
/// ~/Library/LaunchAgents/. With the SMAppService flow, BTM auto-tracks the
/// agent so it actually auto-starts at login (the legacy hand-installed
/// plist is silently disallowed by BTM on Sequoia/Tahoe — that's the
/// "skhd doesn't always start after reboot" bug at its root).
pub fn installService(allocator: std.mem.Allocator, io: std.Io) !void {
    cleanupLegacyInstall(allocator, io);
    try registerWithBTM();
}

pub fn uninstallService(allocator: std.mem.Allocator, io: std.Io) !void {
    cleanupLegacyInstall(allocator, io);

    const service = sm.agentService(LAUNCH_AGENT_PLIST_NAME) orelse {
        std.debug.print("SMAppService unavailable; nothing to unregister.\n", .{});
        return;
    };
    sm.unregister(service) catch |err| {
        // unregister fails if the service was never registered — treat as success.
        log.info("Unregister returned: {}", .{err});
    };
    std.debug.print("Service unregistered.\n", .{});

    // The agent uninstall is what users reach for first; the grabber and
    // the Karabiner DriverKit pieces don't get auto-removed because
    // they're root-owned and need a separate sudo step. Surface them
    // here so a user reading the terminal output knows what's still on
    // disk and how to finish the cleanup.
    printPostUninstallHints(io);
}

/// Print follow-up cleanup instructions if the grabber or VHIDD daemon
/// LaunchDaemons are still on disk after `--uninstall-service`. Silent
/// when nothing else is installed (the agent-only path doesn't need
/// extra noise). Mirrors the tail message from `--uninstall-grabber` but
/// scoped to whatever's actually present.
fn printPostUninstallHints(io: std.Io) void {
    const grabber_plist = "/Library/LaunchDaemons/com.jackielii.skhd.grabber.plist";
    const vhidd_plist = "/Library/LaunchDaemons/org.pqrs.service.daemon.Karabiner-VirtualHIDDevice-Daemon.plist";
    const pqrs_payload = "/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice";

    const has_grabber = fileExistsAbsolute(io, grabber_plist);
    const has_vhidd = fileExistsAbsolute(io, vhidd_plist);
    const has_pqrs = fileExistsAbsolute(io, pqrs_payload);

    if (!has_grabber and !has_vhidd and !has_pqrs) return;

    std.debug.print("\nStill installed (run these to fully clean up):\n", .{});

    if (has_grabber or has_vhidd) {
        std.debug.print(
            \\  sudo skhd --uninstall-grabber
            \\    Removes:
        , .{});
        if (has_grabber) std.debug.print("\n      - skhd-grabber LaunchDaemon ({s})", .{grabber_plist});
        if (has_vhidd) std.debug.print("\n      - VHIDD daemon LaunchDaemon ({s})", .{vhidd_plist});
        std.debug.print("\n", .{});
    }

    if (has_pqrs) {
        std.debug.print(
            \\
            \\  Karabiner-DriverKit-VirtualHIDDevice .pkg payload + dext
            \\    pqrs's domain — skhd doesn't ship its own uninstaller for these.
            \\    Run pqrs's scripts:
            \\      sudo bash "/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/scripts/uninstall/remove_files.sh"
            \\      sudo bash "/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/scripts/uninstall/deactivate_driver.sh"
            \\    The dext (kernel-side) needs SIP-aware removal — toggle it
            \\    off in System Settings → Login Items & Extensions →
            \\    Driver Extensions if you want it gone.
            \\
        , .{});
    } else {
        std.debug.print("\n", .{});
    }
}

fn fileExistsAbsolute(io: std.Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

pub fn startService(allocator: std.mem.Allocator, io: std.Io) !void {
    _ = allocator;
    _ = io;
    try registerWithBTM();
}

/// Register (or re-register) the bundled LaunchAgent and print the
/// resulting BTM status. Idempotent — calling on an already-registered
/// agent re-loads it (useful as the implementation of both
/// --install-service and --start-service).
fn registerWithBTM() !void {
    const service = sm.agentService(LAUNCH_AGENT_PLIST_NAME) orelse {
        std.debug.print("Failed to obtain SMAppService instance.\n", .{});
        std.debug.print("Verify the bundled plist exists at:\n", .{});
        std.debug.print("  <skhd.app>/Contents/Library/LaunchAgents/{s}\n", .{std.mem.span(LAUNCH_AGENT_PLIST_NAME)});
        return error.SMAppServiceUnavailable;
    };

    sm.register(service) catch |err| {
        std.debug.print("Failed to register service: {}\n", .{err});
        std.debug.print("\nMake sure you're running skhd from inside its .app bundle.\n", .{});
        std.debug.print("Try: /opt/homebrew/opt/skhd-zig/skhd.app/Contents/MacOS/skhd --install-service\n", .{});
        return err;
    };

    const st = sm.status(service);
    std.debug.print("Service registered with macOS.\n", .{});
    std.debug.print("Status: {s}\n", .{st.describe()});
    std.debug.print("Logs: {s}/Library/Logs/skhd.log\n", .{@import("utils.zig").getenv("HOME") orelse "~"});

    if (st == .requires_approval) {
        std.debug.print("\nMacOS requires approval before the agent can run:\n", .{});
        std.debug.print("1. Open System Settings → General → Login Items & Extensions\n", .{});
        std.debug.print("2. Find 'skhd' under 'Allow in the Background' and toggle it on\n", .{});
        std.debug.print("3. Then run: skhd --restart-service\n", .{});
    }
}

/// Best-effort cleanup of the pre-0.0.21 install layout: bootout the
/// hand-installed launchd job and delete the plist at
/// ~/Library/LaunchAgents/com.jackielii.skhd.plist. Silent if the legacy
/// state isn't present. Run on every install/uninstall to make sure we
/// never have both a legacy agent and a BTM-registered agent racing for
/// the event tap.
fn cleanupLegacyInstall(allocator: std.mem.Allocator, io: std.Io) void {
    const service_path = getServicePath(allocator) catch return;
    defer allocator.free(service_path);

    if (!fileExistsAbsolute(io, service_path)) return;

    log.info("Found legacy plist at {s}, cleaning up.", .{service_path});

    // Bootout from launchd (no-op if not loaded).
    const uid = getuid();
    const target = std.fmt.allocPrint(allocator, "gui/{d}/{s}", .{ uid, BUNDLE_ID }) catch return;
    defer allocator.free(target);
    _ = runQuiet(allocator, io, &.{ "launchctl", "bootout", target }) catch 0;

    // Older code wrote a persistent `disable` flag via `unload -w` — clear
    // it so a future register isn't silently blocked.
    _ = runQuiet(allocator, io, &.{ "launchctl", "enable", target }) catch 0;

    std.Io.Dir.deleteFileAbsolute(io, service_path) catch {};
}

pub fn stopService(allocator: std.mem.Allocator, io: std.Io) !void {
    const uid = getuid();
    const target = try std.fmt.allocPrint(allocator, "gui/{d}/com.jackielii.skhd", .{uid});
    defer allocator.free(target);

    // bootout unloads the agent without touching the disable list, so the
    // agent can still auto-load on next login (unlike legacy `unload -w`).
    const status = runQuiet(allocator, io, &.{ "launchctl", "bootout", target }) catch return error.SpawnFailed;
    if (status != 0) return; // not running is fine
    std.debug.print("Service stopped\n", .{});
}

pub fn restartService(allocator: std.mem.Allocator, io: std.Io) !void {
    try stopService(allocator, io);
    // 1s pause so launchd fully tears down before re-register.
    std.Io.sleep(io, .fromSeconds(1), .awake) catch {};
    try startService(allocator, io);
}

pub fn reloadConfig(allocator: std.mem.Allocator, io: std.Io) !void {
    // Read PID file to find running instance
    const pid = try readPidFile(allocator, io) orelse {
        std.debug.print("skhd is not running (no PID file found)\n", .{});
        return error.NotRunning;
    };

    // Check if process is actually running
    if (!isProcessRunning(pid)) {
        std.debug.print("skhd is not running (PID {d} not found)\n", .{pid});
        removePidFile(allocator, io);
        return error.NotRunning;
    }

    // Send SIGUSR1 to reload config
    std.posix.kill(pid, std.posix.SIG.USR1) catch |err| {
        std.debug.print("Failed to send reload signal to PID {d}: {}\n", .{ pid, err });
        return error.SignalFailed;
    };

    std.debug.print("Sent reload signal to skhd (PID {d})\n", .{pid});
}

/// State of the LaunchAgent as known to launchd, from `launchctl list`.
const DaemonState = union(enum) {
    /// Agent isn't loaded into launchd at all (nobody ran --start-service or
    /// the plist isn't installed).
    not_loaded,
    /// Agent is loaded but currently not running — usually means it just
    /// exited and launchd is waiting for `ThrottleInterval` before respawning.
    loaded_idle,
    /// Agent is loaded and the daemon process is alive.
    running: i32,
};

fn getDaemonState(allocator: std.mem.Allocator, io: std.Io) DaemonState {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "launchctl", "list" },
    }) catch return .not_loaded;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (!std.mem.endsWith(u8, line, "\tcom.jackielii.skhd")) continue;
        // Format: "<PID-or-->\t<exit>\t<label>"
        var fields = std.mem.splitScalar(u8, line, '\t');
        const pid_str = fields.next() orelse return .loaded_idle;
        if (std.mem.eql(u8, pid_str, "-")) return .loaded_idle;
        const pid = std.fmt.parseInt(i32, pid_str, 10) catch return .loaded_idle;
        if (pid > 0) return .{ .running = pid };
        return .loaded_idle;
    }
    return .not_loaded;
}

const EventTapHealth = enum {
    /// No running daemon to query, or the CoreGraphics call itself failed
    /// — we genuinely can't tell.
    unknown,
    /// The daemon owns an event tap and it is enabled — events flow
    /// (modulo a separate Input Monitoring / TCC denial, checked below).
    working,
    /// The daemon owns a tap but it is currently disabled (e.g. the kernel
    /// disabled it on a timeout and the watchdog hasn't re-enabled it yet).
    disabled,
    /// The daemon is running but owns no event tap — tap creation failed,
    /// which on macOS means Accessibility is denied.
    denied,
};

/// Determine whether the daemon's event tap is currently active by asking
/// the window server directly via `CGGetEventTapList`, filtered to the
/// daemon's PID. This reads the *actual* live tap state rather than
/// inferring it from process uptime or scraping success/denial markers out
/// of the log — the old heuristic could never confirm success in a
/// ReleaseFast build (where `log.info` is suppressed) and reported
/// "unknown" for the first ~30s after every (re)start. The direct query
/// works identically across Debug / ReleaseSafe / ReleaseFast and has no
/// timing window.
///
/// Note: a tap reported `enabled` here can still have its events suppressed
/// by a stale Input Monitoring (kTCCServiceListenEvent) grant — that case
/// is surfaced separately by `checkInputMonitoringAccess`.
fn getEventTapHealth(allocator: std.mem.Allocator, daemon_state: DaemonState) EventTapHealth {
    const pid: c.pid_t = switch (daemon_state) {
        .running => |p| p,
        // Without a running daemon there's no tap to attribute; the caller
        // already reports the daemon as not running.
        else => return .unknown,
    };

    // First call with a null list just yields the current tap count.
    var count: u32 = 0;
    if (c.CGGetEventTapList(0, null, &count) != 0) return .unknown;
    if (count == 0) return .denied; // no taps at all → ours wasn't created

    const taps = allocator.alloc(c.CGEventTapInformation, count) catch return .unknown;
    defer allocator.free(taps);

    var written: u32 = count;
    if (c.CGGetEventTapList(count, taps.ptr, &written) != 0) return .unknown;

    var saw_tap_for_pid = false;
    for (taps[0..@min(written, count)]) |t| {
        if (t.tappingProcess == pid) {
            saw_tap_for_pid = true;
            if (t.enabled) return .working;
        }
    }
    return if (saw_tap_for_pid) .disabled else .denied;
}

pub fn checkServiceStatus(allocator: std.mem.Allocator, io: std.Io) !void {
    const daemon_state = getDaemonState(allocator, io);
    const tap_health = getEventTapHealth(allocator, daemon_state);

    // Determine SMAppService registration status. Don't use the legacy
    // ~/Library/LaunchAgents/<id>.plist file as a marker any more — that
    // path is empty for SMAppService-managed installs (our 0.0.21+ flow).
    const sm_service = sm.agentService(LAUNCH_AGENT_PLIST_NAME);
    const sm_status = if (sm_service) |svc| sm.status(svc) else sm.Status.not_found;
    const installed = sm_status != .not_registered and sm_status != .not_found;

    std.debug.print("skhd service status:\n", .{});

    // Versions of the two daemons. skhd's is this binary's own build
    // (== the running agent: same install path, and macOS won't let our
    // install flow swap a running binary's inode without stopping it
    // first). The grabber's is queried live over IPC (its hello-ok reply),
    // so it reflects the actually-running daemon, not the on-disk binary.
    const skhd_version = std.mem.trimEnd(u8, @embedFile("VERSION"), "\n\r\t ");
    const grabber_ver = grabber_cli.runningGrabberVersion(allocator, io);
    defer if (grabber_ver) |v| allocator.free(v);
    std.debug.print("  skhd version:         {s}\n", .{skhd_version});
    std.debug.print("  skhd-grabber version: {s}\n", .{grabber_ver orelse "not running"});

    std.debug.print("  Service installed:    {s}\n", .{if (installed) "Yes" else "No"});
    std.debug.print("  Registration status:  {s}\n", .{sm_status.describe()});

    switch (daemon_state) {
        .running => |pid| std.debug.print("  Daemon running:       Yes (PID {d})\n", .{pid}),
        .loaded_idle => std.debug.print("  Daemon running:       No (loaded, waiting for respawn — see log)\n", .{}),
        .not_loaded => std.debug.print("  Daemon running:       No (LaunchAgent not loaded)\n", .{}),
    }

    const tap_label = switch (tap_health) {
        .working => "Yes (event tap active)",
        .disabled => "No (event tap registered but disabled — try --restart-service)",
        .denied => "No (accessibility denied — see remediation below)",
        .unknown => "Unknown (daemon not running or window server unavailable)",
    };
    std.debug.print("  Hotkeys functional:   {s}\n", .{tap_label});

    // Input Monitoring is the smoking gun for the silent cdHash-mismatch
    // case: tap_health says working, daemon log shows no errors, but no
    // events flow because the kTCCServiceListenEvent grant's csreq is
    // anchored on a stale cdHash. IOHIDCheckAccess returns Denied for that
    // case. Surface it as a separate status line.
    const im_access = checkInputMonitoringAccess();
    const im_label = switch (im_access) {
        .granted => "Granted",
        .denied => "Denied (events suppressed — see remediation below)",
        .unknown => "Unknown (will prompt on first key event)",
    };
    std.debug.print("  Input Monitoring:     {s}\n", .{im_label});

    // Grabber: only surfaced when the user's config actually needs it
    // (block-form `.remap` / tap-hold rules targeting a connected device).
    // For configs that never use those, the grabber is irrelevant and we
    // stay quiet. Parse failures are swallowed — `--status` shouldn't error
    // out over a malformed config.
    if (grabber_cli.analyzeGrabberNeed(allocator, io)) |need| {
        switch (need) {
            .needed => |device_alias| {
                defer allocator.free(device_alias);
                grabber_cli.printGrabberStatusSummary(allocator, io, device_alias);
            },
            .no_rules, .no_device => {},
        }
    } else |_| {}

    // HID daemon (Karabiner-DriverKit-VirtualHIDDevice). Required by
    // skhd-grabber for .remap / .taphold rules. printHidDaemonStatus
    // emits its own line (and a Karabiner-Elements conflict warning when
    // detected) and returns the state so we can print remediation below.
    const hid_state = grabber_cli.printHidDaemonStatus(allocator, io);

    std.debug.print("  Log file:             {s}/Library/Logs/skhd.log\n", .{@import("utils.zig").getenv("HOME") orelse "~"});

    if (!installed) {
        std.debug.print("\nTo install the service, run: skhd --install-service\n", .{});
        std.debug.print("(must be invoked from inside the .app — typically via\n", .{});
        std.debug.print(" /Applications/skhd.app/Contents/MacOS/skhd --install-service)\n", .{});
    } else if (sm_status == .requires_approval) {
        std.debug.print("\nMacOS requires approval before the agent can run:\n", .{});
        std.debug.print("1. Open System Settings → General → Login Items & Extensions\n", .{});
        std.debug.print("2. Find 'skhd' under 'Allow in the Background' and toggle it on\n", .{});
        std.debug.print("3. Then run: skhd --restart-service\n", .{});
    } else if (daemon_state == .not_loaded) {
        std.debug.print("\nTo start the service, run: skhd --start-service\n", .{});
    } else if (tap_health == .denied) {
        std.debug.print("\nTo grant accessibility permissions:\n", .{});
        std.debug.print("1. Open System Settings → Privacy & Security → Accessibility\n", .{});
        std.debug.print("2. Click '+' and add /Applications/skhd.app (the .app shows\n", .{});
        std.debug.print("   up in the list, unlike a bare binary)\n", .{});
        std.debug.print("3. Toggle the entry on\n", .{});
        std.debug.print("4. Run: skhd --restart-service\n", .{});
        std.debug.print(
            \\
            \\If the entry already shows as granted in System Settings but
            \\events still don't flow (typical after `brew upgrade` on macOS
            \\Tahoe — the cached csreq is anchored to the previous binary's
            \\cdHash), drop the stale grant and re-grant from scratch:
            \\
            \\  tccutil reset ListenEvent com.jackielii.skhd
            \\  tccutil reset Accessibility com.jackielii.skhd
            \\  skhd --restart-service     # then re-grant via System Settings
            \\
            \\For more troubleshooting, see docs/CODE_SIGNING.md.
            \\
        , .{});
    } else if (im_access == .denied) {
        // Reached when Accessibility is fine and the daemon looks healthy
        // — but the IM grant's csreq is still stale (the most common
        // post-`brew upgrade` failure mode, and the one tap_health can't
        // see because the tap creates successfully).
        std.debug.print(
            \\
            \\Input Monitoring is denied for com.jackielii.skhd, so key-down
            \\events are silently dropped before reaching skhd's event tap.
            \\This usually means TCC's stored grant is anchored on a stale
            \\cdHash from a previous build (every brew upgrade / rebuild
            \\changes the cdHash). System Settings still shows it granted.
            \\
            \\Reset and re-grant:
            \\  tccutil reset ListenEvent com.jackielii.skhd
            \\  skhd --restart-service
            \\  # press any hotkey — macOS prompts for Input Monitoring; approve
            \\
            \\The fresh grant anchors on the cert root and survives future
            \\upgrades.
            \\
        , .{});
    }

    // HID daemon remediation runs after the agent-side chain so it
    // doesn't bury an Accessibility / IM problem the user has to fix
    // first. Only print it when the grabber is actually installed —
    // for users who never set up `.remap` / `.taphold`, "Not installed"
    // is an informational line, not an actionable problem.
    if (grabber_cli.isGrabberInstalled(io)) {
        if (hid_state != .running) {
            grabber_cli.printHidDaemonRemediation(hid_state);
        } else if (grabber_cli.readHidDaemonVersion(allocator, io)) |installed_dext| {
            defer allocator.free(installed_dext);
            const compat = grabber_cli.compareVersions(installed_dext, grabber_cli.pinned_dext_version);
            grabber_cli.printVersionMismatchRemediation(installed_dext, compat);
        }
    }
}

/// Run `argv` with stdio captured (to avoid noise in the terminal) and
/// return the exit code. Returns `-1` for signal-terminated or otherwise
/// non-`.exited` children; callers treat both negative and unknown terms
/// as failure.
fn runQuiet(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !i32 {
    const result = try std.process.run(allocator, io, .{ .argv = argv });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return switch (result.term) {
        .exited => |code| @intCast(code),
        else => -1,
    };
}

