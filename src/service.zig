const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig");
const sm = @import("sm_app_service.zig");
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

/// PID file management
pub fn writePidFile(allocator: std.mem.Allocator) !void {
    const username = std.posix.getenv("USER") orelse "unknown";
    const pid_path = try std.fmt.allocPrint(allocator, "/tmp/skhd_{s}.pid", .{username});
    defer allocator.free(pid_path);

    const pid = @as(i32, @intCast(getpid()));
    const pid_str = try std.fmt.allocPrint(allocator, "{d}\n", .{pid});
    defer allocator.free(pid_str);

    const file = try std.fs.createFileAbsolute(pid_path, .{ .truncate = true });
    defer file.close();

    try file.writeAll(pid_str);
}

pub fn removePidFile(allocator: std.mem.Allocator) void {
    const username = std.posix.getenv("USER") orelse "unknown";
    const pid_path = std.fmt.allocPrint(allocator, "/tmp/skhd_{s}.pid", .{username}) catch return;
    defer allocator.free(pid_path);

    std.fs.deleteFileAbsolute(pid_path) catch {};
}

pub fn readPidFile(allocator: std.mem.Allocator) !?i32 {
    const username = std.posix.getenv("USER") orelse "unknown";
    const pid_path = try std.fmt.allocPrint(allocator, "/tmp/skhd_{s}.pid", .{username});
    defer allocator.free(pid_path);

    const file = std.fs.openFileAbsolute(pid_path, .{}) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 256);
    defer allocator.free(content);

    const trimmed = std.mem.trim(u8, content, " \n\r\t");
    return std.fmt.parseInt(i32, trimmed, 10) catch null;
}

/// Check if a process with given PID is running
pub fn isProcessRunning(pid: i32) bool {
    // On macOS/Unix, we can check if a process exists by sending signal 0
    std.posix.kill(pid, 0) catch |err| {
        // If we get permission denied, the process exists but we can't signal it
        return err == error.PermissionDenied;
    };
    return true;
}

/// Pick a path to recommend in error messages for the System Settings →
/// Accessibility picker. Tahoe's picker only accepts `.app` bundles, and TCC
/// keys entries by the running process's signature — so we prefer the `.app`
/// that actually contains the running binary, since that's the one a grant
/// would apply to. Only fall back to `/Applications/skhd.app` when the running
/// process is bare (e.g. cellar binary), in which case adding the prod bundle
/// is the right pointer for the install.
pub fn resolveBundlePath(allocator: std.mem.Allocator, exe_path: []const u8) ![]const u8 {
    const marker = ".app/Contents/MacOS/";
    if (std.mem.indexOf(u8, exe_path, marker)) |idx| {
        return allocator.dupe(u8, exe_path[0 .. idx + 4]); // keep ".app"
    }

    const apps_path = "/Applications/skhd.app";
    if (std.fs.accessAbsolute(apps_path, .{})) |_| {
        return allocator.dupe(u8, apps_path);
    } else |_| {}

    return allocator.dupe(u8, exe_path);
}

/// Resolve a Homebrew Cellar path (e.g. /opt/homebrew/Cellar/skhd-zig/0.0.15/bin/skhd)
/// to its stable opt symlink (/opt/homebrew/opt/skhd-zig/bin/skhd) so the plist
/// keeps working across `brew upgrade` + `brew cleanup`. Returns the input
/// unchanged when no stable equivalent exists.
pub fn resolveStableExePath(allocator: std.mem.Allocator, exe_path: []const u8) ![]const u8 {
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

    std.fs.accessAbsolute(candidate, .{}) catch {
        allocator.free(candidate);
        return allocator.dupe(u8, exe_path);
    };
    return candidate;
}

pub fn getServicePath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDirectory;
    return std.fmt.allocPrint(allocator, "{s}/Library/LaunchAgents/com.jackielii.skhd.plist", .{home});
}


/// Register the bundled LaunchAgent with macOS Background Tasks Manager via
/// SMAppService and clean up any pre-0.0.21 plist installed at
/// ~/Library/LaunchAgents/. With the SMAppService flow, BTM auto-tracks the
/// agent so it actually auto-starts at login (the legacy hand-installed
/// plist is silently disallowed by BTM on Sequoia/Tahoe — that's the
/// "skhd doesn't always start after reboot" bug at its root).
pub fn installService(allocator: std.mem.Allocator) !void {
    cleanupLegacyInstall(allocator);
    try registerWithBTM();
}

