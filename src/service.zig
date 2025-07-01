const std = @import("std");
const builtin = @import("builtin");

// Import C function
extern "c" fn getpid() c_int;

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
    \\    <string>/tmp/skhd_{s}.log</string>
    \\    <key>StandardErrorPath</key>
    \\    <string>/tmp/skhd_{s}.log</string>
    \\    <key>ThrottleInterval</key>
    \\    <integer>30</integer>
    \\    <key>ProcessType</key>
    \\    <string>Interactive</string>
    \\</dict>
    \\</plist>
    \\
;

pub fn getServicePath(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDirectory;
    return std.fmt.allocPrint(allocator, "{s}/Library/LaunchAgents/com.jackielii.skhd.plist", .{home});
}

pub fn installService(allocator: std.mem.Allocator) !void {
    const service_path = try getServicePath(allocator);
    defer allocator.free(service_path);

    // Get the current executable path
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);

    // Get PATH environment variable
    const path_env = std.posix.getenv("PATH") orelse "/usr/local/bin:/usr/bin:/bin";

    // Get username for log file
    const username = std.posix.getenv("USER") orelse "unknown";

    // Format the plist content
    const plist_content = try std.fmt.allocPrint(allocator, plist_template, .{
        exe_path,
        path_env,
        username,
        username,
    });
    defer allocator.free(plist_content);

    // Create LaunchAgents directory if it doesn't exist
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDirectory;
    const launch_agents_dir = try std.fmt.allocPrint(allocator, "{s}/Library/LaunchAgents", .{home});
    defer allocator.free(launch_agents_dir);

    std.fs.makeDirAbsolute(launch_agents_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Write the plist file
    const file = try std.fs.createFileAbsolute(service_path, .{});
    defer file.close();
    try file.writeAll(plist_content);

    std.debug.print("Service installed at: {s}\n", .{service_path});
    std.debug.print("To start the service, run: skhd --start-service\n", .{});
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
    const service_path = try getServicePath(allocator);
    defer allocator.free(service_path);

    const argv = [_][]const u8{ "launchctl", "load", "-w", service_path };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    try child.spawn();
    const term = try child.wait();

    if (term != .Exited or term.Exited != 0) {
        std.debug.print("Failed to start service. Make sure it's installed first.\n", .{});
        return error.ServiceStartFailed;
    }

    std.debug.print("Service started\n", .{});
}

pub fn stopService(allocator: std.mem.Allocator) !void {
    const service_path = try getServicePath(allocator);
    defer allocator.free(service_path);

    const argv = [_][]const u8{ "launchctl", "unload", "-w", service_path };
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
