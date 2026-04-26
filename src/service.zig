const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig");
const log = std.log.scoped(.service);

// Import C functions
extern "c" fn getpid() c_int;
extern "c" fn getuid() c_uint;

/// Check if the current process has accessibility permissions
pub fn hasAccessibilityPermissions() bool {
    // Use the official macOS API to check accessibility permissions
    // AXIsProcessTrusted() is the recommended way to check if the current
    // process has been granted accessibility permissions by the user
    return c.AXIsProcessTrusted() != 0;
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

/// Launchd plist template
const plist_template =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    \\<plist version="1.0">
    \\<dict>
    \\    <key>Label</key>
    \\    <string>com.jackielii.skhd</string>
    \\    <key>ProgramArguments</key>
    \\    <array>
    \\        <string>{s}</string>
    \\    </array>
    \\    <key>EnvironmentVariables</key>
    \\    <dict>
    \\        <key>PATH</key>
    \\        <string>{s}</string>
    \\    </dict>
    \\    <key>RunAtLoad</key>
    \\    <true/>
    \\    <key>KeepAlive</key>
    \\    <true/>
    \\    <key>StandardOutPath</key>
    \\    <string>{s}/Library/Logs/skhd.log</string>
    \\    <key>StandardErrorPath</key>
    \\    <string>{s}/Library/Logs/skhd.log</string>
    \\    <key>ThrottleInterval</key>
    \\    <integer>10</integer>
    \\    <key>ProcessType</key>
    \\    <string>Interactive</string>
    \\</dict>
    \\</plist>
    \\
;

/// Pick a path to recommend in error messages for the System Settings →
/// Accessibility picker. Tahoe's picker only accepts `.app` bundles, so we
/// prefer `/Applications/skhd.app` when present, fall back to the `.app`
/// inferred from a binary that lives inside a bundle, and finally return the
/// caller's path unchanged for bare-binary installs.
pub fn resolveBundlePath(allocator: std.mem.Allocator, exe_path: []const u8) ![]const u8 {
    const apps_path = "/Applications/skhd.app";
    if (std.fs.accessAbsolute(apps_path, .{})) |_| {
        return allocator.dupe(u8, apps_path);
    } else |_| {}

    const marker = ".app/Contents/MacOS/";
    if (std.mem.indexOf(u8, exe_path, marker)) |idx| {
        return allocator.dupe(u8, exe_path[0 .. idx + 4]); // keep ".app"
    }

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

/// Install or update the service plist file (silent version)
fn installOrUpdateService(allocator: std.mem.Allocator) !void {
    const service_path = try getServicePath(allocator);
    defer allocator.free(service_path);

    // Get the current executable path, then prefer a Homebrew-stable symlink
    // when available so the plist survives `brew upgrade` + `brew cleanup`.
    const raw_exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(raw_exe_path);
    const exe_path = try resolveStableExePath(allocator, raw_exe_path);
    defer allocator.free(exe_path);

    // Get PATH environment variable
    const path_env = std.posix.getenv("PATH") orelse "/usr/local/bin:/usr/bin:/bin";

    const home = std.posix.getenv("HOME") orelse return error.NoHomeDirectory;

    // Format the plist content
    const plist_content = try std.fmt.allocPrint(allocator, plist_template, .{
        exe_path,
        path_env,
        home,
        home,
    });
    defer allocator.free(plist_content);

    // Create LaunchAgents directory if it doesn't exist
    const launch_agents_dir = try std.fmt.allocPrint(allocator, "{s}/Library/LaunchAgents", .{home});
    defer allocator.free(launch_agents_dir);

    std.fs.makeDirAbsolute(launch_agents_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Ensure ~/Library/Logs exists so launchd can write Standard{Out,Error}Path
    const logs_dir = try std.fmt.allocPrint(allocator, "{s}/Library/Logs", .{home});
    defer allocator.free(logs_dir);

    std.fs.makeDirAbsolute(logs_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Write the plist file
    const file = try std.fs.createFileAbsolute(service_path, .{});
    defer file.close();
    try file.writeAll(plist_content);
}

pub fn installService(allocator: std.mem.Allocator) !void {
    // Use the helper function to do the actual installation
    try installOrUpdateService(allocator);

    const service_path = try getServicePath(allocator);
    defer allocator.free(service_path);

    std.debug.print("Service installed at: {s}\n", .{service_path});
    std.debug.print("\nNext steps:\n", .{});
    std.debug.print("1. Grant accessibility permissions to skhd in System Settings\n", .{});
    std.debug.print("2. Run: skhd --start-service\n", .{});
    std.debug.print("\nNote: The service will start automatically on login once enabled.\n", .{});
}

pub fn uninstallService(allocator: std.mem.Allocator) !void {
    const service_path = try getServicePath(allocator);
    defer allocator.free(service_path);

    // First try to stop the service
    stopService(allocator) catch {};

    // Remove the plist file
    std.fs.deleteFileAbsolute(service_path) catch |err| {
        if (err != error.FileNotFound) return err;
    };

    std.debug.print("Service uninstalled\n", .{});
}

pub fn startService(allocator: std.mem.Allocator) !void {
    // Always install/update the service first to ensure it's up to date
    try installOrUpdateService(allocator);

    const service_path = try getServicePath(allocator);
    defer allocator.free(service_path);

    const uid = getuid();
    const target = try std.fmt.allocPrint(allocator, "gui/{d}/com.jackielii.skhd", .{uid});
    defer allocator.free(target);
    const domain = try std.fmt.allocPrint(allocator, "gui/{d}", .{uid});
    defer allocator.free(domain);

    // Clear any persistent disable flag. Older versions of skhd used
    // `launchctl unload -w` for --stop-service, which writes a flag to the
    // disable list that survives reboot — so on the next login launchd
    // refuses to auto-load the agent even with RunAtLoad=true. `enable` is
    // idempotent and a no-op when the agent isn't disabled.
    {
        const enable_argv = [_][]const u8{ "launchctl", "enable", target };
        var enable_child = std.process.Child.init(&enable_argv, allocator);
        enable_child.stdout_behavior = .Ignore;
        enable_child.stderr_behavior = .Ignore;
        enable_child.spawn() catch {};
        _ = enable_child.wait() catch {};
    }

    const argv = [_][]const u8{ "launchctl", "bootstrap", domain, service_path };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // Collect stderr to show any launchctl errors
    var stderr_data = std.ArrayList(u8).init(allocator);
    defer stderr_data.deinit();

    if (child.stderr) |stderr| {
        try stderr.reader().readAllArrayList(&stderr_data, 8192);
    }

    const term = try child.wait();

    if (term != .Exited or term.Exited != 0) {
        // bootstrap returns errno 17 (EEXIST, "File exists") or 37
        // ("Operation already in progress") when the agent is already
        // loaded. Both are no-ops for --start-service.
        const already_loaded = std.mem.indexOf(u8, stderr_data.items, "File exists") != null or
            std.mem.indexOf(u8, stderr_data.items, "already in progress") != null;
        if (!already_loaded) {
            if (stderr_data.items.len > 0) {
                std.debug.print("Failed to start service: {s}\n", .{stderr_data.items});
            } else {
                std.debug.print("Failed to start service. Check ~/Library/Logs/skhd.log for details.\n", .{});
            }
            return error.ServiceStartFailed;
        }
    }

    std.debug.print("Service started successfully.\n", .{});
    std.debug.print("Check logs at: {s}/Library/Logs/skhd.log\n", .{std.posix.getenv("HOME") orelse "~"});
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

/// Look at the tail of the daemon's log file to determine whether the most
/// recent event-tap attempt succeeded. This is the only reliable way to
/// answer "does the daemon actually have accessibility right now?" from the
/// CLI: AXIsProcessTrusted() in a CLI process reports the *terminal's*
/// trust state, not skhd's, because the CLI is the responsible process.
fn getEventTapHealth(allocator: std.mem.Allocator) EventTapHealth {
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
    const service_path = try getServicePath(allocator);
    defer allocator.free(service_path);

    const service_installed = blk: {
        std.fs.accessAbsolute(service_path, .{}) catch break :blk false;
        break :blk true;
    };

    const daemon_state = getDaemonState(allocator);
    const tap_health = getEventTapHealth(allocator);

    std.debug.print("skhd service status:\n", .{});
    std.debug.print("  Service installed:    {s}\n", .{if (service_installed) "Yes" else "No"});

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

    if (service_installed) {
        std.debug.print("  Service path:         {s}\n", .{service_path});
        std.debug.print("  Log file:             {s}/Library/Logs/skhd.log\n", .{std.posix.getenv("HOME") orelse "~"});
    }

    if (!service_installed) {
        std.debug.print("\nTo install the service, run: skhd --install-service\n", .{});
    } else if (daemon_state == .not_loaded) {
        std.debug.print("\nTo start the service, run: skhd --start-service\n", .{});
    } else if (tap_health == .denied) {
        std.debug.print("\nTo grant accessibility permissions:\n", .{});
        std.debug.print("1. Open System Settings → Privacy & Security → Accessibility\n", .{});
        std.debug.print("2. Add /Applications/skhd.app and enable it\n", .{});
        std.debug.print("3. Run: skhd --restart-service\n", .{});
        std.debug.print("\nIf the picker won't accept the .app, see docs/CODE_SIGNING.md.\n", .{});
    }
}