pub fn uninstallService(allocator: std.mem.Allocator) !void {
    cleanupLegacyInstall(allocator);

    const service = sm.agentService(LAUNCH_AGENT_PLIST_NAME) orelse {
        std.debug.print("SMAppService unavailable; nothing to unregister.\n", .{});
        return;
    };
    sm.unregister(service) catch |err| {
        // unregister fails if the service was never registered — treat as success.
        log.info("Unregister returned: {}", .{err});
    };
    std.debug.print("Service unregistered.\n", .{});
}

pub fn startService(allocator: std.mem.Allocator) !void {
    _ = allocator;
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
    std.debug.print("Logs: {s}/Library/Logs/skhd.log\n", .{std.posix.getenv("HOME") orelse "~"});

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
fn cleanupLegacyInstall(allocator: std.mem.Allocator) void {
    const service_path = getServicePath(allocator) catch return;
    defer allocator.free(service_path);

    std.fs.accessAbsolute(service_path, .{}) catch return;

    log.info("Found legacy plist at {s}, cleaning up.", .{service_path});

    // Bootout from launchd (no-op if not loaded).
    const uid = getuid();
    const target = std.fmt.allocPrint(allocator, "gui/{d}/{s}", .{ uid, BUNDLE_ID }) catch return;
    defer allocator.free(target);
    {
        const argv = [_][]const u8{ "launchctl", "bootout", target };
        var child = std.process.Child.init(&argv, allocator);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.spawn() catch {};
        _ = child.wait() catch {};
    }

    // Older code wrote a persistent `disable` flag via `unload -w` — clear
    // it so a future register isn't silently blocked.
    {
        const argv = [_][]const u8{ "launchctl", "enable", target };
        var child = std.process.Child.init(&argv, allocator);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.spawn() catch {};
        _ = child.wait() catch {};
    }

    std.fs.deleteFileAbsolute(service_path) catch {};
}

pub fn stopService(allocator: std.mem.Allocator) !void {
    const uid = getuid();
    const target = try std.fmt.allocPrint(allocator, "gui/{d}/com.jackielii.skhd", .{uid});
    defer allocator.free(target);

    // bootout unloads the agent without touching the disable list, so the
    // agent can still auto-load on next login (unlike legacy `unload -w`).
    const argv = [_][]const u8{ "launchctl", "bootout", target };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    try child.spawn();
    const term = try child.wait();

    if (term != .Exited or term.Exited != 0) {
        // Service might not be running, which is okay
        return;
    }

    std.debug.print("Service stopped\n", .{});
}

pub fn restartService(allocator: std.mem.Allocator) !void {
    try stopService(allocator);
    // Small delay to ensure service is fully stopped
    std.time.sleep(1 * std.time.ns_per_s);
    try startService(allocator);
}

pub fn reloadConfig(allocator: std.mem.Allocator) !void {
    // Read PID file to find running instance
    const pid = try readPidFile(allocator) orelse {
        std.debug.print("skhd is not running (no PID file found)\n", .{});
        return error.NotRunning;
    };

    // Check if process is actually running
    if (!isProcessRunning(pid)) {
        std.debug.print("skhd is not running (PID {d} not found)\n", .{pid});
        removePidFile(allocator);
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

fn getDaemonState(allocator: std.mem.Allocator) DaemonState {
    const argv = [_][]const u8{ "launchctl", "list" };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return .not_loaded;

    var stdout_data = std.ArrayList(u8).init(allocator);
    defer stdout_data.deinit();
    if (child.stdout) |stdout| {
        stdout.reader().readAllArrayList(&stdout_data, 1 << 20) catch return .not_loaded;
    }
    _ = child.wait() catch return .not_loaded;

    var lines = std.mem.splitScalar(u8, stdout_data.items, '\n');
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

const EventTapHealth = enum { unknown, working, denied };

/// Darwin sysctl MIB to fetch a single process's kinfo_proc.
/// Equivalent to: `int mib[] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };`
const CTL_KERN: c_int = 1;
const KERN_PROC: c_int = 14;
const KERN_PROC_PID: c_int = 1;

/// Get the running process's uptime in seconds via the darwin sysctl
/// `kern.proc.pid.<pid>` interface. The first 8 bytes of `struct
/// kinfo_proc` are `kp_proc.p_un.__p_starttime.tv_sec` (this layout has
/// been stable across macOS versions). Avoids spawning `ps`. Returns
/// null if the process isn't reachable or the call fails.
fn getProcessUptimeSeconds(pid: i32) ?u64 {
    var mib = [_]c_int{ CTL_KERN, KERN_PROC, KERN_PROC_PID, @intCast(pid) };

    // kinfo_proc is ~656 bytes on macOS — 1 KiB stack buffer is plenty.
    var buf: [1024]u8 = undefined;
    var size: usize = buf.len;
    if (std.c.sysctl(&mib, mib.len, &buf, &size, null, 0) != 0) return null;
    if (size < @sizeOf(i64)) return null;

    const tv_sec = std.mem.readInt(i64, buf[0..@sizeOf(i64)], .little);
    if (tv_sec <= 0) return null;

    const now = std.time.timestamp();
    if (now < tv_sec) return null;
    return @intCast(now - tv_sec);
}

/// Determine whether the daemon's event tap is currently active. Two signals
/// in priority order:
///
/// 1. **Process uptime.** With `KeepAlive=true` and `ThrottleInterval=10`,
///    a daemon that fails event-tap creation exits within ~5s (10 retries
///    × 500ms) and is respawned 10s later — so a daemon that has been
///    alive for >30s necessarily has a working event tap. This is the
///    primary signal: it works for any build mode without relying on the
///    daemon emitting success messages (we deliberately keep the log
///    quiet on the happy path).
/// 2. **Log tail fallback** for daemons too young for #1 to be conclusive,
///    or when the daemon is loaded but currently in the throttle window.
///    Recent "ACCESSIBILITY PERMISSIONS REQUIRED" / "Event tap creation
///    failed" entries point to denial. Success-side patterns are also
///    matched for Debug/ReleaseSafe builds where `log.info` reaches the
///    file.
fn getEventTapHealth(allocator: std.mem.Allocator, daemon_state: DaemonState) EventTapHealth {
    if (daemon_state == .running) {
        if (getProcessUptimeSeconds(daemon_state.running)) |uptime| {
            if (uptime >= 30) return .working;
        }
    }

    const home = std.posix.getenv("HOME") orelse return .unknown;
    const log_path = std.fmt.allocPrint(allocator, "{s}/Library/Logs/skhd.log", .{home}) catch return .unknown;
    defer allocator.free(log_path);

    const file = std.fs.openFileAbsolute(log_path, .{}) catch return .unknown;
    defer file.close();

    const stat = file.stat() catch return .unknown;
    const tail_size: u64 = 8192;
    if (stat.size == 0) return .unknown;
    const start: u64 = if (stat.size > tail_size) stat.size - tail_size else 0;
    file.seekTo(start) catch return .unknown;

    const content = file.readToEndAlloc(allocator, tail_size) catch return .unknown;
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var last: EventTapHealth = .unknown;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "Event tap created successfully") != null or
            std.mem.indexOf(u8, line, "Event tap created on attempt") != null)
        {
            last = .working;
        } else if (std.mem.indexOf(u8, line, "ACCESSIBILITY PERMISSIONS REQUIRED") != null or
            std.mem.indexOf(u8, line, "Event tap creation failed") != null)
        {
            last = .denied;
        }
    }
    return last;
}

pub fn checkServiceStatus(allocator: std.mem.Allocator) !void {
    const daemon_state = getDaemonState(allocator);
    const tap_health = getEventTapHealth(allocator, daemon_state);

    // Determine SMAppService registration status. Don't use the legacy
    // ~/Library/LaunchAgents/<id>.plist file as a marker any more — that
    // path is empty for SMAppService-managed installs (our 0.0.21+ flow).
    const sm_service = sm.agentService(LAUNCH_AGENT_PLIST_NAME);
    const sm_status = if (sm_service) |svc| sm.status(svc) else sm.Status.not_found;
    const installed = sm_status != .not_registered and sm_status != .not_found;

    std.debug.print("skhd service status:\n", .{});
    std.debug.print("  Service installed:    {s}\n", .{if (installed) "Yes" else "No"});
    std.debug.print("  Registration status:  {s}\n", .{sm_status.describe()});

    switch (daemon_state) {
        .running => |pid| std.debug.print("  Daemon running:       Yes (PID {d})\n", .{pid}),
        .loaded_idle => std.debug.print("  Daemon running:       No (loaded, waiting for respawn — see log)\n", .{}),
        .not_loaded => std.debug.print("  Daemon running:       No (LaunchAgent not loaded)\n", .{}),
    }

    const tap_label = switch (tap_health) {
        .working => "Yes (event tap active)",
        .denied => "No (accessibility denied — see remediation below)",
        .unknown => "Unknown (no recent event-tap activity in log)",
    };
    std.debug.print("  Hotkeys functional:   {s}\n", .{tap_label});
    std.debug.print("  Log file:             {s}/Library/Logs/skhd.log\n", .{std.posix.getenv("HOME") orelse "~"});

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
        std.debug.print("\nFor more troubleshooting, see docs/CODE_SIGNING.md.\n", .{});
    }
}

